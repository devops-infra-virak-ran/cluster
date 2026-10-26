#!/usr/bin/env bash
#
# Render and apply the Argo CD projects and Applications for one environment.
#
#   scripts/argocd-apps.sh <workspace> [--render-only]
#
# Renders argocd/apps.example.yaml: the platform project and its `teams`
# Application once, then a project and an Application for every team — every
# directory under helm/values/. A new team is a new directory and a re-run.
#
# The rendered argocd/rendered-<ws>.yaml carries the account id (inside the ECR
# prefix) and the environment's hostname, so it is gitignored, like the
# platform facts it is built from.
#
# Which environments sync themselves: dev and uat follow git the moment CI
# commits a tag. prod shows the drift and waits for `make argocd-sync`, which
# is the second gate behind the approval Jenkins already asks for.
# AUTOMATED_WORKSPACES overrides the list.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${ROOT}/scripts/platform.sh"
TEMPLATE="${ROOT}/argocd/apps.example.yaml"

WORKSPACE="${1:-}"
RENDER_ONLY=false
[[ "${2:-}" == "--render-only" ]] && RENDER_ONLY=true

[[ -n "${WORKSPACE}" ]] || { echo "usage: $(basename "$0") <workspace> [--render-only]" >&2; exit 1; }
[[ -f "${ROOT}/helm/env/${WORKSPACE}.yaml" ]] || {
  echo "error: no helm/env/${WORKSPACE}.yaml — that is the per-env values file the apps deploy" >&2
  exit 1; }

repo_url="$(git -C "${ROOT}" remote get-url origin 2>/dev/null || true)"

# The branch Argo CD tracks. The checkout's own branch by default;
# TARGET_REVISION overrides it, so rendering from a feature branch cannot
# quietly point an environment at that branch.
revision="${TARGET_REVISION:-$(git -C "${ROOT}" branch --show-current 2>/dev/null || echo main)}"

fact() { "${PLATFORM}" "${WORKSPACE}" "$1"; }

declare -A v=(
  [WORKSPACE]="${WORKSPACE}"
  [REPO_URL]="${repo_url}"
  [TARGET_REVISION]="${revision}"
  [ECR_IMAGE_PREFIX]="$(fact ecr_image_prefix)"
  [SITE_HOST]="$(fact site_hostname)"
  [SITE_URL]="$(fact site_url)"
  [ALB_GROUP]="$(fact cluster_name)"
  [CERT_ARN]="$(fact certificate_arn)"
  [REGION]="$(fact region)"
  [ALB_CIDRS]="$(fact public_subnet_cidrs)"
  [SECRETS_NAME_PREFIX]="$(fact secrets_name_prefix)"
  [SECRETS_ROLE_PREFIX]="$(fact secrets_role_prefix)"
)

missing=""
for k in REPO_URL ECR_IMAGE_PREFIX ALB_GROUP REGION ALB_CIDRS SECRETS_NAME_PREFIX SECRETS_ROLE_PREFIX; do
  [[ -n "${v[$k]}" ]] || missing+=" ${k,,}"
done
if [[ -n "${missing}" ]]; then
  echo "error: cannot render — missing:${missing}" >&2
  echo "       make platform-pull WORKSPACE=${WORKSPACE}   (and a git remote 'origin' Argo CD can pull)" >&2
  exit 1
fi

automated=false
for w in ${AUTOMATED_WORKSPACES:-dev uat}; do
  [[ "${w}" == "${WORKSPACE}" ]] && automated=true
done

teams="$(cd "${ROOT}/helm/values" && ls -d */ | tr -d '/' | tr '\n' ' ')"
out="${ROOT}/argocd/rendered-${WORKSPACE}.yaml"

# Values reach the renderer through the environment, so a hostname or an ARN
# needs no quoting rules of its own.
for k in "${!v[@]}"; do export "ARGO_${k}=${v[$k]}"; done

python3 "${ROOT}/scripts/render-apps.py" "${TEMPLATE}" "${out}" "${automated}" ${teams}

echo "==> rendered ${out#"${ROOT}/"}"
echo "    repo      ${repo_url} @ ${revision}"
echo "    teams     ${teams}"
echo "    host      ${v[SITE_HOST]:-(none — the ALB hostname, HTTP only)}"
if [[ "${automated}" == true ]]; then
  echo "    sync      automatic (prune, selfHeal)"
else
  echo "    sync      manual — Argo CD shows drift and waits for make argocd-sync"
fi

if [[ "${RENDER_ONLY}" == true ]]; then
  echo "    (--render-only: not applied)"
  exit 0
fi

echo "==> applying to namespace argocd"
kubectl apply -f "${out}"
