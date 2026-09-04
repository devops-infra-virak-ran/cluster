# devops-01 — AWS infrastructure, one environment per Terraform workspace.
#
#   make plan    WORKSPACE=dev
#   make apply   WORKSPACE=dev
#   make destroy WORKSPACE=dev
#
# WORKSPACE picks two things at once, and they always agree:
#
#   the state file   terraform/terraform.tfstate.d/<workspace>/terraform.tfstate
#   the variables    terraform/env/<workspace>.tfvars
#
# So `dev` and `prod` are the same code with different sizes, and neither can
# see the other's state. Changing dev cannot touch prod.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

TF_DIR    := $(CURDIR)/terraform
WORKSPACE ?= dev
VARS      := env/$(WORKSPACE).tfvars

# Read from the tfvars so it cannot disagree with what Terraform used. Only the
# aws CLI calls in this file need it; Terraform reads the variable itself.
REGION    := $(shell sed -n 's/^[[:space:]]*region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(CURDIR)/terraform/env/$(WORKSPACE).tfvars 2>/dev/null | head -1)

# Every kubectl in this file talks to THIS workspace's cluster, and nothing
# else. Exported, because `kubectl` on the host would otherwise read
# ~/.kube/config — whatever cluster that happens to point at, from whenever.
#
# That is not a theoretical mix-up. Every kubeconfig this repository writes
# uses https://127.0.0.1:6443, because they all reach the apiserver through an
# SSH tunnel on the same local port. So a stale default config does not fail to
# connect; it connects to whichever tunnel is open, with the wrong cluster's
# credentials, and fails with an x509 error that reads like a broken cluster
# rather than the wrong file.
#
# Set here rather than per-recipe so scripts/ inherit it too.
export KUBECONFIG := $(HOME)/.kube/config-$(WORKSPACE)

# Kubespray runs from its official container image, so the only thing to
# install is Docker. The tag pins Ansible, Python and the Kubespray release
# together, which is why a laptop and a CI agent run identical code.
#
# This tag and kube_version in kubespray/group_vars/k8s_cluster/k8s-cluster.yml
# are a pair. v2.31.0 supports Kubernetes 1.33.0 to 1.35.4; move both or
# neither.
KUBESPRAY_VERSION ?= v2.31.0
KUBESPRAY         := $(CURDIR)/kubespray/run.sh $(WORKSPACE)
INVENTORY         := $(CURDIR)/kubespray/inventory/$(WORKSPACE)/inventory.ini

# Pinned upstream, not the copy Kubespray bundles — see kubespray/group_vars/
# all/aws.yml for why.
EBS_CSI_VERSION   ?= v1.64.0

# ─── Helm ────────────────────────────────────────────────────────────────────
# Helm runs from a container for the same reason Kubespray does: the version is
# pinned by a tag, and nothing has to be installed on the host.
#
# --network host is what lets it reach the apiserver through the SSH tunnel on
# 127.0.0.1 — without it, "localhost" inside the container is the container.
HELM_VERSION ?= 3.16.3
INGRESS_NGINX_VERSION ?= 4.14.5
HELM_RELEASE ?= apps
HELM_NS      ?= apps
CHART        := $(CURDIR)/helm/services

# The catalogue. Every file under helm/values/<group>/ becomes a -f, sorted so
# the order is reproducible. One file per group today; the glob means a group
# can be split across several files, or a new group added, with no change here.
VALUE_FILES := $(sort $(wildcard $(CURDIR)/helm/values/*/*.yaml))

# What differs about this environment: image tags and replica counts. It goes
# LAST so it wins — the catalogue says a service exists, this says which build
# of it runs here and how many.
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

# The registry every image name is prefixed with. Read from Terraform rather
# than written into a values file: it contains the account id and region, which
# are properties of the environment you actually applied into, not a choice
# anyone makes in Helm. Nothing to keep in sync and no account id in git.
#
# TF_WORKSPACE, not `workspace select`: this must read the state for the
# workspace being deployed, whichever one happens to be selected right now.
TF_OUT := TF_WORKSPACE=$(WORKSPACE) terraform -chdir=$(TF_DIR) output -raw

# There is no registry until `make apply`, and most of the time an environment
# is destroyed — that is the point of destroying it. Rendering and linting the
# chart has nothing to do with AWS, so they fall back to a placeholder rather
# than refusing to run.
#
# A .invalid host (RFC 2606) can never resolve, so a rendered manifest that
# escaped into a cluster fails immediately and visibly instead of quietly
# pulling some unrelated image from Docker Hub.
REGISTRY_PLACEHOLDER := unresolved-registry.invalid
INGRESS_PLACEHOLDER  := http://unresolved-loadbalancer.invalid

# Both facts Helm needs from AWS, resolved in the shell at recipe time so make
# does not run Terraform just to parse this file.
REGISTRY  = --set global.imageRegistry="$$(r="$$($(TF_OUT) ecr_image_prefix 2>/dev/null)"; echo "$${r:-$(REGISTRY_PLACEHOLDER)}")"
INGRESS   = --set global.ingress.url="$$(r="$$($(TF_OUT) alb_url 2>/dev/null)"; echo "$${r:-$(INGRESS_PLACEHOLDER)}")"
HELM_SETS = $(REGISTRY) $(INGRESS)

# For helm-lint and helm-render: say the values are not the real ones, on
# stderr, so `make helm-render > manifest.yaml` still produces clean YAML.
define warn_offline
	@r="$$($(TF_OUT) ecr_image_prefix 2>/dev/null)$$($(TF_OUT) alb_url 2>/dev/null)"; test -n "$$r" || { \
	  echo "note: workspace '$(WORKSPACE)' is not applied — images render as" >&2; \
	  echo "      $(REGISTRY_PLACEHOLDER)/<service>:<tag> and the URL as" >&2; \
	  echo "      $(INGRESS_PLACEHOLDER). Fine for lint and render; run" >&2; \
	  echo "      'make apply WORKSPACE=$(WORKSPACE)' for the real ones." >&2; }
endef

# For `make url` and `make ingress`, which need the load balancer specifically.
# The tunnel is a process, not a setting: it dies with the terminal that
# started it, with the laptop sleeping, or with the bastion's IP changing. Its
# absence surfaces as whatever the command happened to be doing at the time —
# `make storage` reports "failed to download openapi", which reads like a
# broken cluster and says nothing about a tunnel.
# Resolve every image against ECR before applying anything. A tag that was
# never pushed is otherwise found by the kubelet, and surfaces as helm's
# "context deadline exceeded" five minutes later — an error about waiting,
# which names neither the image nor the reason.
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
	@r="$$($(TF_OUT) alb_url 2>/dev/null)"; test -n "$$r" || { \
	  echo "error: workspace '$(WORKSPACE)' has no load balancer yet."; \
	  echo "       Terraform creates it, and the outputs naming it:"; \
	  echo "         make apply WORKSPACE=$(WORKSPACE)"; \
	  exit 1; }
endef

# For helm-diff and helm-deploy, which touch a cluster. Deploying the
# placeholder would leave every pod in ImagePullBackOff, so this refuses.
define need_registry
	@r="$$($(TF_OUT) ecr_image_prefix 2>/dev/null)"; test -n "$$r" || { \
	  echo "error: workspace '$(WORKSPACE)' has no ECR registry yet, so there are"; \
	  echo "       no images to deploy. Terraform creates the repositories:"; \
	  echo "         make apply WORKSPACE=$(WORKSPACE)"; \
	  exit 1; }
endef

HELM = docker run --rm --network host \
         -v "$(CURDIR):/work" -v "$(HOME)/.kube:/root/.kube:ro" \
         -e KUBECONFIG=/root/.kube/config-$(WORKSPACE) \
         -w /work alpine/helm:$(HELM_VERSION)

# Every workspace-aware target starts here. `-or-create` means the first
# `make plan WORKSPACE=staging` just works instead of failing on a workspace
# that does not exist yet.
define tf
	@test -f "$(TF_DIR)/$(VARS)" || { \
	  echo "error: no $(VARS) — environments are: $$(ls $(TF_DIR)/env/*.tfvars | xargs -n1 basename | sed 's/.tfvars//' | tr '\n' ' ')"; \
	  exit 1; }
	@cd $(TF_DIR) && terraform workspace select -or-create $(WORKSPACE) >/dev/null
	cd $(TF_DIR) && terraform $(1)
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
	@printf '\nWORKSPACE is \033[36m%s\033[0m. Available: ' "$(WORKSPACE)"
	@ls $(TF_DIR)/env/*.tfvars 2>/dev/null | xargs -n1 basename | sed 's/.tfvars//' | tr '\n' ' '
	@printf '\n\n'

# ─── Core loop ───────────────────────────────────────────────────────────────

.PHONY: init
init: ## Download providers and set up the backend (run once, and after adding a provider)
	cd $(TF_DIR) && terraform init -input=false

.PHONY: plan
plan: ## Show what would change: make plan WORKSPACE=dev
	$(call tf,plan -var-file=$(VARS) -out=tfplan)

.PHONY: apply
apply: ## Apply the plan you just reviewed (asks before changing anything)
	$(call tf,apply -var-file=$(VARS))

.PHONY: apply-plan
apply-plan: ## Apply exactly the saved tfplan from `make plan` — no second prompt, no drift
	$(call tf,apply tfplan)

# The repositories carry lifecycle.prevent_destroy, which is an assertion and not
# a filter: a plain `terraform destroy` does not skip them, it refuses the whole
# plan with "Instance cannot be destroyed". The scope has to be narrowed when the
# plan is built, and this Terraform has -target but no -exclude — so the list
# below is every top-level address in state except module.registry.
#
# Derived from state rather than written out here, so adding a module does not
# silently leave it running after a destroy that claimed to remove everything.
.PHONY: destroy
destroy: ## Tear the workspace down, keeping ECR. Costs stop when this finishes.
	@echo "This destroys everything in workspace '$(WORKSPACE)' that Terraform created,"
	@echo "EXCEPT module.registry — the ECR repositories and their images survive, so"
	@echo "a rebuild does not lose image history. (ECR storage still bills, in cents.)"
	@echo
	@echo "It does NOT destroy what Kubernetes created: ELBs from Service"
	@echo "type=LoadBalancer, EBS volumes from PersistentVolumeClaims. Those are"
	@echo "not in Terraform state, they keep billing, and a leftover ELB holds an"
	@echo "ENI that blocks the VPC from deleting. Run 'make cluster-down' first."
	@echo
	@read -p "Type the workspace name to confirm: " c; \
	  if [[ "$$c" != "$(WORKSPACE)" ]]; then echo "aborted"; exit 1; fi
	@test -f "$(TF_DIR)/$(VARS)" || { echo "error: no $(VARS)"; exit 1; }
	@cd $(TF_DIR) && terraform workspace select -or-create $(WORKSPACE) >/dev/null
	@cd $(TF_DIR) && targets=$$(terraform state list \
	  | sed 's/\[.*\]//' \
	  | awk -F. '{ if ($$1 == "module") print "module."$$2; else print $$1"."$$2 }' \
	  | sort -u \
	  | grep -v '^data\.' \
	  | grep -v '^module\.registry$$' \
	  | sed 's/^/-target=/' | tr '\n' ' '); \
	  test -n "$$targets" || { echo "nothing in state for workspace '$(WORKSPACE)'"; exit 0; }; \
	  echo "keeping module.registry (ECR); destroying: $$targets"; \
	  terraform destroy -var-file=$(VARS) $$targets

.PHONY: output
output: ## Print this workspace's outputs
	$(call tf,output)

.PHONY: refresh
refresh: ## Re-read reality into state, without changing anything
	$(call tf,refresh -var-file=$(VARS))

# ─── Workspaces ──────────────────────────────────────────────────────────────

.PHONY: workspaces
workspaces: ## List workspaces, which is selected, and whether each holds anything
	@cd $(TF_DIR) && terraform workspace list -no-color | while IFS= read -r line; do \
	  [[ -n "$${line// }" ]] || continue; \
	  if [[ "$$line" == '*'* ]]; then mark='->'; else mark='  '; fi; \
	  w=$$(echo "$$line" | tr -d '* '); \
	  state="$(TF_DIR)/terraform.tfstate.d/$$w/terraform.tfstate"; \
	  if [[ -s "$$state" ]]; then \
	    held="$$(grep -c '"mode"' "$$state" 2>/dev/null || true) resources"; \
	  else held='empty'; fi; \
	  if [[ -f "$(TF_DIR)/env/$$w.tfvars" ]]; then env='';  else env='  (no env/'"$$w"'.tfvars — not usable)'; fi; \
	  printf '%s %-10s %-14s%s\n' "$$mark" "$$w" "$$held" "$$env"; \
	done

.PHONY: current
current: ## Show what WORKSPACE would build, selecting it first
	@test -f "$(TF_DIR)/$(VARS)" || { echo "error: no $(VARS)"; exit 1; }
	@cd $(TF_DIR) && terraform workspace select -or-create $(WORKSPACE) >/dev/null
	@cd $(TF_DIR) && printf 'workspace: %s\n' "$$(terraform workspace show)"
	@printf 'varfile:   %s\n\n' "$(VARS)"
	@grep -vE '^\s*(#|$$)' $(TF_DIR)/$(VARS) | sed 's/^/  /'

# ─── Checks ──────────────────────────────────────────────────────────────────

.PHONY: fmt
fmt: ## Rewrite .tf files to canonical formatting
	cd $(TF_DIR) && terraform fmt -recursive

.PHONY: validate
validate: ## Check the configuration is internally consistent (no AWS calls, no credentials)
	cd $(TF_DIR) && terraform validate

.PHONY: check
check: fmt validate ## fmt + validate, the fast loop while editing

.PHONY: graph
graph: ## Write a dependency graph to graph.svg (needs graphviz)
	cd $(TF_DIR) && terraform graph | dot -Tsvg > $(CURDIR)/graph.svg
	@echo "wrote graph.svg"

.PHONY: myip
myip: ## Check whether your current public IP is in this workspace's SSH allowlist
	@test -f "$(TF_DIR)/$(VARS)" || { echo "error: no $(VARS)"; exit 1; }
	@ip=$$(curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]'); \
	  test -n "$$ip" || { echo "error: could not reach checkip.amazonaws.com — are you online?"; exit 1; }; \
	  allowed=$$(sed -n 's/^[[:space:]]*ssh_allowed_cidrs[[:space:]]*=[[:space:]]*//p' "$(TF_DIR)/$(VARS)" | head -1); \
	  printf '  your IP now: %s\n  allowlisted: %s\n\n' "$$ip" "$$allowed"; \
	  if [[ "$$allowed" == *"$$ip/32"* ]]; then \
	    echo "  match — SSH to the bastion will work."; \
	  else \
	    echo "  NO MATCH. SSH will hang rather than fail: a security group drops"; \
	    echo "  unmatched packets instead of refusing them, so Ansible waits for its"; \
	    echo "  full timeout and then blames privilege escalation."; \
	    echo; \
	    echo "      make myip-set WORKSPACE=$(WORKSPACE)   # writes it to $(VARS)"; \
	    echo "      make apply     WORKSPACE=$(WORKSPACE)   # one rule added, one removed"; \
	    exit 1; \
	  fi

.PHONY: myip-set
myip-set: ## Write your current public IP into this workspace's ssh_allowed_cidrs
	@test -f "$(TF_DIR)/$(VARS)" || { echo "error: no $(VARS)"; exit 1; }
	@ip=$$(curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]'); \
	  test -n "$$ip" || { echo "error: could not reach checkip.amazonaws.com — are you online?"; exit 1; }; \
	  line="ssh_allowed_cidrs       = [\"$$ip/32\"]"; \
	  sed -i "s|^ssh_allowed_cidrs.*|$$line|" "$(TF_DIR)/$(VARS)"; \
	  grep -n '^ssh_allowed_cidrs' "$(TF_DIR)/$(VARS)" | sed 's/^/  /'; \
	  echo; \
	  echo "  Nothing has changed in AWS yet. Apply it:"; \
	  echo "      make apply WORKSPACE=$(WORKSPACE)"

.PHONY: cost
cost: ## What this workspace runs to per month, from the notes in its tfvars
	@grep -E '^\s*#\s*(cost|~\$$)' $(TF_DIR)/$(VARS) | sed 's/^\s*#\s*/  /' || \
	  echo "  no cost notes in $(VARS)"


# ─── Cluster ─────────────────────────────────────────────────────────────────
# Terraform builds the machines; Kubespray turns them into Kubernetes. Every
# target here carries WORKSPACE through to a per-workspace inventory, so
# `make kubespray-deploy WORKSPACE=prod` cannot reach dev's nodes.

# The whole thing, in order, from nothing to a URL that answers.
#
# Ordering that is not obvious:
#
#   tunnel, not kubeconfig   kubeconfig holds the tunnel in the foreground and
#                            waits for Ctrl-C, which would stop the chain dead.
#   ecr-auth before deploy   the pull secret has to exist when the first pod is
#                            scheduled, or it lands in ImagePullBackOff and
#                            helm-deploy --wait sits there until it times out.
#   ingress before deploy    not required, but the ALB's targets only go
#                            healthy once something answers on the NodePort,
#                            so doing it first means `url` works immediately.
.PHONY: up
up: ## Everything: infrastructure, Kubernetes, ingress, services, URL (35-55 min)
	@echo "Building $(WORKSPACE) from nothing. This takes 35-55 minutes."
	@$(MAKE) --no-print-directory myip WORKSPACE=$(WORKSPACE)
	@$(MAKE) --no-print-directory apply WORKSPACE=$(WORKSPACE)
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
cluster-up: apply kubespray-pull kubespray-ping kubespray-deploy ## Infrastructure and Kubernetes only — `up` also deploys the services
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

.PHONY: inventory
inventory: ## Rewrite this workspace's Kubespray inventory from live state
	$(call tf,apply -var-file=$(VARS) -target=local_file.inventory -auto-approve)
	@echo "wrote $(INVENTORY)"

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
kubespray-scale: ## Add NODES=<name,name> to the cluster (raise the count, apply, then this)
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
# Stopping the nodes keeps everything that is slow or annoying to rebuild — the
# disks, the cluster's etcd data, the VPC, the ECR images — and stops paying
# for the compute, which is most of the bill.
#
# It works because a stopped instance in a VPC keeps its PRIVATE ip. The
# Kubespray inventory and every kubeconfig address nodes by private ip, so
# they are all still correct when it starts again. The bastion keeps its public
# address too, because that is an Elastic IP rather than an ephemeral one.
#
# What it does NOT stop: EBS volumes, the NAT gateway, the load balancer, and
# public IPv4 addresses. Those bill whether or not anything is running, and the
# only way to stop them is to delete them — `make destroy`, or `make pause-hard`.

define instance_filter
--filters Name=tag:Environment,Values=$(WORKSPACE) Name=tag:ManagedBy,Values=terraform
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

.PHONY: pause-hard
pause-hard: ## Also delete the NAT gateway and load balancer (~$49/mo more)
	@echo "This DELETES the NAT gateway, the load balancer and its target group."
	@echo "Terraform recreates them on the next 'make apply' — but the load"
	@echo "balancer comes back with a DIFFERENT DNS name."
	@echo
	@read -p "Type the workspace name to confirm: " c; \
	  if [[ "$$c" != "$(WORKSPACE)" ]]; then echo "aborted"; exit 1; fi
	$(call tf,destroy -var-file=$(VARS) -auto-approve \
	  -target=module.loadbalancer -target=module.network.aws_nat_gateway.main)
	@echo
	@echo "Bring it all back with: make apply WORKSPACE=$(WORKSPACE)"

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
# Getting from nothing to a URL:
#
#   make apply        the cluster, the ECR repositories and the ALB
#   make kubespray-deploy   Kubernetes on the nodes
#   make kubeconfig         a kubectl that can reach it
#   make ingress            the controller the ALB forwards to
#   make helm-deploy        the services
#   make url                where they answer
#
# One Helm release holds every service, and Helm owns the whole definition:
#
#   helm/values/<group>/services.yaml   which services exist, in every env
#   helm/env/<workspace>.yaml           image tag and replicas, per env
#
# Add a block to add a service, delete one to remove it, and `helm upgrade`
# reconciles the difference. Terraform reads the service names out of the
# first to create their ECR repositories, so a new service also needs a
# `make apply` before its images have anywhere to go.

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
	@# Pinned to the NodePort Terraform built the target group around. If these
	@# two numbers ever disagree the ALB health check fails on every target and
	@# the URL returns 503 with nothing obviously wrong in the cluster.
	@#
	@# publishService is off because there is no cloud controller manager to
	@# populate a LoadBalancer Service; publish-status-address puts the ALB's
	@# name into every Ingress instead, so `kubectl get ingress` shows the
	@# address that actually serves it.
	$(HELM) upgrade --install ingress-nginx ingress-nginx \
	  --repo https://kubernetes.github.io/ingress-nginx \
	  --version $(INGRESS_NGINX_VERSION) \
	  --namespace ingress-nginx --create-namespace \
	  --set controller.service.type=NodePort \
	  --set controller.service.nodePorts.http="$$($(TF_OUT) ingress_nodeport)" \
	  --set controller.publishService.enabled=false \
	  --set controller.extraArgs.publish-status-address="$$($(TF_OUT) alb_dns_name)" \
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
	@base="$$($(TF_OUT) alb_url)"; echo "$$base"; echo; \
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
	@# Silent on purpose: the output is meant to be piped into kubectl or a
	@# file, and make echoing the docker command would corrupt the YAML.
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
	@# --atomic rolls the release back if it does not become ready, rather
	@# than leaving it `failed` for the next deploy to inherit.
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
# Plain make answers a typo with "No rule to make target 'plane'. Stop.", which
# tells you that you are wrong but not what would have been right. .DEFAULT
# runs whenever no rule matches, so this turns a typo into a suggestion.

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
clean: ## Remove saved plans, the rendered graph and playbook artifacts
	rm -f $(TF_DIR)/tfplan $(CURDIR)/graph.svg
	rm -rf $(CURDIR)/kubespray/inventory/$(WORKSPACE)/artifacts
