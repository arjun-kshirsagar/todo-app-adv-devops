"""Logs, metrics and traces.

* Logs: one JSON object per line on stdout, carrying request_id and trace_id
  so a log line can be matched to a trace and to a user report.
* Metrics: Prometheus RED metrics (rate, errors, duration) per route
  template, plus business counters. Route templates (``/api/todos/{todo_id}``)
  are used instead of raw paths to keep label cardinality bounded.
* Traces: OpenTelemetry, exported over OTLP/HTTP only when
  OTEL_EXPORTER_OTLP_ENDPOINT is set. FastAPI and SQLAlchemy are
  auto-instrumented so each request shows its database spans.
"""

import json
import logging
import sys
import time
import uuid
from datetime import UTC, datetime

from prometheus_client import Counter, Gauge, Histogram
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

from app import config

# ---------------------------------------------------------------- metrics

HTTP_REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests by method, route template and status code.",
    ["method", "route", "status"],
)
HTTP_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency by method and route template.",
    ["method", "route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.3, 0.5, 1.0, 2.5, 5.0),
)
HTTP_IN_FLIGHT = Gauge("http_requests_in_flight", "Requests currently being served.")
TODO_OPERATIONS = Counter(
    "todo_operations_total",
    "Todo operations by type and outcome.",
    ["operation", "outcome"],
)
DB_UP = Gauge("todo_db_up", "1 if the last readiness check reached the database, else 0.")
BUILD_INFO = Gauge(
    "todo_app_build_info",
    "Always 1; labels identify the running build.",
    ["version", "git_sha"],
)
BUILD_INFO.labels(version=config.APP_VERSION, git_sha=config.GIT_SHA).set(1)

# Paths excluded from request logging (probe/scrape noise). They are still counted.
QUIET_PATHS = {"/healthz", "/readyz", "/metrics"}


# ---------------------------------------------------------------- logging

_RESERVED = set(logging.makeLogRecord({}).__dict__) | {"message", "asctime", "color_message"}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
            "version": config.APP_VERSION,
        }
        trace_id = _current_trace_id()
        if trace_id:
            payload["trace_id"] = trace_id
        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def setup_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(config.LOG_LEVEL)
    # Route uvicorn's own server logs through the same JSON formatter.
    for name in ("uvicorn", "uvicorn.error"):
        uv = logging.getLogger(name)
        uv.handlers[:] = []
        uv.propagate = True
    # Our middleware writes one structured access line per request instead.
    logging.getLogger("uvicorn.access").disabled = True


# ---------------------------------------------------------------- tracing


def _current_trace_id() -> str | None:
    try:
        from opentelemetry import trace

        ctx = trace.get_current_span().get_span_context()
        return format(ctx.trace_id, "032x") if ctx.is_valid else None
    except Exception:  # noqa: BLE001
        return None


def setup_tracing(app, engine) -> bool:
    if not config.OTEL_ENDPOINT:
        return False

    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    resource = Resource.create({"service.name": config.APP_NAME, "service.version": config.APP_VERSION})
    provider = TracerProvider(resource=resource)
    # Endpoint and protocol are read from the standard OTEL_* variables.
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)

    FastAPIInstrumentor.instrument_app(app, excluded_urls="healthz,readyz,metrics")
    SQLAlchemyInstrumentor().instrument(engine=engine)
    return True


# ---------------------------------------------------------------- middleware


class RequestMiddleware(BaseHTTPMiddleware):
    """Assigns a request id, records RED metrics and writes an access log line."""

    async def dispatch(self, request: Request, call_next):
        request_id = request.headers.get("x-request-id") or uuid.uuid4().hex
        start = time.perf_counter()
        HTTP_IN_FLIGHT.inc()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            response.headers["x-request-id"] = request_id
            response.headers["x-app-version"] = config.APP_VERSION
            return response
        finally:
            HTTP_IN_FLIGHT.dec()
            elapsed = time.perf_counter() - start
            route = request.scope.get("route")
            # Unmatched paths share one label value to bound cardinality.
            template = getattr(route, "path", "unmatched")
            HTTP_REQUESTS.labels(request.method, template, str(status)).inc()
            HTTP_LATENCY.labels(request.method, template).observe(elapsed)
            if request.url.path not in QUIET_PATHS:
                logging.getLogger("app.access").info(
                    "request",
                    extra={
                        "request_id": request_id,
                        "method": request.method,
                        "path": request.url.path,
                        "route": template,
                        "status": status,
                        "duration_ms": round(elapsed * 1000, 2),
                    },
                )
