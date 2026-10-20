# Runbook

## What "healthy" means

| Signal | Healthy | Where to look |
|---|---|---|
| User success | `scripts/smoke-test.sh` passes (create, list, complete, delete) | terminal / CI step |
| Availability SLI | `1 - todo:api_error_ratio:rate30m` >= 99.5% | Grafana "Todo App - Service Health", top-left |
| Latency SLI | `todo:api_latency_good_ratio:rate5m` >= 95% under 300 ms | Grafana, top row |
| Capacity | ready API pods >= 2, `todo_db_up == 1` | Grafana, `kubectl -n todo get pods` |
| Version | `/version` `git_sha` equals the intended commit | `curl 127.0.0.1:8080/version` |

SLO window: 30 days. Error budget: 0.5% of `/api` requests (about 3.6 h of full outage per 30 days).

## General investigation flow

1. **Symptom:** which alert, what users see (`curl -i 127.0.0.1:8080/api/todos`).
2. **Scope:** `kubectl -n todo get pods,deploy,sts -o wide` and `kubectl -n todo get events --sort-by=.lastTimestamp | tail`.
3. **Change?** `helm -n todo history todo`. Did a release just happen? Compare `/version` with the expected SHA.
4. **Evidence:** logs `kubectl -n todo logs deploy/todo --tail=100 | grep -v '"status": 2'`, take a `trace_id`, open it in Jaeger (127.0.0.1:16686).
5. **Act**, then **verify recovery** with the same signal that alerted (alert resolves) *and* the user signal (`scripts/smoke-test.sh`).

---

## TodoApiErrorBudgetFastBurn
*Page. More than 7.2% of /api requests are failing (14.4x the budget) over both 1h and 5m.*

- If a release went out in the last hour: roll back first, investigate second. Run `helm -n todo rollback todo` (previous revision) and confirm `/version`.
- Otherwise, check whether `TodoDatabaseUnreachable` is also firing. If so, follow that entry.
- Look for the failing route: Grafana panel "Request rate by route and status", or `sum by (route,status)(rate(http_requests_total{status=~"5.."}[5m]))`.
- Grep logs for `"status": 5` and follow the trace.
- **Verify:** the 5m error ratio is back under 0.5% and the smoke test passes. The alert clears quickly because its 5m window drops first.

## TodoApiErrorBudgetSlowBurn
*Ticket. A steady error rate above 3% over 6h.* Usually one route or one input failing persistently. Find the route as above and fix it in code. No rollback unless it correlates with a release.

## TodoApiLatencySLOBreach
*Ticket. Fewer than 95% of /api requests finish within 300 ms for 10 minutes.*

- Check the p95/p99 panel and pod CPU. Throttling at the 500m limit shows as CPU flat at the limit.
- Check whether the HPA is at max: `kubectl -n todo get hpa`.
- Open a slow trace in Jaeger. Is the time in the SQL span (DB) or in the handler?
- Mitigate by scaling (`kubectl -n todo scale deploy/todo --replicas=4`, temporary; then make it permanent in values and redeploy).

## TodoApiDown
*Page. No API pod has been scraped successfully for 2 minutes.*

- `kubectl -n todo get pods -l app.kubernetes.io/component=api`. Look for CrashLoopBackOff, ImagePullBackOff or Pending.
- ImagePullBackOff after a deploy means the wrong tag or a private GHCR package. Run `helm rollback`.
- CrashLoopBackOff: `kubectl -n todo logs <pod> --previous`.
- Pending: `kubectl describe pod`, usually resources or PVC.
- If the pods are fine, it is a scrape problem. Check the Prometheus targets page (127.0.0.1:9090/targets) and the NetworkPolicy.

## TodoDatabaseUnreachable
*Page. Every API pod's readiness check fails to reach PostgreSQL.*

Expected behaviour during this incident: API pods are **NotReady but not restarting**, and requests fail fast instead of hanging.

- `kubectl -n todo get sts,pods -l app.kubernetes.io/component=database`
- `kubectl -n todo logs sts/todo-postgres --tail=50`. Watch for disk full, auth errors, or crash recovery in progress.
- `kubectl -n todo get pvc` should show the PVC Bound.
- If the StatefulSet was scaled down or the pod deleted, `kubectl -n todo scale sts/todo-postgres --replicas=1`.
- **Verify:** `kubectl -n todo rollout status deploy/todo`, `/readyz` returns `database: up`, data written before the outage is still listed, and the alert resolves. `scripts/fault-demo.sh` rehearses exactly this.

## TodoPodRestartingOften
*Ticket. A pod restarted more than twice in 15 minutes.*

- `kubectl -n todo describe pod <pod>` and read Last State. `OOMKilled` means raise the memory limit or find the leak. An exit code with a logged traceback means an app bug.
- Liveness failures without crashes: check whether `/healthz` is slow (CPU throttling) before loosening probe timeouts.

---

## Routine operations

| Task | Command |
|---|---|
| Deploy a CI-built commit | `scripts/deploy.sh --tag <sha>` |
| Roll back to the previous release | `helm -n todo rollback todo` then `scripts/smoke-test.sh` |
| Roll back to a specific revision | `helm -n todo history todo`, then `helm -n todo rollback todo <rev>` |
| Detect manual changes (drift) | `scripts/drift-check.sh` (fix by redeploying from git, never by hand) |
| Rotate the DB password | `ALTER USER todo PASSWORD '...'` in Postgres, update the Secret, then `kubectl -n todo rollout restart deploy/todo` |
