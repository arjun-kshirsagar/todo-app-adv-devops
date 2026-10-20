# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------- build stage
# Installs dependencies into a virtualenv. Nothing from this stage except the
# venv reaches the final image (no compilers, caches or build metadata).
# Same base image in both stages so the venv's interpreter matches at runtime.
FROM python:3.15-slim-trixie AS build

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
    # pip is not needed at runtime; removing it shrinks the attack surface.
    && pip uninstall -y pip

# ---------------------------------------------------------------- runtime stage
FROM python:3.15-slim-trixie AS runtime

# Build metadata, passed by CI. Baked into the image so the running container
# can report exactly which commit it was built from (/version endpoint).
ARG GIT_SHA=unknown
ARG APP_VERSION=dev
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="todo-app" \
      org.opencontainers.image.description="Todo list API and web UI" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}"

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    GIT_SHA="${GIT_SHA}" \
    APP_VERSION="${APP_VERSION}" \
    BUILD_DATE="${BUILD_DATE}"

# Remove pip from the system interpreter too, then create an unprivileged user
# with a fixed numeric UID so Kubernetes can enforce runAsNonRoot.
RUN python -m pip uninstall -y pip \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=build /opt/venv /opt/venv
WORKDIR /srv
# Code is owned by root and only readable by the app user: a compromised
# process cannot modify its own code.
COPY --chown=root:root app ./app

USER 10001:10001
EXPOSE 8000

# Exec form so uvicorn is PID 1 and receives SIGTERM directly for graceful shutdown.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--no-server-header", "--timeout-graceful-shutdown", "20"]
