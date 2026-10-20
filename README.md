# Todo App: Advanced DevOps project

A small todo list (FastAPI + PostgreSQL + a single-page UI) taken from "runs on my laptop" to a reproducible, observable, secured Kubernetes deployment with a tested CI/CD pipeline.

- **Baseline:** commit `d296a89897d47fe88cb16753e58c91ff7b60b20b` (app + unit tests, no DevOps).
- **Docs:** [Architecture](docs/ARCHITECTURE.md) · [Design decisions and trade-offs](docs/DECISIONS.md) · [Runbook and SLOs](docs/RUNBOOK.md) · [Evidence](docs/EVIDENCE.md)

## What was added

| Area | Implementation |
|---|---|
| App readiness for ops | `/healthz` (liveness, no DB), `/readyz` (DB check), `/version` (git SHA), `/metrics` (Prometheus), JSON logs with `request_id`/`trace_id`, OpenTelemetry tracing, DB config from Secret, schema creation safe with concurrent replicas, graceful shutdown |
| Container | Multi-stage `Dockerfile`, non-root UID 10001, no pip in the image, code read-only to the app, build metadata baked in as OCI labels + env |
| Kubernetes | Helm chart: API `Deployment` (2 replicas, startup/liveness/readiness probes, requests/limits, HPA, PDB, topology spread, preStop drain), PostgreSQL `StatefulSet` with PVC, Services, `helm test` user journey |
| Configuration | One chart, `values.yaml` defaults + small `values-local.yaml` / `values-ci.yaml` overrides, config checksum triggers rollouts |
| CI/CD | GitHub Actions: lint, tests, dependency audit, Dockerfile lint, secret scan, IaC scan, chart + alert-rule validation, image build + vulnerability scan, multi-arch push with SBOM and provenance, **full deploy and verification on kind**, approval-gated promotion |
| Release control | Immutable SHA tags, rolling update with zero unavailability, automatic rollback on failed readiness, `helm rollback`, drift detection |
| Observability | Prometheus ServiceMonitor, SLO recording rules, multi-window burn-rate alerts (unit-tested with promtool), Grafana dashboard, Jaeger traces, runbook links on every alert |
| Security | Pod Security Standard `restricted`, read-only root FS, dropped capabilities, seccomp, no SA token, default-deny NetworkPolicies (ingress and egress), random credentials outside git/Helm, loopback-only exposure, pinned + checksum-verified CI tools, least-privilege workflow permissions, Dependabot |

## Prerequisites

| Tool | Version used | Notes |
|---|---|---|
| Docker Desktop (or Colima) | recent | give it **at least 6 GB RAM** (monitoring stack) |
| kind | v0.29+ | NetworkPolicy enforcement needs kind >= v0.24 |
| kubectl | 1.31+ | |
| Helm | v3.x or v4.x | scripts detect the version |
| Python 3 + PyYAML | 3.11+ | only for `drift-check.sh` (`pip install pyyaml`) |
| openssl, curl | any | |

macOS: `brew install kind kubectl helm`.

## Run it locally

```bash
# 1. Cluster + platform: kind, metrics-server, Prometheus/Alertmanager/Grafana, Jaeger (~5 min first time)
scripts/cluster-up.sh

# 2a. Deploy the image CI built for a commit (needs the GHCR package to be public, see below)
scripts/deploy.sh --tag "$(git rev-parse HEAD)"
# 2b. ...or build the current checkout locally and load it into kind
scripts/deploy.sh --build

# 3. Verify
scripts/smoke-test.sh "$(git rev-parse HEAD)"   # user journey through the Service + version check
helm test todo -n todo --logs                    # same journey from inside the cluster
scripts/verify-netpol.sh                         # network policies are enforced
scripts/observability-check.sh                   # scraping, SLO rules, SLIs, traces
```

Open:

| What | URL |
|---|---|
| Todo app | http://127.0.0.1:8080 (API docs: `/docs`, version: `/version`) |
| Grafana | http://127.0.0.1:3000 · user `admin` · password: `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' \| base64 -d` · dashboard **Todo App - Service Health** |
| Prometheus | http://127.0.0.1:9090 (alerts tab: `Todo*` rules) |
| Alertmanager | http://127.0.0.1:9093 |
| Jaeger | http://127.0.0.1:16686 (service `todo`) |

