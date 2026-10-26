# Release, promotion and rollback

## The model

- **An image is built once.** Its tag is immutable in ECR, so a tag names one
  image forever.
- **A deploy is a git commit** that moves a tag in `helm/env/<ws>.yaml`.
  Argo CD runs whatever this repository says.
- **Promotion copies the tag** from one environment's file to the next. The
  image uat accepted is byte-for-byte the image prod runs.

```
push to main → Jenkins: tests, scans, gates, build once, push to ECR
        │  commits the tag
        ▼
helm/env/dev.yaml ──auto-sync──► dev           Jenkins waits, smoke-tests, records
        │  `release` job: SERVICE, TARGET=uat
        ▼
helm/env/uat.yaml ──auto-sync──► uat           …and rolls back by itself on failure
        │  `release` job: TARGET=prod → approval
        ▼
helm/env/prod.yaml ──Jenkins syncs──► prod     …after the approver clicks Release
```

prod's Argo CD Application never syncs by itself: only the release job's
sync, after an approval, or a person's `make argocd-sync`. The pipelines are
described in `../jenkins-sonarqube/docs/pipelines.md`.

## Promote

**The usual way:** Jenkins → `release` → Build with Parameters → SERVICE,
TARGET (`uat` takes what dev runs, `prod` what uat runs), ACTION `promote`.
It refuses a tag not in ECR, asks for approval before prod, waits for Argo CD,
smoke-tests, records the result, and rolls back by itself if the checks fail.
ACTION `rollback` restores the previous tag the same way.

**By hand**, the same operation:

```bash
make svc-tag NAME=auth-api TAG=1.4.2 WORKSPACE=uat
git commit -am "release(uat): auth-api 1.4.2" && git push
make argocd-status WORKSPACE=uat          # Synced / Healthy
```

For prod, the same, then:

```bash
make argocd-sync   WORKSPACE=prod
make argocd-status WORKSPACE=prod
```

`make check-images WORKSPACE=<ws>` before pushing catches a tag that was
never pushed to ECR — otherwise the rollout sits in ImagePullBackOff.

## Verify

A release is healthy when all three hold:

1. `make argocd-status` — the Application is `Synced` and `Healthy`. Healthy
   means every Deployment finished rolling out, which means every new pod
   passed its readiness probe **and** the ALB's health check (readiness gates).
2. The routes answer from outside — the site root and each public API route:
   `curl -fsS -o /dev/null -w '%{http_code}\n' https://<host>/` (and the same
   for a known `/api/auth/...` path).
3. No restarts: `kubectl -n <team> get pods` — RESTARTS stays 0.

## Roll back

**Revert the commit that moved the tag.** That keeps git, Argo CD and the
cluster in agreement, and the history shows who rolled back and why:

```bash
git log --oneline -- helm/env/prod.yaml           # find the release commit
git revert <sha> && git push
make argocd-sync WORKSPACE=prod                   # dev/uat sync by themselves
```

The previous image is still in ECR — tags are immutable, and the lifecycle
policy keeps the last 30 images tagged `v*`/`release*` and the last 10 of any
other tag — so a rollback to a recent release pulls an image that exists.

**Faster, while the fix is being written:** Argo CD's own rollback re-applies
an earlier sync without a commit. Auto-sync must be off for the app, or it
re-applies git immediately:

```bash
make argocd-history TEAM=api-service WORKSPACE=prod   # pick an ID
argocd app rollback api-service-prod <ID>             # argocd CLI
```

Then make git match — revert the commit — before syncing again, or the next
sync puts the bad version back.

## What a failed deploy looks like

| Symptom | Cause | Where to look |
| --- | --- | --- |
| `Progressing` for minutes, `ImagePullBackOff` | tag never pushed | `make check-images` |
| `Degraded`, `CrashLoopBackOff` | the app fails to start — config, DB | `kubectl -n <team> logs deploy/apps-<svc> --previous` |
| rollout stuck, old pods still serving | new pods fail readiness or the ALB check | `kubectl -n <team> describe pod` (readiness gate) |
| `exceeded quota` events | the team's quota is full | `kubectl -n <team> describe resourcequota` |
| 502 from the ALB | NetworkPolicy, or no healthy target | `kubectl -n <team> describe ingress` |

In every case the old ReplicaSet keeps serving: `maxUnavailable: 0` means no
old pod is removed until its replacement is Ready. A failed deploy is a
deploy that did not finish, not an outage.
