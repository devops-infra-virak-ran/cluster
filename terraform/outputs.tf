# ─── Access ──────────────────────────────────────────────────────────────────

output "bastion_public_ip" {
  description = "Public IP of the bastion host"
  value       = module.compute.bastion_public_ip
}

output "bastion_ssh_command" {
  description = "Ready-to-paste SSH command for the bastion"
  value       = "ssh -i ${var.ssh_private_key_path} ${var.node_ssh_user}@${module.compute.bastion_public_ip}"
}

output "nat_gateway_public_ips" {
  description = "Cluster egress IPs — allowlist these on third-party services"
  value       = module.network.nat_gateway_public_ips
}

# ─── Cluster ─────────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "Kubernetes cluster name"
  value       = local.cluster_name
}

output "control_plane_private_ips" {
  description = "Private IPs of the control-plane nodes"
  value       = module.compute.control_plane_private_ips
}

output "worker_private_ips" {
  description = "Private IPs of the worker nodes"
  value       = module.compute.worker_private_ips
}

output "inventory_path" {
  description = "Kubespray inventory rendered by this apply"
  value       = local_file.inventory.filename
}

# ─── Network ─────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets holding the cluster nodes"
  value       = module.network.private_subnet_ids
}

# ─── Load balancer ───────────────────────────────────────────────────────────

output "alb_url" {
  description = "Base URL of the public load balancer — what every route hangs off"
  value       = module.loadbalancer.url
}

output "alb_dns_name" {
  description = "The load balancer's hostname, for a CNAME or ALIAS record"
  value       = module.loadbalancer.dns_name
}

output "ingress_nodeport" {
  description = "NodePort the ALB polls — `make ingress` pins the controller to it"
  value       = module.loadbalancer.ingress_nodeport
}

# ─── Registry ────────────────────────────────────────────────────────────────

output "ecr_registry_url" {
  description = "Registry host to docker login against"
  value       = module.registry.registry_url
}

output "ecr_image_prefix" {
  description = "What every image name is prefixed with — registry host plus the repository prefix"

  # This is the value Helm needs, not ecr_registry_url. Repositories are named
  # <project>/<service>, so the host alone would resolve to a repository that
  # does not exist and every pod would sit in ImagePullBackOff.
  #
  #   make helm-deploy passes it as global.imageRegistry
  #
  # Null before the first apply, because there are no repositories yet to read
  # the account and region back from.
  value = module.registry.registry_url == null ? null : "${module.registry.registry_url}/${var.project_name}"
}

output "services" {
  description = "Service names that got an ECR repository"
  value       = local.service_names
}

output "environment" {
  description = "Which environment this state holds — always the workspace name"
  value       = local.environment
}

output "ecr_repository_urls" {
  description = "Map of service name to ECR repository URL"
  value       = module.registry.repository_urls
}

output "ecr_login_command" {
  description = "Docker login command for the registry"
  value       = "aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}
