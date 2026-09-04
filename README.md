# devops-01

AWS infrastructure and the Kubernetes cluster on top of it. One Terraform root,
one environment per workspace.

## Quick start

Once, on a new machine:

```bash
make init                        # download providers
make myip-set WORKSPACE=dev      # put your public IP in the SSH allowlist
```

You need Docker, Terraform, AWS credentials, and an SSH key at
`~/.ssh/id_ed25519` — everything else runs from pinned containers.

Then, from nothing to a URL that answers:

```bash
make up WORKSPACE=dev            # 35-55 minutes
```

And to stop the billing:

```bash
make cluster-down WORKSPACE=dev  # ELBs and volumes Terraform does not know about
make destroy      WORKSPACE=dev
```

### What `up` runs

Each of these works on its own, in this order, if you would rather watch it
happen a step at a time.

| #   | Command                 | Minutes | What it does                                        |
| --- | ----------------------- | ------- | --------------------------------------------------- |
| 1   | `make myip`             | —       | Refuses to continue if your IP is not allowlisted   |
| 2   | `make apply`            | 5-8     | VPC, bastion, nodes, ECR repositories, the ALB      |
| 3   | `make kubespray-pull`   | 1-3     | The pinned Kubespray image                          |
| 4   | `make kubespray-ping`   | —       | Ansible reaches every node through the bastion      |
| 5   | `make kubespray-deploy` | 20-40   | Kubernetes itself                                   |
| 6   | `make tunnel`           | —       | A kubeconfig, and an SSH tunnel to the apiserver    |
| 7   | `make storage`          | 1       | EBS CSI driver, gp3 as the default StorageClass     |
| 8   | `make ingress`          | 1-2     | ingress-nginx, pinned to the NodePort the ALB polls |
| 9   | `make ecr-auth`         | —       | The pull secret, and a CronJob that refreshes it    |
| 10  | `make helm-deploy`      | 1-2     | Every service in the catalogue                      |
| 11  | `make url`              | —       | Where each one answers                              |

Three of those orderings are load-bearing:

- **`tunnel`, not `kubeconfig`.** They do the same thing, but `kubeconfig`
  holds the tunnel in the foreground until Ctrl-C, which would stop a chained
  run dead.
- **`ecr-auth` before `helm-deploy`.** The pull secret has to exist when the
  first pod is scheduled. Otherwise it lands in `ImagePullBackOff` and
  `helm-deploy --wait` sits there until it times out.
- **`ingress` before `helm-deploy`.** Not required, but the ALB's targets only
  go healthy once something answers on the NodePort, so doing it first means
  `url` works the moment it prints.

### Day to day

Once the cluster is up, deploying a change is the last step alone:

```bash
make services    WORKSPACE=dev   # what is in the catalogue, and at which tag
make helm-diff   WORKSPACE=dev   # what would change
make helm-deploy WORKSPACE=dev

make env-apply WORKSPACE=dev
make helm-deploy WORKSPACE=dev

```

This directory builds the machines, the network around them, the cluster on
them, and the one Helm release that runs on that. What it does not do is
multi-cloud, or anything CI-shaped.

---

## The one idea

**The workspace is the environment.** It picks two things at once, and they
cannot disagree:

```
make plan WORKSPACE=dev
                 │
                 ├──→ state:     terraform/terraform.tfstate.d/dev/terraform.tfstate
                 └──→ variables: terraform/env/dev.tfvars
```

`dev`, `staging` and `prod` are the _same code_ with different numbers. There
is no `environment` variable to set, because `main.tf` derives it:

```hcl
environment = terraform.workspace
```

That closes a real hole. With a plain variable you can pass `prod.tfvars`
while the `dev` state is selected — Terraform will happily apply prod sizing
onto dev's resources, and nothing warns you. Here that is not expressible.

A `workspace_guard` block rejects anything that is not `dev`, `staging` or
`prod`, and the Makefile refuses a workspace with no `env/<name>.tfvars`
before Terraform even starts. The `default` workspace is deliberately unusable:
it is the one you land in by accident.

