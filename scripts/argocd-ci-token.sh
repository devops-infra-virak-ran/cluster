#!/usr/bin/env bash
#
# Mint an API token for Argo CD's `ci` account — the one Jenkins uses to wait
# for syncs and to sync prod after an approval.
#
#   scripts/argocd-ci-token.sh <workspace>
#
# Prints the token once. Put it in jenkins-sonarqube/docker/.env as
# ARGOCD_TOKEN_<WORKSPACE> and run `make deploy` there. The token is never
# stored here, and the admin password used to mint it is never printed.
#
# Through a port-forward rather than the ALB, so it works before
# `make argocd-expose` and from any address.
#
# The `ci` account is declared in controllers/argocd.yaml (accounts.ci) with
# get and sync on Applications only. Tokens do not expire; revoke one with
#   argocd account delete-token --account ci <id>

set -euo pipefail

WORKSPACE="${1:-}"
[[ -n "${WORKSPACE}" ]] || { echo "usage: $(basename "$0") <workspace>" >&2; exit 1; }
NS="${ARGOCD_NS:-argocd}"
PORT="${ARGOCD_TOKEN_PORT:-18080}"

command -v jq >/dev/null 2>&1 || { echo "error: jq is not installed" >&2; exit 1; }

password="$(kubectl -n "${NS}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
if [[ -z "${password}" ]]; then
  echo "error: no argocd-initial-admin-secret in ${NS}. If you changed the admin password" >&2
  echo "       and deleted it, set ARGOCD_ADMIN_PASSWORD and re-run." >&2
  password="${ARGOCD_ADMIN_PASSWORD:-}"
  [[ -n "${password}" ]] || exit 1
fi

kubectl -n "${NS}" port-forward svc/argocd-server "${PORT}:80" >/dev/null 2>&1 &
pf=$!
trap 'kill ${pf} 2>/dev/null || true' EXIT
for _ in $(seq 20); do
  curl -s -o /dev/null "http://127.0.0.1:${PORT}/healthz" && break
  sleep 0.5
done

api="http://127.0.0.1:${PORT}/api/v1"
session="$(jq -nc --arg p "${password}" '{username: "admin", password: $p}' \
  | curl -fsS -H 'Content-Type: application/json' --data @- "${api}/session" | jq -r .token)"

token="$(curl -fsS -H "Authorization: Bearer ${session}" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg id "jenkins-$(date +%Y%m%d%H%M)" '{id: $id, expiresIn: 0}')" \
  "${api}/account/ci/token" | jq -r .token)"

[[ -n "${token}" && "${token}" != null ]] || {
  echo "error: Argo CD returned no token. Is accounts.ci set? (make argocd-install re-applies controllers/argocd.yaml)" >&2
  exit 1; }

echo "Argo CD ci token for ${WORKSPACE} — paste into jenkins-sonarqube/docker/.env:"
echo
echo "ARGOCD_TOKEN_${WORKSPACE^^}=${token}"
echo
echo "Jenkins reaches Argo CD at https://argocd.<site> through the ALB, so the"
echo "Jenkins Elastic IP must be in ADMIN_ALLOWED_CIDRS (platform/${WORKSPACE}.local.env),"
echo "then: make argocd-expose WORKSPACE=${WORKSPACE}"
