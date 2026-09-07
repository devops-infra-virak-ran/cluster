# cluster

AWS infrastructure and a Kubernetes cluster built on top of it, managed from a single Terraform root with one environment per workspace.

---

## Quick Start

On a new machine, run this once:

```bash
make init                        # Download Terraform providers
make myip-set WORKSPACE=dev      # Add your public IP to the SSH allowlist
```

You need Docker, Terraform, AWS credentials, and an SSH key at:

```bash
~/.ssh/id_ed25519
```

Everything else runs from pinned containers.

To create the complete environment:

```bash
make up WORKSPACE=dev            # Takes approximately 35–55 minutes
```

To stop unnecessary billing:

```bash
make cluster-down WORKSPACE=dev  # Remove ELBs and volumes Terraform does not manage
make destroy WORKSPACE=dev
```

### What `up` Runs

Each command can also be run individually if you prefer to monitor the process step by step.

| #   | Command                 | Time      | Description                                                                |
| --- | ----------------------- | --------- | -------------------------------------------------------------------------- |
| 1   | `make myip`             | —         | Verifies that your IP address is allowlisted                               |
| 2   | `make apply`            | 5–8 min   | Creates the VPC, bastion, nodes, ECR repositories, and ALB                 |
| 3   | `make kubespray-pull`   | 1–3 min   | Pulls the pinned Kubespray image                                           |
| 4   | `make kubespray-ping`   | —         | Verifies Ansible connectivity to every node through the bastion            |
| 5   | `make kubespray-deploy` | 20–40 min | Deploys Kubernetes                                                         |
| 6   | `make tunnel`           | —         | Creates a kubeconfig and SSH tunnel to the API server                      |
| 7   | `make storage`          | ~1 min    | Installs the EBS CSI driver and configures gp3 as the default StorageClass |
| 8   | `make ingress`          | 1–2 min   | Installs ingress-nginx pinned to the NodePort monitored by the ALB         |
| 9   | `make ecr-auth`         | —         | Creates the ECR pull secret and refresh CronJob                            |
| 10  | `make helm-deploy`      | 1–2 min   | Deploys all services in the catalogue                                      |
| 11  | `make url`              | —         | Displays the URL for each service                                          |

Three parts of this order are important:

- **`tunnel`, not `kubeconfig`.** Both perform the same setup, but `kubeconfig` keeps the tunnel running in the foreground until `Ctrl+C`. This would stop a chained command sequence.

- **`ecr-auth` before `helm-deploy`.** The pull secret must exist before the first pod is scheduled. Otherwise, pods may enter `ImagePullBackOff`, causing `helm-deploy --wait` to eventually time out.

- **`ingress` before `helm-deploy`.** This is not strictly required, but the ALB targets become healthy only when something responds on the NodePort. Running ingress first ensures `url` works immediately after deployment.

### Day-to-Day Usage

Once the cluster is running, deploying application changes only requires the final steps:

```bash
make services    WORKSPACE=dev   # Show services in the catalogue and their tags
make env-apply WORKSPACE=dev
make helm-diff   WORKSPACE=dev   # Preview changes
make helm-deploy WORKSPACE=dev   # Deploy changes
```

This directory manages the infrastructure, networking, Kubernetes cluster, and Helm release running on top of it.

It does not handle multi-cloud deployments or CI/CD pipelines.

---

## The Core Concept

### The Workspace Is the Environment

The Terraform workspace determines two things simultaneously:

```text
make plan WORKSPACE=dev

                 │
                 ├──→ State:
                 │    ../terraform/terraform.tfstate.d/dev/terraform.tfstate
                 │
                 └──→ Variables:
                      ../terraform/env/dev.tfvars
```

`dev`, `staging`, and `prod` use the **same Terraform code** with different configuration values.

There is no separate `environment` variable because `main.tf` derives it directly from the Terraform workspace:

```hcl
environment = terraform.workspace
```

This prevents a common configuration mistake.

With a traditional variable approach, it is possible to select the `dev` Terraform state while accidentally passing `prod.tfvars`. Terraform would then apply production-sized resources to the development environment without warning.

With this structure, that situation cannot occur.

A `workspace_guard` block rejects any workspace other than:

- `dev`
- `staging`
- `prod`

The Makefile also refuses to run if the corresponding `env/<workspace>.tfvars` file does not exist.

The default Terraform workspace is intentionally unusable because it is easy to select accidentally.

---

## Project Layout

