#!/usr/bin/env bash
#
# Put the Argo CD web UI on the environment's ALB, at https://argocd.<site>.
#
#   scripts/argocd-expose.sh <workspace> [--render-only] [--remove]
#
# Two things have to be true, and only one of them is this script's:
#
#   1. argocd-server must speak plain HTTP. TLS ends at the ALB; a second TLS
#      hop only fails. controllers/argocd.yaml sets server.insecure, so
#      `make argocd-install` already did this.
#   2. The Ingress, with its source-ip condition. That is what this renders.
#
# The rendered argocd/ingress-<ws>.yaml carries the hostname and the allowed
# CIDRs, so it is gitignored, like the rendered Applications next to it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${ROOT}/scripts/platform.sh"
TEMPLATE="${ROOT}/argocd/ingress.example.yaml"
ARGOCD_NS="${ARGOCD_NS:-argocd}"

WORKSPACE="${1:-}"
RENDER_ONLY=false
REMOVE=false
case "${2:-}" in
  --render-only) RENDER_ONLY=true ;;
  --remove)      REMOVE=true ;;
  "")            ;;
  *) echo "unknown argument: $2" >&2; exit 1 ;;
esac

[[ -n "${WORKSPACE}" ]] || { echo "usage: $(basename "$0") <workspace> [--render-only|--remove]" >&2; exit 1; }
[[ -f "${TEMPLATE}" ]]  || { echo "error: no ${TEMPLATE}" >&2; exit 1; }

out="${ROOT}/argocd/ingress-${WORKSPACE}.yaml"

if [[ "${REMOVE}" == true ]]; then
  kubectl -n "${ARGOCD_NS}" delete ingress argocd-server --ignore-not-found
  rm -f "${out}"
  echo "The UI is back to the port-forward only:  make argocd-ui WORKSPACE=${WORKSPACE}"
  exit 0
fi

# ─── The hostname ────────────────────────────────────────────────────────────
site="$("${PLATFORM}" "${WORKSPACE}" site_hostname || true)"
cert="$("${PLATFORM}" "${WORKSPACE}" certificate_arn || true)"
group="$("${PLATFORM}" "${WORKSPACE}" cluster_name || true)"
if [[ -z "${site}" || -z "${cert}" ]]; then
  echo "error: '${WORKSPACE}' has no site_hostname or certificate_arn — no domain," >&2
  echo "       so there is no name to publish the UI under. Use the port-forward:" >&2
  echo "         make argocd-ui WORKSPACE=${WORKSPACE}" >&2
  exit 1
fi
hostname="argocd.${site}"

# ─── Who may reach it ────────────────────────────────────────────────────────
# Configured, or this machine's current public address. It is a snapshot: a
# changed address needs a re-run.
cidrs="$("${PLATFORM}" "${WORKSPACE}" admin_allowed_cidrs || true)"
origin="platform/${WORKSPACE}.local.env"
if [[ -z "${cidrs}" ]]; then
  ip="$(curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]' || true)"
  [[ -n "${ip}" ]] || {
    echo "error: ADMIN_ALLOWED_CIDRS is not set and your public IP could not be" >&2
    echo "       detected — are you online? Set it explicitly:" >&2
    echo "         ADMIN_ALLOWED_CIDRS=1.2.3.4/32 make argocd-expose WORKSPACE=${WORKSPACE}" >&2
    exit 1; }
  cidrs="${ip}/32"
  origin="detected now"
fi
cidrs_json="$(python3 -c 'import json,sys; print(json.dumps([c.strip() for c in sys.argv[1].split(",") if c.strip()]))' "${cidrs}")"

# ─── Render ──────────────────────────────────────────────────────────────────
sed -e "s#__WORKSPACE__#${WORKSPACE}#g" \
    -e "s#__HOSTNAME__#${hostname}#g" \
    -e "s#__ALB_GROUP__#${group}#g" \
    -e "s#__CERT_ARN__#${cert}#g" \
    -e "s#__ALLOWED_CIDRS_JSON__#${cidrs_json}#g" \
    "${TEMPLATE}" > "${out}"

echo "==> rendered ${out#"${ROOT}/"}"
echo "    host      ${hostname}"
echo "    allowed   ${cidrs}   (${origin})"

if [[ "${RENDER_ONLY}" == true ]]; then
  echo "    (--render-only: not applied)"
  exit 0
fi

kubectl apply -f "${out}"

echo
echo "  https://${hostname}     (2-3 minutes for the rule, the target and the DNS record)"
echo "  user: admin    password: make argocd-password"
echo
echo "  Reachable from ${cidrs} only; anyone else gets a 404 from the ALB."
echo "  Re-run this when your address changes."
