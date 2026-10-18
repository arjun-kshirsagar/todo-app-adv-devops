#!/usr/bin/env bash
# Detect configuration drift in two directions:
#   1. live cluster vs. what Helm last applied (someone ran kubectl edit/scale/set)
#   2. what Helm last applied vs. the chart in this checkout (repo changed, not deployed)
# Exit code 1 if either differs. The fix for (1) is to re-run deploy.sh from
# git, never to "fix forward" by hand.
source "$(dirname "$0")/lib.sh"
need kubectl helm
drift=0

log "1) live objects vs. last Helm release"
# Server-side diff as Helm's field manager: shows only fields whose live value
# differs from what the release declares.
if helm -n "$NS" get manifest "$RELEASE" \
    | kubectl diff --server-side --field-manager=helm --force-conflicts -f - ; then
  ok "no manual changes in the cluster"
else
  echo "  ^ live state differs from release $(helm -n "$NS" status "$RELEASE" -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])')"
  drift=1
fi

log "2) last Helm release vs. chart in this checkout"
tag="$(helm -n "$NS" get values "$RELEASE" -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["image"]["tag"])')"
tmp_live="$(mktemp)"; tmp_repo="$(mktemp)"
helm -n "$NS" get manifest "$RELEASE" >"$tmp_live"
helm template "$RELEASE" "$CHART" -n "$NS" --skip-tests \
  --api-versions monitoring.coreos.com/v1 \
  -f "$CHART/values.yaml" -f "$CHART/values-$ENV_NAME.yaml" \
  --set image.repository="$IMAGE_REPO" --set image.tag="$tag" >"$tmp_repo"
# Normalise (parse, sort by kind/namespace/name, re-dump) so only content differences count.
norm() { python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
docs.sort(key=lambda d: (d["kind"], d["metadata"].get("namespace", ""), d["metadata"]["name"]))
yaml.safe_dump_all(docs, sys.stdout, sort_keys=True)' "$1"; }
if diff -u <(norm "$tmp_live") <(norm "$tmp_repo") >/tmp/todo-repo-drift.diff; then
  ok "deployed release matches the chart in git (image $tag)"
else
  echo "  chart in git differs from deployed release (see /tmp/todo-repo-drift.diff):"
  head -40 /tmp/todo-repo-drift.diff
  drift=1
fi

if git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1; then
  head_sha="$(git -C "$ROOT" rev-parse HEAD)"
  [[ "$tag" == "$head_sha" ]] && ok "deployed image is HEAD ($head_sha)" \
    || echo "  note: deployed image $tag, checkout HEAD is $head_sha"
fi
exit $drift
