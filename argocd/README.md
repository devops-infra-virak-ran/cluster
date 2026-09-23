# ArgoCD

GitOps for the `services` chart. ArgoCD runs in the cluster and reconciles the
chart from git. Sync is **manual** to start, so `make helm-deploy` keeps working
alongside it — ArgoCD shows drift but does not act until you sync.

```bash
make storage · ingress · ecr-auth · env-apply WORKSPACE=dev   # bootstrap (unchanged)
make argocd-install
make argocd-app    WORKSPACE=dev
make argocd-sync   WORKSPACE=dev
make argocd-expose WORKSPACE=dev   # UI at https://<site>/argocd
```

## Prerequisites

- A running cluster you can reach (`make tunnel WORKSPACE=dev`).
- `platform/<ws>.env` filled in — the Application needs `ecr_image_prefix` and
  `alb_url` from it (`make platform WORKSPACE=dev` to check).
- A git remote ArgoCD can pull from (`origin`), on the branch you deploy.

## Install and deploy

```bash
make argocd-install                 # one-time, installs ArgoCD into the cluster
make argocd-app     WORKSPACE=dev   # render + apply the Application for dev
make argocd-sync    WORKSPACE=dev   # first sync (manual)
```

Watch it:

```bash
make argocd-password                # the admin password
make argocd-ui                      # https://localhost:8080  (user: admin)
```

`make argocd-ui` port-forwards, so it needs the tunnel up and a free local
port. 8080 is the default and is often already taken — a local Jenkins is the
usual culprit. `ARGOCD_PORT` overrides it: `make argocd-ui ARGOCD_PORT=8090`.

## The web UI on the load balancer

`make argocd-expose WORKSPACE=dev` publishes the UI at
`https://<site_url>/argocd`, through the ALB and ingress controller the
services already use, restricted to `ADMIN_ALLOWED_CIDRS`. No port-forward, no
tunnel — but also no second hostname, because the ALB certificate covers the
apex domain and nothing else, so `argocd.<domain>` would fail TLS.

```bash
make argocd-expose   WORKSPACE=dev                  # publish
make argocd-expose   WORKSPACE=dev --render-only    # see the manifest, change nothing
make argocd-unexpose WORKSPACE=dev                  # back to port-forward only
```

Three settings have to agree, which is why one target does all of them:

| | why |
| --- | --- |
| `server.rootpath=/argocd` | ArgoCD builds asset URLs from it. Left at `/`, the page loads and every script under it 404s. |
| `server.insecure=true` | TLS terminates at the ALB. A second hop to ArgoCD's self-signed cert only fails. |
| `use-forwarded-headers` | Set by `make ingress`. Without it nginx sees the ALB's private IP as the client and the allowlist 403s everyone. |

The allowlist is a snapshot of one address, not a subscription. When your
network changes, the UI starts returning 403 — re-run `make argocd-expose`.
Unset `ADMIN_ALLOWED_CIDRS` and it detects your current public address instead,
the same way `make myip` does in the infrastructure project.

Reapplying the base install (`make argocd-install`) resets
`argocd-cmd-params-cm`, dropping the rootpath and insecure settings with it.
Run `make argocd-expose` again after any reinstall.

Between the ALB and the pod the traffic is plain HTTP inside the VPC. That is
the same path the services already take, and the worker security group opens
the NodePort range to the load balancer alone — but it is worth knowing before
this pattern is copied to an environment that matters.

## How CI deploys

The app repositories map a branch to an environment, build an image, and push
it to ECR. The last stage commits the new tag here — that commit is the deploy,
because ArgoCD runs whatever tag this repo holds.

```
frontend/auth/core repo          this repo                     cluster
─────────────────────────────    ──────────────────────────    ──────────────
develop  → dev     build+push →  helm/env/dev.yaml     tag  →  auto-sync
testing  → staging build+push →  helm/env/staging.yaml tag  →  auto-sync
main/vX  → prod    approve,   →  helm/env/prod.yaml    tag  →  waits for you
                   build+push
```

One branch, one file per environment. Promotion is a tag moving from one file
to the next, which is a one-line diff in a pull request — not a merge that
carries every other difference between two long-lived branches along with it.

`dev` and `staging` carry `syncPolicy.automated`, so a commit reaches them by
itself. `prod` does not: the commit lands and waits for `make argocd-sync
WORKSPACE=prod`, which is the second gate behind the approval CI already asks
for. `scripts/argocd-app.sh` decides that from the workspace name —
`AUTOMATED_WORKSPACES` overrides it.

Moving a tag by hand is the same operation:

```bash
make svc-tag NAME=client-side TAG=dev-a1b2c3d4 WORKSPACE=dev
```

It edits the file as text so the comments survive, refuses a service that has
no entry rather than inventing one, and does nothing when the tag is already
what you asked for — which is what keeps a rebuild of an unchanged commit from
producing an empty commit.

CI needs one Jenkins credential: `github-cluster-repo`, a username/password
pair whose password is a GitHub token with **write** access to this repository.
That is the only new secret — the image push already uses the CI box's instance
profile.

## How the pieces fit

```
git repo (helm/services + values)
        │  ArgoCD pulls
        ▼
   Application "services-<ws>"   ← rendered from platform.<ws>.env
        │  renders the chart, syncs on demand
        ▼
   namespace "apps"   (same place make helm-deploy targets)
```

`make helm-deploy` injects two values from `platform.sh` at deploy time —
`global.imageRegistry` and `global.ingress.url`. ArgoCD runs in-cluster and
cannot call `platform.sh`, so `make argocd-app` bakes those two into the
Application's `helm.parameters` when it renders.

## Files

```
argocd/
  application.example.yaml    the Application template, with __PLACEHOLDERS__ (committed)
  application-<ws>.yaml       rendered by `make argocd-app` (gitignored — carries the account id)
```

The rendered file is gitignored on purpose: it contains the ECR prefix (your
AWS account id) and this repo is public. The template is safe to commit.

## What ArgoCD does NOT manage yet

Deliberately out of scope for this first integration — still bootstrap steps:

|                             | still run as                   | why not in git                                                           |
| --------------------------- | ------------------------------ | ------------------------------------------------------------------------ |
| `regcred` (ECR pull secret) | `make ecr-auth`                | minted from AWS creds; a CronJob refreshes it                            |
| `app-env` (DB/JWT secrets)  | `make env-apply`               | **secrets must not go in git** — needs sealed-secrets / external-secrets |
| ingress-nginx, storage      | `make ingress`, `make storage` | cluster bootstrap, rarely changes                                        |

So the deploy order on a fresh cluster is unchanged up to the app:

```
make storage · ingress · ecr-auth · env-apply    (bootstrap)
make argocd-install · argocd-app · argocd-sync    (ArgoCD deploys the services)
```

## Going full GitOps later

When you want ArgoCD to own deploys and self-heal, add automation to the
Application (`spec.syncPolicy.automated: {prune: true, selfHeal: true}`) and
retire `make helm-deploy` — with auto-sync on, running Helm by hand fights the
reconcile. The natural next steps after that:

- **external-secrets** or **sealed-secrets** so `app-env` comes from git too.
- **app-of-apps** so ingress and ecr-auth become ArgoCD Applications.
- a **private config repo** (or make this one private) so per-env values commit
  cleanly instead of being rendered from `platform.<ws>.env`.
