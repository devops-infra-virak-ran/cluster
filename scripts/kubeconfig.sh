#!/usr/bin/env bash
#
# Turn the admin kubeconfig Kubespray left behind into one that works from
# here, and open the tunnel it needs.
#
#   scripts/kubeconfig.sh dev [--output ~/.kube/config-dev] [--port 6443]
#                             [--no-tunnel]
#
# Kubespray writes inventory/<workspace>/artifacts/admin.conf with the control
# plane's private address, which resolves nowhere outside the VPC. This points
# it at a local port and forwards that port through the bastion. The apiserver
# certificate already lists 127.0.0.1, so TLS verification stays on.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKSPACE="${1:-}"
if [[ -z "${WORKSPACE}" || "${WORKSPACE}" == -* ]]; then
  echo "usage: $(basename "$0") <workspace> [--output PATH] [--port N] [--no-tunnel]" >&2
  exit 1
fi
shift

OUTPUT="${HOME}/.kube/config-${WORKSPACE}"
PORT=6443
TUNNEL=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)    OUTPUT="$2"; shift 2 ;;
    --port)      PORT="$2"; shift 2 ;;
    --no-tunnel) TUNNEL=false; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

ADMIN_CONF="${ROOT}/kubespray/inventory/${WORKSPACE}/artifacts/admin.conf"
if [[ ! -f "${ADMIN_CONF}" ]]; then
  echo "error: ${ADMIN_CONF} not found." >&2
  echo "       make kubespray-deploy WORKSPACE=${WORKSPACE}" >&2
  exit 1
fi

# Read the addresses out of the same workspace's state, so a mismatched
# workspace cannot tunnel to one cluster with another's credentials.
cd "${ROOT}/terraform"
terraform workspace select "${WORKSPACE}" >/dev/null
BASTION="$(terraform output -raw bastion_public_ip)"
CONTROL_PLANE="$(terraform output -json control_plane_private_ips | jq -r '.[0]')"
SSH_USER="$(sed -n 's/^[[:space:]]*node_ssh_user[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "env/${WORKSPACE}.tfvars" | head -1)"
SSH_KEY="$(sed -n 's/^[[:space:]]*ssh_private_key_path[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "env/${WORKSPACE}.tfvars" | head -1)"
cd - >/dev/null

SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/${HOME}}"

mkdir -p "$(dirname "${OUTPUT}")"
sed "s#server: https://.*#server: https://127.0.0.1:${PORT}#" "${ADMIN_CONF}" > "${OUTPUT}"
chmod 600 "${OUTPUT}"

echo "==> wrote ${OUTPUT} (server https://127.0.0.1:${PORT})"
echo "    export KUBECONFIG=${OUTPUT}"

# Kubespray also fetched a kubectl matching the cluster. Say so, because the
# one on PATH is usually older than the apiserver by more than the supported
# one minor version of skew.
KUBECTL="${ROOT}/kubespray/inventory/${WORKSPACE}/artifacts/kubectl"
[[ -x "${KUBECTL}" ]] && echo "    matching kubectl: ${KUBECTL}"

if [[ "${TUNNEL}" != true ]]; then
  echo "==> start the tunnel yourself:"
  echo "    ssh -i ${SSH_KEY} -N -L ${PORT}:${CONTROL_PLANE}:6443 ${SSH_USER}@${BASTION}"
  exit 0
fi

echo "==> tunnel ${PORT} → ${CONTROL_PLANE}:6443 via ${BASTION} — Ctrl-C closes it"

exec ssh -i "${SSH_KEY}" -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -L "${PORT}:${CONTROL_PLANE}:6443" \
  "${SSH_USER}@${BASTION}"
