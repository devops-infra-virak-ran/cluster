variable "project_name" {
  type        = string
  description = "Project name used for resource naming and tagging"
}

variable "environment" {
  type        = string
  description = "Environment name — the Terraform workspace"
}

variable "vpc_id" {
  type        = string
  description = "VPC the target group resolves instance targets in"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = <<-DESC
    Public subnets to place the load balancer nodes in.

    An ALB needs at least two, in different availability zones. AWS rejects one
    outright, which is why dev still runs two subnets even though it runs one
    NAT gateway.
  DESC

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An ALB needs at least two subnets in different availability zones."
  }
}

variable "security_group_id" {
  type        = string
  description = "The load balancer security group — 80/443 in, NodePort range out"
}

variable "target_instance_ids" {
  type        = list(string)
  description = <<-DESC
    Instances to register as targets — the worker nodes.

    Every worker is registered, not just the ones running an ingress controller
    pod. kube-proxy forwards a NodePort from any node to wherever the pod
    actually is, so a node with no controller pod still serves the port and
    still passes the health check.
  DESC
  default     = []
}

variable "ingress_nodeport" {
  type        = number
  description = <<-DESC
    The NodePort the in-cluster ingress controller listens on.

    Fixed rather than allocated, because Terraform has to know it to build the
    target group and it is created after Terraform runs. `make ingress` pins
    the controller to the same number; they are one decision in two places.
  DESC
  default     = 30080

  validation {
    condition     = var.ingress_nodeport >= 30000 && var.ingress_nodeport <= 32767
    error_message = "Must be inside the NodePort range 30000-32767, which is what the security group allows."
  }
}

variable "health_check_path" {
  type        = string
  description = <<-DESC
    Path the ALB polls to decide a target is up.

    /healthz is served by ingress-nginx's own default server and returns 200
    without touching any backend, so a target stays healthy even when every
    application pod is down — which is what you want, or a bad deploy would
    also take the load balancer's targets out and hide the real error behind a
    503 from AWS instead of the ingress controller's own response.
  DESC
  default     = "/healthz"
}

variable "deregistration_delay" {
  type        = number
  description = "Seconds to keep draining a removed target. Low in dev, where nodes come and go."
  default     = 30
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged into every resource"
  default     = {}
}
