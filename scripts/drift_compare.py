#!/usr/bin/env python3
"""Compare live cluster objects with what a Helm release declares.

Drift = a field the release declares has a different value in the cluster
(e.g. someone ran `kubectl set env` or `kubectl edit`). Fields the API server
adds itself (defaults, status, clusterIP, ...) are not drift and are ignored,
because only declared fields are compared. Lists must match in length, so an
extra env var or port added by hand is detected.

Usage: helm get manifest <release> -n <ns> | drift_compare.py <namespace>
Exit 1 if any drift is found.
"""

import json
import subprocess
import sys

import yaml


def diff(declared, live, path):
    """Yield (path, declared, live) for every declared value that differs."""
    if isinstance(declared, dict):
        if not isinstance(live, dict):
            yield path, declared, live
            return
        for key, value in declared.items():
            yield from diff(value, live.get(key), f"{path}.{key}")
    elif isinstance(declared, list):
        if declared == [] and live in (None, []):
            return  # the API server omits empty lists (e.g. NetworkPolicy egress: [])
        if not isinstance(live, list) or len(declared) != len(live):
            yield path, declared, live
            return
        for i, (want, have) in enumerate(zip(declared, live, strict=True)):
            yield from diff(want, have, f"{path}[{i}]")
    elif str(declared) != str(live):  # tolerate 5432 vs "5432"-style scalar typing
        yield path, declared, live


def main() -> int:
    default_ns = sys.argv[1]
    drift = 0
    for doc in yaml.safe_load_all(sys.stdin):
        if not doc:
            continue
        kind, name = doc["kind"], doc["metadata"]["name"]
        ns = doc["metadata"].get("namespace", default_ns)
        # Arguments come from our own Helm release manifest; kubectl from PATH.
        res = subprocess.run(  # noqa: S603
            ["kubectl", "get", kind, name, "-n", ns, "-o", "json"],  # noqa: S607
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            print(f"  DRIFT {kind}/{name}: missing from the cluster")
            drift += 1
            continue
        live = json.loads(res.stdout)
        found = list(diff({k: v for k, v in doc.items() if k != "status"}, live, kind + "/" + name))
        for path, want, have in found:
            print(f"  DRIFT {path}: release={json.dumps(want)[:120]} live={json.dumps(have)[:120]}")
        drift += len(found)
        if not found:
            print(f"  ok    {kind}/{name}")
    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main())
