# Root configuration — wires the modules into one environment and renders the
# Kubespray inventory from the addresses Terraform just created.
#
#   terraform apply      → VPC, nodes, ECR + kubespray/inventory/inventory.ini
#   make kubespray-deploy → Kubernetes on those nodes
#   make deploy      → workloads on that cluster

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Remote state. Create the bucket and lock table once (see docs/), then
  # uncomment and run: terraform init -migrate-state
  #
  # backend "s3" {
  #   bucket       = "terraform-state-<account-id>-<region>"
  #   key          = "devops/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = local.environment
      ManagedBy   = "terraform"
      Repository  = "devops"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # The workspace IS the environment. `make apply WORKSPACE=dev` selects the
  # dev state and the dev variables together, so there is no way to apply prod
  # sizing onto dev's resources — the mistake a plain `environment` variable
  # leaves open, because nothing stops you passing prod.tfvars while the dev
  # state is selected.
  environment = terraform.workspace

  name_prefix  = "${var.project_name}-${local.environment}"
  cluster_name = coalesce(var.cluster_name, local.name_prefix)
}

# Terraform has no validation block for a workspace name, so this is the check.
# It fails at plan time, before anything is created.
resource "terraform_data" "workspace_guard" {
  lifecycle {
    precondition {
      condition     = contains(["dev", "staging", "prod"], terraform.workspace)
      error_message = <<-ERR
        Workspace "${terraform.workspace}" is not one of dev, staging, prod.

        The 'default' workspace is deliberately not usable: it is the one you
        land in by accident, and it is where people apply prod changes while
        thinking they are somewhere else.

            make plan WORKSPACE=dev
      ERR
    }
  }
}

# ─── Network ─────────────────────────────────────────────────────────────────

module "network" {
  source = "./modules/network"

  project_name       = var.project_name
  environment        = local.environment
  region             = var.region
  cluster_name       = local.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  single_nat_gateway = var.single_nat_gateway
  enable_flow_logs   = var.enable_flow_logs
  tags               = var.tags
}

# ─── Security ────────────────────────────────────────────────────────────────

module "security" {
  source = "./modules/security"

  project_name            = var.project_name
  environment             = local.environment
  cluster_name            = local.cluster_name
  vpc_id                  = module.network.vpc_id
  ssh_allowed_cidrs       = var.ssh_allowed_cidrs
  apiserver_allowed_cidrs = var.apiserver_allowed_cidrs
  tags                    = var.tags
}

# ─── Compute ─────────────────────────────────────────────────────────────────

module "compute" {
  source = "./modules/compute"

  project_name = var.project_name
  environment  = local.environment
  cluster_name = local.cluster_name

  ssh_public_key     = file(pathexpand(var.ssh_public_key_path))
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids

  bastion_security_group_id       = module.security.bastion_security_group_id
  control_plane_security_group_id = module.security.control_plane_security_group_id
  worker_security_group_id        = module.security.worker_security_group_id
  node_instance_profile_name      = module.security.node_instance_profile_name

  control_plane_count         = var.control_plane_count
  control_plane_instance_type = var.control_plane_instance_type
  worker_count                = var.worker_count
  worker_instance_type        = var.worker_instance_type
  etcd_volume_size            = var.etcd_volume_size

  tags = var.tags
}

# ─── Registry ────────────────────────────────────────────────────────────────
# One ECR repository per name in var.services, set in env/<workspace>.tfvars.
#
# The full platform reads this list out of helm/services.yaml so that adding a
# service to the catalogue creates its repository automatically. That coupling
# is worth having once Helm exists; here it would only be a file reference to
# a directory that is not in this tree.

locals {
  service_names = sort(var.services)
}

module "registry" {
  source = "./modules/registry"

  project_name        = var.project_name
  environment         = local.environment
  repository_prefix   = var.project_name
  repositories        = local.service_names
  pull_principal_arns = [module.security.node_role_arn]

  tags = var.tags
}

# ─── Ansible inventory ───────────────────────────────────────────────────────
# Terraform knows every address it just created, so it writes the inventory
# rather than leaving you to copy IPs out of the console. Nothing in this
# directory consumes it yet — installing Kubernetes on these machines is the
# next thing to learn, and this file is what it will read.
#
# It is an output, not a source file: never edit it, and expect `make apply`
# to overwrite it.

locals {
  # Absolute, because this path is also mounted into the Kubespray container at
  # the identical location — "~" there would resolve to /root.
  ssh_key = pathexpand(var.ssh_private_key_path)

  control_plane_hosts = [
    for i, ip in module.compute.control_plane_private_ips :
    "cp${i + 1} ansible_host=${ip} ip=${ip} etcd_member_name=etcd${i + 1}"
  ]

  worker_hosts = [
    for i, ip in module.compute.worker_private_ips :
    "worker${i + 1} ansible_host=${ip} ip=${ip}"
  ]

  inventory = <<-INI
    # Generated by Terraform — do not edit by hand.
    # Regenerate with: make apply WORKSPACE=<env>
    #
    # Cluster:     ${local.cluster_name}
    # Region:      ${var.region}
    # Workspace:   ${terraform.workspace}
    # Bastion:     ${coalesce(module.compute.bastion_public_ip, "none")}

    [all]
    ${join("\n", concat(local.control_plane_hosts, local.worker_hosts))}

    [kube_control_plane]
    ${join("\n", [for i, _ in module.compute.control_plane_private_ips : "cp${i + 1}"])}

    [etcd]
    ${join("\n", [for i, _ in module.compute.control_plane_private_ips : "cp${i + 1}"])}

    [kube_node]
    ${join("\n", [for i, _ in module.compute.worker_private_ips : "worker${i + 1}"])}

    [calico_rr]

    [k8s_cluster:children]
    kube_control_plane
    kube_node
    calico_rr

    [all:vars]
    ansible_user=${var.node_ssh_user}
    ansible_ssh_private_key_file=${local.ssh_key}
    ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new -o ProxyCommand="ssh -W %h:%p -q -o StrictHostKeyChecking=accept-new -i ${local.ssh_key} ${var.node_ssh_user}@${coalesce(module.compute.bastion_public_ip, "127.0.0.1")}"'
  INI
}

resource "local_file" "inventory" {
  content         = local.inventory
  filename        = "${path.module}/inventory/hosts.ini"
  file_permission = "0644"
}
