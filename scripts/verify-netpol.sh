#!/usr/bin/env bash
# Prove the NetworkPolicies are enforced, not just present:
#   - an unrelated pod cannot open a connection to PostgreSQL
#   - the API pod can reach PostgreSQL
#   - the API pod cannot reach the internet (egress is allow-listed)
source "$(dirname "$0")/lib.sh"
need kubectl
PG_HOST="$RELEASE-postgres"

py='import socket,sys
h,p=sys.argv[1],int(sys.argv[2])
try:
    socket.create_connection((h,p),timeout=3); print("CONNECTED")
except OSError: print("BLOCKED")'

# The probe uses the app image (already on the node) but WITHOUT the API's
# labels, so no allow rule matches it.
IMAGE="$(kubectl -n "$NS" get deploy "$RELEASE" -o jsonpath='{.spec.template.spec.containers[0].image}')"
log "unrelated pod -> postgres:5432 (expected: blocked)"
overrides="$(python3 - "$IMAGE" "$PG_HOST" "$py" <<'PY'
import json, sys
image, host, code = sys.argv[1:]
print(json.dumps({"spec": {
    "automountServiceAccountToken": False,
    "securityContext": {"runAsNonRoot": True, "runAsUser": 10001,
                        "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": "netpol-probe", "image": image, "imagePullPolicy": "IfNotPresent",
                    "command": ["python", "-c", code, host, "5432"],
                    "securityContext": {"allowPrivilegeEscalation": False,
                                        "capabilities": {"drop": ["ALL"]}}}]}}))
PY
)"
out="$(kubectl -n "$NS" run netpol-probe --rm -i --restart=Never --quiet \
  --image="$IMAGE" --overrides="$overrides" 2>/dev/null || true)"
echo "  result: $out"
[[ "$out" == *BLOCKED* ]] && ok "unrelated pod blocked from PostgreSQL" || fail "unrelated pod reached PostgreSQL"

log "API pod -> postgres:5432 (expected: allowed)"
out="$(kubectl -n "$NS" exec "deploy/$RELEASE" -- python -c "$py" "$PG_HOST" 5432)"
echo "  result: $out"
[[ "$out" == CONNECTED ]] && ok "API reaches PostgreSQL" || fail "API cannot reach PostgreSQL"

log "API pod -> 1.1.1.1:443 (expected: blocked)"
out="$(kubectl -n "$NS" exec "deploy/$RELEASE" -- python -c "$py" 1.1.1.1 443)"
echo "  result: $out"
[[ "$out" == BLOCKED ]] && ok "API egress to the internet blocked" || fail "API reached the internet"
