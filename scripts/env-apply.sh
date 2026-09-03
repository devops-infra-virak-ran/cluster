#!/usr/bin/env bash
#
# Turn helm/env/<workspace>.env into a Secret the services read at runtime.
#
#   scripts/env-apply.sh <workspace> [namespace]
#
# The .env file is the one place you set application variables. It is NOT in
# git and never reaches the Helm values, so a database password lives in
# exactly two places: your machine, and the cluster.
#
#   helm/env/dev.env          you edit this          (gitignored)
#         │
#         │  make env-apply WORKSPACE=dev
#         ▼
#   Secret app-env in the apps namespace
#         │
#         │  envFrom: [secretRef: app-env]   in helm/env/dev.yaml
#         ▼
#   every variable, in the container
#
# Values are read by `kubectl --from-env-file`, which is deliberately literal:
#
#   KEY=value            good
#   KEY="value"          the quotes become part of the value
#   export KEY=value     "export KEY" becomes the variable name
#
# Comments and blank lines are fine. Anything after the first `=` is the value,
# so URLs, spaces and query strings need no escaping.

set -euo pipefail

WORKSPACE="${1:-}"
NAMESPACE="${2:-apps}"
SECRET="app-env"

[[ -n "${WORKSPACE}" ]] || { echo "usage: $(basename "$0") <workspace> [namespace]" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/helm/env/${WORKSPACE}.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "error: no ${ENV_FILE#"${ROOT}/"}" >&2
  echo >&2
  echo "       Start from the template, then fill it in:" >&2
  echo "         cp helm/env/${WORKSPACE}.env.example helm/env/${WORKSPACE}.env" >&2
  exit 1
fi

# Catch the two mistakes `--from-env-file` accepts silently, before they turn
# into a variable literally named "export DB_HOST" or a password wrapped in
# quote characters.
bad=0
while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
  if [[ "${line}" =~ ^[[:space:]]*export[[:space:]] ]]; then
    echo "error: drop the 'export' — this is not a shell script:" >&2
    echo "         ${line}" >&2
    bad=1
  elif [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*=[\"\'] ]]; then
    echo "error: remove the quotes — they become part of the value:" >&2
    echo "         ${line}" >&2
    bad=1
  elif [[ ! "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    echo "error: not KEY=value:" >&2
    echo "         ${line}" >&2
    bad=1
  fi
done < "${ENV_FILE}"
[[ ${bad} -eq 0 ]] || exit 1

count="$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "${ENV_FILE}" || true)"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# create --dry-run | apply, so this is safe to run repeatedly. A plain `create`
# fails the second time, and `--from-env-file` cannot patch in place.
kubectl create secret generic "${SECRET}" \
  --from-env-file="${ENV_FILE}" \
  --namespace "${NAMESPACE}" \
  --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

echo "==> ${SECRET} in ${NAMESPACE}: ${count} variables from helm/env/${WORKSPACE}.env"
kubectl get secret "${SECRET}" -n "${NAMESPACE}" -o jsonpath='{range .data}{""}{end}' >/dev/null 2>&1 || true
kubectl get secret "${SECRET}" -n "${NAMESPACE}" \
  -o go-template='{{range $k, $v := .data}}    {{$k}}{{"\n"}}{{end}}' 2>/dev/null

echo
echo "Names only — values are never printed. The services that read them say so"
echo "in helm/env/${WORKSPACE}.yaml:"
echo "    envFrom:"
echo "      - secretRef: { name: ${SECRET} }"
echo
echo "Changing a value means re-running this, then restarting the pods:"
echo "    kubectl -n ${NAMESPACE} rollout restart deploy"
