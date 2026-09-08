# ArgoCD

GitOps for the `services` chart. ArgoCD runs in the cluster and reconciles the
chart from git. Sync is **manual** to start, so `make helm-deploy` keeps working
alongside it — ArgoCD shows drift but does not act until you sync.

make storage · ingress · ecr-auth · env-apply WORKSPACE=dev # bootstrap (unchanged)
make argocd-install
make argocd-app WORKSPACE=dev
make argocd-sync WORKSPACE=dev
make argocd-ui # admin / make argocd-password

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
