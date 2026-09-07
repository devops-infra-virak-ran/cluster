#!/usr/bin/env bash
#
# Run a Kubespray playbook against one workspace's cluster.
#
#   kubespray/run.sh dev cluster.yml                     install Kubernetes
#   kubespray/run.sh dev scale.yml --limit=worker3       add nodes
#   kubespray/run.sh dev upgrade-cluster.yml             upgrade in place
#   kubespray/run.sh dev remove-node.yml -e node=worker3
#   kubespray/run.sh dev shell                           a prompt inside the image
#   kubespray/run.sh dev shell -c 'ansible all -m ping'  one command in it
#
# Kubespray is not vendored here. Playbooks run from the official container
# image, so the host needs Docker and an SSH key and nothing else — no Ansible,
# no Python, no virtualenv — and an upgrade is a tag bump rather than a merge
# against thousands of upstream commits.
#
# Overridable: KUBESPRAY_VERSION, SSH_KEY, CONTAINER_ENGINE.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# The SSH key comes from platform/<workspace>.env, not from Terraform.
PLATFORM="${ROOT}/scripts/platform.sh"

KUBESPRAY_VERSION="${KUBESPRAY_VERSION:-v2.31.0}"
IMAGE="quay.io/kubespray/kubespray:${KUBESPRAY_VERSION}"
ENGINE="${CONTAINER_ENGINE:-docker}"

WORKSPACE="${1:-}"
if [[ -z "${WORKSPACE}" || "${WORKSPACE}" == -* ]]; then
  echo "usage: $(basename "$0") <workspace> [playbook] [ansible args...]" >&2
  echo "       workspaces: $(ls "${ROOT}"/platform/*.env 2>/dev/null | grep -v '\.local\.env$' | xargs -n1 basename | sed 's/\.env$//' | tr '\n' ' ')" >&2
  exit 1
fi
shift

INVENTORY_DIR="${HERE}/inventory/${WORKSPACE}"
INVENTORY="${INVENTORY_DIR}/inventory.ini"
GROUP_VARS="${HERE}/group_vars"
KNOWN_HOSTS="${HERE}/.known_hosts"

# ─── Inventory ───────────────────────────────────────────────────────────────

if [[ ! -s "${INVENTORY}" ]]; then
  echo "error: no inventory at ${INVENTORY}" >&2
  echo "       This project does not generate one. Ask whoever provisions the" >&2
  echo "       machines for it, or write it by hand — see README.md." >&2
  exit 1
fi

# The inventory is per-workspace and Terraform stamps the workspace into it.
# Checking both means a mismatched pair — a prod inventory reached through a
# dev path, a file copied by hand — stops here rather than 30 minutes into a
# playbook that is reconfiguring the wrong cluster.
STAMPED="$(sed -n 's/^# Workspace:[[:space:]]*//p' "${INVENTORY}" | head -1)"
if [[ -n "${STAMPED}" && "${STAMPED}" != "${WORKSPACE}" ]]; then
  echo "error: ${INVENTORY} was generated for workspace '${STAMPED}', not '${WORKSPACE}'." >&2
  echo "       make inventory WORKSPACE=${WORKSPACE}" >&2
  exit 1
fi

if ! grep -qE '^(cp|worker)[0-9]+[[:space:]]' "${INVENTORY}"; then
  echo "error: ${INVENTORY} has no hosts — was the workspace destroyed?" >&2
  exit 1
fi

# ─── SSH key ─────────────────────────────────────────────────────────────────
# Resolved to an absolute path and mounted at that *same* path inside the
# container: the inventory names an absolute key path for both the node
# connection and the bastion ProxyCommand, and mounting it anywhere else would
# break both. This is also why the inventory template calls pathexpand() — a
# "~" would resolve to /root in here.

SSH_KEY="${SSH_KEY:-$("${PLATFORM}" "${WORKSPACE}" ssh_private_key_path)}"
SSH_KEY="${SSH_KEY/#\~/${HOME}}"

