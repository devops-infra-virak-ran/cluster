#!/usr/bin/env bash
#
# Put the ArgoCD web UI behind the ALB, at https://<site>/argocd.
#
#   scripts/argocd-expose.sh <workspace> [--render-only] [--remove]
#
# Three things have to agree for this to work, so this script does all three
# rather than leaving two of them as README steps:
#
#   1. argocd-server must serve itself under /argocd, not /. ArgoCD builds
#      absolute asset paths from --rootpath; left at /, the page loads and
#      every script under it 404s.
#   2. argocd-server must speak HTTP, not HTTPS, on port 80. TLS terminates at
#      the ALB; a second TLS hop to a self-signed backend cert only fails.
#   3. nginx must know the real client address, or the IP allowlist on the
#      Ingress matches the ALB instead of the caller.
#
# (3) is not this script's to set — it belongs to the controller install, so
# `make ingress` sets it and this checks for it.
#
# The rendered argocd/ingress-<ws>.yaml carries the hostname and the allowed
# CIDRs, so it is gitignored, like the rendered Application next to it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${ROOT}/scripts/platform.sh"
TEMPLATE="${ROOT}/argocd/ingress.example.yaml"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
ROOTPATH="/argocd"

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

# ─── Undo ────────────────────────────────────────────────────────────────────
# Removing the Ingress alone would leave argocd-server on a rootpath nothing
# serves, so `make argocd-ui` would come up blank. Put it back to /.
if [[ "${REMOVE}" == true ]]; then
  echo "==> removing the Ingress and returning argocd-server to /"
  kubectl -n "${ARGOCD_NS}" delete ingress argocd-server --ignore-not-found
  kubectl -n "${ARGOCD_NS}" patch configmap argocd-cmd-params-cm --type merge \
    -p '{"data":{"server.rootpath":null,"server.basehref":null,"server.insecure":null}}'
  kubectl -n "${ARGOCD_NS}" rollout restart deployment argocd-server
  kubectl -n "${ARGOCD_NS}" rollout status deployment argocd-server --timeout=120s
  rm -f "${out}"
  echo
  echo "The UI is back to the port-forward only:  make argocd-ui WORKSPACE=${WORKSPACE}"
  exit 0
fi

# ─── The hostname ────────────────────────────────────────────────────────────
# site_url when the workspace has a domain, the load balancer's own name when
# it does not. The scheme is stripped: an Ingress rule matches a host header,
# which carries no scheme.
site="$("${PLATFORM}" "${WORKSPACE}" site_url || true)"
[[ -n "${site}" ]] || site="$("${PLATFORM}" "${WORKSPACE}" alb_url || true)"
if [[ -z "${site}" ]]; then
  echo "error: no site_url or alb_url for workspace '${WORKSPACE}'." >&2
  echo "       Set SITE_URL in platform/${WORKSPACE}.env (make platform WORKSPACE=${WORKSPACE})." >&2
  exit 1
fi
hostname="${site#http://}"; hostname="${hostname#https://}"; hostname="${hostname%%/*}"

scheme="https"
[[ "${site}" == http://* ]] && scheme="http"

# ─── Who may reach it ────────────────────────────────────────────────────────
# Configured, or this machine's current public address. Detecting it mirrors
# `make myip` in the infrastructure project, and means the common case needs no
# handover value at all. It is a snapshot: a changed address needs a re-run.
cidrs="$("${PLATFORM}" "${WORKSPACE}" admin_allowed_cidrs || true)"
origin="platform/${WORKSPACE}.env"
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

# ─── Preflight: does nginx see the real client? ──────────────────────────────
# Checked rather than patched: the ConfigMap belongs to the ingress-nginx Helm
# release, so a patch here would be silently reverted by the next
# `make ingress` — and the failure mode is a 403 for everyone, which reads like
# a broken allowlist rather than a reverted setting.
command -v kubectl >/dev/null 2>&1 || { echo "error: kubectl not found" >&2; exit 1; }
fwd="$(kubectl -n ingress-nginx get configmap ingress-nginx-controller \
        -o jsonpath='{.data.use-forwarded-headers}' 2>/dev/null || true)"
if [[ "${fwd}" != "true" && "${RENDER_ONLY}" != true ]]; then
  echo "error: the ingress controller is not trusting the load balancer's" >&2
  echo "       X-Forwarded-For, so it would see every request as coming from" >&2
  echo "       the ALB's private address and the allowlist below would return" >&2
  echo "       403 to everyone, you included." >&2
  echo >&2
  echo "       That setting lives with the controller install:" >&2
  echo "         make ingress WORKSPACE=${WORKSPACE}     # re-runs the Helm upgrade" >&2
  echo "       then run this again." >&2
  exit 1
fi

# ─── Render ──────────────────────────────────────────────────────────────────
sed -e "s#__WORKSPACE__#${WORKSPACE}#g" \
    -e "s#__HOSTNAME__#${hostname}#g" \
    -e "s#__ALLOWED_CIDRS__#${cidrs}#g" \
    "${TEMPLATE}" > "${out}"

echo "==> rendered ${out}"
echo "    host      ${hostname}"
echo "    path      ${ROOTPATH}"
echo "    allowed   ${cidrs}   (${origin})"

if [[ "${RENDER_ONLY}" == true ]]; then
  echo "    (--render-only: not applied)"
  exit 0
fi

# ─── Tell ArgoCD it lives under /argocd ──────────────────────────────────────
# argocd-cmd-params-cm is what the install manifest reads these from. Merge, so
# anything else already set there survives.
echo "==> pointing argocd-server at ${ROOTPATH} (and turning off its own TLS)"
kubectl -n "${ARGOCD_NS}" patch configmap argocd-cmd-params-cm --type merge -p "$(cat <<JSON
{"data":{"server.rootpath":"${ROOTPATH}","server.basehref":"${ROOTPATH}","server.insecure":"true"}}
JSON
)"

# The ConfigMap is read at startup, not watched.
kubectl -n "${ARGOCD_NS}" rollout restart deployment argocd-server
kubectl -n "${ARGOCD_NS}" rollout status deployment argocd-server --timeout=120s

echo "==> applying the Ingress"
kubectl apply -f "${out}"

echo
echo "  ${scheme}://${hostname}${ROOTPATH}"
echo
echo "  user: admin    password: make argocd-password"
echo
echo "  Reachable from ${cidrs} only. Your address changes when your network"
echo "  does — re-run this after that, or the UI starts answering 403."