```text
Makefile
    All available commands

../terraform/
    Separate repo, beside this one. Override with TF_DIR=/path/to/terraform

    Makefile
        The Terraform targets on their own

    main.tf
        Connects the four Terraform modules

    variables.tf
        Defines all inputs and defaults

    outputs.tf
        Defines infrastructure outputs

    env/
        dev.tfvars
            ~$35/month

        staging.tfvars
            ~$70/month

        prod.tfvars
            ~$285/month

    modules/
        network/
            VPC, subnets, internet gateway, NAT gateways, routing

        security/
            Security groups and IAM roles

        compute/
            Bastion, control-plane, and worker instances

        registry/
            ECR repositories

kubespray/
    run.sh
        Runs playbooks using the pinned container image

    group_vars/
        Cluster configuration

    storage/
        Default StorageClass configuration

    inventory/<workspace>/
        Generated by Terraform for each environment

scripts/
    kubeconfig.sh
        Provides kubectl access through the bastion
```

The recommended reading order follows the dependency structure.

Start with `network`, then move through each module in sequence.

---

## Development Workflow

```bash
make init                       # Run once, and again after adding a provider

make check                      # Run fmt + validate without AWS calls

make plan WORKSPACE=dev         # Preview infrastructure changes

make apply WORKSPACE=dev        # Apply infrastructure changes

make output WORKSPACE=dev       # Display generated IDs and addresses

make destroy WORKSPACE=dev      # Remove infrastructure
```

### Fast vs. Slow Feedback

`make check` is the fast development loop.

It runs formatting and validation without contacting AWS, making it useful for catching syntax and type errors while editing.

`make plan` is slower because Terraform contacts AWS to compare the desired configuration with existing infrastructure.

### Other Useful Commands

| Command                       | Purpose                                                                |
| ----------------------------- | ---------------------------------------------------------------------- |
| `make current WORKSPACE=prod` | Shows the selected workspace and configuration values                  |
| `make workspaces`             | Lists all workspaces and their current state                           |
| `make cost WORKSPACE=prod`    | Displays the estimated monthly cost from the environment configuration |
| `make graph`                  | Generates a dependency graph as SVG (requires Graphviz)                |
| `make refresh WORKSPACE=dev`  | Refreshes Terraform state without changing infrastructure              |

### Plan Then Apply

`make apply` creates a new plan and asks for confirmation.

If you want to apply exactly the plan you previously reviewed:

```bash
make plan WORKSPACE=dev         # Writes ../terraform/tfplan
make apply-plan WORKSPACE=dev   # Applies the saved plan
```

This approach is useful in CI/CD.

A saved plan applies the exact changes that were reviewed. Running a new plan before applying introduces the possibility of infrastructure drift between the review and deployment steps.

---

## Cost Considerations

Infrastructure costs vary by environment:

| Resource                   |      Dev |  Staging |      Prod |
| -------------------------- | -------: | -------: | --------: |
| NAT Gateways               |        1 |        2 |         3 |
| Control-plane Nodes        |        1 |        1 |         3 |
| Worker Nodes               |        2 |        2 |         3 |
| **Estimated Monthly Cost** | **~$35** | **~$70** | **~$285** |

### NAT Gateways Are the Main Cost Driver

A NAT Gateway costs approximately $32 per month before data processing charges.

It continues billing hourly even when there is no traffic.

This means a significant portion of the environment cost comes from NAT Gateways.

When you are finished working:

```bash
make destroy WORKSPACE=dev
```

Stopping EC2 instances is not enough.

EBS volumes can continue generating charges even when instances are stopped.

To confirm that no Terraform-managed infrastructure remains:

```bash
make workspaces
```

Every workspace should show as empty.

---

## Before the First Apply

Your public IP address must be configured in the environment variables before deployment.

```bash
make myip WORKSPACE=dev      # Verify the configured IP

make myip-set WORKSPACE=dev  # Update the configuration with your current IP
```

This is important when troubleshooting SSH or `kubespray-ping` connectivity.

If the configured IP address is incorrect, the security group silently drops the connection rather than explicitly rejecting it.

As a result, SSH connections may hang and Ansible may eventually report a timeout that appears unrelated to the actual problem.

Home and mobile IP addresses can change frequently, so this should be one of the first things to check when connectivity fails.

For security reasons, `0.0.0.0/0` is rejected by the security module.

You also need an SSH key:

```bash
~/.ssh/id_ed25519
```

If you do not already have one:

```bash
ssh-keygen -t ed25519 -C "learn" -f ~/.ssh/id_ed25519
```

---

## The Kubernetes Cluster

Running Terraform generates the Kubespray inventory:

