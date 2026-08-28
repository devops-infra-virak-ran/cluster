# Security module — security groups and node IAM for the Kubespray cluster.
#
# Traffic model:
#   internet → bastion (SSH)        → control-plane / workers (SSH)
#   internet → alb (80/443)         → workers (NodePort)
#   workers  ↔ control-plane        → all cluster ports + CNI overlay
#
# Nodes reach any external database over NAT egress, which the worker and
# control-plane egress rules already allow.

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

# ─── Bastion ─────────────────────────────────────────────────────────────────

resource "aws_security_group" "bastion" {
  name        = "${local.name_prefix}-bastion-sg"
  description = "SSH entry point to the cluster nodes"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-bastion-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.bastion.id
  description       = "SSH from operator network"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "bastion_all" {
  security_group_id = aws_security_group.bastion.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ─── Load balancer ───────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Public load balancer fronting the ingress controller"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-alb-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere (redirected to HTTPS)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_nodes" {
  security_group_id            = aws_security_group.alb.id
  description                  = "NodePort range on the workers"
  referenced_security_group_id = aws_security_group.worker.id
  from_port                    = 30000
  to_port                      = 32767
  ip_protocol                  = "tcp"
}

# ─── Control plane ───────────────────────────────────────────────────────────

resource "aws_security_group" "control_plane" {
  name        = "${local.name_prefix}-control-plane-sg"
  description = "Kubernetes control-plane nodes (apiserver, etcd, scheduler)"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-control-plane-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cp_ssh_from_bastion" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "SSH from bastion (Kubespray runs from here)"
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "cp_apiserver_from_workers" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "kube-apiserver from worker nodes"
  referenced_security_group_id = aws_security_group.worker.id
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "cp_apiserver_from_bastion" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "kube-apiserver from bastion (kubectl / CI)"
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "cp_apiserver_external" {
  for_each = toset(var.apiserver_allowed_cidrs)

  security_group_id = aws_security_group.control_plane.id
  description       = "kube-apiserver from an allowlisted operator network"
  cidr_ipv4         = each.value
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "cp_self" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "etcd peer/client and control-plane internals"
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "cp_kubelet_from_workers" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "kubelet API from worker nodes (metrics-server, logs)"
  referenced_security_group_id = aws_security_group.worker.id
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "cp_cni_from_workers" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "CNI overlay traffic from worker nodes"
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "cp_all" {
  security_group_id = aws_security_group.control_plane.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ─── Workers ─────────────────────────────────────────────────────────────────

resource "aws_security_group" "worker" {
  name        = "${local.name_prefix}-worker-sg"
  description = "Kubernetes worker nodes"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-worker-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "worker_ssh_from_bastion" {
  security_group_id            = aws_security_group.worker.id
  description                  = "SSH from bastion"
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "worker_self" {
  security_group_id            = aws_security_group.worker.id
  description                  = "Pod-to-pod traffic between workers"
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "worker_from_control_plane" {
  security_group_id            = aws_security_group.worker.id
  description                  = "kubelet, CNI and control-plane traffic"
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "worker_nodeport_from_alb" {
  security_group_id            = aws_security_group.worker.id
  description                  = "NodePort range from the public load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 30000
  to_port                      = 32767
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "worker_all" {
  security_group_id = aws_security_group.worker.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ─── Node IAM ────────────────────────────────────────────────────────────────
# Attached to every cluster node: SSM for keyless shell access, ECR pull for
# images, and (when cloud_provider_integration is on) the EC2 permissions the
# EBS CSI driver needs to back PersistentVolumeClaims with real volumes.

resource "aws_iam_role" "node" {
  name = "${local.name_prefix}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "node_ecr_pull" {
  name = "${local.name_prefix}-node-ecr-pull"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
      ]
      Resource = "*"
    }]
  })
}

# EBS CSI driver permissions, taken from the driver's own example policy
# (kubernetes-sigs/aws-ebs-csi-driver, docs/example-iam-policy.json) rather
# than written by hand — the conditions are the subtle part.
#
# What it replaced did not work. Every action sat under one condition:
#
#   "aws:ResourceTag/kubernetes.io/cluster/<name>" = "owned"
#
# A resource that does not exist yet carries no tags, so the condition is false
# for ec2:CreateVolume and the call is denied. Every PVC would have stayed
# Pending with an AccessDenied buried in the csi-provisioner log. The driver
# tags what it creates with ebs.csi.aws.com/cluster and CSIVolumeName, which is
# what the delete and snapshot statements below match on instead.
#
# Service type=LoadBalancer is deliberately absent: provisioning an ELB from
# inside the cluster needs the AWS cloud controller manager, which Kubespray
# v2.31.0 does not ship — external_cloud_provider accepts only hcloud,
# huaweicloud, oci, openstack, vsphere and manual. Ingress here is the ALB in
# front of the NodePort range, which Terraform owns.

resource "aws_iam_role_policy" "node_ebs_csi" {
  count = var.cloud_provider_integration ? 1 : 0
  name  = "${local.name_prefix}-node-ebs-csi"
  role  = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Describe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeSnapshots",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumesModifications",
          "ec2:DescribeVolumeStatus",
        ]
        Resource = "*"
      },
      {
        Sid      = "SnapshotAndResizeVolumes"
        Effect   = "Allow"
        Action   = ["ec2:CreateSnapshot", "ec2:ModifyVolume"]
        Resource = "arn:aws:ec2:*:*:volume/*"
      },
      {
        Sid      = "AttachDetach"
        Effect   = "Allow"
        Action   = ["ec2:AttachVolume", "ec2:DetachVolume"]
        Resource = ["arn:aws:ec2:*:*:volume/*", "arn:aws:ec2:*:*:instance/*"]
      },
      {
        Sid      = "CreateVolumeFromSnapshot"
        Effect   = "Allow"
        Action   = ["ec2:CreateVolume"]
        Resource = "arn:aws:ec2:*:*:snapshot/*"
      },
      {
        # Tagging is only allowed as part of the create call that the driver
        # makes, never as a standalone re-tag of something else.
        Sid      = "TagOnCreate"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = ["arn:aws:ec2:*:*:volume/*", "arn:aws:ec2:*:*:snapshot/*"]
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = ["CreateVolume", "CreateSnapshot"]
          }
        }
      },
      {
        Sid      = "Untag"
        Effect   = "Allow"
        Action   = ["ec2:DeleteTags"]
        Resource = ["arn:aws:ec2:*:*:volume/*", "arn:aws:ec2:*:*:snapshot/*"]
      },
      {
        # aws:RequestTag, not aws:ResourceTag: the tag is being applied by this
        # very call, so it is part of the request and not yet on a resource.
        Sid      = "CreateVolumeTaggedByTheDriver"
        Effect   = "Allow"
        Action   = ["ec2:CreateVolume"]
        Resource = "arn:aws:ec2:*:*:volume/*"
        Condition = {
          StringLike = {
            "aws:RequestTag/ebs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Sid      = "CreateVolumeForAPersistentVolumeClaim"
        Effect   = "Allow"
        Action   = ["ec2:CreateVolume"]
        Resource = "arn:aws:ec2:*:*:volume/*"
        Condition = {
          StringLike = {
            "aws:RequestTag/CSIVolumeName" = "*"
          }
        }
      },
      {
        Sid      = "DeleteVolumesTheDriverCreated"
        Effect   = "Allow"
        Action   = ["ec2:DeleteVolume"]
        Resource = "arn:aws:ec2:*:*:volume/*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/ebs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Sid      = "DeleteVolumesBackingAPersistentVolumeClaim"
        Effect   = "Allow"
        Action   = ["ec2:DeleteVolume"]
        Resource = "arn:aws:ec2:*:*:volume/*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/CSIVolumeName" = "*"
          }
        }
      },
      {
        Sid      = "SnapshotVolumes"
        Effect   = "Allow"
        Action   = ["ec2:CreateSnapshot"]
        Resource = "arn:aws:ec2:*:*:snapshot/*"
        Condition = {
          StringLike = {
            "aws:RequestTag/CSIVolumeSnapshotName" = "*"
          }
        }
      },
      {
        Sid      = "DeleteSnapshotsTheDriverCreated"
        Effect   = "Allow"
        Action   = ["ec2:DeleteSnapshot"]
        Resource = "arn:aws:ec2:*:*:snapshot/*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/CSIVolumeSnapshotName" = "*"
          }
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${local.name_prefix}-node-profile"
  role = aws_iam_role.node.name

  tags = local.common_tags
}
