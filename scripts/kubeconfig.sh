#!/usr/bin/env bash
#
# Write a kubeconfig for one environment's EKS cluster.
#
#   scripts/kubeconfig.sh <workspace>
#
# One file per environment, ~/.kube/config-<workspace>, which the Makefile
# exports as KUBECONFIG — so `make ... WORKSPACE=prod` can only ever talk to
# prod, and a shell left pointing at prod cannot leak into a dev command.
#
# The file holds no credential. kubectl runs `aws eks get-token` for each call,
# as whatever AWS identity your shell has — the same identity the EKS access
# entries grant (Terraform: admin_principal_arns, team_access, or the creator).
#
# The API endpoint only answers allowlisted addresses (Terraform
# api_allowed_cidrs). From anywhere else kubectl hangs, then times out.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${ROOT}/scripts/platform.sh"

WORKSPACE="${1:-}"
[[ -n "${WORKSPACE}" ]] || { echo "usage: $(basename "$0") <workspace>" >&2; exit 1; }

cluster="$("${PLATFORM}" "${WORKSPACE}" cluster_name)"
region="$("${PLATFORM}" "${WORKSPACE}" region)"
if [[ -z "${cluster}" || -z "${region}" ]]; then
  echo "error: no cluster_name or region for '${WORKSPACE}'." >&2
  echo "         make platform-pull WORKSPACE=${WORKSPACE}" >&2
  exit 1
fi

output="${HOME}/.kube/config-${WORKSPACE}"
mkdir -p "$(dirname "${output}")"

# --alias: the context is named after the environment, so `kubectl config
# current-context` says "dev" rather than an ARN.
aws eks update-kubeconfig \
  --region "${region}" \
  --name "${cluster}" \
  --alias "${WORKSPACE}" \
  --kubeconfig "${output}" >/dev/null
chmod 600 "${output}"

echo "==> ${output}  (context ${WORKSPACE} → ${cluster})"

if ! KUBECONFIG="${output}" kubectl get nodes --request-timeout=15s 2>/tmp/kubeconfig.$$.err; then
  echo >&2
  echo "error: the kubeconfig is written, but the API did not answer:" >&2
  sed 's/^/         /' /tmp/kubeconfig.$$.err >&2
  echo >&2
  echo "       A timeout is almost always the allowlist — your public IP changed:" >&2
  echo "         make -C ../terraform myip WORKSPACE=${WORKSPACE}" >&2
  echo "       \"Unauthorized\" means this AWS identity has no access entry:" >&2
  echo "         aws sts get-caller-identity" >&2
  rm -f /tmp/kubeconfig.$$.err
  exit 1
fi
rm -f /tmp/kubeconfig.$$.err

echo
echo "  export KUBECONFIG=${output}"
