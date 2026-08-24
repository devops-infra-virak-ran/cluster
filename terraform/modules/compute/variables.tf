variable "project_name" {
  type        = string
  description = "Project name used for resource naming and tagging"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
}

variable "cluster_name" {
  type        = string
  description = "Kubernetes cluster name, applied as a kubernetes.io/cluster/<name>=owned tag"
}

variable "ami_name_filter" {
  type        = string
  description = "Name pattern for the AMI lookup. gp3 images exist for 24.04, not for 22.04."
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
}

variable "ami_id" {
  type        = string
  description = "AMI for all nodes. Empty looks up the latest Ubuntu 22.04 LTS."
  default     = ""
}

variable "ssh_public_key" {
  type        = string
  description = "OpenSSH public key installed on every node"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnets (bastion goes in the first one)"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets; nodes are spread across these round-robin"
}

variable "bastion_security_group_id" {
  type        = string
  description = "Security group for the bastion"
}

variable "control_plane_security_group_id" {
  type        = string
  description = "Security group for control-plane nodes"
}

variable "worker_security_group_id" {
  type        = string
  description = "Security group for worker nodes"
}

variable "node_instance_profile_name" {
  type        = string
  description = "IAM instance profile attached to every node"
}

variable "create_bastion" {
  type        = bool
  description = "Provision the bastion host"
  default     = true
}

variable "bastion_instance_type" {
  type        = string
  description = "Instance type for the bastion"
  default     = "t3.micro"
}

variable "control_plane_count" {
  type        = number
  description = "Number of control-plane nodes. Use 1 for dev, 3 for HA etcd quorum."
  default     = 1

  validation {
    condition     = var.control_plane_count % 2 == 1
    error_message = "Control-plane count must be odd so etcd can form a quorum."
  }
}

variable "control_plane_instance_type" {
  type        = string
  description = "Instance type for control-plane nodes (2 vCPU / 4 GB is the practical floor)"
  default     = "t3.medium"
}

variable "control_plane_root_volume_size" {
  type        = number
  description = "Root volume size in GB for control-plane nodes"
  default     = 50
}

variable "etcd_volume_size" {
  type        = number
  description = "Size in GB of the dedicated etcd volume. 0 keeps etcd on the root disk."
  default     = 0
}

variable "worker_count" {
  type        = number
  description = "Number of worker nodes"
  default     = 2
}

variable "worker_instance_type" {
  type        = string
  description = "Instance type for worker nodes"
  default     = "t3.large"
}

variable "worker_root_volume_size" {
  type        = number
  description = "Root volume size in GB for worker nodes (image layers live here)"
  default     = 100
}

variable "tags" {
  type        = map(string)
  description = "Additional tags merged into every resource"
  default     = {}
}
