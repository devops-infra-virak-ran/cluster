# cluster

Everything that runs inside an environment's EKS cluster: the controllers,
one namespace per team, and every team's services — deployed by Argo CD from
this repository. The cluster itself is `../terraform`'s.

Design and the contract with Terraform: [docs/platform.md](docs/platform.md).
Releasing, promoting and rolling back: [docs/release.md](docs/release.md).

## Needs

Docker, `kubectl`, the AWS CLI with credentials an EKS access entry knows, and
the environment applied in `../terraform`. Helm runs from a pinned container.

## Bring an environment up

```bash
cp helm/env/dev.env.example helm/env/dev.env   # once: DB and JWT values
make up WORKSPACE=dev                          # ~10 min, ends at the URL
```

`make up` runs these, each of which also works alone:

```bash
make platform-pull  WORKSPACE=dev   # facts from SSM → platform/dev.env
make kubeconfig     WORKSPACE=dev   # ~/.kube/config-dev
make controllers    WORKSPACE=dev   # LB controller, external-dns, External Secrets, autoscaler
make teams          WORKSPACE=dev   # namespaces, quotas, RBAC, network policies
make secrets        WORKSPACE=dev   # helm/env/dev.env → Secrets Manager
make argocd-install WORKSPACE=dev
make argocd-apps    WORKSPACE=dev   # Argo CD now deploys every team
```

## Day to day

```bash
make argocd-status  WORKSPACE=dev                    # sync and health of every app
make svc-tag NAME=auth-api TAG=1.4.2 WORKSPACE=uat   # then commit and push — that is the deploy
make argocd-sync    WORKSPACE=prod                   # prod waits for this
make argocd-history TEAM=api-service WORKSPACE=prod
make url            WORKSPACE=dev
```

## Tear down

```bash
make cluster-down WORKSPACE=dev                 # ALB, DNS records, volumes — first
make -C ../terraform destroy WORKSPACE=dev
```

`make help` lists every target.
