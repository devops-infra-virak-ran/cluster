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

.PHONY: destroy
destroy: ## Tear the whole workspace down. Costs stop when this finishes.
	@echo "This destroys everything in workspace '$(WORKSPACE)' that Terraform created."
	@echo
	@echo "It does NOT destroy what Kubernetes created: ELBs from Service"
	@echo "type=LoadBalancer, EBS volumes from PersistentVolumeClaims. Those are"
	@echo "not in Terraform state, they keep billing, and a leftover ELB holds an"
	@echo "ENI that blocks the VPC from deleting. Run 'make cluster-down' first."
	@echo
	@read -p "Type the workspace name to confirm: " c; \
	  if [[ "$$c" != "$(WORKSPACE)" ]]; then echo "aborted"; exit 1; fi
	$(call tf,destroy -var-file=$(VARS))

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

.PHONY: cluster-up
cluster-up: apply kubespray-pull kubespray-ping kubespray-deploy ## Infrastructure, then Kubernetes on it (30-50 minutes)
	@echo
	@echo "Cluster is up. Next:"
	@echo "    make kubeconfig WORKSPACE=$(WORKSPACE)   # kubectl access, through the bastion"
	@echo "    make storage    WORKSPACE=$(WORKSPACE)   # EBS CSI driver + default StorageClass"

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
kubeconfig: ## Write a kubeconfig for this workspace and tunnel to its apiserver
	scripts/kubeconfig.sh $(WORKSPACE)

.PHONY: storage
storage: ## Install the EBS CSI driver and make gp3 the default StorageClass
	kubectl apply -k "github.com/kubernetes-sigs/aws-ebs-csi-driver/deploy/kubernetes/overlays/stable/?ref=$(EBS_CSI_VERSION)"
	kubectl apply -f kubespray/storage/gp3-storageclass.yaml

.PHONY: cluster-down
cluster-down: ## Delete what Kubernetes created in AWS — run this BEFORE destroy
	@echo "Deleting LoadBalancer services and PersistentVolumeClaims in every namespace."
	@echo "Terraform does not know about these; they outlive 'make destroy' and keep billing."
	@read -p "Type the workspace name to confirm: " c; \
	  if [[ "$$c" != "$(WORKSPACE)" ]]; then echo "aborted"; exit 1; fi
	kubectl delete svc --all-namespaces --field-selector spec.type=LoadBalancer --ignore-not-found
	kubectl delete pvc --all-namespaces --all --ignore-not-found
	@echo "Wait for the volumes to disappear, then: make destroy WORKSPACE=$(WORKSPACE)"

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
