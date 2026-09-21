#!/usr/bin/env bash
#
# One platform fact, without Terraform.
#
#   scripts/platform.sh <workspace> <key>
#   scripts/platform.sh dev alb_url
#
# These are the values the infrastructure produces and this project consumes.
# Reading them here rather than running `terraform output` means this project
# needs no Terraform binary, no state file, and no access to the repo that
# built the infrastructure.
#
# Resolution order, first hit wins:
#
#   1. environment variable             ALB_URL=... make helm-deploy
#   2. platform/<workspace>.local.env   THIS machine — gitignored
#   3. platform/<workspace>.env         the environment — checked into git
#   4. AWS SSM Parameter Store          only when PLATFORM_SSM_PREFIX is set
#
# Layers 2 and 3 are the important split. Facts about the environment (the
# load balancer's address, the registry, the NodePort) are the same for
# everyone and belong in git. Facts about the machine you are sitting at
# (where your SSH key lives) are yours alone and must not be.
#
# Add --origin as a third argument to print which layer answered, instead of
# the value. That is what `make platform` uses.
#
# A missing key prints nothing and exits 0. That is deliberate: `make
# helm-lint` and `make helm-render` fall back to placeholders and still work
# with no infrastructure at all, while the targets that genuinely need a value
# check for the empty string themselves and refuse.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKSPACE="${1:-}"
KEY="${2:-}"
if [[ -z "${WORKSPACE}" || -z "${KEY}" ]]; then
  echo "usage: $(basename "$0") <workspace> <key>" >&2
  echo "       keys: region cluster_name ecr_image_prefix alb_url alb_dns_name" >&2
  echo "             ingress_nodeport bastion_ip control_plane_ip node_ssh_user" >&2
  echo "             ssh_private_key_path site_url admin_allowed_cidrs" >&2
  exit 1
fi

VAR="${KEY^^}"
VAR="${VAR//-/_}"
ORIGIN=false
[[ "${3:-}" == "--origin" ]] && ORIGIN=true

SHARED="${ROOT}/platform/${WORKSPACE}.env"
LOCAL="${ROOT}/platform/${WORKSPACE}.local.env"

emit() {  # emit <value> <origin>
  if [[ "${ORIGIN}" == true ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi
  exit 0
}

# Files are parsed, not sourced: an `rm -rf` on a line of one should not run
# just because something asked for a URL.
read_file() {
  local file="$1" value
  [[ -f "${file}" ]] || return 1
  value="$(sed -n "s/^[[:space:]]*${VAR}[[:space:]]*=[[:space:]]*//p" "${file}" | head -1)"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  [[ -n "${value}" ]] || return 1
  printf '%s' "${value}"
}

# 1. Environment override.
if [[ -n "${!VAR:-}" ]]; then
  emit "${!VAR}" env
fi

# 2. This machine.
if value="$(read_file "${LOCAL}")"; then
  emit "${value}" local
fi

# 3. The environment, shared through git.
if value="$(read_file "${SHARED}")"; then
  emit "${value}" shared
fi

# 3. SSM, opt-in. Left off by default because this script is called several
# times per make invocation and an AWS round trip on each — or worse, a slow
# failure when there are no credentials — would be felt on every command.
#
#   PLATFORM_SSM_PREFIX=/platform make helm-deploy WORKSPACE=dev
#     → reads /platform/dev/alb_url
if [[ -n "${PLATFORM_SSM_PREFIX:-}" ]] && command -v aws >/dev/null 2>&1; then
  region="${AWS_REGION:-$(sed -n 's/^[[:space:]]*REGION[[:space:]]*=[[:space:]]*//p' "${SHARED}" 2>/dev/null | head -1)}"
  if [[ "${ORIGIN}" == true ]]; then printf 'ssm'; exit 0; fi
  aws ssm get-parameter \
    --name "${PLATFORM_SSM_PREFIX}/${WORKSPACE}/${KEY}" \
    ${region:+--region "${region}"} \
    --query Parameter.Value --output text 2>/dev/null || true
  exit 0
fi

exit 0