All ports are bound to `127.0.0.1` only.

### Demonstrations

```bash
scripts/release-demo.sh                    # ship a broken release: auto-rollback, 0 failed user requests
WAIT_FOR_ALERT=1 scripts/fault-demo.sh     # kill PostgreSQL: readiness drops, alert fires, self-recovery, data intact
scripts/drift-check.sh                     # cluster == Helm release == git?
kubectl -n todo set env deploy/todo LOG_LEVEL=DEBUG && scripts/drift-check.sh   # ...now it reports drift
scripts/deploy.sh --tag <sha>              # ...redeploying from git removes it
scripts/collect-evidence.sh                # evidence bundle for the running version -> evidence/<sha>/
```

### Run the app without Kubernetes

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
uvicorn app.main:app --reload       # SQLite at ./todos.db
pytest                              # unit tests
```

### Tear down

```bash
kind delete cluster --name todo
```

## CI/CD

`.github/workflows/ci.yml` runs on every push and on pull requests to `main`:

1. **quality:** ruff, pytest with coverage, pip-audit, hadolint, gitleaks (full history), trivy config, `helm lint` + `kubeconform` for every environment, `promtool check/test rules`.
2. **build:** image tagged with the full commit SHA, trivy image scan (fails on fixable HIGH/CRITICAL), non-root and version self-check. On push events: multi-arch push to `ghcr.io/arjun-kshirsagar/todo-app-adv-devops:<sha>` with SBOM and provenance.
3. **deploy-test:** fresh kind cluster, kube-prometheus-stack, `scripts/deploy.sh` with the tested image, then helm test, smoke test, NetworkPolicy check, observability check, bad-release rollback, database fault and recovery (alert must fire and resolve), drift check. Uploads an evidence bundle and writes it to the run summary.
4. **release:** on `main`, or manually (*Run workflow*, tick *release*). Uses the `production` environment, which requires reviewer approval, and promotes the same digest to `:release` without rebuilding.

One-time repository settings (owner):

- **Settings > Environments > New environment `production`:** add yourself under *Required reviewers*. This enforces the manual approval.
- **GHCR package visibility:** after the first push, open *Packages > todo-app-adv-devops > Package settings* and set it to **Public**, so the local kind cluster can pull `:<sha>` without a pull secret. Otherwise use `scripts/deploy.sh --build`.

## Repository layout

```
app/                         FastAPI app (config, db, observability, routes)
tests/                       unit tests; tests/alerts = promtool alert tests
Dockerfile, .dockerignore
deploy/helm/todo-app/        Helm chart (+ files/dashboard.json)
deploy/kind/cluster.yaml     local cluster (loopback port mappings)
deploy/observability/        kube-prometheus-stack values, Jaeger
scripts/                     cluster-up, deploy, smoke/netpol/observability checks, demos, drift, evidence
scripts/ci/                  pinned tool installer, chart validation
.github/workflows/ci.yml     pipeline; .github/dependabot.yml
docs/                        architecture, decisions, runbook, evidence
```

## Known limitations

- **Single PostgreSQL replica, no backups.** A DB pod or node failure is an outage until it reschedules, and the PVC is node-local on kind. Production would use a managed DB or CloudNativePG with backups.
- **CI cannot deploy to the laptop cluster.** GitHub-hosted runners can't reach it (by design, see Decision 12). CI proves the deployment on its own ephemeral kind cluster, and the laptop deploy uses the same script with the CI-built SHA image.
- **No log aggregation.** Logs are read with `kubectl logs` and disappear with the pod. Loki would fix this.
- **No TLS / Ingress locally.** NodePort on loopback only.
- **Tracing uses in-memory Jaeger.** Traces are lost on restart. Tracing is disabled in CI.
- **Alerts are not routed anywhere.** Alertmanager has no receiver configured (no Slack/email in this environment). Firing alerts are visible in Prometheus and Alertmanager UIs, and CI asserts on them.
- **NetworkPolicy egress for an external DB.** If `database.host` points outside the cluster, an egress rule for it must be added.
- **`actions/*` and `docker/*` actions are pinned by major tag**, not commit SHA (Dependabot updates them). Other CI tools are checksum-pinned.
- **Schema management is `create_all`.** Fine for one table. Real schema changes need migrations (Alembic) using expand/contract to stay compatible during rolling updates.
