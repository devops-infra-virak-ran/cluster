output "bastion_security_group_id" {
  description = "Security group ID for the bastion host"
  value       = aws_security_group.bastion.id
}

output "alb_security_group_id" {
  description = "Security group ID for the public load balancer"
  value       = aws_security_group.alb.id
}

output "control_plane_security_group_id" {
  description = "Security group ID for control-plane nodes"
  value       = aws_security_group.control_plane.id
}

output "worker_security_group_id" {
  description = "Security group ID for worker nodes"
  value       = aws_security_group.worker.id
}

output "node_instance_profile_name" {
  description = "Instance profile attached to every cluster node"
  value       = aws_iam_instance_profile.node.name
}

output "node_role_arn" {
  description = "ARN of the node IAM role"
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "Name of the node IAM role, for attaching additional policies"
  value       = aws_iam_role.node.name
}
