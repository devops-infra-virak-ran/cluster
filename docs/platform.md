# Platform — what runs in each cluster, and why

One EKS cluster per environment (`dev`, `uat`, `prod`), built by
`../terraform`. This repository owns everything inside it.

```
                         Route 53  dev.devops-selft-learning.xyz  (external-dns)
                              │
internet ──► ALB :443 ────────┤  one ALB per environment, shared by every team
           (LB controller)    │  rules:  argocd.<host>   → argocd/argocd-server   (your IP only)
                              │          <host>/api/auth → api-service/apps-auth-api
                              │          <host>/         → web-service/apps-client-side
                              ▼
            pods directly (target-type ip — no NodePort, no in-cluster proxy)

  kube-system        aws-load-balancer-controller · cluster-autoscaler · teams release
  external-dns       external-dns
  external-secrets   External Secrets Operator
  argocd             Argo CD — one Application per team, plus `teams-<ws>`
  api-service        auth-api · core-api (internal)       ← team namespace
  web-service        client-side                          ← team namespace
```

## The contract with `../terraform`

Nothing from Terraform is pasted by hand. Two things cross the boundary:

**Platform facts in SSM** at `/platform/<ws>/<key>`. `make platform-pull`
copies them into `platform/<ws>.env` (generated, gitignored), which
`scripts/platform.sh` reads. Re-run it after any apply.

**Pod identities.** Terraform binds an IAM role to a namespace and service
account; each controller's values file in `controllers/` installs it under
exactly that name, with no credentials anywhere:

| namespace / service account | values file | may |
| --- | --- | --- |
| `kube-system/aws-load-balancer-controller` | `aws-load-balancer-controller.yaml` | create and change ALBs |
| `kube-system/cluster-autoscaler` | `cluster-autoscaler.yaml` | resize this cluster's node group |
| `external-dns/external-dns` | `external-dns.yaml` | write records in the one hosted zone |
| `external-secrets/external-secrets` | `external-secrets.yaml` | assume the per-team secret roles, nothing else |

Rename a service account and the controller runs with no AWS permissions.

## Teams

A team is a directory under `helm/values/` — today `api-service` (backend)
and `web-service` (frontend). The same name is its namespace, its Argo CD
project and Application, its Secrets Manager secret, and its IAM role
(Terraform `var.teams`). The names are matched by hand, so they must agree.

`helm/teams` gives each team namespace, and the team cannot change any of it
(its Argo CD project denies these kinds):

| | |
| --- | --- |
| ResourceQuota | caps summed CPU/memory requests and pod count; no `LoadBalancer` Services |
| LimitRange | default requests/limits for containers that state none |
| RoleBinding | group `team:<name>` → `edit`, in this namespace only. Terraform `team_access` maps an IAM role into that group |
| NetworkPolicy | ingress from the same namespace, the ALB subnets, kube-system and the team's `allowFrom` only |
| SecretStore + ExternalSecret | `app-env` filled from `<project>/<ws>/<team>` in Secrets Manager |
| Pod Security | `baseline` enforced, `restricted` warned |
| readiness gates | a new pod is not Ready until the ALB sees it healthy |

Sizing per environment is the `teams:` block at the bottom of
`helm/env/<ws>.yaml`.

**Adding a team:** a `helm/values/<team>/services.yaml`, an entry under
`teams:` in `helm/teams/values.yaml`, the name in Terraform's `var.teams`
(and `var.services` in `global/` for its images), then `make argocd-apps`.

## Secrets

```
helm/env/<ws>.env  ──make secret-push──►  Secrets Manager <project>/<ws>/<team>
                                                │ External Secrets, via the team's role
                                                ▼
                                    Secret app-env in <team>  ──envFrom──► pods
```

`helm/env/<ws>.<team>.env` overrides the shared file for one team. Values
never touch git, Helm values or Terraform state, and are never printed.
After a change: `kubectl -n <team> rollout restart deploy`.

## Scaling

- **Pods:** an HPA per service (`autoscaling:` in `helm/env/<ws>.yaml`), on
  CPU as a percentage of the request. metrics-server is an EKS add-on.
- **Nodes:** Cluster Autoscaler adds a node when pods are Pending, and removes
  one idle for 5 minutes, within Terraform's `node_min_size`/`node_max_size`.
- **Disruption:** every service with 2+ pods has a PodDisruptionBudget, so a
  scale-down drain never takes the last pod.

## Gotchas

- **`kubectl` hangs** when your IP is not in Terraform's `api_allowed_cidrs`.
  `make -C ../terraform myip WORKSPACE=<ws>`.
- **`make cluster-down` before `terraform destroy`.** The ALB and EBS volumes
  are the cluster's, not Terraform's; left behind they bill, and the ALB stops
  the VPC and certificate from deleting.
- **`make helm-deploy` refuses** a team Argo CD already deploys. With
  selfHeal, Argo CD would revert it within a minute. Commit instead.
- **A new host takes 2-3 minutes**: ALB rule, two health checks, the DNS record.
  `kubectl -n <team> describe ingress` shows the controller's events.
- **Local kubectl should be 1.35-1.37.** Helm's container carries 1.36; a
  much older local kubectl mostly works but is outside the supported skew.
- **Why no Kubespray:** EKS runs the control plane — see
  `../terraform/docs/eks.md`.
