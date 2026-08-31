# Load balancer module — the public front door.
#
#   internet → ALB :80 → worker NodePort → ingress-nginx → Service → pod
#
# The ALB is here rather than in Kubernetes because this cluster runs no cloud
# controller manager (see kubespray/group_vars/all/aws.yml). A Service of type
# LoadBalancer would stay Pending forever — nothing would be watching to create
# the ELB. So Terraform creates it and points it at a NodePort the ingress
# controller is pinned to.
#
# That is also why the target group is instance-typed and lists every worker:
# without a CCM there is no controller keeping target registration in step with
# the cluster, so the registration is Terraform's, and it changes when the node
# list changes.

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

  # ELB names are capped at 32 characters and AWS rejects anything longer
  # rather than truncating. project_name allows 25, so the untrimmed name can
  # go over on its own.
  lb_name = substr("${local.name_prefix}-alb", 0, 32)
  tg_name = substr("${local.name_prefix}-ingress", 0, 32)
}

# ─── Load balancer ───────────────────────────────────────────────────────────

resource "aws_lb" "this" {
  name               = local.lb_name
  internal           = false
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [var.security_group_id]

  # Off so `make destroy` works. Turn it on for anything you would be upset to
  # lose to a mistyped workspace.
  enable_deletion_protection = false

  tags = merge(local.common_tags, { Name = local.lb_name })
}

# ─── Target group ────────────────────────────────────────────────────────────

resource "aws_lb_target_group" "ingress" {
  name        = local.tg_name
  port        = var.ingress_nodeport
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  deregistration_delay = var.deregistration_delay

  health_check {
    enabled  = true
    path     = var.health_check_path
    protocol = "HTTP"
    matcher  = "200"

    # 10s/5s and 2 checks: a node that stops serving is out in about 20
    # seconds. The default 30s interval and 5 unhealthy checks means two and a
    # half minutes of requests going to a node that cannot answer them.
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.common_tags, { Name = local.tg_name })

  # The name is fixed, so a replacement would collide with the target group
  # still attached to the listener. Create the new one first.
  lifecycle {
    create_before_destroy = true
  }
}

# count, not for_each. Instance ids do not exist until apply, and for_each has
# to know every key at plan time — it fails with "the for_each set includes
# values derived from resource attributes that cannot be determined until
# apply". The list *length* is known, because it comes from worker_count, so
# count plans cleanly.
#
# The usual objection to count — that removing an element renumbers everything
# after it — does not apply: this list is aws_instance.worker[*].id, itself
# count-indexed, so index 2 stays index 2.
resource "aws_lb_target_group_attachment" "workers" {
  count = length(var.target_instance_ids)

  target_group_arn = aws_lb_target_group.ingress.arn
  target_id        = var.target_instance_ids[count.index]
  port             = var.ingress_nodeport
}

# ─── Listener ────────────────────────────────────────────────────────────────
# HTTP only. The security group already allows 443, but a TLS listener needs a
# certificate, and an ACM certificate needs a domain you control — neither of
# which this directory has. Add an aws_lb_listener on 443 with certificate_arn
# once there is one, and turn this into a redirect.

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress.arn
  }

  tags = local.common_tags
}
