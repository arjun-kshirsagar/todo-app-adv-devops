# Design decisions and trade-offs

Each entry gives the choice, why it fits *this* application, the credible alternative, and when the alternative would be the better call.

## Runtime

**1. Local kind cluster, not a cloud cluster.**
Free, reproducible, and the same cluster type runs inside CI, so "works in CI" means "works on Kubernetes". The trade-off is that there is no real load balancer, ingress TLS or multi-node failure. For a real service I would use a managed cluster (EKS/GKE) provisioned by Terraform. Terraform is out of scope for this course.

**2. API as a `Deployment` with 2+ replicas.**
The API is stateless, since all state lives in PostgreSQL, so pods are interchangeable. Two replicas mean a single pod failure or a rolling update never takes the service down. The alternative, one replica, is cheaper but turns every restart into downtime.

**3. PostgreSQL as an in-cluster `StatefulSet` (1 replica, PVC).**
A StatefulSet gives a stable name (`todo-postgres-0`) and a PVC that is reattached to the same pod, which a Deployment does not guarantee. *Alternative:* a managed database (RDS, Cloud SQL) gives backups, HA and patching, and is what I would use in production. The chart supports it via `postgres.enabled=false` and `database.host`. *Another alternative:* CloudNativePG operator for HA Postgres on Kubernetes. That's overkill for a todo app. *Why not SQLite on a PVC:* it would pin the API to one pod (RWO volume) and make horizontal scaling impossible.

**4. Liveness `/healthz` does NOT check the database; readiness `/readyz` does.**
If liveness checked the DB, a database outage would make Kubernetes restart every healthy API pod. That adds load and recovers nothing. Readiness removes pods from the Service instead, so clients fail fast. A `startupProbe` (up to 150 s) covers first boot while the schema is created, so liveness can stay strict afterwards. This is verified by `scripts/fault-demo.sh` (0 restarts during a DB outage).

**5. Resources: requests sized from observation, memory limit, a moderate CPU limit.**
Requests (50m/96Mi) let the scheduler and HPA reason about the pod. The memory limit (256Mi) protects the node from a leak. The CPU limit (500m) is a deliberate trade-off: it can cause throttling under bursts, but on a shared laptop cluster it stops one component starving the others. On a dedicated production cluster I would consider dropping CPU limits and relying on requests.

**6. HPA on CPU (2-5 replicas) locally; fixed 2 replicas in CI.**
CPU is a reasonable proxy for this CPU-light app's load and needs only metrics-server. A request-rate metric through the Prometheus Adapter would track user load more directly but adds another component. CI uses fixed replicas so tests are deterministic.

**7. NodePort on 127.0.0.1 instead of an Ingress controller.**
One service, no TLS needs locally, and binding to loopback means nothing is exposed to the network. The once-default ingress-nginx project has been retired upstream, so on a real cluster I would use the Gateway API (e.g. Envoy Gateway) with TLS termination.

## Configuration

**8. One Helm chart with per-environment overrides (`values.yaml` + `values-local.yaml` / `values-ci.yaml`).**
The base file holds the production-like defaults. Override files contain only differences (about 10 lines each), so there are no drifting copies of manifests. *Alternative:* Kustomize overlays, which are equally valid. Helm was chosen for templated logic (conditional monitoring resources, SLO thresholds rendered into PromQL), `helm test`, and release history with one-command rollback.

**9. Secrets are created outside Helm.**
Helm stores every rendered manifest in its release Secret, so a chart-generated password would sit in release history. `deploy.sh` creates `todo-db-credentials` once with a random value that is never printed or written to disk, and the chart references it by name. *In production:* External Secrets Operator or Sealed Secrets, sourced from a vault, with rotation.

**10. Configuration through environment variables (ConfigMap + Secret refs), with a `checksum/config` annotation.**
The same image runs everywhere. Changing the ConfigMap changes the pod template hash, so config changes roll out exactly like code changes, with the same safety.

## Delivery

**11. GitHub Actions; full deploy to an ephemeral kind cluster on every push.**
Pipeline: `quality -> build -> deploy-test -> release`. The deploy-test job installs the same chart the same way as locally and runs the real checks: helm test, smoke test, NetworkPolicy enforcement, monitoring wiring, a bad release, a DB outage and a drift check. A green run therefore demonstrates behaviour, not just a build.

