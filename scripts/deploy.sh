#!/usr/bin/env bash
# Deploy (or upgrade) the todo app with Helm.
#
#   scripts/deploy.sh --tag <git-sha>   # deploy the image CI built and pushed for that commit
#   scripts/deploy.sh --build           # build the current checkout locally and load it into kind
#
# The image tag is always a full git SHA, so the running version maps to
# exactly one commit. The upgrade is atomic: if the new pods do not become
# ready, Helm rolls the release back automatically.
source "$(dirname "$0")/lib.sh"
need kubectl helm

TAG=""
BUILD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --build) BUILD=1; shift ;;
    --env) ENV_NAME="$2"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

if [[ -n "$BUILD" ]]; then
  need docker kind git
  TAG="${TAG:-$(git -C "$ROOT" rev-parse HEAD)}"
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    log "warning: working tree has uncommitted changes; image $TAG will not match the commit exactly"
  fi
  log "building $IMAGE_REPO:$TAG"
  docker build -t "$IMAGE_REPO:$TAG" \
    --build-arg GIT_SHA="$TAG" \
    --build-arg APP_VERSION="$TAG" \
    --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$ROOT"
  kind load docker-image "$IMAGE_REPO:$TAG" --name "$CLUSTER"
fi
[[ -n "$TAG" ]] || fail "pass --tag <git-sha> or --build"

log "preparing namespace '$NS' (Pod Security Standard: restricted)"
kubectl apply -f - >/dev/null <<NSYAML
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
NSYAML

if ! kubectl -n "$NS" get secret todo-db-credentials >/dev/null 2>&1; then
  log "creating database credentials Secret (random password, never written to disk)"
  kubectl -n "$NS" create secret generic todo-db-credentials \
    --from-literal=username=todo \
    --from-literal=password="$(openssl rand -hex 24)" >/dev/null
fi

log "helm upgrade --install $RELEASE (image tag $TAG, env $ENV_NAME)"
# shellcheck disable=SC2046
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NS" \
  -f "$CHART/values.yaml" -f "$CHART/values-$ENV_NAME.yaml" \
  --set image.repository="$IMAGE_REPO" \
  --set image.tag="$TAG" \
  $(helm_atomic_flags) --timeout "${HELM_TIMEOUT:-6m}"

kubectl -n "$NS" rollout status "deploy/$RELEASE" --timeout 120s
log "deployed:"
helm -n "$NS" history "$RELEASE" --max 3
kubectl -n "$NS" get deploy "$RELEASE" -o jsonpath='  image: {.spec.template.spec.containers[0].image}{"\n"}'
