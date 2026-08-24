variable "project_name" {
  type        = string
  description = "Project name used for resource naming and tagging"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
}

variable "repository_prefix" {
  type        = string
  description = "Namespace prefixed to every repository name, e.g. <prefix>/api"
}

variable "repositories" {
  type        = list(string)
  description = "Service names to create repositories for"
  default     = []
}

variable "image_tag_mutability" {
  type        = string
  description = "IMMUTABLE stops a tag being repointed after it ships"
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "Must be MUTABLE or IMMUTABLE."
  }
}

variable "scan_on_push" {
  type        = bool
  description = "Run the ECR vulnerability scan on every push"
  default     = true
}

variable "untagged_expiry_days" {
  type        = number
  description = "Days before untagged images are expired"
  default     = 7
}

variable "release_tag_prefixes" {
  type        = list(string)
  description = "Tag prefixes treated as releases and kept longer"
  default     = ["v", "release"]
}

variable "keep_release_images" {
  type        = number
  description = "Number of release-tagged images to keep"
  default     = 30
}

variable "keep_any_images" {
  type        = number
  description = "Number of images of any other tag to keep"
  default     = 10
}

variable "pull_principal_arns" {
  type        = list(string)
  description = "IAM principals granted pull access via the repository policy (the node role)"
  default     = []
}

variable "create_push_policy" {
  type        = bool
  description = "Create a managed policy granting push access, for the CI role"
  default     = true
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key for image encryption. Null uses AES256 with the AWS-managed key."
  default     = null
}

variable "force_delete" {
  type        = bool
  description = "Allow destroying repositories that still contain images"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Additional tags merged into every resource"
  default     = {}
}
