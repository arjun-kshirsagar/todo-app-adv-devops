#!/usr/bin/env bash
# End-to-end check of a running deployment through its public entry point:
# health, the exact version being served, and the full user journey.
#
#   scripts/smoke-test.sh [expected-git-sha]
source "$(dirname "$0")/lib.sh"
need curl python3
EXPECTED_SHA="${1:-}"
ensure_base_url

log "smoke test against $BASE_URL"
curl -fsS "$BASE_URL/healthz" >/dev/null && ok "liveness /healthz"
curl -fsS "$BASE_URL/readyz" | grep -q '"database":"up"' && ok "readiness /readyz (database up)"

version_json="$(curl -fsS "$BASE_URL/version")"
echo "  version: $version_json"
if [[ -n "$EXPECTED_SHA" ]]; then
  served="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["git_sha"])' <<<"$version_json")"
  [[ "$served" == "$EXPECTED_SHA" ]] && ok "serving expected commit $EXPECTED_SHA" \
    || fail "serving $served, expected $EXPECTED_SHA"
fi

curl -fsS "$BASE_URL/" | grep -q "<title>Todos</title>" && ok "web UI served"

# User journey: create -> list -> complete -> delete, exactly as the UI does.
title="smoke-$(date +%s)"
created="$(curl -fsS -X POST "$BASE_URL/api/todos" -H 'Content-Type: application/json' -d "{\"title\":\"$title\"}")"
id="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' <<<"$created")"
ok "created todo #$id"
curl -fsS "$BASE_URL/api/todos" | grep -q "\"$title\"" && ok "todo #$id listed"
curl -fsS -X PATCH "$BASE_URL/api/todos/$id" -H 'Content-Type: application/json' -d '{"done":true}' \
  | grep -q '"done":true' && ok "todo #$id marked done"
code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/todos/$id")"
[[ "$code" == "204" ]] && ok "todo #$id deleted" || fail "delete returned $code"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/todos" -H 'Content-Type: application/json' -d '{"title":""}')"
[[ "$code" == "422" ]] && ok "invalid input rejected (422)" || fail "validation returned $code"

curl -fsS "$BASE_URL/metrics" | grep -q 'todo_operations_total{operation="create",outcome="success"}' \
  && ok "metrics exported"
log "smoke test passed"
