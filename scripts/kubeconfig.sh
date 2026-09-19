#!/usr/bin/env bash
#
# Turn the admin kubeconfig Kubespray left behind into one that works from
# here, and open the tunnel it needs.
#
#   scripts/kubeconfig.sh dev [--output ~/.kube/config-dev] [--port 6443]
#                             [--background | --no-tunnel] [--stop]
#
# Kubespray writes inventory/<workspace>/artifacts/admin.conf with the control
# plane's private address, which resolves nowhere outside the VPC. This points
# it at a local port and forwards that port through the bastion. The apiserver
# certificate already lists 127.0.0.1, so TLS verification stays on.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Addresses come from platform/<workspace>.env, not from Terraform state.
PLATFORM="${ROOT}/scripts/platform.sh"

WORKSPACE="${1:-}"
if [[ -z "${WORKSPACE}" || "${WORKSPACE}" == -* ]]; then
  echo "usage: $(basename "$0") <workspace> [--output PATH] [--port N] [--no-tunnel]" >&2
  exit 1
fi
shift

OUTPUT="${HOME}/.kube/config-${WORKSPACE}"
PORT=6443
TUNNEL=true
BACKGROUND=false
STOP=false
PIDFILE="${ROOT}/kubespray/inventory/${WORKSPACE}/.tunnel.pid"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)    OUTPUT="$2"; shift 2 ;;
    --port)      PORT="$2"; shift 2 ;;
    --no-tunnel)  TUNNEL=false; shift ;;
    --background) BACKGROUND=true; shift ;;
    --stop)       STOP=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

# A tunnel started with --background outlives the shell that created it, so
# there has to be a way to find and stop it again.
tunnel_pid() {
  [[ -f "${PIDFILE}" ]] || return 1
  local pid; pid="$(cat "${PIDFILE}")"
  kill -0 "${pid}" 2>/dev/null || { rm -f "${PIDFILE}"; return 1; }
  echo "${pid}"
}

if [[ "${STOP}" == true ]]; then
  if pid="$(tunnel_pid)"; then
    kill "${pid}" && rm -f "${PIDFILE}"
    echo "==> stopped the tunnel for ${WORKSPACE} (pid ${pid})"
  else
    echo "==> no tunnel running for ${WORKSPACE}"
  fi
  exit 0
fi

ADMIN_CONF="${ROOT}/kubespray/inventory/${WORKSPACE}/artifacts/admin.conf"
if [[ ! -f "${ADMIN_CONF}" ]]; then
  echo "error: ${ADMIN_CONF} not found." >&2
  echo "       make kubespray-deploy WORKSPACE=${WORKSPACE}" >&2
  exit 1
fi

# Read the addresses for THIS workspace, so a mismatched workspace cannot
# tunnel to one cluster with another's credentials.
BASTION="$("${PLATFORM}" "${WORKSPACE}" bastion_ip)"
CONTROL_PLANE="$("${PLATFORM}" "${WORKSPACE}" control_plane_ip)"
SSH_USER="$("${PLATFORM}" "${WORKSPACE}" node_ssh_user)"
SSH_KEY="$("${PLATFORM}" "${WORKSPACE}" ssh_private_key_path)"

if [[ -z "${BASTION}" || -z "${CONTROL_PLANE}" ]]; then
  echo "error: no bastion_ip / control_plane_ip for workspace '${WORKSPACE}'." >&2
  echo "       Set BASTION_IP and CONTROL_PLANE_IP in platform/${WORKSPACE}.env" >&2
  exit 1
fi

# Not guessed, for the same reason as in kubespray/run.sh: a default that
# happens to exist but is wrong fails later and less clearly.
missing=""
[[ -n "${SSH_USER}" ]] || missing+=" NODE_SSH_USER"
[[ -n "${SSH_KEY}"  ]] || missing+=" SSH_PRIVATE_KEY_PATH"
if [[ -n "${missing}" ]]; then
  echo "error: not configured for workspace '${WORKSPACE}':${missing}" >&2
  echo "       set them in ${ROOT}/platform/${WORKSPACE}.env" >&2
  exit 1
