SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

WORKSPACE ?= dev

PLATFORM  := scripts/platform.sh $(WORKSPACE)
REGION    := $(shell scripts/platform.sh $(WORKSPACE) region)

# One kubeconfig per environment, so a command for dev can never reach prod.
export KUBECONFIG := $(HOME)/.kube/config-$(WORKSPACE)

# ─── Pinned versions ─────────────────────────────────────────────────────────
# Every chart pinned, so `make controllers` installs the same thing next month.
# The load balancer controller's IAM policy in ../terraform is v3.5.0's — bump
# the two together.

LBC_CHART              ?= 3.5.0
EXTERNAL_DNS_CHART     ?= 1.23.0
EXTERNAL_SECRETS_CHART ?= 2.12.0
AUTOSCALER_CHART       ?= 9.59.0
ARGOCD_CHART           ?= 10.10.2

ARGOCD_NS   ?= argocd
ARGOCD_PORT ?= 8080
GIT_REPO_URL := $(shell git config --get remote.origin.url 2>/dev/null)

# ─── Helm ────────────────────────────────────────────────────────────────────
# Helm runs in alpine/k8s, which carries kubectl and the aws CLI matching the
# cluster's Kubernetes 1.36. The aws CLI matters: an EKS kubeconfig has no
# credential in it, only a command — `aws eks get-token` — that kubectl and
# Helm run on every call. Your ~/.aws is mounted read-only for that.

K8S_IMAGE ?= alpine/k8s:1.36.4

HELM = docker run --rm --network host \
         -v "$(CURDIR):/work" -v "$(HOME)/.kube:/root/.kube:ro" -v "$(HOME)/.aws:/root/.aws:ro" \
         -e KUBECONFIG=/root/.kube/config-$(WORKSPACE) -e AWS_PROFILE -e AWS_REGION \
         -w /work --entrypoint helm $(K8S_IMAGE)

HELM_RELEASE := apps
CHART        := /work/helm/services

