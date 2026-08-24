# devops-01

AWS infrastructure only. One Terraform root, one environment per workspace.

```bash
make plan    WORKSPACE=dev
make apply   WORKSPACE=dev
make destroy WORKSPACE=dev
```

No Helm, no Kubernetes, no other cloud. This directory builds machines and the
network around them, and stops there.

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

`dev`, `staging` and `prod` are the *same code* with different numbers. There
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
  inventory/hosts.ini        written by apply — the bridge to installing Kubernetes
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

| Command | What it is for |
| --- | --- |
| `make current WORKSPACE=prod` | what is selected, and the values it would use |
| `make workspaces` | every workspace, which is selected, how much each holds |
| `make cost WORKSPACE=prod` | the monthly figure, read from that tfvars |
| `make graph` | dependency graph as an SVG (needs graphviz) |
| `make refresh WORKSPACE=dev` | re-read reality into state, change nothing |

### plan then apply, exactly

`make apply` re-plans and asks you to confirm. To apply *precisely* what you
already reviewed, with no chance of something having changed in between:

```bash
make plan       WORKSPACE=dev    # writes terraform/tfplan
make apply-plan WORKSPACE=dev    # applies that file, no second prompt
```

This is what CI does. A saved plan cannot drift; a re-plan can.

---

## Money

You just tore down an account over this, so it is worth being blunt:

| | dev | staging | prod |
| --- | --- | --- | --- |
| NAT gateways | 1 | 2 | 3 |
| Control-plane nodes | 1 | 1 | 3 |
| Workers | 2 | 2 | 3 |
| **Per month** | **~$35** | **~$70** | **~$285** |

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
curl -s ifconfig.me            # then edit ssh_allowed_cidrs
```

`0.0.0.0/0` is rejected by the security module on purpose. You also need an SSH
key at `~/.ssh/id_ed25519`; if you have none:

```bash
ssh-keygen -t ed25519 -C "learn" -f ~/.ssh/id_ed25519
```

---

## What this is not

It does not install Kubernetes. `make apply` writes
`terraform/inventory/hosts.ini` — every node's address, grouped the way Ansible
wants — and that is where the next thing picks up. Nothing in this directory
reads it yet.

The full platform in [`../devops/`](../devops/) is this plus Kubespray, Helm, a
service catalogue, monitoring and multi-cloud deploy targets. Come back to it
when this directory holds no surprises.

---

## Two fixes already applied here

The copied configuration did not work. Both bugs also exist in `../devops/`:

**It could not validate.** `main.tf` read `../helm/services.yaml` to decide
which ECR repositories to create — a file that does not exist in this tree.
Replaced with a plain `services` variable in `env/<workspace>.tfvars`.

**The AMI lookup matched nothing, in any region.** It asked for
`hvm-ssd-gp3` + `ubuntu-jammy-22.04`, and Canonical publishes 22.04 only under
`hvm-ssd`. The storage path is tied to the release. Now on 24.04, which is
where the gp3 images actually are, and behind a variable so you can check a
change before applying it:

```bash
aws ec2 describe-images --owners 099720109477 --region us-east-1 \
  --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
  --query 'length(Images)'
```
