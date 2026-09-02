#!/usr/bin/env bash
#
# Give the cluster a way to pull from ECR.
#
#   scripts/ecr-auth.sh <workspace> [namespace]
#
# The node role already has ecr:GetAuthorizationToken and the pull actions, but
# IAM permission is not a registry login. The kubelet used to make that
# exchange itself; the in-tree ECR credential provider was removed, and its
# replacement is an ecr-credential-provider binary that upstream does not
# publish anywhere — no GitHub release asset, no image on registry.k8s.io. The
# only prebuilt copies are personal forks, which is not where a credential
# handler for every node should come from.
#
# So this does it the other way: an imagePullSecret, refreshed on a schedule.
#
#   now         one is created from this machine's AWS credentials, so the
#               next deploy works rather than waiting for a first schedule
#   every 6h    a CronJob mints a new one from inside the cluster, using the
#               node role through IMDS — no credentials are stored anywhere
#
# An ECR token lasts 12 hours. Refreshing at 6 means one missed run is
# survivable; at 12 the first failure is an outage.

set -euo pipefail

WORKSPACE="${1:-}"
NAMESPACE="${2:-apps}"
SECRET="regcred"

[[ -n "${WORKSPACE}" ]] || { echo "usage: $(basename "$0") <workspace> [namespace]" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Bundles kubectl and the AWS CLI — both verified present in this tag. Pinned,
# because an unpinned tag on the thing holding your registry credentials is how
# a supply chain gets interesting. The version tracks kube_version in
# kubespray/group_vars/k8s_cluster/k8s-cluster.yml, so kubectl matches the
# apiserver it talks to.
IMAGE="${ECR_AUTH_IMAGE:-alpine/k8s:1.35.4}"

tf_out() { TF_WORKSPACE="${WORKSPACE}" terraform -chdir="${ROOT}/terraform" output -raw "$1" 2>/dev/null; }

REGISTRY="$(tf_out ecr_registry_url)" || true
REGION="$(tf_out region)" || true

[[ -n "${REGISTRY}" ]] || {
  echo "error: workspace '${WORKSPACE}' has no ECR registry yet." >&2
  echo "         make apply WORKSPACE=${WORKSPACE}" >&2
  exit 1; }

# The registry host carries the region, and it is the authority — a REGION that
# disagreed with it would mint a token for the wrong registry.
REGION="$(echo "${REGISTRY}" | sed -n 's/.*\.dkr\.ecr\.\([a-z0-9-]*\)\.amazonaws\.com.*/\1/p')"
[[ -n "${REGION}" ]] || { echo "error: could not read a region out of '${REGISTRY}'" >&2; exit 1; }

echo "==> registry  ${REGISTRY}"
echo "==> namespace ${NAMESPACE}"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ─── The secret, now ─────────────────────────────────────────────────────────
# From this machine, so the cluster can pull before the CronJob has ever run.
#
# create --dry-run | apply, rather than create: `create` fails once the secret
# exists, and this script has to be safe to run twice.

echo "==> minting a token from this machine"

# The secret is assembled by hand rather than with `create secret
# docker-registry --docker-password=`, which would put a live registry
# credential in the process table for anyone on this machine to read. There is
# no --docker-password-stdin: that flag belongs to `docker login`, not kubectl.
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
chmod 700 "${TMP}"

token="$(aws ecr get-login-password --region "${REGION}")"
[[ -n "${token}" ]] || { echo "error: ECR returned no token — check your AWS credentials." >&2; exit 1; }

# An ECR token is base64, so it needs no JSON escaping. `auth` is the field
# containerd actually reads; username/password are there for tools that look
# at those instead.
printf '{"auths":{"%s":{"username":"AWS","password":"%s","auth":"%s"}}}' \
  "${REGISTRY}" "${token}" "$(printf 'AWS:%s' "${token}" | base64 -w0)" \
  > "${TMP}/.dockerconfigjson"

kubectl create secret generic "${SECRET}" \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="${TMP}/.dockerconfigjson" \
  --namespace "${NAMESPACE}" \
  --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null
echo "    ${SECRET} in ${NAMESPACE}, good for 12 hours"

# ─── The refresh, from here on ───────────────────────────────────────────────
# The pod reaches IMDS for the node role, which is why the worker instances set
# http_put_response_hop_limit = 2 — a container is one hop further away than
# the host, and at the default limit of 1 the request is dropped and every
# refresh fails with "Unable to locate credentials".

echo "==> installing the refresh CronJob"
kubectl apply -f - <<YAML >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ecr-credentials
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ecr-credentials
  namespace: ${NAMESPACE}
rules:
  # resourceNames scopes this to the one secret it rewrites. Without it the
  # job could read every secret in the namespace, which is a large amount of
  # authority for something that only needs to overwrite its own.
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get, patch, update]
    resourceNames: [${SECRET}]
  - apiGroups: [""]
    resources: [secrets]
    verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ecr-credentials
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ecr-credentials
subjects:
  - kind: ServiceAccount
    name: ecr-credentials
    namespace: ${NAMESPACE}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ecr-credentials
  namespace: ${NAMESPACE}
spec:
  schedule: "0 */6 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          serviceAccountName: ecr-credentials
          restartPolicy: OnFailure
          containers:
            - name: refresh
              image: ${IMAGE}
              command: [/bin/sh, -c]
              args:
                - |
                  set -eu
                  token=\$(aws ecr get-login-password --region ${REGION})
                  kubectl create secret docker-registry ${SECRET} \\
                    --docker-server=${REGISTRY} \\
                    --docker-username=AWS \\
                    --docker-password="\$token" \\
                    --namespace ${NAMESPACE} \\
                    --dry-run=client -o yaml \\
                  | kubectl apply -f -
                  echo "refreshed ${SECRET}"
              resources:
                requests: { cpu: 50m, memory: 64Mi }
                limits:   { memory: 128Mi }
YAML

echo "    CronJob ecr-credentials, every 6 hours"
echo
echo "Check it:"
echo "  kubectl -n ${NAMESPACE} get secret ${SECRET}"
echo "  kubectl -n ${NAMESPACE} create job --from=cronjob/ecr-credentials refresh-now"
