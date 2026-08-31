#!/usr/bin/env bash
#
# Add or remove a service without opening a values file.
#
#   scripts/service.sh add payments-api api-service --tag 1.2.0
#   scripts/service.sh add payments-api api-service --tag 1.2.0 --route /pay
#   scripts/service.sh rm  payments-api
#   scripts/service.sh list dev
#
# The files are edited as text, not parsed and rewritten, because the YAML
# libraries available here drop comments on the way out — and the comments are
# most of what those files are for. Every edit is checked afterwards: if the
# result does not parse, the original is restored.
#
# `add` and `rm` touch the catalogue — helm/values/<group>/services.yaml — which
# is also where Terraform reads service names from to create ECR repositories.
# A new service still needs its tag and replicas in helm/env/<workspace>.yaml,
# and a `make apply` to get its registry.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES="${ROOT}/helm/values"
ENVS="${ROOT}/helm/env"
INDENT="      "        # services live six spaces deep: groups > <g> > services

usage() {
  cat >&2 <<USAGE
usage: $(basename "$0") add <name> <group> --tag T [--route R] [--repo R] [--replicas N]
       $(basename "$0") rm  <name>
       $(basename "$0") list

groups: $(ls -d "${VALUES}"/*/ 2>/dev/null | xargs -n1 basename | tr '\n' ' ')
USAGE
  exit 1
}

# The file a service is defined in, and the file a group's services go into.
group_file() { echo "${VALUES}/$1/services.yaml"; }

find_service() {
  local name="$1"
  grep -rl "^${INDENT}${name}:" "${VALUES}"/*/*.yaml 2>/dev/null | head -1
}

# Restore the file and fail loudly if an edit produced something unparseable.
verify() {
  local file="$1" backup="$2"
  if ! python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "${file}" 2>/dev/null; then
    mv "${backup}" "${file}"
    echo "error: the edit produced invalid YAML; ${file} was left unchanged." >&2
    exit 1
  fi
  rm -f "${backup}"
}

cmd_add() {
  local name="${1:-}" group="${2:-}"; shift 2 || usage
  [[ -n "${name}" && -n "${group}" ]] || usage

  local tag="" route="" repo="" replicas=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag)      tag="$2"; shift 2 ;;
      --route)    route="$2"; shift 2 ;;
      --repo)     repo="$2"; shift 2 ;;
      --replicas) replicas="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; usage ;;
    esac
  done

  [[ "${name}" =~ ^[a-z][a-z0-9-]*$ ]] || {
    echo "error: '${name}' is not a valid service name (lowercase, digits, hyphens)." >&2; exit 1; }

  local file; file="$(group_file "${group}")"
  [[ -f "${file}" ]] || { echo "error: no group '${group}' — expected ${file}" >&2; usage; }

  local existing; existing="$(find_service "${name}" || true)"
  [[ -z "${existing}" ]] || {
    echo "error: '${name}' already exists in ${existing#${ROOT}/}" >&2; exit 1; }

  # Without a tag the service falls back to the chart's `tag: latest`, which
  # cannot be rolled back — the check that used to live on the Terraform
  # variable, now that the catalogue is Helm's.
  [[ -n "${tag}" ]] || {
    echo "error: --tag is required. A service with no pinned tag deploys :latest," >&2
    echo "       and there is no earlier tag to roll back to." >&2; exit 1; }

  local backup="${file}.bak"; cp "${file}" "${backup}"

  # Two destinations, because the two kinds of setting now live apart:
  #
  #   repository, route   the catalogue — true in every environment
  #   tag, replicas       helm/env/<ws>.yaml — one value per environment
  #
  # Build the block first, then append once. Editing the file from inside a
  # block that is redirecting to it does not work: sed -i replaces the inode,
  # so the redirect keeps writing to the old, now-unlinked file.
  local block=""
  if [[ -n "${repo}" ]]; then
    block+="${INDENT}  image:"$'\n'
    block+="${INDENT}    repository: ${repo}"$'\n'
  fi
  [[ -n "${route}" ]] && block+="${INDENT}  route: ${route}"$'\n'

  if [[ -z "${block}" ]]; then
    # A key with no children is not valid YAML. `{}` says "every default"
    # explicitly, which is also the shortest an entry can be.
    printf '\n%s%s: {}\n' "${INDENT}" "${name}" >> "${file}"
  else
    printf '\n%s%s:\n%s' "${INDENT}" "${name}" "${block}" >> "${file}"
  fi

  verify "${file}" "${backup}"
  echo "==> added ${name} to ${group}  (${file#${ROOT}/})"

  # Every environment gets an entry, all on the same tag to start. A service
  # in the catalogue but in no environment file deploys with chart defaults,
  # which is never what you meant.
  local env_file env_backup
  for env_file in "${ENVS}"/*.yaml; do
    [[ -e "${env_file}" ]] || continue
    env_backup="${env_file}.bak"; cp "${env_file}" "${env_backup}"
    env_add "${env_file}" "${group}" "${name}" "${tag}" "${replicas:-1}"
    verify "${env_file}" "${env_backup}"
    echo "    ${env_file#${ROOT}/}: tag ${tag}, replicas ${replicas:-1}"
  done

  echo "    review it:  make services WORKSPACE=<env>"
  echo "    registry:   make apply WORKSPACE=<env>       # creates its ECR repo"
  echo "    apply it:   make helm-deploy WORKSPACE=<env>"
}

# Insert a service into one helm/env/<ws>.yaml, under its group's `services:`.
# Creates the group, and the `services:` key under it, when the file has
# neither — so adding the first service of a new group does not mean
# hand-editing three files before this script will work.
env_add() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'ENVADD'
import sys

path, group, name, tag, replicas = sys.argv[1:6]
lines = open(path).read().split("\n")

entry = [
    "      %s:" % name,
    '        image: { tag: "%s" }' % tag,
    "        replicas: %s" % replicas,
]

def block_end(start, indent):
    """Index just past the last non-blank child of the block opened at start."""
    end = start + 1
    for i in range(start + 1, len(lines)):
        if lines[i].strip() and not lines[i].startswith(indent):
            break
        if lines[i].strip():
            end = i + 1
    return end

group_at = next((i for i, l in enumerate(lines) if l == "  %s:" % group), None)

if group_at is None:
    while lines and not lines[-1].strip():
        lines.pop()
    lines += ["", "  %s:" % group, "    services:"] + entry + [""]
else:
    group_end = block_end(group_at, "    ")
    services_at = next((i for i in range(group_at + 1, group_end)
                        if lines[i] == "    services:"), None)
    if services_at is None:
        lines[group_end:group_end] = ["    services:"] + entry
    else:
        at = block_end(services_at, "      ")
        lines[at:at] = [""] + entry

open(path, "w").write("\n".join(lines))
ENVADD
}

cmd_rm() {
  local name="${1:-}"; [[ -n "${name}" ]] || usage

  local file; file="$(find_service "${name}" || true)"
  [[ -n "${file}" ]] || { echo "error: no service '${name}' in ${VALUES}" >&2; exit 1; }

  local backup="${file}.bak"; cp "${file}" "${backup}"
  rm_entry "${file}" "${name}"
  verify "${file}" "${backup}"
  echo "==> removed ${name} from ${file#${ROOT}/}"

  # And from every environment file. Left behind, the entry shows up as an
  # orphan in `make services` and outlives the service it configured.
  local env_file env_backup
  for env_file in "${ENVS}"/*.yaml; do
    [[ -e "${env_file}" ]] || continue
    grep -q "^${INDENT}${name}:" "${env_file}" || continue
    env_backup="${env_file}.bak"; cp "${env_file}" "${env_backup}"
    rm_entry "${env_file}" "${name}"
    verify "${env_file}" "${env_backup}"
    echo "    also removed from ${env_file#${ROOT}/}"
  done

  echo "    apply it:  make helm-deploy WORKSPACE=<env>   # Helm deletes its objects"
}

# Delete a service entry, and any comment lines directly above it, from its
# key until the next key at the same depth (or end of file).
rm_entry() {
  python3 - "$1" "$2" "${INDENT}" <<'RMENTRY'
import sys
path, name, indent = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().split("\n")
key = next(i for i, l in enumerate(lines) if l.startswith(f"{indent}{name}:"))
start = key
# walk back over the comment block and blank line that introduce it
while start > 0 and (lines[start-1].strip().startswith("#") or not lines[start-1].strip()):
    start -= 1
end = len(lines)
for i in range(key + 1, len(lines)):
    if lines[i].strip() and not lines[i].startswith(indent + " ") and not lines[i].strip().startswith("#"):
        end = i
        break
kept = lines[:start] + lines[end:]
# Removing the entry also removed the blank line that separated it from what
# came before. Put one back, or the next entry ends up welded to the previous
# one and every removal makes the file slightly uglier.
if 0 < start < len(kept) and kept[start-1].strip() and kept[start].strip():
    kept.insert(start, "")
open(path, "w").write("\n".join(kept))
RMENTRY
}

cmd_list() {
  local workspace="$1"
  local env_file="${ROOT}/helm/env/${workspace}.yaml"

  if [[ ! -f "${env_file}" ]]; then
    echo "error: no environment file for workspace '${workspace}' at ${env_file#${ROOT}/}" >&2
    echo "       copy helm/env/dev.yaml and set the tags and replicas it should run." >&2
    exit 1
  fi

  python3 - "${VALUES}" "${env_file}" <<'PYEOF'
import sys, glob, os, yaml

values_dir, env_path = sys.argv[1], sys.argv[2]

def load(path):
    return yaml.safe_load(open(path)) or {}

def services(doc):
    """(group, name, config) for every service in a values document."""
    for group, gv in (doc.get("groups") or {}).items():
        for name, cfg in ((gv or {}).get("services") or {}).items():
            yield group, name, cfg or {}

# The catalogue is which services exist at all. Helm's group files own it, and
# Terraform reads the same files to decide which ECR repositories to create.
catalogue = {}
for path in sorted(glob.glob(os.path.join(values_dir, "*", "*.yaml"))):
    for group, name, cfg in services(load(path)):
        catalogue[name] = (group, cfg)

# The environment file says which build of each runs here, and how many.
env = {name: cfg for _, name, cfg in services(load(env_path))}

def tag(cfg):
    return (cfg.get("image") or {}).get("tag")

fmt = "%-14s %-16s %-12s %-5s %s"
print(fmt % ("GROUP", "SERVICE", "TAG", "REPL", "SOURCE"))
for name, (group, cfg) in sorted(catalogue.items(), key=lambda kv: (kv[1][0], kv[0])):
    e = env.get(name, {})
    # The env file wins, which is exactly the order Helm merges them in.
    print(fmt % (group, name,
                 tag(e) or tag(cfg) or "chart default",
                 e.get("replicas", cfg.get("replicas", "default")),
                 os.path.basename(env_path) if name in env else "catalogue only"))

orphans = set(env) - set(catalogue)
if orphans:
    print()
    print("These have settings in %s but are not in the catalogue, so" % os.path.basename(env_path))
    print("nothing deploys them. Add them under helm/values/<group>/services.yaml:")
    for n in sorted(orphans):
        print("  " + n)
PYEOF
}

case "${1:-}" in
  add)  shift; cmd_add "$@" ;;
  rm)   shift; cmd_rm "$@" ;;
  list) shift; cmd_list "${1:-dev}" ;;
  *) usage ;;
esac
