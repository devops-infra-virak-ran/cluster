# ─── Identity ────────────────────────────────────────────────────────────────

variable "project_name" {
  type        = string
  description = "Project name used for resource naming and tagging"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,24}$", var.project_name))
    error_message = "Use lowercase letters, digits and hyphens (2-25 chars)."
  }
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "cluster_name" {
  type        = string
  description = "Kubernetes cluster name. Null falls back to <project>-<environment>."
  default     = null
}

# The service catalogue used to be a `services` variable here. It moved to
# helm/values/<group>/services.yaml, where the thing that deploys the services
# also reads them; main.tf reads the names back out of those files to create
# the ECR repositories. Per-environment tags and replicas live in
# helm/env/<workspace>.yaml.

variable "tags" {
  type        = map(string)
  description = "Extra tags merged into every resource"
  default     = {}
}

# ─── Network ─────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones to spread the cluster across"
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "single_nat_gateway" {
  type        = bool
  description = "One shared NAT gateway instead of one per AZ (~$32/mo each)"
  default     = true
}

variable "enable_flow_logs" {
  type        = bool
  description = "Ship rejected-traffic VPC flow logs to CloudWatch"
  default     = false
}

# ─── Access ──────────────────────────────────────────────────────────────────

variable "ssh_allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to SSH into the bastion"
}

variable "apiserver_allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach kube-apiserver directly (empty = via bastion only)"
  default     = []
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the public key installed on every node"
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to the matching private key, written into the Ansible inventory"
  default     = "~/.ssh/id_ed25519"
}

variable "node_ssh_user" {
  type        = string
  description = "SSH user on the nodes (ubuntu for Ubuntu AMIs, ec2-user for Amazon Linux)"
  default     = "ubuntu"
}

# ─── Ingress ─────────────────────────────────────────────────────────────────

variable "ingress_nodeport" {
  type        = number
  description = <<-DESC
    NodePort the ALB forwards to, and the port `make ingress` pins the ingress
    controller to. One number, used in two places that must agree — change it
    here and re-run both.
  DESC
  default     = 30080
}

# ─── Cluster nodes ───────────────────────────────────────────────────────────

variable "control_plane_count" {
  type        = number
  description = "Control-plane nodes. 1 for dev, 3 for a real etcd quorum."
  default     = 3
}

variable "control_plane_instance_type" {
  type        = string
  description = "Instance type for control-plane nodes"
  default     = "t3.medium"
}

variable "worker_count" {
  type        = number
  description = "Worker nodes. Scaling is deliberate: raise this, apply, then run kubespray-scale."
  default     = 3
}

variable "worker_instance_type" {
  type        = string
  description = "Instance type for worker nodes"
  default     = "t3.large"
}

variable "etcd_volume_size" {
  type        = number
  description = "Dedicated etcd volume in GB (0 keeps etcd on the root disk)"
  default     = 0
}
