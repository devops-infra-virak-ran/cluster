# prod — the same code, sized to survive things.
#
# cost  ~$285/month if left running
# cost  three NAT gateways and three control-plane nodes are most of it
#
# Read this next to dev.tfvars. Every difference is a deliberate answer to
# "what happens when one machine or one datacentre goes away".

project_name = "learn"
region       = "us-east-1"

# ─── Network ─────────────────────────────────────────────────────────────────

vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

# One NAT per AZ, ~$32/month each. Three times the cost of dev's shared NAT,
# and the reason is exactly that shared one: with it, losing us-east-1a takes
# egress away from every private subnet in the VPC.
single_nat_gateway = false

# Rejected-traffic logs to CloudWatch. Off in dev because it is noise you will
# not read; on here because after an incident it is the only record of what
# was refused and from where.
enable_flow_logs = true

# ─── Access ──────────────────────────────────────────────────────────────────

ssh_allowed_cidrs       = ["203.0.113.10/32"]
apiserver_allowed_cidrs = []

ssh_public_key_path  = "~/.ssh/id_ed25519.pub"
ssh_private_key_path = "~/.ssh/id_ed25519"
node_ssh_user        = "ubuntu"

# ─── Nodes ───────────────────────────────────────────────────────────────────
# Three control-plane nodes, because etcd needs a majority to accept a write.
# 3 tolerates losing 1. 2 tolerates losing NONE — it is strictly worse than 1,
# which is the single most surprising fact about etcd.

control_plane_count         = 3
control_plane_instance_type = "t3.medium"
worker_count                = 3
worker_instance_type        = "t3.large"

# etcd on its own volume: it is disk-latency sensitive, and sharing a disk with
# container logs is a classic way to make a cluster mysteriously slow.
etcd_volume_size = 20

tags = {
  Owner = "learning"
}
