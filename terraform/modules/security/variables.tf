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
  description = "Kubernetes cluster name, used to scope node IAM permissions by tag"
}

variable "vpc_id" {
  type        = string
  description = "VPC the security groups belong to"
}

variable "ssh_allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to SSH into the bastion. Keep this to known office/VPN ranges."

  validation {
    condition     = !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "Refusing to open SSH to the whole internet. Use a specific CIDR."
  }
}

variable "apiserver_allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach kube-apiserver on 6443 directly (empty = bastion only)"
  default     = []
}

variable "cloud_provider_integration" {
  type        = bool
  description = <<-DESC
    Grant nodes the EC2 permissions the AWS EBS CSI driver needs to provision,
    attach and delete PersistentVolumes. Turn it off for a cluster that has no
    storage driver.

    It does not grant ELB permissions: Service type=LoadBalancer needs the AWS
    cloud controller manager, which Kubespray v2.31.0 does not install.
  DESC
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Additional tags merged into every resource"
  default     = {}
}
