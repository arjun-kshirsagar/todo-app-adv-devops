#!/usr/bin/env bash
# Static checks for the deployment configuration, run in CI before anything
# is built: Helm lint, schema validation of the rendered manifests for every
# environment, and promtool syntax + unit tests for the alert rules.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="$ROOT/deploy/helm/todo-app"
OUT="$(mktemp -d)"
CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

for env in local ci; do
  echo "== helm lint ($env)"
  helm lint "$CHART" -f "$CHART/values.yaml" -f "$CHART/values-$env.yaml" --set image.tag=ci
  helm template todo "$CHART" -n todo --api-versions monitoring.coreos.com/v1 \
    -f "$CHART/values.yaml" -f "$CHART/values-$env.yaml" --set image.tag=ci >"$OUT/$env.yaml"
done
helm template todo "$CHART" -n todo >"$OUT/default.yaml"

echo "== kubeconform (Kubernetes + CRD schemas, strict)"
kubeconform -strict -summary -schema-location default -schema-location "$CRDS" \
  "$OUT/default.yaml" "$OUT/local.yaml" "$OUT/ci.yaml" "$ROOT/deploy/observability/jaeger.yaml"

echo "== promtool: alert rules syntax + unit tests"
python3 "$ROOT/scripts/render-rules.py" <"$OUT/local.yaml" >/tmp/todo-rules.yaml
promtool check rules /tmp/todo-rules.yaml
promtool test rules "$ROOT/tests/alerts/slo-alerts.test.yaml"

echo "== dashboard JSON"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["panels"]), "panels OK")' "$CHART/files/dashboard.json"
