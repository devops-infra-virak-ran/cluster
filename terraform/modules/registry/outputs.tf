output "repository_urls" {
  description = "Map of service name to repository URL"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "Map of service name to repository ARN"
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}

output "registry_url" {
  description = "Registry host to docker login against"
  value       = length(aws_ecr_repository.this) > 0 ? split("/", values(aws_ecr_repository.this)[0].repository_url)[0] : null
}

output "push_policy_arn" {
  description = "ARN of the push policy to attach to the CI role"
  value       = var.create_push_policy ? aws_iam_policy.push[0].arn : null
}
