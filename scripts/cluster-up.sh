#!/usr/bin/env bash
# Create the local kind cluster and the platform pieces the app relies on:
# metrics-server (HPA), kube-prometheus-stack (metrics, alerts, Grafana) and
# Jaeger (traces). Idempotent: safe to re-run.
#
#   scripts/cluster-up.sh                 # full local setup
#   SKIP_KIND=1 scripts/cluster-up.sh     # cluster already exists (CI)
#   SKIP_GRAFANA=1 SKIP_JAEGER=1 ...      # lighter install
source "$(dirname "$0")/lib.sh"
need kubectl helm

if [[ -z "${SKIP_KIND:-}" ]]; then
  need kind docker
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    log "kind cluster '$CLUSTER' already exists"
  else
    log "creating kind cluster '$CLUSTER'"
    kind create cluster --name "$CLUSTER" --config "$ROOT/deploy/kind/cluster.yaml" --wait 120s
  fi
fi

log "adding helm repositories"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
helm repo update >/dev/null

log "installing metrics-server (needed by the HorizontalPodAutoscaler)"
# kind kubelets use self-signed serving certs, hence --kubelet-insecure-tls (local only).
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system --version "$METRICS_SERVER_VERSION" \
  --set 'args={--kubelet-insecure-tls}' --wait --timeout 5m

log "installing kube-prometheus-stack $KPS_VERSION"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  # Random admin password, stored only in the cluster.
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -hex 16)" >/dev/null
fi
extra=()
[[ -n "${SKIP_GRAFANA:-}" ]] && extra+=(--set grafana.enabled=false)
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace monitoring --version "$KPS_VERSION" \
  -f "$ROOT/deploy/observability/kube-prometheus-stack.values.yaml" ${extra[@]+"${extra[@]}"} \
  --wait --timeout 10m

if [[ -z "${SKIP_JAEGER:-}" ]]; then
  log "installing Jaeger"
  kubectl apply -f "$ROOT/deploy/observability/jaeger.yaml" >/dev/null
  kubectl -n observability rollout status deploy/jaeger --timeout 180s
fi

log "platform ready"
cat <<MSG
  Prometheus:   http://127.0.0.1:9090
  Alertmanager: http://127.0.0.1:9093
  Grafana:      http://127.0.0.1:3000   (user: admin, password:
                kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
  Jaeger:       http://127.0.0.1:16686
Next: scripts/deploy.sh --build
MSG
