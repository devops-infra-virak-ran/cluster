# cluster

Kubernetes on servers someone else provisioned, and the Helm release that runs
on it. One environment per workspace.

This project owns no infrastructure. It needs three things to already exist:

| | |
| --- | --- |
| **Servers** | 1 or 3 control planes, plus workers, reachable over SSH |
| **An inventory** | `kubespray/inventory/<workspace>/inventory.ini` |
| **Platform facts** | `platform/<workspace>.env` — registry, load balancer, addresses |

Nothing here runs Terraform, reads Terraform state, or needs the repo that
built the machines.

## Quick start

```bash
make platform       WORKSPACE=dev    # are all the facts configured?
make kubespray-pull WORKSPACE=dev    # ~1-3 min
make kubespray-ping WORKSPACE=dev    # ~15 s — want 4 × SUCCESS
make up             WORKSPACE=dev    # 25-45 min, ends at a URL
```

`make platform` and `make kubespray-ping` are the two preflights. Both are
seconds, and between them they catch almost everything that would otherwise
fail twenty minutes into a playbook.

## Platform facts

Everything this project needs from the infrastructure comes through
`scripts/platform.sh`, resolved in this order — first hit wins:

| | Source | Scope |
| --- | --- | --- |
| 1 | environment variable | one command |
| 2 | `platform/<ws>.local.env` | **your machine** — gitignored |
| 3 | `platform/<ws>.env` | **the environment** — gitignored, handed over |
| 4 | SSM, when `PLATFORM_SSM_PREFIX` is set | the account |

Neither file is committed — this repository is public, and layer 3 names a live
environment. `platform/<ws>.env.example` lists every key; get the values from
whoever provisions the machines, who can generate the file directly:

```bash
make platform-env WORKSPACE=dev > platform/dev.env    # in the infrastructure repo
```

```bash
make platform WORKSPACE=dev     # every key, its value, and which layer answered
```

Nothing is guessed. A missing value is reported by name, with the file to put
it in — it is never silently defaulted, because a default that happens to exist
but is wrong fails later and far less clearly.

On a new machine, two files:

```bash
cp platform/dev.env.example       platform/dev.env         # or have it generated
cp platform/dev.local.env.example platform/dev.local.env   # your SSH key path
make platform WORKSPACE=dev                                # confirms both
```

## What `make up` runs

Each step works on its own, in this order.

| # | Target | Min | What it does |
| --- | --- | --- | --- |
| 1 | `kubespray-pull` | 1-3 | The pinned Kubespray image |
| 2 | `kubespray-ping` | — | Ansible reaches every node through the bastion |
| 3 | `kubespray-deploy` | 20-40 | Kubernetes itself |
| 4 | `tunnel` | — | A kubeconfig, and an SSH tunnel to the apiserver |
| 5 | `storage` | 1 | EBS CSI driver, gp3 as the default StorageClass |
| 6 | `ingress` | 1-2 | ingress-nginx, pinned to the NodePort the load balancer polls |
| 7 | `ecr-auth` | — | The pull secret, and a CronJob that refreshes it |
| 8 | `env-apply` | — | `helm/env/<ws>.env` into the cluster as the `app-env` Secret |
| 9 | `helm-deploy` | 1-2 | Every service in the catalogue |
| 10 | `url` | — | Where each one answers |

Three of those orderings are load-bearing, and all three fail *slowly*:

- **`tunnel`, not `kubeconfig`.** Same job, but `kubeconfig` holds the tunnel in
  the foreground until Ctrl-C, which stops a chained run dead.
- **`ecr-auth` before `helm-deploy`.** The pull secret must exist when the first
  pod is scheduled, or it lands in `ImagePullBackOff` and `--wait` burns its
  full timeout.
- **`ingress` before `helm-deploy`.** The load balancer's targets only go
  healthy once something answers on the NodePort.

## Day to day

Once the cluster is up, deploying a change is the last step alone:

```bash
make services    WORKSPACE=dev   # what is in the catalogue, and at which tag
make helm-diff   WORKSPACE=dev   # what would change
make helm-deploy WORKSPACE=dev
```

| Change | What to run |
| --- | --- |
| A service's tag or replicas | edit `helm/env/<ws>.yaml`, then `helm-deploy` |
| Add or remove a service | `svc-add` / `svc-rm`, then `helm-deploy` |
| Application secrets | edit `helm/env/<ws>.env`, then `env-apply` |
| More nodes | have them provisioned, refresh the inventory, `kubespray-scale NODES=…` |
| Addresses changed | update `platform/<ws>.env` and the inventory |

## Targets

```
make help                        # this list, with the current WORKSPACE
```

| Group | |
| --- | --- |
| **Platform** | `platform` |
| **Cluster** | `up` · `cluster-up` · `kubespray-pull` · `-ping` · `-deploy` · `-scale` · `-remove` · `-upgrade` · `-reset` · `-shell` · `kubeconfig` · `tunnel` · `tunnel-stop` · `storage` |
| **Pausing** | `pause` · `resume` · `cluster-down` |
| **Services** | `services` · `svc-add` · `svc-rm` · `ingress` · `env-apply` · `ecr-auth` · `url` · `helm-lint` · `helm-render` · `helm-diff` · `helm-deploy` · `helm-status` · `helm-uninstall` |
| **Housekeeping** | `list` · `clean` |

There is no `apply`, `destroy` or `plan` here. This project cannot create or
delete infrastructure, which is the point.

## Layout

```
platform/
  dev.env.example        the key list, committed
  dev.env                the environment, gitignored
  dev.local.env          your machine, gitignored
kubespray/
  run.sh                 runs playbooks in the pinned container
  group_vars/            cluster configuration
  inventory/<ws>/        the inventory, provided not generated
  storage/               gp3 StorageClass
helm/
  services/              the chart
  values/<group>/        the catalogue — which services exist
  env/<ws>.yaml          tags and replicas, per environment
  env/<ws>.env           application secrets
scripts/
  platform.sh            every fact from the infrastructure
  kubeconfig.sh          kubeconfig + tunnel through the bastion
  ecr-auth.sh            registry pull secret + refresh CronJob
  env-apply.sh           the app-env Secret
  service.sh             svc-add / svc-rm
  check-images.sh        refuses to deploy a tag that was never pushed
```

## Gotchas

- **The inventory is provided, not generated.** If addresses changed, every
  host comes back `UNREACHABLE` in about 15 seconds. Ask for a fresh one —
  editing it by hand works until the next time it is regenerated.
- **`platform/<ws>.env` goes stale the same way.** Regenerate it after any
  apply that moves an address. `make platform` shows the values;
  `make kubespray-ping` proves them.
- **A 503 for the first half-minute is normal** while the load balancer health
  checks new targets. If it persists, the NodePort and the target group
  disagree.
- **`cluster-down` before the infrastructure is destroyed.** It deletes what
  Kubernetes created in AWS — LoadBalancer Services, PVC volumes — which
  nothing else knows about. A leftover load balancer holds an ENI that blocks
  the VPC from deleting.
- **`pause` keeps private addresses.** A stopped instance keeps its private IP,
  so the inventory and kubeconfig still hold after `resume`. The bastion keeps
  its public address too, because it is an Elastic IP.
# cluster
