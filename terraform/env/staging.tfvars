# staging — prod-shaped, dev-sized. The environment that catches what dev cannot.
#
# cost  ~$70/month if left running
# cost  two NAT gateways instead of one is most of the gap to dev
#
# `environment` is NOT set here. It comes from the workspace name, so the
# file and the state can never disagree about which environment this is.

project_name = "learn"
region       = "us-east-1"

# ─── Network ─────────────────────────────────────────────────────────────────

vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]

# One NAT gateway shared by both AZs. ~$32/month and the single largest line
# on this bill. It exists so private instances can reach the internet outbound
# (apt, docker pull) while staying unreachable from it.
#
# If an AZ dies, the other AZ's private subnets lose egress with it. That is a
# real single point of failure, and the right trade in dev.
single_nat_gateway = false
enable_flow_logs   = false

# ─── Access ──────────────────────────────────────────────────────────────────
# Your public egress IP, as AWS sees it — not a 192.168.x address.
#   make myip     WORKSPACE=<env>   does this line still match?
#   make myip-set WORKSPACE=<env>   rewrite it to your current one
# A stale entry does not error: the security group drops the packets and SSH
# hangs. 0.0.0.0/0 is rejected by the security module on purpose.

ssh_allowed_cidrs       = ["124.248.190.205/32"]
apiserver_allowed_cidrs = []

ssh_public_key_path  = "~/.ssh/id_ed25519.pub"
ssh_private_key_path = "~/.ssh/id_ed25519"
node_ssh_user        = "ubuntu"

# ─── Nodes ───────────────────────────────────────────────────────────────────
# One control plane: no etcd quorum, so this cannot survive losing it. Fine
# for learning, wrong for anything else — see prod.tfvars.

control_plane_count         = 1
control_plane_instance_type = "t3.medium"
worker_count                = 2
worker_instance_type        = "t3.medium"
etcd_volume_size            = 0

tags = {
  Owner = "learning"
}

# ─── Services ────────────────────────────────────────────────────────────────
# Not here any more. A service is declared once, in the files Helm deploys it
# from:
#
#   helm/values/<group>/services.yaml   which services exist, in every env
#   helm/env/staging.yaml               its image tag and replicas here
#
#   make svc-add NAME=payments-api GROUP=api-service TAG=0.1.0
#   make svc-rm  NAME=payments-api
#   make services WORKSPACE=staging
#
# Terraform still reads the service names out of the first to create their ECR
# repositories, so `make apply` is what gives a new service a registry.
