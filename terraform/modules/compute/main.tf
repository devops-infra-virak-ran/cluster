# Compute module — bastion, control-plane and worker EC2 instances that
# Kubespray will turn into a Kubernetes cluster.
#
# Nodes are plain instances rather than an ASG on purpose: Kubespray drives
# them over SSH from a static inventory, so their addresses have to be stable.

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

  # "owned" (not "shared") lets the AWS cloud provider clean up resources it
  # created for this cluster.
  cluster_tag = { "kubernetes.io/cluster/${var.cluster_name}" = "owned" }
}

# ─── AMI ─────────────────────────────────────────────────────────────────────

# Looked up rather than hardcoded, because an AMI id is region-specific: the
# same Ubuntu release has a different id in every region.
#
# The storage path in the name is tied to the RELEASE, which is easy to get
# wrong: Canonical publishes 24.04 under hvm-ssd-gp3 and 22.04 under hvm-ssd,
# and never both. Asking for hvm-ssd-gp3 + jammy matches nothing in any
# region, and the failure looks like an AWS problem rather than a typo:
#
#   Error: Your query returned no results.
#
# Check a change here before applying it:
#   aws ec2 describe-images --owners 099720109477 --region us-east-1 \
#     --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
#     --query 'length(Images)'
data "aws_ami" "ubuntu" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu[0].id
}

# ─── SSH key ─────────────────────────────────────────────────────────────────

resource "aws_key_pair" "cluster" {
  key_name   = "${local.name_prefix}-key"
  public_key = var.ssh_public_key

  tags = local.common_tags
}

# ─── Bastion ─────────────────────────────────────────────────────────────────

resource "aws_instance" "bastion" {
  count = var.create_bastion ? 1 : 0

  ami                    = local.ami_id
  instance_type          = var.bastion_instance_type
  subnet_id              = var.public_subnet_ids[0]
  key_name               = aws_key_pair.cluster.key_name
  vpc_security_group_ids = [var.bastion_security_group_id]
  iam_instance_profile   = var.node_instance_profile_name

  associate_public_ip_address = true

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-bastion"
    Role = "bastion"
  })
}

resource "aws_eip" "bastion" {
  count    = var.create_bastion ? 1 : 0
  instance = aws_instance.bastion[0].id
  domain   = "vpc"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-bastion-eip" })
}

# ─── Control plane ───────────────────────────────────────────────────────────

resource "aws_instance" "control_plane" {
  count = var.control_plane_count

  ami                    = local.ami_id
  instance_type          = var.control_plane_instance_type
  subnet_id              = var.private_subnet_ids[count.index % length(var.private_subnet_ids)]
  key_name               = aws_key_pair.cluster.key_name
  vpc_security_group_ids = [var.control_plane_security_group_id]
  iam_instance_profile   = var.node_instance_profile_name

  # Overlay CNIs send packets with pod source addresses; EC2 drops those
  # unless the check is off.
  source_dest_check = false

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # containers need one extra hop to IMDS
  }

  root_block_device {
    volume_size           = var.control_plane_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = local.control_plane_user_data

  tags = merge(local.common_tags, local.cluster_tag, {
    Name = "${local.name_prefix}-cp-${count.index + 1}"
    Role = "control-plane"
  })

  lifecycle {
    # Rebuilding a node means re-running Kubespray; do not let an AMI refresh
    # quietly recycle the control plane.
    ignore_changes = [ami]
  }
}

# Dedicated etcd disk: etcd is fsync-bound and will flap if it shares IOPS
# with the OS disk under load.
resource "aws_ebs_volume" "etcd" {
  count = var.etcd_volume_size > 0 ? var.control_plane_count : 0

  availability_zone = aws_instance.control_plane[count.index].availability_zone
  size              = var.etcd_volume_size
  type              = "gp3"
  iops              = 3000
  encrypted         = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-etcd-${count.index + 1}" })
}

