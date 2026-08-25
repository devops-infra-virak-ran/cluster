# Registry module — one ECR repository per service, plus the IAM policy CI
# uses to push and the cluster uses to pull.

locals {
  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags
  )
  name_prefix = "${var.project_name}-${var.environment}"
}

# ─── Repositories ────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = "${var.repository_prefix}/${each.value}"
  image_tag_mutability = var.image_tag_mutability
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = var.kms_key_arn == null ? "AES256" : "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = merge(local.common_tags, { Name = "${var.repository_prefix}/${each.value}" })
}

# ─── Lifecycle policy ────────────────────────────────────────────────────────
# Rules are evaluated in priority order and an image matches only the first
# rule it hits, so the "untagged" rule must come before the catch-all.

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last ${var.keep_release_images} release images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = var.release_tag_prefixes
          countType     = "imageCountMoreThan"
          countNumber   = var.keep_release_images
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "Keep the last ${var.keep_any_images} images of any other tag"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_any_images
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ─── Repository policy ───────────────────────────────────────────────────────
# Lets the cluster nodes pull without any registry credentials in the cluster.

data "aws_iam_policy_document" "pull" {
  count = length(var.pull_principal_arns) > 0 ? 1 : 0

  statement {
    sid    = "AllowClusterPull"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.pull_principal_arns
    }

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
  }
}

resource "aws_ecr_repository_policy" "pull" {
  for_each = length(var.pull_principal_arns) > 0 ? aws_ecr_repository.this : {}

  repository = each.value.name
  policy     = data.aws_iam_policy_document.pull[0].json
}

# ─── CI push policy ──────────────────────────────────────────────────────────
# Attach to the Jenkins agent role so builds can push images without a
# long-lived registry password.
#
# Skipped when there are no repositories. The PushAndPull statement below
# resolves its Resource list from aws_ecr_repository.this, so with an empty
# catalogue it becomes Resource = [] — and IAM rejects that outright:
#
#   MalformedPolicyDocument: Policy statement must contain resources
#
# Terraform cannot catch this at plan time, because the policy body is only
# assembled during apply. It fails after everything else has been created.

resource "aws_iam_policy" "push" {
  count       = var.create_push_policy && length(var.repositories) > 0 ? 1 : 0
  name        = "${local.name_prefix}-ecr-push"
  description = "Push images to the ${var.repository_prefix} repositories"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AuthToRegistry"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PushAndPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeImages",
          "ecr:ListImages",
        ]
        Resource = [for r in aws_ecr_repository.this : r.arn]
      },
    ]
  })

  tags = local.common_tags
}