**12. Automation boundary: CI deploys to its own cluster; my laptop cluster is deployed by `scripts/deploy.sh --tag <sha>`.**
GitHub-hosted runners cannot reach a cluster on my laptop, and exposing the API server to the internet (or running a self-hosted runner on my laptop) would be a worse security trade. The artefact crossing the boundary is the immutable `:<sha>` image built and scanned by CI. *If the cluster were reachable* (cloud), the release job would run `helm upgrade` directly, or I would add Argo CD to pull from git, which also gives continuous drift correction.

**13. Manual approval only at promotion (`release` job, `production` environment with required reviewers).**
Everything before it is automated, because it is safe and reversible. Promotion is the step a human should own. It re-tags the **same digest** that passed tests (`imagetools create`) rather than rebuilding, so what was tested is what ships.

**14. Immutable SHA tags; no `latest`.**
A tag that can move cannot answer "what is running?". With SHA tags, `kubectl get deploy -o yaml`, `/version` and Prometheus all name the exact commit.

**15. Release strategy: rolling update with `maxSurge: 1, maxUnavailable: 0`, `minReadySeconds: 5`, and Helm `--rollback-on-failure`.**
Old pods are removed only after a new one has been ready for 5 s. A release that never turns ready is rolled back automatically, and users keep hitting old pods throughout (0 failed requests in `release-demo.sh`). *Blue-green* would give instant switch-back but doubles resources and adds traffic-switching machinery. *Canary* (Argo Rollouts/Flagger) shines with real traffic and metric-based analysis, but a single-user todo app has no traffic to measure a canary against. *Feature flags* would separate deploy from release, which is useful when changes are risky to user behaviour rather than to availability. Schema changes would need expand/contract migrations so old and new pods can share the DB during a roll.

**16. Supply chain: no third-party actions, pinned and checksum-verified tools.**
CI uses only `actions/*` and `docker/*` actions. Other tools (helm, kind, trivy, gitleaks, ...) are downloaded at pinned versions and checked against SHA-256 values in `scripts/ci/install-tools.sh`. This choice was reinforced by the March 2026 compromise of `aquasecurity/trivy-action` tags (CVE-2026-33634): a moved tag cannot change what runs here. Trivy itself is pinned to 0.69.3, a known-good release. Next step: pin `actions/*` by commit SHA too (Dependabot keeps them current).

## Observability

**17. RED metrics per route template, plus business and build metrics.**
`http_requests_total`, `http_request_duration_seconds` (buckets include the 0.3 s SLO threshold exactly), `todo_operations_total`, `todo_db_up`, `todo_app_build_info`. Route templates (`/api/todos/{todo_id}`) keep label cardinality bounded. This is tested in `tests/test_ops.py`.

**18. SLOs and multi-window burn-rate alerts.**
Availability 99.5% non-5xx and latency 95% < 300 ms on `/api/*`. Alerts follow the SRE-workbook burn-rate pattern: fast burn (14.4x over 1h and 5m) pages, slow burn (6x over 6h and 30m) opens a ticket. This catches real budget consumption while ignoring blips. Each alert links to a runbook entry. The logic is unit-tested with `promtool test rules` in CI, and the DB alert is fired for real in the fault demo.

**19. Structured JSON logs with `request_id` and `trace_id`; logs read with `kubectl logs`.**
A user-reported request ID leads to the log line, and its trace ID leads to the Jaeger trace showing the SQL spans. *Gap:* no log aggregation (Loki or similar). Logs are lost when a pod is deleted. On a real cluster I would add Loki with Grafana so logs, metrics and traces are linked in one UI.

**20. OpenTelemetry tracing, opt-in (`tracing.enabled`).**
Auto-instrumented FastAPI and SQLAlchemy show where a slow request spent its time. Export is async and failure-tolerant, so tracing can never take the API down. Disabled in CI to keep the job lean.

## What I would change under different requirements

| Requirement change | Change |
|---|---|
| Real users, multi-AZ | Managed cluster, managed Postgres with HA and backups, 3+ API replicas spread across zones, Gateway API + TLS, WAF. |
| Strict compliance | Image signing (cosign keyless) + admission policy (Kyverno) that only admits signed images from GHCR, SBOM retention, audit logging. |
| Frequent risky changes | Argo Rollouts canary with Prometheus analysis on the error/latency SLIs, plus feature flags. |
| Many services / teams | Argo CD (GitOps) for pull-based deploys and drift auto-healing, shared chart library, per-team namespaces with quotas. |
| Write-heavy load | Connection pooling (PgBouncer), DB resource tuning, HPA on request rate via Prometheus Adapter. |
