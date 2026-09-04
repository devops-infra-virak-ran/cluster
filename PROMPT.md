# Master prompt — AWS + Kubespray + Helm platform

Give everything below to an agent in an empty directory. It describes a
complete, working system: infrastructure, a Kubernetes cluster on it, and a
Helm release running on that.

The "Gotchas" section is the important part. Every item there is a real
failure that cost time to diagnose — most of them fail *silently* or with an
error that points somewhere else entirely.

---

## THE PROMPT

Build an AWS platform that goes from nothing to a working URL with one command.
Terraform for infrastructure, Kubespray for Kubernetes, Helm for the workloads.
Target: a learning-grade but production-shaped environment I can destroy nightly.

### Ground rules

- **Every file explains *why*, not *what*.** Assume the reader can read HCL.
  Comments earn their place by recording a decision, a trade-off, or a trap.
- **Pin every version.** No `latest`, no floating tags, anywhere.
- **Fail early and legibly.** A guard that stops a bad `apply` at plan time is
  worth more than any amount of documentation.
- **Nothing runs on the host but Docker.** Kubespray, Helm and kubectl all run
  from pinned container images.

### Part 1 — Terraform

One root module, one environment per **Terraform workspace**. The workspace *is*
the environment:

```hcl
environment = terraform.workspace
```

Never a separate `environment` variable — that lets someone pass `prod.tfvars`
while the `dev` state is selected, and nothing warns them.

Modules under `terraform/modules/`:

| module | contains |
| --- | --- |
| `network` | VPC, public + private subnets across AZs, IGW, NAT (one shared or one per AZ), optional flow logs |
| `security` | bastion / control-plane / worker / ALB security groups, node IAM role with ECR pull + SSM |
| `compute` | bastion, control-plane and worker EC2, cloud-init, optional dedicated etcd volume |
| `loadbalancer` | ALB, target group on the ingress NodePort, one attachment per worker, `:80` listener |
| `registry` | one ECR repo per service, lifecycle policy, pull policy for the node role, CI push policy |

Variables per environment in `terraform/env/{dev,staging,prod}.tfvars`. Each
carries a cost estimate in a comment at the top.

**Two guards, both as `terraform_data` preconditions so they fail at plan time:**

1. **Workspace guard** — reject any workspace not in `dev|staging|prod`. The
   `default` workspace must be unusable; it is the one people land in by accident.
2. **Account guard** — compare `data.aws_caller_identity.current.account_id`
   against an `aws_account_id` variable set in each tfvars. Without this,
   changing AWS credentials does not fail: it *succeeds against the wrong
   account*, finds nothing in state, and builds a complete second copy of the
   environment while the first keeps billing.

Terraform also **renders the Kubespray inventory** to
`kubespray/inventory/<workspace>/inventory.ini` — it knows every address it just
created, so nobody should be copying IPs out of the console.

### Part 2 — Kubespray

Run from the official container image, pinned. The host needs Docker and an SSH
key, nothing else.

- Nodes have no public addresses; Ansible reaches them through the bastion with
  a `ProxyCommand`. Put SSH keepalives on **both** hops.
- `group_vars/` must sit next to the inventory file — mount it there rather than
  passing `--extra-vars`, which is the highest-precedence tier in Ansible and
  would override Kubespray's own role logic.
- Stacked etcd: control-plane nodes are the etcd members. 1 or 3, never 2.
- **No cloud controller manager.** Kubernetes removed the in-tree AWS provider
  in 1.31 and Kubespray ships no replacement. This is why `Service
  type=LoadBalancer` stays `Pending` forever, and why ingress is an
  ALB→NodePort instead.
- Install the EBS CSI driver from **upstream**, not Kubespray's bundled role —
  that one points at a Docker Hub image abandoned in 2021.

### Part 3 — Helm

One chart, `helm/services`, that renders every service from values. No
per-service template and no copy-paste: `range` over a map.

**Three merge tiers, most general to most specific:**

```
defaults:                  chart values.yaml — every service, any group
  └── groups.<g>.defaults: values/<g>/services.yaml
        └── the service:   values/<g>/services.yaml, under `services:`
              └── the env: env/<workspace>.yaml — image tag and replicas
```

- `helm/values/<group>/services.yaml` is **the catalogue** — which services
  exist, their routes, env and probes. True in every environment.
- `helm/env/<workspace>.yaml` holds only what differs per environment: image
  tag and replica count.
- **Terraform reads the catalogue** with `yamldecode` to decide which ECR
  repositories to create, so a service is declared in exactly one place.

Conventions that make an entry one line: `image.repository` defaults to the
service name; `route` defaults to `<group routePrefix>/<name>`.

Templates: Deployment, Service, Ingress, ConfigMap, NOTES.txt, `_helpers.tpl`
holding a `services.all` helper that flattens the tiers once.

### Part 4 — Makefile and scripts

`make up WORKSPACE=dev` runs the whole chain:

```
myip → apply → kubespray-pull → kubespray-ping → kubespray-deploy
     → tunnel → storage → ingress → ecr-auth → env-apply → helm-deploy → url
```

Also: `plan`, `apply-plan`, `destroy`, `output`, `cost`, `workspaces`,
`svc-add`, `svc-rm`, `services`, `helm-diff`, `helm-render`, `pause`, `resume`,
`pause-hard`, `cluster-down`.

