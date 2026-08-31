output "dns_name" {
  description = "The load balancer's AWS-assigned hostname"
  value       = aws_lb.this.dns_name
}

output "url" {
  description = "Base URL every route hangs off — what Helm renders into its notes"
  value       = "http://${aws_lb.this.dns_name}"
}

output "zone_id" {
  description = "Hosted zone of the load balancer, for an ALIAS record once there is a domain"
  value       = aws_lb.this.zone_id
}

output "arn" {
  description = "ARN of the load balancer"
  value       = aws_lb.this.arn
}

output "target_group_arn" {
  description = "ARN of the ingress target group"
  value       = aws_lb_target_group.ingress.arn
}

output "ingress_nodeport" {
  description = "NodePort the target group polls — `make ingress` pins the controller to it"
  value       = var.ingress_nodeport
}
