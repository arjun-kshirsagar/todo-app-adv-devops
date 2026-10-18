# Shared helpers for the scripts in this directory. Source, don't execute.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$ROOT/deploy/helm/todo-app"
CLUSTER="${CLUSTER:-todo}"
NS="${NS:-todo}"
RELEASE="${RELEASE:-todo}"
ENV_NAME="${ENV_NAME:-local}"            # local | ci  -> values-<env>.yaml
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/arjun-kshirsagar/todo-app-adv-devops}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
KPS_VERSION="${KPS_VERSION:-92.10.1}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-3.13.0}"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*"; exit 1; }

need() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || fail "'$bin' is required but not installed"
  done
}

# Helm 4 renamed --atomic to --rollback-on-failure; support both.
helm_atomic_flags() {
  if helm version --short 2>/dev/null | grep -q '^v3'; then
    echo "--atomic --wait"
  else
    echo "--rollback-on-failure --wait=watcher"
  fi
}

# Run a command against the API through a temporary port-forward when the
# NodePort is not reachable (CI). Sets BASE_URL for the caller.
ensure_base_url() {
  if curl -fsS -m 2 "$BASE_URL/healthz" >/dev/null 2>&1; then
    return
  fi
  log "NodePort not reachable, starting port-forward to svc/$RELEASE"
  kubectl -n "$NS" port-forward "svc/$RELEASE" 8080:80 >/tmp/todo-port-forward.log 2>&1 &
  PF_PID=$!
  trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
  for _ in $(seq 1 30); do
    curl -fsS -m 2 "$BASE_URL/healthz" >/dev/null 2>&1 && return
    sleep 1
  done
  fail "API not reachable at $BASE_URL"
}

# Query Prometheus (via a port-forward to the operator-managed service).
prom_query() {
  local q="$1"
  curl -fsS -m 10 --get "http://127.0.0.1:${PROM_PORT:-19090}/api/v1/query" --data-urlencode "query=$q"
}

start_prom_forward() {
  kubectl -n monitoring port-forward svc/prometheus-operated "${PROM_PORT:-19090}:9090" >/tmp/todo-prom-forward.log 2>&1 &
  PROM_PF_PID=$!
  for _ in $(seq 1 30); do
    curl -fsS -m 2 "http://127.0.0.1:${PROM_PORT:-19090}/-/ready" >/dev/null 2>&1 && return
    sleep 1
  done
  fail "Prometheus not reachable"
}
