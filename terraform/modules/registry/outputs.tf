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
  description = "ARN of the push policy to attach to the CI role, or null if there is none"

  # one() returns the single element, or null for an empty list. Reading
  # var.create_push_policy here instead would be a guess about whether the
  # resource exists — and the wrong one, since the policy is also skipped when
  # there are no repositories to grant access to.
  value = one(aws_iam_policy.push[*].arn)
}
