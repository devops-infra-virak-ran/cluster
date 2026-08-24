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
	    printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
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
	@echo "This destroys everything in workspace '$(WORKSPACE)'."
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
	    held="$$(grep -c '"mode"' "$$state" 2>/dev/null || echo 0) resources"; \
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

.PHONY: cost
cost: ## What this workspace runs to per month, from the notes in its tfvars
	@grep -E '^\s*#\s*(cost|~\$$)' $(TF_DIR)/$(VARS) | sed 's/^\s*#\s*/  /' || \
	  echo "  no cost notes in $(VARS)"


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
clean: ## Remove saved plans and the rendered graph
	rm -f $(TF_DIR)/tfplan $(CURDIR)/graph.svg
