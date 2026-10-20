"""Runtime configuration, read once from environment variables.

Everything environment-specific (database location, credentials, version,
telemetry endpoints) comes from the environment so the same image runs
unchanged on a laptop, in CI and on Kubernetes.
"""

import os

from sqlalchemy.engine import URL


def _env(name: str, default: str | None = None) -> str | None:
    value = os.getenv(name)
    return value if value not in (None, "") else default


APP_NAME = _env("APP_NAME", "todo-app")
# Injected at image build time (see Dockerfile); "dev" when running from source.
APP_VERSION = _env("APP_VERSION", "dev")
GIT_SHA = _env("GIT_SHA", "unknown")
BUILD_DATE = _env("BUILD_DATE", "unknown")
LOG_LEVEL = _env("LOG_LEVEL", "INFO")

# Tracing is only switched on when an OTLP endpoint is configured.
OTEL_ENDPOINT = _env("OTEL_EXPORTER_OTLP_ENDPOINT")


def database_url() -> str | URL:
    """Return the database URL.

    Precedence:
      1. DATABASE_URL (full URL; convenient for local development and tests)
      2. DB_HOST + DB_USER + DB_PASSWORD (+ DB_PORT, DB_NAME): used on
         Kubernetes, where the password comes from a Secret and must not be
         pasted into a URL by hand. URL.create escapes special characters.
      3. Local SQLite file.
    """
    explicit = _env("DATABASE_URL")
    if explicit:
        return explicit

    host = _env("DB_HOST")
    if host:
        return URL.create(
            drivername="postgresql+psycopg",
            username=_env("DB_USER", "todo"),
            password=_env("DB_PASSWORD"),
            host=host,
            port=int(_env("DB_PORT", "5432")),
            database=_env("DB_NAME", "todos"),
        )

    return "sqlite:///./todos.db"
