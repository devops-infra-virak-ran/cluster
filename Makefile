SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

WORKSPACE ?= dev

PLATFORM  := scripts/platform.sh $(WORKSPACE)
REGION    := $(shell scripts/platform.sh $(WORKSPACE) region)

export KUBECONFIG := $(HOME)/.kube/config-$(WORKSPACE)

KUBESPRAY_VERSION ?= v2.31.0
KUBESPRAY         := $(CURDIR)/kubespray/run.sh $(WORKSPACE)
INVENTORY         := $(CURDIR)/kubespray/inventory/$(WORKSPACE)/inventory.ini

EBS_CSI_VERSION   ?= v1.64.0

# ArgoCD. `stable` always resolves to the latest release manifest; pin a tag
# (e.g. ARGOCD_VERSION=v3.0.6) for a reproducible install.
ARGOCD_VERSION ?= stable
ARGOCD_NS      ?= argocd
ARGOCD_MANIFEST := https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml

# ─── Helm ────────────────────────────────────────────────────────────────────
HELM_VERSION ?= 3.16.3
INGRESS_NGINX_VERSION ?= 4.14.5
HELM_RELEASE ?= apps
HELM_NS      ?= apps
CHART        := $(CURDIR)/helm/services

VALUE_FILES := $(sort $(wildcard $(CURDIR)/helm/values/*/*.yaml))

ENV_VALUES  := $(CURDIR)/helm/env/$(WORKSPACE).yaml
VALUE_ARGS  := $(foreach f,$(VALUE_FILES),-f /work/helm/values/$(notdir $(patsubst %/,%,$(dir $(f))))/$(notdir $(f))) \
               -f /work/helm/env/$(WORKSPACE).yaml

define need_env_values
	@test -f "$(ENV_VALUES)" || { \
	  echo "error: no $(ENV_VALUES)"; \
	  echo "       every workspace needs one — copy helm/env/dev.yaml and set"; \
	  echo "       the tags and replicas $(WORKSPACE) should run."; \
	  exit 1; }
endef

REGISTRY_PLACEHOLDER := unresolved-registry.invalid
INGRESS_PLACEHOLDER  := http://unresolved-loadbalancer.invalid

REGISTRY  = --set global.imageRegistry="$$(r="$$($(PLATFORM) ecr_image_prefix 2>/dev/null)"; echo "$${r:-$(REGISTRY_PLACEHOLDER)}")"
INGRESS   = --set global.ingress.url="$$(r="$$($(PLATFORM) alb_url 2>/dev/null)"; echo "$${r:-$(INGRESS_PLACEHOLDER)}")"
HELM_SETS = $(REGISTRY) $(INGRESS)

define warn_offline
	@r="$$($(PLATFORM) ecr_image_prefix 2>/dev/null)$$($(PLATFORM) alb_url 2>/dev/null)"; test -n "$$r" || { \
	  echo "note: workspace '$(WORKSPACE)' is not applied — images render as" >&2; \
	  echo "      $(REGISTRY_PLACEHOLDER)/<service>:<tag> and the URL as" >&2; \
	  echo "      $(INGRESS_PLACEHOLDER). Fine for lint and render; fill in" >&2; \
	  echo "      platform/$(WORKSPACE).env for the real ones." >&2; }
endef

define need_images
	@$(HELM) template $(HELM_RELEASE) /work/helm/services \
	  --namespace $(HELM_NS) $(VALUE_ARGS) $(HELM_SETS) 2>/dev/null \
	  | scripts/check-images.sh
endef

define need_cluster
	@test -f "$(KUBECONFIG)" || { \
	  echo "error: no kubeconfig at $(KUBECONFIG)"; \
	  echo "         make tunnel WORKSPACE=$(WORKSPACE)"; \
	  exit 1; }
	@kubectl version -o json --request-timeout=10s >/dev/null 2>&1 || { \
	  echo "error: cannot reach the $(WORKSPACE) apiserver."; \
	  echo "       kubeconfig: $(KUBECONFIG)"; \
	  echo; \
	  echo "       Usually the SSH tunnel is not running — it does not survive"; \
	  echo "       the terminal that started it:"; \
	  echo "         make tunnel WORKSPACE=$(WORKSPACE)"; \
	  echo; \
	  echo "       If the bastion's address changed, re-run it: the tunnel is"; \
	  echo "       pinned to the IP it was created with."; \
	  exit 1; }
endef

define need_alb
	@r="$$($(PLATFORM) alb_url 2>/dev/null)"; test -n "$$r" || { \
	  echo "error: no alb_url for workspace '$(WORKSPACE)'."; \
	  echo "       Ask the infrastructure team for it, then set ALB_URL in"; \
	  echo "         platform/$(WORKSPACE).env"; \
	  exit 1; }
endef

define need_registry
	@r="$$($(PLATFORM) ecr_image_prefix 2>/dev/null)"; test -n "$$r" || { \
	  echo "error: no ecr_image_prefix for workspace '$(WORKSPACE)', so there is"; \
	  echo "       nowhere to pull images from. Set ECR_IMAGE_PREFIX in"; \
	  echo "         platform/$(WORKSPACE).env"; \
	  exit 1; }
endef

HELM = docker run --rm --network host \
         -v "$(CURDIR):/work" -v "$(HOME)/.kube:/root/.kube:ro" \
         -e KUBECONFIG=/root/.kube/config-$(WORKSPACE) \
         -w /work alpine/helm:$(HELM_VERSION)

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
	@printf '\nWORKSPACE is \033[36m%s\033[0m. Available: ' "$(WORKSPACE)"
	@ls $(CURDIR)/platform/*.env 2>/dev/null | grep -v '\.local\.env$$' | xargs -n1 basename | sed 's/\.env$$//' | tr '\n' ' '
	@printf '\n\n'

# ─── Platform ────────────────────────────────────────────────────────────────

PLATFORM_KEYS := region cluster_name ecr_image_prefix ecr_registry_url \
                 alb_url alb_dns_name \
                 ingress_nodeport bastion_ip control_plane_ip node_ssh_user \
                 ssh_private_key_path

.PHONY: platform
platform: ## Show this workspace's platform facts, and which are missing
	@printf 'workspace: \033[36m%s\033[0m\n' "$(WORKSPACE)"
	@printf '  shared  platform/%s.env         (committed)\n' "$(WORKSPACE)"
	@printf '  local   platform/%s.local.env   (gitignored)\n\n' "$(WORKSPACE)"
	@missing=0; for k in $(PLATFORM_KEYS); do \
	  v="$$(scripts/platform.sh $(WORKSPACE) $$k)"; \
	  o="$$(scripts/platform.sh $(WORKSPACE) $$k --origin)"; \
	  if [[ -n "$$v" ]]; then printf '  %-22s %-8s %s\n' "$$k" "$$o" "$$v"; \
	  else printf '  %-22s %-8s \033[31mMISSING\033[0m\n' "$$k" "-"; missing=1; fi; \
	done; \
	echo; \
	if [[ $$missing -eq 1 ]]; then \
	  echo "Set the missing ones in platform/$(WORKSPACE).env, or pass them per-run"; \
	  echo "as uppercase environment variables (ALB_URL=..., SSH_KEY=...)."; \
	  exit 1; \
	else echo "All set."; fi

# ─── Cluster ─────────────────────────────────────────────────────────────────

.PHONY: inventory
inventory: ## Discover the nodes from AWS tags and (re)write the Kubespray inventory
	@scripts/discover-inventory.sh $(WORKSPACE)

.PHONY: up
up: ## Everything: Kubernetes, ingress, services, URL (25-45 min)
	@echo "Building $(WORKSPACE) on existing servers. This takes 25-45 minutes."
	@$(MAKE) --no-print-directory kubespray-pull WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory kubespray-ping WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory kubespray-deploy WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory tunnel WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory storage WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory ingress WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory ecr-auth WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory env-apply WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory helm-deploy WORKSPACE=$(WORKSPACE)
	@echo
	@$(MAKE) --no-print-directory url WORKSPACE=$(WORKSPACE)

.PHONY: cluster-up
cluster-up: kubespray-pull kubespray-ping kubespray-deploy ## Kubernetes only — `up` also deploys the services
	@echo
	@echo "Cluster is up — but nothing is running on it yet. Next:"
	@echo "    make kubeconfig  WORKSPACE=$(WORKSPACE)   # kubectl access, through the bastion"
	@echo "    make storage     WORKSPACE=$(WORKSPACE)   # EBS CSI driver + default StorageClass"
	@echo "    make ingress     WORKSPACE=$(WORKSPACE)   # the controller the ALB forwards to"
	@echo "    make helm-deploy WORKSPACE=$(WORKSPACE)   # the services"
	@echo "    make url         WORKSPACE=$(WORKSPACE)   # where they answer"
	@echo
	@echo "  helm-deploy will land in ImagePullBackOff until ECR auth exists —"
	@echo "  see global.imagePullSecrets in helm/services/values.yaml."

.PHONY: kubespray-pull
kubespray-pull: ## Pull the pinned Kubespray image (~135 MB)
	docker pull quay.io/kubespray/kubespray:$(KUBESPRAY_VERSION)

.PHONY: kubespray-ping
kubespray-ping: ## Check Ansible reaches every node through the bastion
	$(KUBESPRAY) shell -c 'ansible -i /inventory/inventory.ini all -m ping'

.PHONY: kubespray-deploy
kubespray-deploy: ## Install Kubernetes on this workspace's nodes (20-40 minutes)
	$(KUBESPRAY) cluster.yml

.PHONY: kubespray-scale
kubespray-scale: ## Add NODES=<name,name> to the cluster (after the servers exist)
	@test -n "$(NODES)" || { echo "usage: make kubespray-scale NODES=worker3 WORKSPACE=$(WORKSPACE)"; exit 1; }
	$(KUBESPRAY) scale.yml --limit=$(NODES)

.PHONY: kubespray-remove
kubespray-remove: ## Drain and remove NODES=<name> from the cluster
	@test -n "$(NODES)" || { echo "usage: make kubespray-remove NODES=worker3 WORKSPACE=$(WORKSPACE)"; exit 1; }
	$(KUBESPRAY) remove-node.yml -e node=$(NODES)

.PHONY: kubespray-upgrade
kubespray-upgrade: ## Upgrade Kubernetes one minor at a time (bump the image tag and kube_version together)
	$(KUBESPRAY) upgrade-cluster.yml

.PHONY: kubespray-reset
kubespray-reset: ## Wipe Kubernetes off the nodes, leaving the EC2 instances
	@echo "This removes Kubernetes from every node in workspace '$(WORKSPACE)'."
	@read -p "Type the workspace name to confirm: " c; \
	  if [[ "$$c" != "$(WORKSPACE)" ]]; then echo "aborted"; exit 1; fi
	$(KUBESPRAY) reset.yml

.PHONY: kubespray-shell
kubespray-shell: ## A prompt inside the Kubespray image, inventory mounted
	$(KUBESPRAY) shell

.PHONY: kubeconfig
kubeconfig: ## Write a kubeconfig and hold the tunnel open (Ctrl-C ends it)
	scripts/kubeconfig.sh $(WORKSPACE)

.PHONY: tunnel
tunnel: ## Same, but leave the tunnel running in the background
	scripts/kubeconfig.sh $(WORKSPACE) --background

.PHONY: tunnel-stop
tunnel-stop: ## Stop a backgrounded tunnel
	scripts/kubeconfig.sh $(WORKSPACE) --stop

.PHONY: storage
storage: ## Install the EBS CSI driver and make gp3 the default StorageClass
	$(need_cluster)
	kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=$(EBS_CSI_VERSION)"
	kubectl apply -f kubespray/storage/gp3-storageclass.yaml

# ─── Pausing ─────────────────────────────────────────────────────────────────

MANAGED_BY ?= terraform

define instance_filter
--filters Name=tag:Environment,Values=$(WORKSPACE) Name=tag:ManagedBy,Values=$(MANAGED_BY)
endef

.PHONY: pause
pause: ## Stop the nodes, keep the disks and cluster state (~75% off the bill)
	@ids=$$(aws ec2 describe-instances --region $(REGION) $(instance_filter) \
	  Name=instance-state-name,Values=running \
	  --query 'Reservations[].Instances[].InstanceId' --output text); \
	  test -n "$$ids" || { echo "nothing running in $(WORKSPACE)"; exit 0; }; \
	  echo "Stopping:"; aws ec2 describe-instances --region $(REGION) --instance-ids $$ids \
	    --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key==`Name`]|[0].Value]' \
	    --output text | sed 's/^/    /'; \
	  aws ec2 stop-instances --region $(REGION) --instance-ids $$ids \
	    --query 'StoppingInstances[].InstanceId' --output text >/dev/null; \
	  echo; echo "Stopped. Still billing: EBS volumes, the NAT gateway, the load"; \
	  echo "balancer and the public IPv4 addresses — see 'make pause-hard'."; \
	  echo "    make resume WORKSPACE=$(WORKSPACE)"

.PHONY: resume
resume: ## Start the nodes again after `make pause`
	@ids=$$(aws ec2 describe-instances --region $(REGION) $(instance_filter) \
	  Name=instance-state-name,Values=stopped \
	  --query 'Reservations[].Instances[].InstanceId' --output text); \
	  test -n "$$ids" || { echo "nothing stopped in $(WORKSPACE)"; exit 0; }; \
	  aws ec2 start-instances --region $(REGION) --instance-ids $$ids \
	    --query 'StartingInstances[].InstanceId' --output text | tr '\t' '\n' | sed 's/^/    starting /'; \
	  echo; echo "Private addresses are unchanged, so the inventory and kubeconfig still"; \
	  echo "hold. etcd needs a minute or two to settle. Then:"; \
	  echo "    make tunnel WORKSPACE=$(WORKSPACE)    # the old tunnel died with the nodes"; \
	  echo "    kubectl get nodes"

.PHONY: cluster-down
cluster-down: ## Delete what Kubernetes created in AWS — run this BEFORE destroy
	@echo "Deleting LoadBalancer services and PersistentVolumeClaims in every namespace."
	@echo "Terraform does not know about these; they outlive 'make destroy' and keep billing."
	@read -p "Type the workspace name to confirm: " c; \
	  if [[ "$$c" != "$(WORKSPACE)" ]]; then echo "aborted"; exit 1; fi
	kubectl delete svc --all-namespaces --field-selector spec.type=LoadBalancer --ignore-not-found
	kubectl delete pvc --all-namespaces --all --ignore-not-found
	@echo "Wait for the volumes to disappear, then: make destroy WORKSPACE=$(WORKSPACE)"

# ─── Services ────────────────────────────────────────────────────────────────

.PHONY: services
services: ## List the catalogue for this workspace, and which files override it
	@scripts/service.sh list $(WORKSPACE)

.PHONY: svc-add
svc-add: ## Add a service: make svc-add NAME=payments-api GROUP=api-service TAG=0.1.0
	@test -n "$(NAME)" -a -n "$(GROUP)" -a -n "$(TAG)" || { \
	  echo "usage: make svc-add NAME=<service> GROUP=<group> TAG=<version> [ROUTE=/x] [REPO=x] [REPLICAS=n]"; exit 1; }
	@scripts/service.sh add "$(NAME)" "$(GROUP)" \
	  $(if $(TAG),--tag $(TAG)) $(if $(ROUTE),--route $(ROUTE)) \
	  $(if $(REPO),--repo $(REPO)) $(if $(REPLICAS),--replicas $(REPLICAS))

.PHONY: svc-rm
svc-rm: ## Remove a service: make svc-rm NAME=payments-api
	@test -n "$(NAME)" || { echo "usage: make svc-rm NAME=<service>"; exit 1; }
	@scripts/service.sh rm "$(NAME)"

.PHONY: ingress
ingress: ## Install the ingress controller the ALB forwards to
	$(need_cluster)
	$(need_alb)
	$(HELM) upgrade --install ingress-nginx ingress-nginx \
	  --repo https://kubernetes.github.io/ingress-nginx \
	  --version $(INGRESS_NGINX_VERSION) \
	  --namespace ingress-nginx --create-namespace \
	  --set controller.service.type=NodePort \
	  --set controller.service.nodePorts.http="$$($(PLATFORM) ingress_nodeport)" \
	  --set controller.publishService.enabled=false \
	  --set controller.extraArgs.publish-status-address="$$($(PLATFORM) alb_dns_name)" \
	  --wait --timeout 5m
	@echo
	@echo "Targets take about 30s to pass their first health check."
	@echo "Then: make url WORKSPACE=$(WORKSPACE)"

.PHONY: env-apply
env-apply: ## Push helm/env/<ws>.env into the cluster as the app-env Secret
	$(need_cluster)
	@scripts/env-apply.sh $(WORKSPACE) $(HELM_NS)

.PHONY: ecr-auth
ecr-auth: ## Give the cluster a pull secret for ECR, and a CronJob to refresh it
	$(need_cluster)
	@scripts/ecr-auth.sh $(WORKSPACE) $(HELM_NS)

.PHONY: url
url: ## The public URL, and the route each service answers on
	$(need_env_values)
	$(need_alb)
	@base="$$($(PLATFORM) alb_url)"; echo "$$base"; echo; \
	  $(HELM) template $(HELM_RELEASE) /work/helm/services \
	    --namespace $(HELM_NS) $(VALUE_ARGS) $(HELM_SETS) 2>/dev/null \
	  | python3 -c "\
import sys, yaml, re; \
base = sys.argv[1]; \
clean = lambda p: re.sub(r'\(/\|\\\$$\)\(\.\*\)\$$', '', p); \
rows = [(i['metadata']['labels']['app.kubernetes.io/name'], clean(p['path'])) \
        for i in yaml.safe_load_all(sys.stdin) if i and i.get('kind') == 'Ingress' \
        for r in i['spec']['rules'] for p in r['http']['paths']]; \
print('\n'.join('  %-16s %s%s' % (n, base, p) for n, p in sorted(rows)) \
      or '  no service declares a route')" "$$base"
	@echo
	@echo "A 503 for the first half-minute is the ALB waiting on health checks."
	@echo "If it persists, the targets never went healthy — check the NodePort matches:"
	@echo "  kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide"
	@echo "  make output WORKSPACE=$(WORKSPACE) | grep ingress_nodeport"

.PHONY: helm-lint
helm-lint: ## Check the chart renders and follows Helm conventions
	$(need_env_values)
	$(warn_offline)
	$(HELM) lint /work/helm/services $(VALUE_ARGS) $(HELM_SETS)

.PHONY: helm-render
helm-render: ## Print the Kubernetes YAML this release would apply
	$(need_env_values)
	$(warn_offline)
	@$(HELM) template $(HELM_RELEASE) /work/helm/services \
	  --namespace $(HELM_NS) $(VALUE_ARGS) $(HELM_SETS)

.PHONY: helm-diff
helm-diff: ## Ask the live apiserver what would change, without changing it
	$(need_env_values)
	$(need_registry)
	$(need_cluster)
	$(HELM) template $(HELM_RELEASE) /work/helm/services \
	  --namespace $(HELM_NS) $(VALUE_ARGS) $(HELM_SETS) | kubectl diff -f - || true

.PHONY: helm-deploy
helm-deploy: ## Apply the release — creates, updates and removes to match the files
	$(need_env_values)
	$(need_registry)
	$(need_cluster)
	$(need_images)
	$(HELM) upgrade --install $(HELM_RELEASE) /work/helm/services \
	  --namespace $(HELM_NS) --create-namespace $(VALUE_ARGS) $(HELM_SETS) \
	  --atomic --wait --timeout 5m

.PHONY: helm-status
helm-status: ## What is deployed right now
	$(need_cluster)
	$(HELM) list --namespace $(HELM_NS)
	@kubectl get deploy,svc,ingress -n $(HELM_NS) \
	  -l app.kubernetes.io/instance=$(HELM_RELEASE) 2>/dev/null || true

.PHONY: helm-uninstall
helm-uninstall: ## Remove the whole release (every service at once)
	@read -p "Remove release '$(HELM_RELEASE)' from namespace '$(HELM_NS)'? Type the workspace name: " c; \
	  if [[ "$$c" != "$(WORKSPACE)" ]]; then echo "aborted"; exit 1; fi
	$(HELM) uninstall $(HELM_RELEASE) --namespace $(HELM_NS)

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

# ─── ArgoCD ──────────────────────────────────────────────────────────────────
# GitOps for the services chart. ArgoCD runs in the cluster and reconciles the
# chart from git; `make helm-deploy` still works, because the Application syncs
# manually (it shows drift but does not act until you sync).

.PHONY: argocd-install
argocd-install: ## Install ArgoCD into the cluster (one-time)
	@kubectl create namespace $(ARGOCD_NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n $(ARGOCD_NS) -f $(ARGOCD_MANIFEST)
	@echo "waiting for the server to come up..."
	kubectl -n $(ARGOCD_NS) rollout status deploy/argocd-server --timeout=180s
	@echo; echo "Next: make argocd-app WORKSPACE=$(WORKSPACE)"

.PHONY: argocd-app
argocd-app: ## Render this workspace's Application from platform.<ws>.env and apply it
	@scripts/argocd-app.sh $(WORKSPACE)

.PHONY: argocd-password
argocd-password: ## Print the initial ArgoCD admin password
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: argocd-ui
argocd-ui: ## Port-forward the ArgoCD UI to https://localhost:8080 (Ctrl-C ends it)
	@echo "UI: https://localhost:8080   user: admin   pass: make argocd-password"
	kubectl -n $(ARGOCD_NS) port-forward svc/argocd-server 8080:443

.PHONY: argocd-sync
argocd-sync: ## Sync this workspace's Application now (manual sync)
	@if command -v argocd >/dev/null 2>&1; then \
	  argocd app sync services-$(WORKSPACE); \
	else \
	  echo "argocd CLI not found — triggering a sync via the API instead:"; \
	  kubectl -n $(ARGOCD_NS) patch application services-$(WORKSPACE) --type merge \
	    -p '{"operation":{"initiatedBy":{"username":"makefile"},"sync":{}}}'; \
	  echo "watch it:  make argocd-ui   (or kubectl -n $(ARGOCD_NS) get app services-$(WORKSPACE) -w)"; \
	fi

.PHONY: argocd-uninstall
argocd-uninstall: ## Remove ArgoCD and its Applications
	@read -p "Remove ArgoCD from workspace '$(WORKSPACE)'? Type the workspace name: " c; \
	  if [[ "$$c" != "$(WORKSPACE)" ]]; then echo "aborted"; exit 1; fi
	-kubectl delete -n $(ARGOCD_NS) -f $(ARGOCD_MANIFEST) --ignore-not-found
	-kubectl delete namespace $(ARGOCD_NS) --ignore-not-found

# ─── Housekeeping ────────────────────────────────────────────────────────────

.PHONY: clean
clean: ## Remove the rendered graph and playbook artifacts
	rm -f $(CURDIR)/graph.svg
	rm -rf $(CURDIR)/kubespray/inventory/$(WORKSPACE)/artifacts