```text
kubespray/inventory/<workspace>/inventory.ini
```

This file contains the node addresses and groups required by Ansible and Kubespray.

To create the cluster:

```bash
make cluster-up WORKSPACE=dev    # Apply, pull, ping, and deploy cluster.yml

make kubeconfig WORKSPACE=dev    # Configure kubectl access through the bastion

make storage WORKSPACE=dev       # Install EBS CSI driver and default StorageClass
```

`cluster-up` stops after creating a working Kubernetes cluster with no application workloads.

`make up` performs the full setup, including:

- Ingress
- ECR authentication
- Helm deployments

The first Kubespray deployment typically takes 20–40 minutes.

Kubespray runs from the pinned container image:

```text
quay.io/kubespray/kubespray:v2.31.0
```

This means Docker is the only additional tool required to run Kubespray.

### Intentional Cluster Limitations

#### No Cloud Controller Manager

Kubernetes removed the in-tree AWS provider in version 1.31, and Kubespray v2.31.0 does not provide a replacement.

As a result:

```text
Service type=LoadBalancer
```

will remain in the `Pending` state.

Instead, ingress traffic is handled by the Terraform-managed ALB, which forwards traffic to the NodePort used by ingress-nginx.

#### No Storage Until `make storage`

The bundled EBS CSI driver configuration in Kubespray uses an outdated image.

The project installs the upstream EBS CSI driver instead.

#### No ECR Credentials Until `make ecr-auth`

The EC2 node IAM role has permission to pull from ECR, but IAM permissions alone do not automatically authenticate Kubernetes workloads to the registry.

The cluster therefore uses an image pull secret that is refreshed every six hours.

Without this configuration, workloads pulling images from ECR may enter:

```text
ImagePullBackOff
```

### Before Destroying an Environment

Always run:

```bash
make cluster-down WORKSPACE=dev
```

before:

```bash
make destroy WORKSPACE=dev
```

Kubernetes can create AWS resources such as:

- ELBs
- EBS volumes

Terraform may not know about these resources.

If they remain after Terraform destroys the infrastructure, they can continue generating charges and may prevent the VPC from being deleted.

---

## Three Important Fixes Applied

The original copied configuration contained several issues.

### 1. Terraform Validation Failed

`main.tf` previously attempted to read:

```text
../helm/services.yaml
```

However, that file does not exist in this repository.

The configuration now reads:

```text
helm/values/<group>/services.yaml
```

These are the same service catalogue files used by Helm.

This creates a single source of truth.

When a service is added to the catalogue, Terraform creates its ECR repository during the next infrastructure apply.

Environment-specific settings such as image tags and replica counts are stored separately:

```text
helm/env/<workspace>.yaml
```

### 2. AMI Lookup Returned No Results

The previous AMI lookup searched for:

```text
hvm-ssd-gp3 + ubuntu-jammy-22.04
```

However, Canonical publishes Ubuntu 22.04 under a different storage naming pattern.

The configuration now uses Ubuntu 24.04, where the gp3 AMI pattern is available.

The AMI configuration is also controlled through a variable so changes can be reviewed before applying.

Example verification:

```bash
aws ec2 describe-images \
  --owners 099720109477 \
  --region us-east-1 \
  --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
  --query 'length(Images)'
```

### 3. IAM Policy Prevented EBS Volume Creation

The previous IAM policy applied a resource tag condition to every action:

```hcl
Condition = {
  StringEquals = {
    "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}
```

This caused a problem during:

```text
ec2:CreateVolume
```

A new volume does not exist yet and therefore cannot already contain the required resource tags.

As a result, the request would be denied.

This could cause PersistentVolumeClaims to remain in the `Pending` state with an `AccessDenied` error in the CSI provisioner logs.

The policy was replaced with the EBS CSI driver's recommended IAM policy.

The correct policy uses:

- `aws:RequestTag` when creating resources
- Existing resource tags when deleting resources

---

## Useful Commands

```bash
make ecr-auth WORKSPACE=dev
make env-apply WORKSPACE=dev
```

Configure kubectl:

```bash
export KUBECONFIG=~/.kube/config-dev
```

Check cluster nodes:

```bash
kubectl get nodes
```

Other useful variations:

```bash
kubectl get nodes -o wide
```

Displays additional information such as:

- Internal IP addresses
- Operating system
- Container runtime

Watch node changes in real time:

```bash
kubectl get nodes -w
```

Inspect a specific node:

```bash
kubectl describe node worker1
```

In most Kubernetes troubleshooting situations, the first command to run is:

```bash
kubectl get nodes
```
