#!/usr/bin/env bash
# Capture a point-in-time evidence bundle that ties source -> image -> running
# pods -> a working request, for the deployed version.
# Contains no secrets: Secret objects are listed by name only.
#
#   scripts/collect-evidence.sh [output-dir]
source "$(dirname "$0")/lib.sh"
need kubectl helm curl
ensure_base_url
tag="$(helm -n "$NS" get values "$RELEASE" -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["image"]["tag"])')"
OUT="${1:-$ROOT/evidence/$tag}"
mkdir -p "$OUT"
log "writing evidence for $tag to $OUT"

{
  echo "# Evidence bundle"
  echo
  echo "Captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## Source"
  echo '```'
  git -C "$ROOT" log -1 --format='commit %H%nauthor %an%ndate   %cI%n%n    %s' "$tag" 2>/dev/null || echo "commit $tag (not in local checkout)"
  echo '```'
  echo "## Release (Helm)"
  echo '```'
  helm -n "$NS" history "$RELEASE" --max 10
  echo '```'
  echo "## Runtime"
  echo '```'
  kubectl -n "$NS" get deploy,sts,svc,hpa,pdb,netpol,pvc -o wide
  echo
  kubectl -n "$NS" get pods -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,IMAGE:.spec.containers[0].image,VERSION-LABEL:.metadata.labels.app\.kubernetes\.io/version'
  echo
  echo "image digests actually running:"
  kubectl -n "$NS" get pods -l app.kubernetes.io/component=api -o jsonpath='{range .items[*]}  {.metadata.name}: {.status.containerStatuses[0].imageID}{"\n"}{end}'
  echo
  echo "secrets (names only): $(kubectl -n "$NS" get secret -o name | tr '\n' ' ')"
  echo "namespace pod-security: $(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
  echo '```'
  echo "## Served version"
  echo '```'
  curl -fsS -D - "$BASE_URL/version" | grep -iE '^(HTTP|x-app-version)|git_sha' || true
  echo '```'
  echo "## Structured logs (latest API requests)"
  echo '```'
  kubectl -n "$NS" logs deploy/"$RELEASE" --tail=200 | grep '"app.access"' | tail -5 || true
  echo '```'
} | tee "$OUT/EVIDENCE.md"

kubectl -n "$NS" get deploy "$RELEASE" -o yaml >"$OUT/deployment.yaml"
kubectl -n "$NS" describe pods -l app.kubernetes.io/component=api >"$OUT/pods-describe.txt"
kubectl -n "$NS" get events --sort-by=.lastTimestamp >"$OUT/events.txt"
kubectl -n "$NS" logs deploy/"$RELEASE" --tail=500 >"$OUT/api-logs.jsonl" || true
log "done: $OUT"