---

## Layout

```
Makefile                     every command you need
terraform/
  main.tf                    wires the four modules together
  variables.tf               every input, with defaults
  outputs.tf                 what it tells you when it finishes
  env/
    dev.tfvars               ~$35/month
    staging.tfvars           ~$70/month
    prod.tfvars              ~$285/month
  modules/
    network/                 VPC, subnets, internet + NAT gateways, routing
    security/                security groups, IAM roles
    compute/                 bastion, control-plane and worker instances
    registry/                ECR repositories
kubespray/
  run.sh                     runs playbooks from the pinned container image
  group_vars/                cluster configuration — read the aws.yml first
  storage/                   the default StorageClass
  inventory/<workspace>/     written by apply, one per environment
scripts/kubeconfig.sh        kubectl access, tunnelled through the bastion
```

Read them in that order. `network` is the only one that makes sense alone;
each one after it depends on the one before.

---

## The loop

```bash
make init                       # once, and again after adding a provider
make check                      # fmt + validate — no AWS calls, no credentials
make plan    WORKSPACE=dev      # what would change
make apply   WORKSPACE=dev      # do it
make output  WORKSPACE=dev      # the ids and addresses it produced
make destroy WORKSPACE=dev      # stop the billing
```

`make check` is the fast loop while you are editing — it catches typos and type
errors in about a second without touching AWS. `make plan` is the slow one; it
calls AWS to see what already exists.

Other things worth knowing:

| Command                       | What it is for                                          |
| ----------------------------- | ------------------------------------------------------- |
| `make current WORKSPACE=prod` | what is selected, and the values it would use           |
| `make workspaces`             | every workspace, which is selected, how much each holds |
| `make cost WORKSPACE=prod`    | the monthly figure, read from that tfvars               |
| `make graph`                  | dependency graph as an SVG (needs graphviz)             |
| `make refresh WORKSPACE=dev`  | re-read reality into state, change nothing              |

### plan then apply, exactly

`make apply` re-plans and asks you to confirm. To apply _precisely_ what you
already reviewed, with no chance of something having changed in between:

```bash
make plan       WORKSPACE=dev    # writes terraform/tfplan
make apply-plan WORKSPACE=dev    # applies that file, no second prompt
```

This is what CI does. A saved plan cannot drift; a re-plan can.

---

## Money

You just tore down an account over this, so it is worth being blunt:

|                     | dev      | staging  | prod      |
| ------------------- | -------- | -------- | --------- |
| NAT gateways        | 1        | 2        | 3         |
| Control-plane nodes | 1        | 1        | 3         |
| Workers             | 2        | 2        | 3         |
| **Per month**       | **~$35** | **~$70** | **~$285** |

**The NAT gateway is the expensive thing, at about $32/month each**, and it
bills by the hour whether or not a single packet crosses it. Two of the three
lines above are mostly NAT.

`make destroy WORKSPACE=dev` when you stop for the day. Stopping instances is
not enough — EBS volumes bill while attached to a stopped instance, which is
exactly how a "stopped" account keeps costing money.

To confirm nothing survives:

```bash
make workspaces               # every workspace should read "empty"
```

---

## Before the first apply

Set your own IP in `terraform/env/dev.tfvars`, or SSH will be open to a
placeholder range and closed to you:

```bash
make myip     WORKSPACE=dev    # does it match? (exits non-zero if not)
make myip-set WORKSPACE=dev    # write the current one, then: make apply
```

Check this whenever SSH or `kubespray-ping` starts hanging. A wrong entry here
does not produce an error — the security group _drops_ the packets rather than
refusing them, so the connection hangs and Ansible eventually reports a
privilege-escalation timeout, which points at `sudo` and says nothing about the
real cause. Home and mobile addresses move; this is the first thing to check.

`0.0.0.0/0` is rejected by the security module on purpose. You also need an SSH
key at `~/.ssh/id_ed25519`; if you have none:

