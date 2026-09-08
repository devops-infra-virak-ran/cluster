#!/usr/bin/env bash
#
# Render and (optionally) apply the ArgoCD Application for one workspace.
#
#   scripts/argocd-app.sh <workspace> [--render-only]
#
# The template argocd/application.example.yaml is committed with placeholders.
# The rendered argocd/application-<ws>.yaml carries the ECR prefix and ALB URL —
# environment facts this public repo must not hold — so it is gitignored.
#
# ECR prefix and ALB URL come from platform.sh, the same source make helm-deploy
# uses. The git repoURL and branch come from the checkout, so ArgoCD pulls from
# wherever this repo actually lives.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${ROOT}/scripts/platform.sh"
TEMPLATE="${ROOT}/argocd/application.example.yaml"

WORKSPACE="${1:-}"
RENDER_ONLY=false
[[ "${2:-}" == "--render-only" ]] && RENDER_ONLY=true

[[ -n "${WORKSPACE}" ]] || { echo "usage: $(basename "$0") <workspace> [--render-only]" >&2; exit 1; }
[[ -f "${TEMPLATE}" ]] || { echo "error: no ${TEMPLATE}" >&2; exit 1; }

# The env file must exist, or the Application would point at a missing values file.
[[ -f "${ROOT}/helm/env/${WORKSPACE}.yaml" ]] || {
  echo "error: no helm/env/${WORKSPACE}.yaml — that is the per-env values file the app deploys" >&2
  exit 1; }

repo_url="$(git -C "${ROOT}" remote get-url origin 2>/dev/null || true)"
revision="$(git -C "${ROOT}" branch --show-current 2>/dev/null || echo main)"
ecr="$("${PLATFORM}" "${WORKSPACE}" ecr_image_prefix)"
alb="$("${PLATFORM}" "${WORKSPACE}" alb_url)"

missing=""
[[ -n "${repo_url}" ]] || missing+=" git-remote(origin)"
[[ -n "${ecr}" ]]      || missing+=" ecr_image_prefix"
[[ -n "${alb}" ]]      || missing+=" alb_url"
if [[ -n "${missing}" ]]; then
  echo "error: cannot render — missing:${missing}" >&2
  echo "       set the platform values in platform/${WORKSPACE}.env (make platform WORKSPACE=${WORKSPACE})" >&2
  echo "       and add a git remote 'origin' ArgoCD can pull from." >&2
  exit 1
fi

out="${ROOT}/argocd/application-${WORKSPACE}.yaml"
sed -e "s#__WORKSPACE__#${WORKSPACE}#g" \
    -e "s#__REPO_URL__#${repo_url}#g" \
    -e "s#__TARGET_REVISION__#${revision}#g" \
    -e "s#__ECR_IMAGE_PREFIX__#${ecr}#g" \
    -e "s#__ALB_URL__#${alb}#g" \
    "${TEMPLATE}" > "${out}"

echo "==> rendered ${out}"
echo "    repo      ${repo_url} @ ${revision}"
echo "    registry  ${ecr}"
echo "    ingress   ${alb}"

if [[ "${RENDER_ONLY}" == true ]]; then
  echo "    (--render-only: not applied)"
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || { echo "error: kubectl not found" >&2; exit 1; }
echo "==> applying to the cluster (namespace argocd)"
kubectl apply -f "${out}"
echo
echo "Sync it (manual):  make argocd-sync WORKSPACE=${WORKSPACE}"
echo "                   or in the UI:    make argocd-ui"
