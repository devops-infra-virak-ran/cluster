# Root configuration — wires the modules into one environment and renders the
# Kubespray inventory from the addresses Terraform just created.
#
#   make apply            → VPC, nodes, ECR + kubespray/inventory/<ws>/inventory.ini
#   make kubespray-deploy → Kubernetes on those nodes
#   make kubeconfig       → a kubectl that can reach it

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
# One ECR repository per service in the Helm catalogue.
#
# The catalogue is helm/values/<group>/services.yaml — the same files Helm
# deploys from. Terraform reads the names out of them rather than keeping its
# own copy, so a service exists in exactly one place and adding it there
# creates its repository on the next apply. Two lists that have to agree
# eventually will not.
#
# Only names are read. Image tags and replica counts differ per environment,
# live in helm/env/<workspace>.yaml, and are no business of the registry.

locals {
  values_dir = "${path.module}/../helm/values"

  # Every group file. A group may be split across several files, so this is a
  # glob rather than a fixed list.
  catalogue_files = sort(tolist(fileset(local.values_dir, "*/*.yaml")))

  # Decoded up front, and deliberately not wrapped in try(): a catalogue file
  # that is not valid YAML fails the plan naming the file, rather than being
  # silently skipped and taking its services' repositories with it.
  catalogue = {
    for f in local.catalogue_files :
    f => yamldecode(file("${local.values_dir}/${f}"))
  }

  # A file with no `groups:` key — a shared _defaults.yaml, say — contributes
  # nothing. distinct() because a service may be extended in a second file of
  # its own group, and it still gets one repository.
  #
  # Disabled services are included. A parked service keeps its repository, and
  # therefore its images, so re-enabling it does not mean rebuilding every tag.
  service_names = sort(distinct(flatten([
    for f, doc in local.catalogue : [
      for group, g in try(doc.groups, {}) : try(keys(g.services), [])
    ]
  ])))
}

# The validation that used to sit on the `services` variable. ECR repository
# names are the reason it matters: Terraform still owns those, so the check
# belongs here even though the catalogue moved.
resource "terraform_data" "service_names_guard" {
  lifecycle {
    precondition {
      condition = alltrue([
        for name in local.service_names : can(regex("^[a-z][a-z0-9-]*$", name))
      ])
      error_message = <<-ERR
        A service name in the Helm catalogue is not usable as an ECR repository.

        Names: lowercase letters, digits and hyphens, starting with a letter.

        Found: ${join(", ", local.service_names)}
        In:    helm/values/<group>/services.yaml
      ERR
    }
  }
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

# ─── Kubespray inventory ─────────────────────────────────────────────────────
# Terraform knows every address it just created, so it writes the inventory
# rather than leaving you to copy IPs out of the console.
#
#   ../kubespray/inventory/<workspace>/inventory.ini
#
# One directory per workspace, for the same reason state and tfvars are: a
# `make kubespray-deploy WORKSPACE=prod` must not be able to pick up dev's
# addresses. kubespray/run.sh re-checks the "Workspace:" line below before it
# starts a playbook.
#
# The path also matters to Ansible. group_vars/ is loaded from *next to* the
# inventory file, which is why run.sh mounts kubespray/group_vars into this
# directory inside the container rather than passing the values on the command
# line: extra-vars are the highest precedence tier in Ansible and would
# override Kubespray's own host_vars and role logic.
#
# It is an output, not a source file: never edit it, and expect `make apply`
# to overwrite it.

locals {
  # Absolute, because this path is also mounted into the Kubespray container at
  # the identical location — "~" there would resolve to /root.
  ssh_key = pathexpand(var.ssh_private_key_path)

  bastion_ip = module.compute.bastion_public_ip

  # Nodes have no public addresses, so Ansible reaches them by hopping through
  # the bastion. Without a bastion the only way in is from inside the VPC, and
  # a direct connection is the right thing to write.
  #
  # Keepalives on both hops. A long Kubespray task leaves the channel idle for
  # minutes; if it dies quietly, the next command blocks until Ansible's become
  # timeout and the host fails with "Timeout waiting for privilege escalation
  # prompt" — which says nothing about the connection being the problem.
  #
  # LogLevel=ERROR rather than -q on the ProxyCommand: -q also suppresses the
  # reason the hop failed, leaving only "Connection closed by UNKNOWN port
  # 65535" from the outer ssh, which is unactionable.
  keepalive = "-o ServerAliveInterval=30 -o ServerAliveCountMax=10"

  proxy_command = join(" ", [
    "ssh -W %h:%p",
    "-o LogLevel=ERROR",
    "-o StrictHostKeyChecking=accept-new",
    "-o ConnectTimeout=30",
    local.keepalive,
    "-i ${local.ssh_key} ${var.node_ssh_user}@${local.bastion_ip}",
  ])

  ssh_common_args = local.bastion_ip == null ? "-o StrictHostKeyChecking=accept-new ${local.keepalive}" : join(" ", [
    "-o StrictHostKeyChecking=accept-new",
    local.keepalive,
    "-o ProxyCommand=\"${local.proxy_command}\"",
  ])

  # Hosts are declared inside their group, the way Kubespray's own sample
  # inventory does it. etcd_member_name is required on every etcd member.
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
    # Regenerate with: make inventory WORKSPACE=${terraform.workspace}
    #
    # Cluster:     ${local.cluster_name}
    # Workspace:   ${terraform.workspace}
    # Region:      ${var.region}
    # Bastion:     ${coalesce(local.bastion_ip, "none — connect from inside the VPC")}

    [kube_control_plane]
    ${join("\n", local.control_plane_hosts)}

    # Stacked etcd: the control-plane nodes are the etcd members. Kubespray
    # refuses an even number of them, so this is 1 or 3, never 2.
    [etcd:children]
    kube_control_plane

    [kube_node]
    ${join("\n", local.worker_hosts)}

    # Calico route reflectors: empty, because this cluster runs Calico in VXLAN
    # mode, which needs no BGP peering. The group still has to exist — several
    # Kubespray playbooks address it.
    [calico_rr]

    # v2.31.0 composes k8s_cluster itself (roles/dynamic_groups), but only once
    # a playbook has run its boilerplate. Declaring it here means the group —
    # and therefore group_vars/k8s_cluster/ — also resolves for ad-hoc commands
    # like `ansible -m ping` and for --limit.
    [k8s_cluster:children]
    kube_control_plane
    kube_node
    calico_rr

    [all:vars]
    ansible_user=${var.node_ssh_user}
    ansible_ssh_private_key_file=${local.ssh_key}
    ansible_ssh_common_args='${local.ssh_common_args}'
  INI
}

# ─── Helm values ─────────────────────────────────────────────────────────────
# Terraform no longer writes any. It used to render helm/generated/<ws>.yaml
# from a `services` variable in env/<ws>.tfvars, which meant a service was
# declared in Terraform and configured in Helm — two files, one of which you
# always forgot.
#
# Now the whole service definition is Helm's:
#
#   helm/values/<group>/services.yaml   which services exist, everywhere
#   helm/env/<workspace>.yaml           tags and replicas, per environment
#
# Terraform reads the first for names only, above, so `make apply` still
# creates the ECR repositories. `make helm-deploy` passes both with -f.

resource "local_file" "inventory" {
  content         = local.inventory
  filename        = "${path.module}/../kubespray/inventory/${terraform.workspace}/inventory.ini"
  file_permission = "0644"
}
