#!/usr/bin/env bash
#
# Build the Kubespray inventory by discovering nodes from AWS tags.
#
#   scripts/discover-inventory.sh <workspace>
#
# Terraform no longer writes the inventory (it cannot, once the cluster project
# is on another machine). Instead the nodes carry identity tags and this script
# queries EC2 for them at run time. The result:
#
#   - no IPs are committed anywhere, so the inventory can never go stale;
#   - it works on any machine with AWS read access — nothing is handed over
#     from the infra team except the tags Terraform already sets;
#   - every run re-discovers, so a rebuild that changes every IP just works.
#
# Tags it relies on (set in terraform/modules/compute):
#   kubernetes.io/cluster/<cluster_name> = owned   which cluster
#   KubesprayRole  = kube_control_plane | kube_node
#   KubesprayName  = cp1 | worker1 ...             stable node name
#   EtcdMemberName = etcd1 ...                     on control-plane nodes
#   Role           = bastion                       the SSH jump host
#
# Needs the aws CLI and jq on the host (not in the container).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${ROOT}/scripts/platform.sh"

WORKSPACE="${1:-}"
[[ -n "${WORKSPACE}" ]] || { echo "usage: $(basename "$0") <workspace>" >&2; exit 1; }

for t in aws jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: $t not found (needed for AWS discovery)" >&2; exit 1; }
done

REGION="$("${PLATFORM}" "${WORKSPACE}" region)"
CLUSTER_NAME="$("${PLATFORM}" "${WORKSPACE}" cluster_name)"
SSH_USER="$("${PLATFORM}" "${WORKSPACE}" node_ssh_user)"
SSH_KEY="$("${PLATFORM}" "${WORKSPACE}" ssh_private_key_path)"
SSH_KEY="${SSH_KEY/#\~/${HOME}}"

missing=""
[[ -n "${REGION}" ]]       || missing+=" region"
[[ -n "${CLUSTER_NAME}" ]] || missing+=" cluster_name"
[[ -n "${SSH_KEY}" ]]      || missing+=" ssh_private_key_path"
[[ -n "${SSH_USER}" ]]     || missing+=" node_ssh_user"
if [[ -n "${missing}" ]]; then
  echo "error: not configured for '${WORKSPACE}':${missing}" >&2
  echo "       set them in ${ROOT}/platform/${WORKSPACE}.env (make platform WORKSPACE=${WORKSPACE})" >&2
  exit 1
fi

# One query for every running node in this cluster. The cluster tag scopes it to
# this workspace, so dev and prod nodes in the same account never mix.
nodes_json="$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{ip:PrivateIpAddress,tags:Tags}' \
  --output json)"

# Pull out (name, role, ip, etcd_member) rows, sorted by name so cp1<cp2 and
# worker1<worker2 come out stable.
rows="$(echo "${nodes_json}" | jq -r '
  .[] | {
    ip: .ip,
    name: (.tags[] | select(.Key=="KubesprayName") | .Value),
    role: (.tags[] | select(.Key=="KubesprayRole") | .Value),
    etcd: ((.tags[] | select(.Key=="EtcdMemberName") | .Value) // "")
  } | [.name, .role, .ip, .etcd] | @tsv
' | sort)"

if [[ -z "${rows}" ]]; then
  echo "error: no running, tagged nodes found for cluster '${CLUSTER_NAME}' in ${REGION}." >&2
  echo "       Has it been applied?  Are the nodes running (not paused)?" >&2
  echo "         make apply  WORKSPACE=${WORKSPACE}   (in the terraform project)" >&2
  exit 1
fi

# The bastion. Scoped by Environment + Role, NOT the cluster tag: the bastion
# is not a Kubernetes node, so Terraform does not give it
# kubernetes.io/cluster/<name>=owned. Its public IP is the ProxyCommand hop; if
# there is none, nodes are reached directly (VPC-internal).
bastion_ip="$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:Environment,Values=${WORKSPACE}" \
            "Name=tag:Role,Values=bastion" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text 2>/dev/null | head -1)"
[[ "${bastion_ip}" == "None" ]] && bastion_ip=""

# ─── SSH args (identical to what Terraform used to render) ────────────────────
keepalive="-o ServerAliveInterval=30 -o ServerAliveCountMax=10"
if [[ -n "${bastion_ip}" ]]; then
  proxy="ssh -W %h:%p -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 ${keepalive} -i ${SSH_KEY} ${SSH_USER}@${bastion_ip}"
  ssh_common_args="-o StrictHostKeyChecking=accept-new ${keepalive} -o ProxyCommand=\"${proxy}\""
else
  ssh_common_args="-o StrictHostKeyChecking=accept-new ${keepalive}"
fi

# ─── Render inventory.ini ────────────────────────────────────────────────────
out_dir="${ROOT}/kubespray/inventory/${WORKSPACE}"
mkdir -p "${out_dir}"
out="${out_dir}/inventory.ini"

cp_lines=""; worker_lines=""
while IFS=$'\t' read -r name role ip etcd; do
  [[ -n "${name}" && -n "${ip}" ]] || continue
  case "${role}" in
    kube_control_plane) cp_lines+="${name} ansible_host=${ip} ip=${ip} etcd_member_name=${etcd}"$'\n' ;;
    kube_node)          worker_lines+="${name} ansible_host=${ip} ip=${ip}"$'\n' ;;
  esac
done <<< "${rows}"

{
  echo "# Generated by discover-inventory.sh from AWS tags — do not edit by hand."
  echo "# Regenerate: make inventory WORKSPACE=${WORKSPACE}"
  echo "#"
  echo "# Cluster:   ${CLUSTER_NAME}"
  echo "# Workspace: ${WORKSPACE}"
  echo "# Region:    ${REGION}"
  echo "# Bastion:   ${bastion_ip:-none — direct connection}"
  echo
  echo "[kube_control_plane]"
  printf '%s' "${cp_lines}"
  echo
  echo "[etcd:children]"
  echo "kube_control_plane"
  echo
  echo "[kube_node]"
  printf '%s' "${worker_lines}"
  echo
  echo "[calico_rr]"
  echo
  echo "[k8s_cluster:children]"
  echo "kube_control_plane"
  echo "kube_node"
  echo "calico_rr"
  echo
  echo "[all:vars]"
  echo "ansible_user=${SSH_USER}"
  echo "ansible_ssh_private_key_file=${SSH_KEY}"
  echo "ansible_ssh_common_args='${ssh_common_args}'"
} > "${out}"

cp_count="$(grep -cE '^cp[0-9]+ ' "${out}" || true)"
worker_count="$(grep -cE '^worker[0-9]+ ' "${out}" || true)"
echo "==> ${out}"
echo "    ${cp_count} control plane, ${worker_count} workers, bastion ${bastion_ip:-none}"
