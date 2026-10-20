#!/usr/bin/env bash
# Fault-and-recovery demonstration: take PostgreSQL away and verify that
#   symptom   - API readiness fails, requests fail, alert fires
#   boundary  - liveness stays green, so pods are NOT restart-looped
#   recovery  - after the database returns, pods become ready on their own,
#               data written before the outage is still there (PVC),
#               and the alert resolves.
#
#   WAIT_FOR_ALERT=1 scripts/fault-demo.sh   # also wait for Prometheus alert (needs monitoring)
source "$(dirname "$0")/lib.sh"
need kubectl curl python3
ensure_base_url
PG="statefulset/$RELEASE-postgres"

restarts() { kubectl -n "$NS" get pods -l app.kubernetes.io/component=api \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{s+=$1} END {print s+0}'; }

marker="survives-outage-$(date +%s)"
curl -fsS -X POST "$BASE_URL/api/todos" -H 'Content-Type: application/json' -d "{\"title\":\"$marker\"}" >/dev/null
ok "wrote marker todo '$marker'"
restarts_before="$(restarts)"

log "FAULT: scaling PostgreSQL to 0 replicas"
kubectl -n "$NS" scale "$PG" --replicas=0
kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/component=database --timeout=90s || true

log "waiting for API pods to report not-ready"
for _ in $(seq 1 30); do
  ready="$(kubectl -n "$NS" get deploy "$RELEASE" -o jsonpath='{.status.readyReplicas}')"
  [[ -z "$ready" || "$ready" == "0" ]] && break; sleep 2
done
kubectl -n "$NS" get pods -l app.kubernetes.io/component=api
ok "API pods removed from the Service (readyReplicas=${ready:-0})"
kubectl -n "$NS" logs deploy/"$RELEASE" --tail=50 | grep -m1 '"readiness check failed"' && ok "readiness failure visible in structured logs"

if [[ -n "${WAIT_FOR_ALERT:-}" ]]; then
  start_prom_forward
  log "waiting for TodoDatabaseUnreachable to fire (scrape + 1m 'for')"
  for _ in $(seq 1 40); do
    firing="$(prom_query 'ALERTS{alertname="TodoDatabaseUnreachable",alertstate="firing"}' \
      | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["data"]["result"]))')"
    [[ "$firing" != "0" ]] && break; sleep 6
  done
  [[ "$firing" != "0" ]] && ok "alert TodoDatabaseUnreachable is firing" || fail "alert did not fire"
fi

log "RECOVERY: scaling PostgreSQL back to 1"
kubectl -n "$NS" scale "$PG" --replicas=1
kubectl -n "$NS" rollout status "$PG" --timeout 180s
kubectl -n "$NS" rollout status "deploy/$RELEASE" --timeout 180s
for _ in $(seq 1 30); do
  curl -fsS -m 3 "$BASE_URL/readyz" >/dev/null 2>&1 && break; sleep 2
done
# The old port-forward may point at a pod that was briefly unready; refresh it.
curl -fsS "$BASE_URL/readyz" | grep -q '"database":"up"' && ok "readiness recovered without manual action"
curl -fsS "$BASE_URL/api/todos" | grep -q "$marker" && ok "marker todo survived the outage (data on PVC)"
restarts_after="$(restarts)"
[[ "$restarts_after" == "$restarts_before" ]] && ok "no API container restarts during the outage ($restarts_after)" \
  || echo "  note: restarts went from $restarts_before to $restarts_after"

if [[ -n "${WAIT_FOR_ALERT:-}" ]]; then
  log "waiting for the alert to resolve"
  for _ in $(seq 1 30); do
    firing="$(prom_query 'ALERTS{alertname="TodoDatabaseUnreachable",alertstate="firing"}' \
      | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["data"]["result"]))')"
    [[ "$firing" == "0" ]] && break; sleep 6
  done
  [[ "$firing" == "0" ]] && ok "alert resolved" || fail "alert still firing"
  kill "$PROM_PF_PID" 2>/dev/null || true
fi
log "fault demo complete"