fi
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

if [[ "${BACKGROUND}" == true ]]; then
  if pid="$(tunnel_pid)"; then
    echo "==> tunnel already running (pid ${pid}) — nothing to do"
    exit 0
  fi
  # StrictHostKeyChecking=accept-new, because a background process cannot
  # answer the "authenticity of host" prompt and would simply hang.
  nohup ssh -i "${SSH_KEY}" -N \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o StrictHostKeyChecking=accept-new \
    -L "${PORT}:${CONTROL_PLANE}:6443" \
    "${SSH_USER}@${BASTION}" >/dev/null 2>&1 &
  echo $! > "${PIDFILE}"

  # Wait for the port to actually accept a connection, not merely for the ssh
  # process to still exist. An ssh that cannot reach the bastion stays alive
  # and retrying, so a liveness check on the pid reports a working tunnel
  # while every kubectl gets "connection refused".
  for _ in $(seq 20); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
      exec 3<&- 3>&-
      pid="$(tunnel_pid)" || true
      echo "==> tunnel ${PORT} → ${CONTROL_PLANE}:6443 via ${BASTION} (pid ${pid}, backgrounded)"
      echo "    stop it with: make tunnel-stop WORKSPACE=${WORKSPACE}"
      exit 0
    fi
    tunnel_pid >/dev/null || { echo "error: the tunnel exited immediately — is port ${PORT} already in use?" >&2; exit 1; }
    sleep 0.5
  done

  kill "$(cat "${PIDFILE}")" 2>/dev/null || true
  rm -f "${PIDFILE}"
  echo "error: port ${PORT} never came up — the bastion at ${BASTION} is not answering." >&2
  echo >&2

  # Most often the address is simply stale: platform/<workspace>.env is pasted
  # by hand after an apply, while inventory.ini is regenerated from AWS tags.
  # When the two disagree, that is the answer, so say so instead of sending
  # the reader off to guess.
  INVENTORY_INI="${ROOT}/kubespray/inventory/${WORKSPACE}/inventory.ini"
  DISCOVERED=""
  [[ -f "${INVENTORY_INI}" ]] &&
    DISCOVERED="$(sed -n 's/^#[[:space:]]*Bastion:[[:space:]]*//p' "${INVENTORY_INI}" | head -1 | tr -d '[:space:]')"

  if [[ -n "${DISCOVERED}" && "${DISCOVERED}" != "none"* && "${DISCOVERED}" != "${BASTION}" ]]; then
    echo "       The inventory disagrees about where the bastion is:" >&2
    echo "         platform/${WORKSPACE}.env  BASTION_IP=${BASTION}" >&2
    echo "         inventory.ini (from AWS)   ${DISCOVERED}" >&2
    echo >&2
    echo "       An apply moved the address and platform/${WORKSPACE}.env was not" >&2
    echo "       repasted. Refresh it from the infrastructure project's outputs" >&2
    echo "       (bastion_public_ip, control_plane_private_ips, alb_url), or set:" >&2
    echo "         BASTION_IP=${DISCOVERED}" >&2
  else
    echo "       Two things to check, in this order:" >&2
    echo >&2
    echo "       1. Is the address current? platform/${WORKSPACE}.env is pasted by" >&2
    echo "          hand and goes stale whenever an apply replaces the bastion:" >&2
    echo "            make inventory WORKSPACE=${WORKSPACE}   # re-reads AWS tags" >&2
    echo >&2
    echo "       2. Is your IP still allowlisted? An unmatched source address" >&2
    echo "          hangs rather than refuses. That check lives with the" >&2
    echo "          infrastructure, not here:" >&2
    echo "            make myip WORKSPACE=${WORKSPACE}        # in the terraform project" >&2
  fi
  exit 1
fi

echo "==> tunnel ${PORT} → ${CONTROL_PLANE}:6443 via ${BASTION} — Ctrl-C closes it"

exec ssh -i "${SSH_KEY}" -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -L "${PORT}:${CONTROL_PLANE}:6443" \
  "${SSH_USER}@${BASTION}"