resource "aws_volume_attachment" "etcd" {
  count = var.etcd_volume_size > 0 ? var.control_plane_count : 0

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.etcd[count.index].id
  instance_id = aws_instance.control_plane[count.index].id
}

# ─── Workers ─────────────────────────────────────────────────────────────────

resource "aws_instance" "worker" {
  count = var.worker_count

  ami                    = local.ami_id
  instance_type          = var.worker_instance_type
  subnet_id              = var.private_subnet_ids[count.index % length(var.private_subnet_ids)]
  key_name               = aws_key_pair.cluster.key_name
  vpc_security_group_ids = [var.worker_security_group_id]
  iam_instance_profile   = var.node_instance_profile_name

  source_dest_check = false

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = var.worker_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = local.worker_user_data

  tags = merge(local.common_tags, local.cluster_tag, {
    Name = "${local.name_prefix}-worker-${count.index + 1}"
    Role = "worker"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

# ─── Node bootstrap ──────────────────────────────────────────────────────────
# Kept deliberately thin — Kubespray owns the real configuration. This only
# covers what has to be true before Ansible connects.

locals {
  node_cloud_config = <<-CLOUDINIT
    #cloud-config
    package_update: true
    packages:
      - python3
      - python3-pip
      - chrony
    write_files:
      - path: /etc/modules-load.d/k8s.conf
        content: |
          overlay
          br_netfilter
      - path: /etc/sysctl.d/99-k8s.conf
        content: |
          net.bridge.bridge-nf-call-iptables  = 1
          net.bridge.bridge-nf-call-ip6tables = 1
          net.ipv4.ip_forward                 = 1
    runcmd:
      - modprobe overlay
      - modprobe br_netfilter
      - sysctl --system
      - swapoff -a
      - sed -i '/ swap / s/^/#/' /etc/fstab
  CLOUDINIT

  # Mount the dedicated etcd volume. Control-plane nodes only: it is the one
  # place the two instance roles differ, and a worker would spend two minutes
  # waiting for a disk that is never coming.
  #
  # The volume is attached as /dev/sdf, but a Nitro instance (t3, m5, c5 …)
  # renames every EBS device to /dev/nvmeXn1 in an order AWS does not promise,
  # so the path cannot be hardcoded. What is reliable is the shape: the root
  # disk has partitions, this one has none and no filesystem.
  #
  # /var/lib/etcd is Kubespray's etcd_data_dir default, so mounting there is
  # the whole integration — no group_vars entry, nothing to keep in sync.
  etcd_disk_mount = <<-EOT
  - |
    # The attachment lands moments after the instance boots and cloud-init
    # can get here first, so wait for the device instead of silently
    # leaving etcd on the root disk.
    blank_disk() {
      for c in $(lsblk -dpno NAME,TYPE | awk '$2 == "disk" { print $1 }'); do
        [ -n "$(lsblk -no NAME "$c" | tail -n +2)" ] && continue
        blkid "$c" >/dev/null 2>&1 && continue
        echo "$c"; return 0
      done
      return 1
    }
    for _ in $(seq 60); do d=$(blank_disk) && break; sleep 2; done
    if [ -n "$d" ]; then
      mkfs.ext4 -L etcd "$d"
      mkdir -p /var/lib/etcd
      echo "UUID=$(blkid -s UUID -o value "$d") /var/lib/etcd ext4 defaults,noatime 0 2" >> /etc/fstab
      mount /var/lib/etcd
    fi
  EOT

  worker_user_data = local.node_cloud_config

  # indent() leaves the first line alone, so it gets its two spaces by hand.
  # Without them the runcmd entry lands at column 0 and cloud-init reads it as
  # a new top-level key instead of another command.
  control_plane_user_data = var.etcd_volume_size > 0 ? (
    "${local.node_cloud_config}  ${indent(2, trimspace(local.etcd_disk_mount))}\n"
  ) : local.node_cloud_config
}
