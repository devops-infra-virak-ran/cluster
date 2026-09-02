#!/usr/bin/env bash
#
# Read a rendered manifest on stdin and check every ECR image it names actually
# exists, before anything is applied.
#
#   helm template ... | scripts/check-images.sh
#
# Without this, a tag that was never pushed is discovered by the kubelet, four
# layers away from the thing that chose it: `helm upgrade --wait` blocks for
# its full timeout and then reports "context deadline exceeded", which says
# nothing about images at all. The pods sit in ImagePullBackOff and you have to
# go read their events to find out why.
#
# Only ECR images are checked. A public image is somebody else's registry and
# not worth an anonymous round trip to verify.

set -euo pipefail

manifest="$(cat)"

# The registry host carries the region, so one parse gets both.
images="$(printf '%s' "${manifest}" | python3 -c "
import sys, yaml
seen = []
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get('kind') != 'Deployment':
        continue
    for c in d['spec']['template']['spec']['containers']:
        if c['image'] not in seen:
            seen.append(c['image'])
print('\n'.join(seen))
")"

[[ -n "${images}" ]] || exit 0

missing=()
checked=0

while read -r image; do
  [[ -n "${image}" ]] || continue

  # <account>.dkr.ecr.<region>.amazonaws.com/<repo...>:<tag>
  if [[ ! "${image}" =~ ^([0-9]+\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com)/(.+):([^:]+)$ ]]; then
    continue
  fi
  region="${BASH_REMATCH[2]}"
  repo="${BASH_REMATCH[3]}"
  tag="${BASH_REMATCH[4]}"

  checked=$((checked + 1))
  if ! aws ecr describe-images \
        --repository-name "${repo}" \
        --image-ids "imageTag=${tag}" \
        --region "${region}" >/dev/null 2>&1; then
    missing+=("${repo}:${tag}")
  fi
done <<< "${images}"

[[ ${checked} -gt 0 ]] || exit 0

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "error: ${#missing[@]} of ${checked} images do not exist in ECR:" >&2
  for m in "${missing[@]}"; do echo "         ${m}" >&2; done
  echo >&2
  echo "       The repository exists; that tag was never pushed. Deploying would" >&2
  echo "       leave every pod in ImagePullBackOff until helm --wait gave up." >&2
  echo >&2
  echo "       Either push the image:" >&2
  echo "         aws ecr get-login-password --region <region> \\" >&2
  echo "           | docker login --username AWS --password-stdin <registry>" >&2
  echo "         docker build -t <registry>/<repo>:<tag> . && docker push <registry>/<repo>:<tag>" >&2
  echo >&2
  echo "       Or point the service at a tag that exists — what is there now:" >&2
  echo "         aws ecr list-images --repository-name <repo> --region <region>" >&2
  exit 1
fi

echo "==> all ${checked} images exist in ECR"
