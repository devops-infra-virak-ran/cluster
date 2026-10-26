#!/usr/bin/env bash
#
# Write one team's application variables to its AWS Secrets Manager secret.
#
#   scripts/secret-push.sh <workspace> <team>
#
# Reads helm/env/<workspace>.<team>.env when it exists, otherwise the shared
# helm/env/<workspace>.env — so one file still works for every team until a
# team needs variables the others must not see. Both are gitignored.
#
#   helm/env/dev.env                   you edit this            (gitignored)
#         │  make secret-push TEAM=api-service WORKSPACE=dev
#         ▼
#   Secrets Manager <prefix>/api-service   one JSON object
#         │  External Secrets, within its refresh interval (1h) — or now:
#         │  this script asks it to resync immediately
#         ▼
#   Secret app-env in namespace api-service → envFrom in every Deployment
#
# The value never touches git, Terraform state or Helm values. Format is
# literal:
#
#   KEY=value            good
#   KEY="value"          the quotes become part of the value
#   export KEY=value     rejected
#
# Values are never printed — only the variable names.

set -euo pipefail

WORKSPACE="${1:-}"
TEAM="${2:-}"
[[ -n "${WORKSPACE}" && -n "${TEAM}" ]] || {
  echo "usage: $(basename "$0") <workspace> <team>" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${ROOT}/scripts/platform.sh"

[[ -d "${ROOT}/helm/values/${TEAM}" ]] || {
  echo "error: no team '${TEAM}' — teams are: $(ls "${ROOT}/helm/values" | tr '\n' ' ')" >&2; exit 1; }

ENV_FILE="${ROOT}/helm/env/${WORKSPACE}.${TEAM}.env"
[[ -f "${ENV_FILE}" ]] || ENV_FILE="${ROOT}/helm/env/${WORKSPACE}.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "error: neither helm/env/${WORKSPACE}.${TEAM}.env nor helm/env/${WORKSPACE}.env exists." >&2
  echo "         cp helm/env/dev.env.example helm/env/${WORKSPACE}.env" >&2
  exit 1
fi

prefix="$("${PLATFORM}" "${WORKSPACE}" secrets_name_prefix)"
region="$("${PLATFORM}" "${WORKSPACE}" region)"
[[ -n "${prefix}" && -n "${region}" ]] || {
  echo "error: no secrets_name_prefix for '${WORKSPACE}' — make platform-pull WORKSPACE=${WORKSPACE}" >&2; exit 1; }
secret_id="${prefix}/${TEAM}"

# KEY=value → one JSON object. Validated line by line first, so a mistake is
# reported with its line rather than becoming a variable named "export DB_HOST".
json="$(python3 - "${ENV_FILE}" <<'PYEOF'
import json, re, sys
path = sys.argv[1]
out, bad = {}, []
for n, line in enumerate(open(path), 1):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if re.match(r"\s*export\s", line):
        bad.append("%d: drop the 'export' — this is not a shell script" % n)
    elif re.match(r"[A-Za-z_][A-Za-z0-9_]*=[\"']", line):
        bad.append("%d: remove the quotes — they become part of the value" % n)
    elif not re.match(r"[A-Za-z_][A-Za-z0-9_]*=", line):
        bad.append("%d: not KEY=value" % n)
    else:
        k, v = line.split("=", 1)
        out[k] = v
if bad:
    sys.stderr.write("error: %s:\n" % path + "".join("         line %s\n" % b for b in bad))
    sys.exit(1)
if not out:
    sys.stderr.write("error: %s has no KEY=value lines\n" % path)
    sys.exit(1)
print(json.dumps(out))
PYEOF
)"

names="$(printf '%s' "${json}" | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin))))')"

# Through stdin, never argv: a command line is visible to every process on the
# machine (ps), and lands in shell history if someone copies it.
printf '%s' "${json}" | aws secretsmanager put-secret-value \
  --region "${region}" \
  --secret-id "${secret_id}" \
  --secret-string file:///dev/stdin >/dev/null

echo "==> ${secret_id}: $(wc -w <<< "${names}") variables from ${ENV_FILE#"${ROOT}/"}"
printf '    %s\n' ${names}

# Ask External Secrets to resync now instead of within the hour. Harmless if
# the cluster or the ExternalSecret is not there yet.
if kubectl -n "${TEAM}" get externalsecret app-env >/dev/null 2>&1; then
  kubectl -n "${TEAM}" annotate externalsecret app-env \
    force-sync="$(date +%s)" --overwrite >/dev/null
  echo
  echo "Resync requested. Pods read env at start, so restart them to pick it up:"
  echo "    kubectl -n ${TEAM} rollout restart deploy"
fi