Scripts in `scripts/`: `kubeconfig.sh` (SSH tunnel + kubeconfig),
`service.sh` (add/remove a service by editing YAML *as text*, so comments
survive), `ecr-auth.sh`, `env-apply.sh`, `check-images.sh`.

---

## GOTCHAS — build these in from the start

Each of these is a real failure. The symptom rarely names the cause.

### Terraform

**`for_each` on instance IDs fails at plan time.** Instance ids do not exist
until apply. Use `count` — the list *length* is known because it comes from
`worker_count`.

**ELB names cap at 32 characters** and AWS rejects longer rather than
truncating. `substr()` the name.

**An ALB needs two subnets in different AZs.** Even a one-instance dev
environment must have two.

**Wrong-account errors are unrecognisable.** ELBv2 rejects another account's
ARN as `is not a valid load balancer ARN`, not "belongs to someone else". Hence
the account guard.

**AWS Free Tier plan accounts reject most instance types** with
`InvalidParameterCombination: The specified instance type is not eligible for
Free Tier`. Check with
`aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`.
`t4g.*` are Graviton/arm64 and will not boot an amd64 AMI.

**Canonical publishes 22.04 only under `hvm-ssd`, not `hvm-ssd-gp3`.** The
storage path in the AMI name pattern is tied to the release. Use 24.04 for gp3.

**IMDS needs `http_put_response_hop_limit = 2`** or containers cannot reach it —
a pod is one hop further out than the host. At the default of 1 every AWS SDK
call inside a pod fails with "Unable to locate credentials".

**Scope IAM conditions carefully.** A `aws:ResourceTag` condition on
`ec2:CreateVolume` always denies: a resource that does not exist yet carries no
tags, so every PVC sits Pending.

### Kubernetes and Helm

**Set `KUBECONFIG` per workspace in the Makefile, exported.** Every kubeconfig
here points at `https://127.0.0.1:6443` because they all tunnel to the same
local port. A stale `~/.kube/config` therefore does not fail to connect — it
connects to whichever tunnel is open with the wrong cluster's certificate, and
reports `x509: certificate signed by unknown authority`.

**The SSH tunnel is a process, not a setting.** It dies with its terminal.
Guard every cluster-touching target with a reachability check, or a missing
tunnel surfaces as `failed to download openapi`, which reads like a broken
cluster.

**ECR pulls need more than IAM permission.** The kubelet's in-tree ECR
credential provider was removed; its replacement is an `ecr-credential-provider`
binary that **upstream publishes nowhere** — no release asset, no image on
`registry.k8s.io`. Kubespray configures none of it. So use an `imagePullSecret`
refreshed by a CronJob every 6 hours (the token lasts 12).

**`kubectl create secret docker-registry` has no `--docker-password-stdin`.**
That is a `docker login` flag. Build the `.dockerconfigjson` by hand and pass
`--from-file`, which also keeps the credential out of the process table.

**Check image tags exist before deploying.** A tag that was never pushed is
found by the kubelet, four layers from the thing that chose it: `helm upgrade
--wait` blocks for its full timeout then reports `context deadline exceeded`,
which mentions neither the image nor the reason. A preflight against ECR turns
5 minutes into 2 seconds.

**`--atomic` needs a previously successful release.** On a first install that
fails, it reports `unable to find a previously successful release when
attempting to rollback` and leaves the release `failed`.

**`kubectl --from-env-file` is literal.** `KEY="value"` puts the quotes *in* the
value; `export KEY=value` creates a variable named `export KEY`. Validate the
file before applying it.

**Env values must be strings.** `DB_PORT: 5432` unquoted is an int and the
apiserver rejects the pod.

### SonarQube / Elasticsearch (if you add CI)

**`vm.max_map_count=262144`** must be set on the *host* — a container cannot
raise it. Elasticsearch refuses to start below it.

**`-Xms` must equal `-Xmx`** for the search process, or the bootstrap check
fails with `initial heap size not equal to maximum heap size`. Setting only
`-Xmx` leaves `-Xms` at 1/64 of host RAM.

Both present identically: a restart loop with nothing useful in `docker ps`.

### Makefile

**`$$` before a digit in a recipe is a positional parameter.** `echo "costs
~$$2/mo"` becomes `$2` in bash and, under `set -u`, aborts the target. Use
single quotes.

**`##` help text never goes through make's expansion** — awk reads the raw
file, so it needs a single `$`.

---

## Pinned versions used

```
Terraform          >= 1.9.0
AWS provider       ~> 5.0
Kubespray          v2.31.0   (quay.io/kubespray/kubespray)
Kubernetes         1.35.4    (v2.31.0 supports 1.33.0–1.35.4; move both or neither)
Helm               3.16.3    (alpine/helm)
ingress-nginx      4.14.5
AWS EBS CSI driver v1.64.0
Ubuntu             24.04 LTS, hvm-ssd-gp3, amd64
```

## Done when

```bash
make up WORKSPACE=dev      # nothing → a URL that answers, ~35-55 min
make url WORKSPACE=dev     # prints the route each service serves
make pause WORKSPACE=dev   # stops the nodes, keeps disks and cluster state
make destroy WORKSPACE=dev # back to zero
```

`make check` must pass with no AWS credentials at all.
