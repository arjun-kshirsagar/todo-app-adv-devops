#!/usr/bin/env bash
# Verify the monitoring wiring end to end (not just that YAML exists):
# Prometheus scrapes every API pod, sees the expected build, has loaded the
# SLO rules, and computes the SLIs from real traffic.
#
#   scripts/observability-check.sh [expected-git-sha]
source "$(dirname "$0")/lib.sh"
need kubectl curl python3
EXPECTED_SHA="${1:-}"
ensure_base_url
start_prom_forward
trap 'kill ${PF_PID:-0} ${PROM_PF_PID:-0} 2>/dev/null || true' EXIT

val() { python3 -c 'import json,sys;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "none")'; }

log "generating some traffic"
for _ in $(seq 1 40); do curl -fsS -o /dev/null "$BASE_URL/api/todos"; done

log "waiting for Prometheus to scrape the API pods"
want="$(kubectl -n "$NS" get deploy "$RELEASE" -o jsonpath='{.status.readyReplicas}')"
want="${want:-1}"
for _ in $(seq 1 40); do
  up="$(prom_query "sum(up{job=\"$RELEASE\",namespace=\"$NS\"})" | val)"
  [[ "$up" != "none" && "${up%.*}" -ge "$want" ]] && break; sleep 5
done
[[ "$up" != "none" && "${up%.*}" -ge "$want" ]] && ok "Prometheus scraping $up/$want API pods" || fail "only $up/$want targets up"

if [[ -n "$EXPECTED_SHA" ]]; then
  n="$(prom_query "count(todo_app_build_info{job=\"$RELEASE\",git_sha=\"$EXPECTED_SHA\"})" | val)"
  [[ "$n" != "none" ]] && ok "Prometheus sees build $EXPECTED_SHA on $n pod(s)" || fail "build $EXPECTED_SHA not seen"
fi

log "waiting for the operator to load the SLO rules into Prometheus"
for _ in $(seq 1 30); do
  rules="$(curl -fsS "http://127.0.0.1:${PROM_PORT:-19090}/api/v1/rules" \
    | python3 -c 'import json,sys;g=json.load(sys.stdin)["data"]["groups"];print(sum(len(x["rules"]) for x in g if x["name"].startswith("todo-app")))')"
  [[ "$rules" -ge 10 ]] && break; sleep 5
done
[[ "$rules" -ge 10 ]] && ok "SLO recording + alerting rules loaded ($rules)" || fail "rules not loaded ($rules)"

log "waiting for SLI recording rules to produce values"
for _ in $(seq 1 30); do
  rate="$(prom_query 'todo:api_request_rate:rate5m' | val)"
  [[ "$rate" != "none" ]] && break; sleep 5
done
err="$(prom_query 'todo:api_error_ratio:rate5m' | val)"
lat="$(prom_query 'todo:api_latency_good_ratio:rate5m' | val)"
echo "  request rate (5m): $rate req/s | error ratio (5m): $err | share < 300ms (5m): $lat"
[[ "$rate" != "none" ]] && ok "SLIs computed from live traffic" || fail "SLIs not available"

firing="$(prom_query 'ALERTS{alertstate="firing",alertname=~"Todo.*"}' \
  | python3 -c 'import json,sys;print(",".join(r["metric"]["alertname"] for r in json.load(sys.stdin)["data"]["result"]) or "none")')"
echo "  todo alerts firing: $firing"
[[ "$firing" == "none" ]] && ok "healthy: no Todo alerts firing"

if kubectl get ns observability >/dev/null 2>&1 \
   && kubectl -n "$NS" get cm "$RELEASE-config" -o jsonpath='{.data.OTEL_EXPORTER_OTLP_ENDPOINT}' | grep -q .; then
  log "checking traces in Jaeger"
  kubectl -n observability port-forward svc/jaeger 16687:16686 >/dev/null 2>&1 & JPF=$!
  sleep 3
  for _ in $(seq 1 12); do
    n="$(curl -fsS "http://127.0.0.1:16687/api/traces?service=$RELEASE&limit=5" 2>/dev/null \
      | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("data") or []))' 2>/dev/null || echo 0)"
    [[ "$n" != "0" ]] && break; sleep 5
  done
  kill $JPF 2>/dev/null || true
  [[ "$n" != "0" ]] && ok "traces for service '$RELEASE' present in Jaeger" || echo "  note: no traces found yet"
fi
log "observability check passed"