# Teams are the groups in the catalogue — one directory each under helm/values.
TEAMS := $(notdir $(patsubst %/,%,$(sort $(dir $(wildcard $(CURDIR)/helm/values/*/services.yaml)))))
TEAM  ?=

ENV_VALUES := $(CURDIR)/helm/env/$(WORKSPACE).yaml

REGISTRY_PLACEHOLDER := unresolved-registry.invalid

# What the services chart needs from the platform, for one team ($(1)).
define team_args
-f /work/helm/values/$(1)/services.yaml -f /work/helm/env/$(WORKSPACE).yaml \
--set-json "global.groups=[\"$(1)\"]" \
--set global.imageRegistry="$$(r="$$($(PLATFORM) ecr_image_prefix 2>/dev/null)"; echo "$${r:-$(REGISTRY_PLACEHOLDER)}")" \
--set global.ingress.group="$$($(PLATFORM) cluster_name 2>/dev/null)" \
--set global.ingress.host="$$($(PLATFORM) site_hostname 2>/dev/null)" \
--set global.ingress.certificateArn="$$($(PLATFORM) certificate_arn 2>/dev/null)" \
--set global.ingress.url="$$($(PLATFORM) site_url 2>/dev/null)"
endef

define need_env_values
	@test -f "$(ENV_VALUES)" || { \
	  echo "error: no $(ENV_VALUES)"; \
	  echo "       every workspace needs one — copy helm/env/dev.yaml and set"; \
	  echo "       the tags and replicas $(WORKSPACE) should run."; \
	  exit 1; }
endef

define need_platform
	@test -n "$$($(PLATFORM) cluster_name)" || { \
	  echo "error: no platform facts for '$(WORKSPACE)'."; \
	  echo "         make platform-pull WORKSPACE=$(WORKSPACE)"; \
	  exit 1; }
endef

define need_cluster
	@test -f "$(KUBECONFIG)" || { \
	  echo "error: no kubeconfig at $(KUBECONFIG)"; \
	  echo "         make kubeconfig WORKSPACE=$(WORKSPACE)"; \
	  exit 1; }
	@kubectl version -o json --request-timeout=15s >/dev/null 2>&1 || { \
	  echo "error: cannot reach the $(WORKSPACE) API server."; \
	  echo; \
	  echo "       A timeout is almost always your public IP: the endpoint only"; \
	  echo "       answers api_allowed_cidrs, and drops everything else."; \
	  echo "         make -C ../terraform myip WORKSPACE=$(WORKSPACE)"; \
	  exit 1; }
endef

# Refuses to run Helm by hand against a team Argo CD already deploys. With
# selfHeal on, Argo CD reverts the change a minute later, and the two fight
# for as long as both are pointed at it. FORCE=1 to do it anyway.
define not_argocd_managed
	@if [[ -z "$${FORCE:-}" ]] && kubectl -n $(ARGOCD_NS) get application $(1) >/dev/null 2>&1; then \
	  echo "error: Argo CD's Application $(1) deploys this. Commit the change to"; \
	  echo "       git and let it sync (make argocd-sync), or FORCE=1 to run Helm anyway."; \
	  exit 1; fi
endef

# ─── Help ────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@printf '\nUsage: make \033[36m<target>\033[0m WORKSPACE=<env>\n'
	@awk 'BEGIN { FS = ":.*?## " } \
	  /^# \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80 / { \
	    line = substr($$0, 13); i = index(line, " \xe2\x94\x80"); \
	    if (i > 0) line = substr(line, 1, i - 1); \
	    pending = line; next } \
	  /^[a-zA-Z0-9_-]+:.*?## / { \
	    if (pending != "") { printf "\n\033[1m%s\033[0m\n", pending; pending = "" } \
	    printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\nWORKSPACE is \033[36m%s\033[0m. Environments: ' "$(WORKSPACE)"
	@ls $(CURDIR)/helm/env/*.yaml 2>/dev/null | xargs -n1 basename | sed 's/\.yaml$$//' | tr '\n' ' '
	@printf '\nTeams: %s\n\n' "$(TEAMS)"

# ─── Platform ────────────────────────────────────────────────────────────────

PLATFORM_KEYS := region cluster_name vpc_id ecr_image_prefix ecr_registry_url \
                 public_subnet_cidrs secrets_name_prefix secrets_role_prefix

# Present only where the workspace has a domain, or set per machine.
PLATFORM_KEYS_OPTIONAL := site_url site_hostname certificate_arn route53_zone_id \
                          admin_allowed_cidrs

.PHONY: platform-pull
platform-pull: ## Write platform/<ws>.env from the facts Terraform published to SSM
	@scripts/platform-pull.sh $(WORKSPACE)

.PHONY: platform
platform: ## Show this workspace's platform facts, and which are missing
	@printf 'workspace: \033[36m%s\033[0m\n' "$(WORKSPACE)"
	@printf '  shared  platform/%s.env         (make platform-pull)\n' "$(WORKSPACE)"
	@printf '  local   platform/%s.local.env   (yours, gitignored)\n\n' "$(WORKSPACE)"
	@missing=0; for k in $(PLATFORM_KEYS); do \
	  v="$$(scripts/platform.sh $(WORKSPACE) $$k)"; \
	  o="$$(scripts/platform.sh $(WORKSPACE) $$k --origin)"; \
	  if [[ -n "$$v" ]]; then printf '  %-22s %-8s %s\n' "$$k" "$$o" "$$v"; \
	  else printf '  %-22s %-8s \033[31mMISSING\033[0m\n' "$$k" "-"; missing=1; fi; \
	done; \
	for k in $(PLATFORM_KEYS_OPTIONAL); do \
	  v="$$(scripts/platform.sh $(WORKSPACE) $$k)"; \
	  o="$$(scripts/platform.sh $(WORKSPACE) $$k --origin)"; \
	  if [[ -n "$$v" ]]; then printf '  %-22s %-8s %s\n' "$$k" "$$o" "$$v"; \
	  else printf '  %-22s %-8s \033[2moptional — not set\033[0m\n' "$$k" "-"; fi; \
	done; \
	echo; \
	if [[ $$missing -eq 1 ]]; then \
	  echo "Missing facts come from SSM:  make platform-pull WORKSPACE=$(WORKSPACE)"; \
	  exit 1; \
	else echo "All set."; fi

.PHONY: kubeconfig
kubeconfig: ## Write ~/.kube/config-<ws> for this environment's EKS cluster
	@scripts/kubeconfig.sh $(WORKSPACE)

# ─── Bring-up ────────────────────────────────────────────────────────────────

.PHONY: up
up: ## Everything after `terraform apply`: controllers, teams, secrets, Argo CD (~10 min)
	@$(MAKE) --no-print-directory platform-pull WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory kubeconfig    WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory controllers   WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory teams         WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory secrets       WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory argocd-install WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory argocd-apps   WORKSPACE=$(WORKSPACE)
	@echo
	@$(MAKE) --no-print-directory url WORKSPACE=$(WORKSPACE)

.PHONY: controllers
controllers: lbc external-dns external-secrets autoscaler ## Every in-cluster controller, in dependency order

.PHONY: lbc
lbc: ## AWS Load Balancer Controller — Ingress → ALB
	$(need_platform)
	$(need_cluster)
	$(HELM) upgrade --install aws-load-balancer-controller aws-load-balancer-controller \
	  --repo https://aws.github.io/eks-charts --version $(LBC_CHART) \
	  --namespace kube-system -f /work/controllers/aws-load-balancer-controller.yaml \
	  --set clusterName="$$($(PLATFORM) cluster_name)" \
	  --set region="$$($(PLATFORM) region)" \
	  --set vpcId="$$($(PLATFORM) vpc_id)" \
	  --wait --timeout 5m

# The zone is pinned by id, not by a --domain-filter. A filter naming the
# environment's hostname (dev.<zone>) is narrower than the zone itself, and
# external-dns then drops the zone entirely ("record filter for domains: []")
# and never writes a record. txtOwnerId keeps dev, uat and prod from touching
# each other's records in the shared zone.
.PHONY: external-dns
external-dns: ## external-dns — each Ingress host → Route 53 alias (skipped without a domain)
	$(need_platform)
	$(need_cluster)
	@zone="$$($(PLATFORM) route53_zone_id)"; site="$$($(PLATFORM) site_hostname)"; \
	  if [[ -z "$$zone" || -z "$$site" ]]; then \
	    echo "skipping external-dns: '$(WORKSPACE)' has no domain (route53_zone_id / site_hostname)"; exit 0; fi; \
	  $(HELM) upgrade --install external-dns external-dns \
	    --repo https://kubernetes-sigs.github.io/external-dns --version $(EXTERNAL_DNS_CHART) \
	    --namespace external-dns --create-namespace -f /work/controllers/external-dns.yaml \
	    --set txtOwnerId="$$($(PLATFORM) cluster_name)" \
	    --set-json "extraArgs=[\"--zone-id-filter=$$zone\"]" \
	    --wait --timeout 5m

.PHONY: external-secrets
external-secrets: ## External Secrets Operator — Secrets Manager → Kubernetes Secrets
	$(need_cluster)
	$(HELM) upgrade --install external-secrets external-secrets \
	  --repo https://charts.external-secrets.io --version $(EXTERNAL_SECRETS_CHART) \
	  --namespace external-secrets --create-namespace -f /work/controllers/external-secrets.yaml \
	  --wait --timeout 5m

.PHONY: autoscaler
autoscaler: ## Cluster Autoscaler — adds and removes nodes for pending pods
	$(need_platform)
	$(need_cluster)
	$(HELM) upgrade --install cluster-autoscaler cluster-autoscaler \
	  --repo https://kubernetes.github.io/autoscaler --version $(AUTOSCALER_CHART) \
	  --namespace kube-system -f /work/controllers/cluster-autoscaler.yaml \
	  --set autoDiscovery.clusterName="$$($(PLATFORM) cluster_name)" \
	  --set awsRegion="$$($(PLATFORM) region)" \
	  --wait --timeout 5m

.PHONY: teams
teams: ## Team namespaces, quotas, RBAC, network policies, secret wiring (helm/teams)
	$(need_env_values)
	$(need_platform)
	$(need_cluster)
	$(call not_argocd_managed,teams-$(WORKSPACE))
	$(HELM) upgrade --install teams /work/helm/teams \
	  --namespace kube-system -f /work/helm/env/$(WORKSPACE).yaml \
	  --set global.region="$$($(PLATFORM) region)" \
	  --set global.albSourceCidrs="$$($(PLATFORM) public_subnet_cidrs | sed 's/,/\\,/g')" \
	  --set global.secretsNamePrefix="$$($(PLATFORM) secrets_name_prefix)" \
	  --set global.secretsRolePrefix="$$($(PLATFORM) secrets_role_prefix)" \
	  --wait=hookOnly --timeout 3m
	@# hookOnly, not --wait: Helm 4 waits for every object to be ready, and an
	@# ExternalSecret is not ready until `make secrets` has written its value —
	@# which needs these namespaces first. Check them with:
	@#   kubectl get externalsecret -A

.PHONY: secret-push
secret-push: ## Write one team's helm/env/<ws>[.<team>].env to Secrets Manager: TEAM=api-service
	@test -n "$(TEAM)" || { echo "usage: make secret-push TEAM=<team> WORKSPACE=$(WORKSPACE)   teams: $(TEAMS)"; exit 1; }
	@scripts/secret-push.sh $(WORKSPACE) $(TEAM)

.PHONY: secrets
secrets: ## secret-push for every team
	@for t in $(TEAMS); do scripts/secret-push.sh $(WORKSPACE) $$t; echo; done

.PHONY: cluster-down
cluster-down: ## Delete what the cluster created in AWS (ALB, DNS, volumes) — BEFORE terraform destroy
	@echo "Deletes, in workspace '$(WORKSPACE)':"
	@echo "  - every Argo CD Application, and what it deployed"
	@echo "  - every Ingress — the load balancer controller then deletes the ALB,"
	@echo "    and external-dns the DNS records"
	@echo "  - every PersistentVolumeClaim, and so its EBS volume"
	@echo "Terraform does not know these exist. Left behind they keep billing, and"
	@echo "the ALB keeps the VPC and the certificate from being deleted."
	@read -p "Type the workspace name to confirm: " c; \
	  if [[ "$$c" != "$(WORKSPACE)" ]]; then echo "aborted"; exit 1; fi
	$(need_cluster)
	@# Applications first: with selfHeal on, Argo CD would recreate any Ingress
	@# deleted underneath it.
	kubectl -n $(ARGOCD_NS) delete applications --all --wait --timeout=5m --ignore-not-found
	@# --wait holds until the controller's finalizer has deleted the ALB, which
	@# is what has to be gone before the VPC can be.
	kubectl delete ingress --all-namespaces --all --wait --timeout=5m --ignore-not-found
	kubectl delete svc --all-namespaces --field-selector spec.type=LoadBalancer --ignore-not-found
	kubectl delete pvc --all-namespaces --all --wait --timeout=5m --ignore-not-found
	@echo
	@echo "Done. external-dns removes the records within a minute. Then:"
	@echo "    make -C ../terraform destroy WORKSPACE=$(WORKSPACE)"

# ─── Services ────────────────────────────────────────────────────────────────

.PHONY: services
services: ## List the catalogue for this workspace, and which files override it
	@scripts/service.sh list $(WORKSPACE)

.PHONY: svc-tag
svc-tag: ## Point a service at an image tag: make svc-tag NAME=client-side TAG=1.2.3 WORKSPACE=dev
	@test -n "$(NAME)" -a -n "$(TAG)" || { \
	  echo "usage: make svc-tag NAME=<service> TAG=<image-tag> WORKSPACE=<env>"; exit 1; }
	@scripts/service.sh set-tag "$(WORKSPACE)" "$(NAME)" "$(TAG)"

.PHONY: svc-add
svc-add: ## Add a service: make svc-add NAME=payments-api GROUP=api-service TAG=0.1.0
	@test -n "$(NAME)" -a -n "$(GROUP)" -a -n "$(TAG)" || { \
	  echo "usage: make svc-add NAME=<service> GROUP=<team> TAG=<version> [ROUTE=/x] [REPO=x] [REPLICAS=n]"; exit 1; }
	@scripts/service.sh add "$(NAME)" "$(GROUP)" \
	  $(if $(TAG),--tag $(TAG)) $(if $(ROUTE),--route $(ROUTE)) \
	  $(if $(REPO),--repo $(REPO)) $(if $(REPLICAS),--replicas $(REPLICAS))

.PHONY: svc-rm
svc-rm: ## Remove a service: make svc-rm NAME=payments-api
	@test -n "$(NAME)" || { echo "usage: make svc-rm NAME=<service>"; exit 1; }
	@scripts/service.sh rm "$(NAME)"

.PHONY: url
url: ## The public URL, and the route each service answers on
	$(need_env_values)
	@base="$$($(PLATFORM) site_url)"; \
	  if [[ -z "$$base" ]]; then \
	    base="http://$$(kubectl get ingress -A -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"; fi; \
	  echo "$$base"; echo; \
	  for t in $(TEAMS); do \
	    $(HELM) template $(HELM_RELEASE) $(CHART) --namespace $$t $(call team_args,$$t) 2>/dev/null; \
	  done | python3 -c "\
import sys, yaml; \
base = sys.argv[1]; \
rows = [(i['metadata']['namespace'] if 'namespace' in i['metadata'] else '', i['metadata']['labels']['app.kubernetes.io/name'], p['path']) \
        for i in yaml.safe_load_all(sys.stdin) if i and i.get('kind') == 'Ingress' \
        for r in i['spec']['rules'] for p in r['http']['paths']]; \
print('\n'.join('  %-16s %s%s' % (n, base, p) for _, n, p in sorted(rows, key=lambda r: r[2])) \
      or '  no service declares a route')" "$$base"
	@echo
	@echo "A new environment takes 2-3 minutes after its first sync: the ALB is"
	@echo "created, targets pass two health checks, external-dns writes the record."
	@echo "  kubectl get ingress -A        ADDRESS is the ALB once it exists"

.PHONY: check-images
check-images: ## Fail if any tag in this environment was never pushed to ECR
	$(need_env_values)
	@for t in $(TEAMS); do \
	  $(HELM) template $(HELM_RELEASE) $(CHART) --namespace $$t $(call team_args,$$t); \
	done | scripts/check-images.sh

.PHONY: helm-lint
helm-lint: ## Lint both charts for this workspace
	$(need_env_values)
	@for t in $(TEAMS); do \
	  echo "==> services ($$t)"; \
	  $(HELM) lint $(CHART) $(call team_args,$$t); \
	done
	@echo "==> teams"
	$(HELM) lint /work/helm/teams -f /work/helm/env/$(WORKSPACE).yaml \
	  --set global.albSourceCidrs=10.0.1.0/24 --set global.region=us-east-1 \
	  --set global.secretsNamePrefix=lint --set global.secretsRolePrefix=lint-

.PHONY: helm-render
helm-render: ## Print the Kubernetes YAML every team's release would apply (TEAM= for one)
	$(need_env_values)
	@for t in $(or $(TEAM),$(TEAMS)); do \
	  $(HELM) template $(HELM_RELEASE) $(CHART) --namespace $$t $(call team_args,$$t); \
	done

.PHONY: helm-diff
helm-diff: ## Ask the live API server what would change, without changing it
	$(need_env_values)
	$(need_cluster)
	@for t in $(or $(TEAM),$(TEAMS)); do \
	  $(HELM) template $(HELM_RELEASE) $(CHART) --namespace $$t $(call team_args,$$t) \
	    | kubectl diff -n $$t -f - || true; \
	done

.PHONY: helm-deploy
helm-deploy: ## Deploy with Helm directly, bypassing Argo CD (bootstrap and debugging only)
	$(need_env_values)
	$(need_platform)
	$(need_cluster)
	@$(MAKE) --no-print-directory check-images WORKSPACE=$(WORKSPACE)
	@for t in $(or $(TEAM),$(TEAMS)); do \
	  if [[ -z "$${FORCE:-}" ]] && kubectl -n $(ARGOCD_NS) get application $$t-$(WORKSPACE) >/dev/null 2>&1; then \
	    echo "error: Argo CD's Application $$t-$(WORKSPACE) deploys $$t. Commit to git and"; \
	    echo "       make argocd-sync, or FORCE=1 to run Helm anyway."; exit 1; fi; \
	  kubectl get namespace $$t >/dev/null 2>&1 || { \
	    echo "error: no namespace $$t — make teams WORKSPACE=$(WORKSPACE) creates it, with its quota"; exit 1; }; \
	  echo "==> $$t"; \
	  $(HELM) upgrade --install $(HELM_RELEASE) $(CHART) --namespace $$t $(call team_args,$$t) \
	    --rollback-on-failure --wait --timeout 5m; \
	done

.PHONY: helm-status
helm-status: ## What is deployed right now, in every team namespace
	$(need_cluster)
	@for t in $(TEAMS); do \
	  echo "==> $$t"; \
	  kubectl -n $$t get deploy,hpa,pdb,ingress 2>/dev/null || true; echo; \
	done

# ─── Argo CD ─────────────────────────────────────────────────────────────────
# GitOps. Every team's services, and the team namespaces themselves, are
# Applications Argo CD reconciles from this repository. dev and uat sync by
# themselves; prod waits for `make argocd-sync WORKSPACE=prod`.

.PHONY: argocd-install
argocd-install: ## Install Argo CD (pinned chart, plain HTTP behind the ALB)
	$(need_cluster)
	$(HELM) upgrade --install argocd argo-cd \
	  --repo https://argoproj.github.io/argo-helm --version $(ARGOCD_CHART) \
	  --namespace $(ARGOCD_NS) --create-namespace -f /work/controllers/argocd.yaml \
	  --wait --timeout 10m
	@echo; echo "Next: make argocd-apps WORKSPACE=$(WORKSPACE)"

.PHONY: argocd-apps
argocd-apps: ## Render this environment's projects + Applications from the platform facts, and apply
	$(need_platform)
	@scripts/argocd-apps.sh $(WORKSPACE)

.PHONY: argocd-expose
argocd-expose: ## Serve the Argo CD UI at https://argocd.<site>, for ADMIN_ALLOWED_CIDRS only
	@scripts/argocd-expose.sh $(WORKSPACE)

.PHONY: argocd-unexpose
argocd-unexpose: ## Take the UI back off the load balancer (port-forward only)
	@scripts/argocd-expose.sh $(WORKSPACE) --remove

.PHONY: argocd-password
argocd-password: ## Print the initial Argo CD admin password
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: argocd-ui
argocd-ui: ## Port-forward the UI to http://localhost:$(ARGOCD_PORT) (override ARGOCD_PORT)
	@echo "UI: http://localhost:$(ARGOCD_PORT)   user: admin   pass: make argocd-password"
	kubectl -n $(ARGOCD_NS) port-forward svc/argocd-server $(ARGOCD_PORT):80

.PHONY: argocd-status
argocd-status: ## Every Application in this environment: sync, health, revision
	@kubectl -n $(ARGOCD_NS) get applications -l environment=$(WORKSPACE) \
	  -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'

.PHONY: argocd-sync
argocd-sync: ## Sync now — every Application in this environment, or TEAM=<team>
	@apps="$(if $(TEAM),$(TEAM)-$(WORKSPACE),$$(kubectl -n $(ARGOCD_NS) get applications -l environment=$(WORKSPACE) -o name | cut -d/ -f2))"; \
	  for a in $$apps; do \
	    echo "==> sync $$a"; \
	    kubectl -n $(ARGOCD_NS) patch application $$a --type merge \
	      -p "{\"operation\":{\"initiatedBy\":{\"username\":\"$${USER:-make}\"},\"sync\":{}}}" >/dev/null; \
	  done; \
	  echo "watch:  make argocd-status WORKSPACE=$(WORKSPACE)"

.PHONY: argocd-history
argocd-history: ## What a team's Application has deployed, newest last: TEAM=<team>
	@test -n "$(TEAM)" || { echo "usage: make argocd-history TEAM=<team> WORKSPACE=$(WORKSPACE)"; exit 1; }
	@kubectl -n $(ARGOCD_NS) get application $(TEAM)-$(WORKSPACE) \
	  -o jsonpath='{range .status.history[*]}{.id}{"\t"}{.deployedAt}{"\t"}{.revision}{"\t"}{.initiatedBy.username}{"\n"}{end}' \
	  | awk -F'\t' 'BEGIN { printf "%-4s %-22s %-10s %s\n", "ID", "DEPLOYED", "REVISION", "BY" } \
	      { printf "%-4s %-22s %-10s %s\n", $$1, $$2, substr($$3, 1, 8), ($$4 == "" ? "automated" : $$4) }'
	@echo
	@echo "Running now:"
	@kubectl -n $(ARGOCD_NS) get application $(TEAM)-$(WORKSPACE) \
	  -o jsonpath='{range .status.summary.images[*]}{"  "}{@}{"\n"}{end}'
	@echo
	@echo "Roll back by reverting the commit that moved the tag — see docs/release.md."

.PHONY: argocd-ci-token
argocd-ci-token: ## Mint a token for the `ci` account Jenkins uses (paste into jenkins-sonarqube/docker/.env)
	$(need_cluster)
	@scripts/argocd-ci-token.sh $(WORKSPACE)

.PHONY: argocd-repo
argocd-repo: ## Give Argo CD read access to a private git repo (GITHUB_USER=.. GITHUB_TOKEN=..)
	@test -n "$(GITHUB_USER)" && test -n "$(GITHUB_TOKEN)" || { \
	  echo "usage: make argocd-repo GITHUB_USER=<user> GITHUB_TOKEN=<PAT>"; \
	  echo "  the PAT needs READ access to $(GIT_REPO_URL)"; \
	  echo "  (GitHub → Settings → Developer settings → fine-grained token,"; \
	  echo "   repository access = that one repo, permission = Contents: read-only)"; \
	  exit 1; }
	@# A repository-type Secret is how Argo CD learns a private repo's
	@# credentials. The token is passed in, never written to disk or committed.
	@kubectl -n $(ARGOCD_NS) create secret generic repo-cluster \
	  --from-literal=type=git \
	  --from-literal=url="$(GIT_REPO_URL)" \
	  --from-literal=username="$(GITHUB_USER)" \
	  --from-literal=password="$(GITHUB_TOKEN)" \
	  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@kubectl -n $(ARGOCD_NS) label secret repo-cluster \
	  argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
	@echo "Argo CD can now read $(GIT_REPO_URL)."

.PHONY: argocd-uninstall
argocd-uninstall: ## Remove Argo CD (its Applications' workloads stay running)
	@read -p "Remove Argo CD from workspace '$(WORKSPACE)'? Type the workspace name: " c; \
	  if [[ "$$c" != "$(WORKSPACE)" ]]; then echo "aborted"; exit 1; fi
	$(HELM) uninstall argocd --namespace $(ARGOCD_NS)

# ─── Unknown targets ─────────────────────────────────────────────────────────

.PHONY: list
list: ## List every target, one per line
	@awk -F: '/^[a-zA-Z0-9_-]+:.*?## / { print $$1 }' $(MAKEFILE_LIST) | sort -u

.DEFAULT:
	@echo "make: there is no target '$@'."
	@near=$$($(MAKE) --no-print-directory list | while read -r t; do \
	   case "$@" in "$$t"*) echo "$$t" ;; esac; \
	   case "$$t" in "$@"*) echo "$$t" ;; esac; \
	 done | sort -u | head -3); \
	 if [[ -n "$$near" ]]; then \
	   echo; echo "Did you mean:"; \
	   while read -r t; do echo "    make $$t WORKSPACE=$(WORKSPACE)"; done <<< "$$near"; \
	 else \
	   echo; echo "Targets:"; $(MAKE) --no-print-directory list | sed 's/^/    /'; \
	 fi
	@echo; echo "\`make help\` describes them all."
	@exit 1

# ─── Housekeeping ────────────────────────────────────────────────────────────

.PHONY: clean
clean: ## Remove rendered manifests
	rm -f $(CURDIR)/graph.svg $(CURDIR)/argocd/rendered-*.yaml $(CURDIR)/argocd/ingress-*.yaml
