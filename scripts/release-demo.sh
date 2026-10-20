#!/usr/bin/env bash
# Release-control demonstration: ship a deliberately broken release and show
# that (1) users see no errors while it rolls out, because old pods keep
# serving until new ones are ready (maxUnavailable: 0), and (2) Helm
# automatically rolls the release back when readiness never succeeds.
source "$(dirname "$0")/lib.sh"
need kubectl helm curl
ensure_base_url

before_rev="$(helm -n "$NS" history "$RELEASE" -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)[-1]["revision"])')"
before_ver="$(curl -fsS "$BASE_URL/version")"
log "current release revision $before_rev serving $before_ver"

# Continuous probe of the user-facing API while the bad release rolls out.
probe_log="$(mktemp)"
( end=$((SECONDS + 150)); while (( SECONDS < end )); do
    code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$BASE_URL/api/todos" || echo 000)"
    echo "$code" >>"$probe_log"; sleep 0.5
  done ) &
probe_pid=$!

log "deploying broken release (image tag that does not exist)"
set +e
# shellcheck disable=SC2046
helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values \
  --set image.tag=broken-release-does-not-exist \
  $(helm_atomic_flags) --timeout 90s
rc=$?
set -e
kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true

[[ $rc -ne 0 ]] && ok "helm rejected the broken release (exit $rc)" || fail "broken release was accepted"
helm -n "$NS" history "$RELEASE" --max 4
status="$(helm -n "$NS" status "$RELEASE" -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["info"]["status"])')"
[[ "$status" == "deployed" ]] && ok "release status is '$status' after automatic rollback"
after_ver="$(curl -fsS "$BASE_URL/version")"
[[ "$after_ver" == "$before_ver" ]] && ok "still serving the previous version: $after_ver" \
  || fail "version changed: $after_ver"

total="$(wc -l <"$probe_log" | tr -d ' ')"
bad="$(grep -vc '^200$' "$probe_log" || true)"
echo "  user-facing probes during the bad rollout: $total requests, $bad non-200"
[[ "$bad" == "0" ]] && ok "zero failed user requests during the bad rollout" \
  || fail "$bad failed requests during rollout"
kubectl -n "$NS" get pods -l app.kubernetes.io/component=api
