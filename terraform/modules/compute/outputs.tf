output "bastion_public_ip" {
  description = "Public IP of the bastion, or null when no bastion was created"
  value       = var.create_bastion ? aws_eip.bastion[0].public_ip : null
}

output "bastion_private_ip" {
  description = "Private IP of the bastion"
  value       = var.create_bastion ? aws_instance.bastion[0].private_ip : null
}

output "control_plane_private_ips" {
  description = "Private IPs of the control-plane nodes (Kubespray inventory)"
  value       = aws_instance.control_plane[*].private_ip
}

output "control_plane_instance_ids" {
  description = "Instance IDs of the control-plane nodes"
  value       = aws_instance.control_plane[*].id
}

output "worker_private_ips" {
  description = "Private IPs of the worker nodes (Kubespray inventory)"
  value       = aws_instance.worker[*].private_ip
}

output "worker_instance_ids" {
  description = "Instance IDs of the worker nodes"
  value       = aws_instance.worker[*].id
}

output "ssh_key_name" {
  description = "Name of the EC2 key pair installed on the nodes"
  value       = aws_key_pair.cluster.key_name
}

output "ami_id" {
  description = "AMI the nodes were built from"
  value       = local.ami_id
}
