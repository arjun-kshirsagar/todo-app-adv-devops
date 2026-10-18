#!/usr/bin/env python3
"""Render the chart's PrometheusRule into a plain Prometheus rules file so
promtool can syntax-check it and run the alert unit tests in CI.

Usage: helm template ... | scripts/render-rules.py > rules.yaml
"""

import sys

import yaml

for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get("kind") == "PrometheusRule":
        yaml.safe_dump({"groups": doc["spec"]["groups"]}, sys.stdout, sort_keys=False)
        break
else:
    sys.exit("no PrometheusRule found in input")