# Nothing is guessed. A default of ~/.ssh/id_ed25519 would silently pick up
# whatever key happens to be there — and if it exists but is the wrong one,
# the failure arrives much later as an unhelpful SSH error.
if [[ -z "${SSH_KEY}" ]]; then
  echo "error: no ssh_private_key_path configured for workspace '${WORKSPACE}'." >&2
  echo >&2
  echo "  set it in   ${ROOT}/platform/${WORKSPACE}.env" >&2
  echo "                SSH_PRIVATE_KEY_PATH=/absolute/path/to/key" >&2
  echo "  or per-run  SSH_KEY=/absolute/path/to/key $(basename "$0") ${WORKSPACE} ..." >&2
  exit 1
fi

if [[ ! -f "${SSH_KEY}" ]]; then
  echo "error: no SSH private key at ${SSH_KEY}" >&2
  echo "       fix SSH_PRIVATE_KEY_PATH in ${ROOT}/platform/${WORKSPACE}.env" >&2
  exit 1
fi

command -v "${ENGINE}" >/dev/null 2>&1 || {
  echo "error: ${ENGINE} not found. Install Docker, or set CONTAINER_ENGINE=podman." >&2
  exit 1
}

# Persisted across runs so a host key accepted once is not re-accepted every
# time. Mounting the file also creates /tmp/.ssh, which ssh needs to exist.
touch "${KNOWN_HOSTS}"

# Create the group_vars mount point before Docker does, or it appears in the
# generated inventory directory owned by root.
mkdir -p "${INVENTORY_DIR}/group_vars"

# ─── Container ───────────────────────────────────────────────────────────────
# Two mounts, not one. Ansible loads group_vars/ from beside the inventory
# file, and the inventory lives in a per-workspace directory, so the shared
# group_vars is mounted into that directory read-only rather than copied into
# each workspace. (Docker creates an empty group_vars/ in the host inventory
# directory as the mount point. It is generated output; leave it alone.)
#
# --user keeps what the playbook writes into the inventory — notably
# artifacts/admin.conf — owned by you rather than by root.

ENGINE_ARGS=(
  run --rm
  --user "$(id -u):$(id -g)"
  -e HOME=/tmp
  -e ANSIBLE_HOST_KEY_CHECKING=False
  # Every connection crosses the bastion, so a stall there costs a host.
  # Kubespray's ansible.cfg sets timeout=300 and leaves retries at 0, which
  # turns one dropped channel into a failed node 35 minutes into a run.
  -e ANSIBLE_TIMEOUT="${ANSIBLE_TIMEOUT:-600}"
  -e ANSIBLE_SSH_RETRIES="${ANSIBLE_SSH_RETRIES:-5}"
  --mount "type=bind,source=${INVENTORY_DIR},dst=/inventory"
  --mount "type=bind,source=${GROUP_VARS},dst=/inventory/group_vars,readonly"
  --mount "type=bind,source=${SSH_KEY},dst=${SSH_KEY},readonly"
  --mount "type=bind,source=${KNOWN_HOSTS},dst=/tmp/.ssh/known_hosts"
)

# A TTY gives readable progress. There is none under CI.
if [[ -t 0 && -t 1 ]]; then
  ENGINE_ARGS+=(-it)
fi

PLAYBOOK="${1:-cluster.yml}"
shift || true

if [[ "${PLAYBOOK}" == "shell" || "${PLAYBOOK}" == "bash" ]]; then
  if [[ $# -eq 0 ]]; then
    echo "==> ${IMAGE} — inventory at /inventory/inventory.ini"
  fi
  exec "${ENGINE}" "${ENGINE_ARGS[@]}" "${IMAGE}" bash "$@"
fi

echo "==> ${PLAYBOOK} on workspace ${WORKSPACE} via ${IMAGE}"
echo "    inventory: ${INVENTORY}"
echo "    ssh key:   ${SSH_KEY}"

exec "${ENGINE}" "${ENGINE_ARGS[@]}" "${IMAGE}" \
  ansible-playbook \
    -i /inventory/inventory.ini \
    --become --become-user=root \
    "${PLAYBOOK}" "$@"