```bash
ssh-keygen -t ed25519 -C "learn" -f ~/.ssh/id_ed25519
```

---

## The cluster

`make apply` writes `kubespray/inventory/<workspace>/inventory.ini` — every
node's address, grouped the way Ansible wants — and Kubespray reads it from
there.

```bash
make cluster-up WORKSPACE=dev    # apply, pull, ping, then cluster.yml
make kubeconfig WORKSPACE=dev    # kubectl, through the bastion
make storage    WORKSPACE=dev    # EBS CSI driver + a default StorageClass
```

`cluster-up` stops at a working Kubernetes with nothing running on it. `make
up` is the same plus ingress, ECR credentials and the Helm release — see
[Quick start](#quick-start).

The first `cluster.yml` takes 20-40 minutes. Everything runs from
`quay.io/kubespray/kubespray:v2.31.0`, so the only tool to install is Docker.

Two things this cluster deliberately does not have — both explained in
[`kubespray/README.md`](kubespray/README.md):

- **No cloud controller manager.** Kubernetes dropped the in-tree AWS provider
  in 1.31 and Kubespray v2.31.0 ships no replacement, so `Service
type=LoadBalancer` stays Pending. Ingress is the ALB that Terraform creates,
  pointed at the NodePort `make ingress` pins the controller to.
- **No storage until `make storage`.** Kubespray's bundled EBS CSI driver
  points at an image last published in 2021; the upstream release is installed
  instead.
- **No ECR credentials until `make ecr-auth`.** The node role has the pull
  permission, but IAM permission is not a registry login — and the kubelet no
  longer makes that exchange itself. Upstream publishes no
  `ecr-credential-provider` binary, so this uses a pull secret refreshed every
  six hours instead. Without it, every pod sits in `ImagePullBackOff`.

Before tearing an environment down, `make cluster-down` — Kubernetes creates
ELBs and EBS volumes that Terraform does not know about, and they keep billing
after `make destroy`, as well as blocking the VPC from deleting.

The full platform in [`../devops/`](../devops/) is this plus monitoring and
multi-cloud deploy targets. Come back to it when this directory holds no
surprises.

---

## Three fixes already applied here

The copied configuration did not work. All three bugs also exist in
`../devops/`:

**It could not validate.** `main.tf` read `../helm/services.yaml` to decide
which ECR repositories to create — a file that does not exist in this tree.
It now reads `helm/values/<group>/services.yaml`, the same files Helm deploys
from, so the catalogue is in one place and a service added there gets its
repository on the next apply. Image tags and replica counts differ per
environment and live in `helm/env/<workspace>.yaml`.

**The AMI lookup matched nothing, in any region.** It asked for
`hvm-ssd-gp3` + `ubuntu-jammy-22.04`, and Canonical publishes 22.04 only under
`hvm-ssd`. The storage path is tied to the release. Now on 24.04, which is
where the gp3 images actually are, and behind a variable so you can check a
change before applying it:

**The node IAM policy denied every volume the cluster would create.** One
condition covered every action:

```hcl
Condition = { StringEquals = {
  "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
} }
```

A resource that does not exist yet carries no tags, so the condition is false
for `ec2:CreateVolume` and the call is denied. Every PVC would have sat Pending
with an AccessDenied buried in a csi-provisioner log. Replaced with the EBS CSI
driver's own published policy, which matches on `aws:RequestTag` while creating
and on the tags the driver writes when deleting.

```bash
aws ec2 describe-images --owners 099720109477 --region us-east-1 \
  --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
  --query 'length(Images)'
```

```bash
make ecr-auth WORKSPACE=dev
make env-apply WORKSPACE=dev
```

```bash
export KUBECONFIG=~/.kube/config-dev

kubectl get nodes
kubectl get nodes                    # the answer, most of the time
kubectl get nodes -o wide            # + internal IPs, OS, container runtime
kubectl get nodes -w                 # live — watch a node flip during scale/upgrade
kubectl describe node worker1
```
