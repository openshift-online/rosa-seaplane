.PHONY: help terraform-fmt terraform-init terraform-validate terraform-upgrade terraform-output-management terraform-output-regional helm-lint check-rendered-files promtool-test check-session-manager-plugin ephemeral-provision ephemeral-provision-resume ephemeral-teardown ephemeral-resync ephemeral-list ephemeral-shell ephemeral-bastion-rc ephemeral-bastion-mc ephemeral-post-account-shell ephemeral-port-forward-rc ephemeral-port-forward-mc ephemeral-port-forward-rc-all ephemeral-port-forward-mc-all ephemeral-sre-ui ephemeral-e2e ephemeral-dump-env int-shell int-bastion-rc int-bastion-mc int-port-forward-rc int-port-forward-mc int-port-forward-rc-all int-port-forward-mc-all int-e2e int-dump-env stage-shell stage-bastion-rc stage-bastion-mc stage-port-forward-rc stage-port-forward-mc stage-port-forward-rc-all stage-port-forward-mc-all stage-e2e stage-dump-env check-docs check-default-tags pre-push render

# =============================================================================
# Local tool management
# =============================================================================
# Tools are downloaded to ./bin/ on first use. Versions match ci/Containerfile.

LOCALBIN     ?= $(shell pwd)/bin
UNAME_M      := $(shell uname -m)
UNAME_S      := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH         := $(if $(filter x86_64,$(UNAME_M)),amd64,$(if $(filter aarch64 arm64,$(UNAME_M)),arm64,$(error Unsupported architecture: $(UNAME_M))))

PROMTOOL_VERSION ?= 3.4.1
PROMTOOL         ?= $(or $(shell command -v promtool 2>/dev/null),$(LOCALBIN)/promtool)

YQ_VERSION ?= v4.44.3
YQ         ?= $(or $(shell command -v yq 2>/dev/null),$(LOCALBIN)/yq)

$(LOCALBIN):
	mkdir -p $(LOCALBIN)

$(LOCALBIN)/promtool: | $(LOCALBIN)
	@echo "📥 Installing promtool $(PROMTOOL_VERSION)..."
	@curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v$(PROMTOOL_VERSION)/prometheus-$(PROMTOOL_VERSION).$(UNAME_S)-$(ARCH).tar.gz" | \
		tar -xz --strip-components=1 -C $(LOCALBIN) "prometheus-$(PROMTOOL_VERSION).$(UNAME_S)-$(ARCH)/promtool"
	@chmod +x $(LOCALBIN)/promtool
	@echo "   ✅ promtool $(PROMTOOL_VERSION) installed to $(LOCALBIN)/promtool"

$(LOCALBIN)/yq: | $(LOCALBIN)
	@echo "📥 Installing yq $(YQ_VERSION)..."
	@curl -fsSL "https://github.com/mikefarah/yq/releases/download/$(YQ_VERSION)/yq_$(UNAME_S)_$(ARCH)" -o $(LOCALBIN)/yq
	@chmod +x $(LOCALBIN)/yq
	@echo "   ✅ yq $(YQ_VERSION) installed to $(LOCALBIN)/yq"

check-session-manager-plugin: ## Verify AWS session-manager-plugin is installed (SSM port-forward)
	@PATH="/usr/local/sessionmanagerplugin/bin:$$PATH"; \
	command -v session-manager-plugin >/dev/null 2>&1 || { \
	  echo "❌ session-manager-plugin not found (required for bastion port-forward and silence e2e)."; \
	  echo "   Install: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"; \
	  exit 1; \
	}

# Default target — interactive fzf picker, falls back to formatted list
help: ## Show this help message
	@if command -v fzf >/dev/null 2>&1; then \
		target=$$(grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
			awk -F ':.*## ' '{printf "%-35s - %s\n", $$1, $$2}' | \
			fzf --layout=reverse --prompt="make > " --header="Select a target to run" --no-sort | \
			awk '{print $$1}'); \
		if [ -n "$$target" ]; then \
			echo "Running: make $$target"; \
			$(MAKE) "$$target"; \
		fi; \
	else \
		grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
			awk -F ':.*## ' '{printf "  %-35s - %s\n", $$1, $$2}'; \
	fi

# Discover all directories containing Terraform files (excluding .terraform subdirectories)
TERRAFORM_DIRS := $(shell find ./terraform -name "*.tf" -type f -not -path "*/.terraform/*" | xargs dirname | sort -u)

# Root configurations only (terraform/config/*) — used for validate, which can't run on
# standalone child modules that declare provider configuration_aliases.
TERRAFORM_ROOT_DIRS := $(shell find ./terraform/config -name "*.tf" -type f -not -path "*/.terraform/*" | xargs dirname | sort -u)

terraform-fmt: ## Format all Terraform files
	@echo "🔧 Formatting Terraform files..."
	@echo "$(TERRAFORM_DIRS)" | tr ' ' '\n' | xargs -P 8 -I{} sh -c ' \
		echo "   Formatting $$1"; \
		terraform -chdir=$$1 fmt -recursive \
	' _ {}
	@echo "✅ Terraform formatting complete"

terraform-upgrade: ## Upgrade provider versions
	@echo "🔧 Upgrading Terraform provider versions..."
	@for dir in $(TERRAFORM_DIRS); do \
		echo "   Upgrading $$dir"; \
		terraform -chdir=$$dir init -upgrade -backend=false; \
	done
	@echo "✅ Terraform upgrade complete"

terraform-output-management: ## Get Terraform output for Management Cluster
	@cd terraform/config/management-cluster && terraform output -json

terraform-output-regional: ## Get Terraform output for Regional Cluster
	@cd terraform/config/regional-cluster && terraform output -json


# =============================================================================
# Validation & Testing Targets
# =============================================================================

# Initialize root Terraform configurations (no backend)
terraform-init:
	@echo "🔧 Initializing Terraform configurations..."
	@echo "$(TERRAFORM_ROOT_DIRS)" | tr ' ' '\n' | xargs -P 1 -I{} sh -c ' \
		echo "   Initializing $$1"; \
		if ! terraform -chdir=$$1 init -backend=false; then \
			echo "   ❌ Init failed in $$1"; \
			exit 1; \
		fi \
	' _ {} || exit 1
	@echo "✅ Terraform initialization complete"

# Note: fmt runs on all dirs (modules + configs), but validate only runs on
# root configs because child modules with provider configuration_aliases
# cannot be validated in isolation.
terraform-validate: terraform-init ## Check formatting and validate all Terraform configs
	@echo "🔍 Checking Terraform formatting..."
	@echo "$(TERRAFORM_DIRS)" | tr ' ' '\n' | xargs -P 8 -I{} sh -c ' \
		echo "   Checking formatting in $$1"; \
		if ! terraform -chdir=$$1 fmt -check -recursive; then \
			echo "   ❌ Formatting check failed in $$1"; \
			exit 1; \
		fi \
	' _ {} || { echo "❌ Terraform formatting check failed for one or more directories"; \
		echo "   Run '\''make terraform-fmt'\'' to fix formatting."; \
		exit 1; }
	@echo "🔍 Validating Terraform configurations..."
	@echo "$(TERRAFORM_ROOT_DIRS)" | tr ' ' '\n' | xargs -P 2 -I{} sh -c ' \
		echo "   Validating $$1"; \
		if ! terraform -chdir=$$1 validate; then \
			echo "   ❌ Validation failed in $$1"; \
			exit 1; \
		fi \
	' _ {} || { echo "❌ Terraform validation failed for one or more directories"; \
		exit 1; }
	@echo "✅ Terraform validation complete"

# Global values (aws_region, environment, cluster_type) are injected by the
# ApplicationSet at deploy time, so we supply stubs here for linting.
HELM_LINT_SET := --set global.aws_region=us-east-1 --set global.environment=lint --set global.cluster_type=lint --set global.cluster_name=lint
helm-lint: ## Lint all Helm charts
	@echo "🔍 Linting Helm charts..."
	@failed=false; \
	for chart_dir in $$(find argocd/config -name "Chart.yaml" -exec dirname {} \; | sort); do \
		echo "   Linting $$chart_dir"; \
		if ! helm lint $$chart_dir $(HELM_LINT_SET); then \
			failed=true; \
		fi; \
	done; \
	if [ "$$failed" = true ]; then \
		echo "❌ Helm lint failed for one or more charts"; \
		exit 1; \
	fi
	@echo "✅ Helm lint complete"

check-rendered-files: ## Verify deploy/ is up to date with config.yaml
	@echo "🔍 Rendering deploy/ from config.yaml..."
	@uv run --no-cache scripts/render.py
	@echo "Checking for uncommitted changes in deploy/..."
	@if ! git diff --exit-code deploy/; then \
		echo ""; \
		echo "❌ Rendered files in deploy/ are out of date."; \
		echo "   Run 'uv run scripts/render.py' and commit the results."; \
		exit 1; \
	fi
	@untracked=$$(git ls-files --others --exclude-standard deploy/); \
	if [ -n "$$untracked" ]; then \
		echo ""; \
		echo "❌ Untracked rendered files found in deploy/:"; \
		echo "$$untracked"; \
		echo "   Run 'uv run scripts/render.py' and 'git add' the new files."; \
		exit 1; \
	fi
	@echo "✅ Rendered files are up to date"
	@echo "🔍 Checking config documentation..."
	@uv run --no-cache scripts/render.py --check-docs

promtool-test: $(PROMTOOL) $(YQ) ## Run promtool alerting rule tests
	@PATH="$(LOCALBIN):$$PATH" ./ci/promtool-test.sh

check-docs: ## Check documentation formatting
	@echo "🔍 Checking documentation formatting..."
	@npx --no-install prettier --check '**/*.md'
	@echo "✅ Documentation formatting check complete"

# central-account-bootstrap (shared connection/state/ECR) and the platform-image
# source module are excluded from tag enforcement; the CodePipeline modules are
# tagged and linted normally.
TFLINT_EXCLUDE_DIRS := \
	./terraform/config/central-account-bootstrap \
	./terraform/modules/platform-image

TFLINT_DIRS := $(filter-out $(TFLINT_EXCLUDE_DIRS),$(TERRAFORM_DIRS))

check-default-tags: ## Check all AWS resources have required tags (function, module)
	@echo "🔍 Checking AWS resource tag coverage..."
	@tflint --init --config .tflint.hcl
	@echo "$(TFLINT_DIRS)" | tr ' ' '\n' | xargs -P 4 -I{} sh -c ' \
		echo "   Checking $$1"; \
		tflint --config "$(CURDIR)/.tflint.hcl" --chdir "$$1" \
	' _ {} || { echo "❌ Tag coverage check failed — add missing tags or update .tflint.hcl"; exit 1; }
	@echo "✅ Tag coverage check complete"

pre-push: ## Run all CI validation checks (parallel)
	@echo "🚀 Running all CI validation checks..."
	@echo ""
	@echo "Formatting Terraform files..."
	@$(MAKE) terraform-fmt
	@echo ""
	@$(MAKE) -j4 check-docs check-rendered-files helm-lint terraform-validate promtool-test check-default-tags
	@echo ""
	@echo "✅ All pre-push checks passed!"

# =============================================================================
# Ephemeral Environments
# =============================================================================
# Thin wrappers around scripts/dev/ephemeral-env.sh.
# See docs/development-environment.md for full usage guide.

REPO   ?= openshift-online/rosa-seaplane
BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD)

ephemeral-provision: ## Provision an ephemeral environment
	@ID="$(ID)" REPO="$(REPO)" BRANCH="$(if $(filter command line,$(origin BRANCH)),$(BRANCH),)" \
		./scripts/dev/ephemeral-env.sh provision

ephemeral-provision-resume: ## Resync and resume a failed ephemeral provisioning run (RESYNC=false to skip resync)
	@ID="$(ID)" RESYNC="$(if $(RESYNC),$(RESYNC),true)" \
		./scripts/dev/ephemeral-env.sh provision-resume

ephemeral-teardown: ## Tear down (RESYNC=1: update CI branch from your feature branch, then destroy — use after a failed teardown)
	@ID="$(ID)" RESYNC="$(RESYNC)" ./scripts/dev/ephemeral-env.sh teardown

ephemeral-resync: ## Resync an ephemeral environment to your branch
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh resync

ephemeral-swap-branch: ## Swap an ephemeral environment to a different branch
	@ID="$(ID)" NEW_BRANCH="$(NEW_BRANCH)" NEW_REPO="$(NEW_REPO)" \
		./scripts/dev/ephemeral-env.sh swap-branch

ephemeral-list: ## List ephemeral environments
	@./scripts/dev/ephemeral-env.sh list

ephemeral-shell: ## Interactive shell for Platform API access (ephemeral)
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh shell

ephemeral-bastion-rc: ## Connect to RC bastion in an ephemeral env
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh bastion --cluster-type regional

ephemeral-post-account-shell: ## Register a customer AWS account with the platform API via the ephemeral shell (ACCOUNT_ID=<12-digit-id> required)
	@ID="$(ID)" ACCOUNT_ID="$(ACCOUNT_ID)" ./scripts/dev/ephemeral-env.sh post-account

ephemeral-bastion-mc: ## Connect to MC bastion in an ephemeral env
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh bastion --cluster-type management

ephemeral-port-forward-rc: check-session-manager-plugin ## Port-forward to RC service in an ephemeral env
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh port-forward --cluster-type regional

ephemeral-port-forward-mc: check-session-manager-plugin ## Port-forward to MC service in an ephemeral env
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh port-forward --cluster-type management

ephemeral-port-forward-rc-all: check-session-manager-plugin ## Port-forward all RC services in an ephemeral env
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh port-forward --cluster-type regional --all

ephemeral-port-forward-mc-all: check-session-manager-plugin ## Port-forward all MC services in an ephemeral env
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh port-forward --cluster-type management --all

ephemeral-sre-ui: check-session-manager-plugin ## Tunnel SRE UI tools (Grafana, ArgoCD, Prometheus, Thanos, Loki) through the internal ALB via bastion
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh sre-ui

ephemeral-e2e: check-session-manager-plugin ## Run e2e tests against an ephemeral env
	@ID="$(ID)" E2E_REF="$(or $(E2E_REF),main)" E2E_REPO="$(E2E_REPO)" ./scripts/dev/ephemeral-env.sh e2e

ephemeral-zoa-e2e: ## Run zoa's deep e2e suite against an ephemeral env (ZOA_REF/ZOA_REPO to target a branch/fork)
	@ID="$(ID)" ZOA_REF="$(or $(ZOA_REF),main)" ZOA_REPO="$(ZOA_REPO)" GINKGO_FLAGS="$(GINKGO_FLAGS)" ZOA_MAKE_TARGET=test-e2e ./scripts/dev/ephemeral-env.sh zoa-e2e

ephemeral-zoa-e2e-smoke: ## Run zoa's smoke e2e suite (fast ~2min) against an ephemeral env
	@ID="$(ID)" ZOA_REF="$(or $(ZOA_REF),main)" ZOA_REPO="$(ZOA_REPO)" GINKGO_FLAGS="$(GINKGO_FLAGS)" ZOA_MAKE_TARGET=test-e2e-smoke ./scripts/dev/ephemeral-env.sh zoa-e2e

ephemeral-dump-env: ## Dump EKS must-gather and DB state from an ephemeral env (CLUSTER=rc|mc)
	@ID="$(ID)" ./scripts/dev/ephemeral-env.sh dump-env $(CLUSTER)

# =============================================================================
# Integration Environment
# =============================================================================
# Thin wrappers around scripts/dev/int-env.sh.
# Uses AWS profiles with SAML auth (account IDs from rosa-seaplane-internal or RRP_ACCOUNTS_INT).

int-shell: ## Interactive shell for Platform API access (int)
	@./scripts/dev/int-env.sh shell

int-bastion-rc: ## Connect to RC bastion in int env
	@./scripts/dev/int-env.sh bastion --cluster-type regional

int-bastion-mc: ## Connect to MC bastion in int env
	@./scripts/dev/int-env.sh bastion --cluster-type management

int-port-forward-rc: check-session-manager-plugin ## Port-forward to RC service in int env
	@./scripts/dev/int-env.sh port-forward --cluster-type regional

int-port-forward-mc: check-session-manager-plugin ## Port-forward to MC service in int env
	@./scripts/dev/int-env.sh port-forward --cluster-type management

int-port-forward-rc-all: check-session-manager-plugin ## Port-forward all RC services in int env
	@./scripts/dev/int-env.sh port-forward --cluster-type regional --all

int-port-forward-mc-all: check-session-manager-plugin ## Port-forward all MC services in int env
	@./scripts/dev/int-env.sh port-forward --cluster-type management --all

int-e2e: check-session-manager-plugin ## Run e2e tests against int env
	@E2E_REF="$(or $(E2E_REF),main)" E2E_REPO="$(E2E_REPO)" ./scripts/dev/int-env.sh e2e

int-dump-env: ## Dump EKS must-gather and DB state from int env (CLUSTER=rc|mc)
	@./scripts/dev/int-env.sh dump-env $(CLUSTER)

# =============================================================================
# Stage Environment
# =============================================================================
# Thin wrappers around scripts/dev/stage-env.sh.
# Uses AWS profiles with SAML auth (account IDs from rosa-seaplane-internal or RRP_ACCOUNTS_STAGE).

stage-shell: ## Interactive shell for Platform API access (stage)
	@./scripts/dev/stage-env.sh shell

stage-bastion-rc: ## Connect to RC bastion in stage env
	@./scripts/dev/stage-env.sh bastion --cluster-type regional

stage-bastion-mc: ## Connect to MC bastion in stage env
	@./scripts/dev/stage-env.sh bastion --cluster-type management

stage-port-forward-rc: check-session-manager-plugin ## Port-forward to RC service in stage env
	@./scripts/dev/stage-env.sh port-forward --cluster-type regional

stage-port-forward-mc: check-session-manager-plugin ## Port-forward to MC service in stage env
	@./scripts/dev/stage-env.sh port-forward --cluster-type management

stage-port-forward-rc-all: check-session-manager-plugin ## Port-forward all RC services in stage env
	@./scripts/dev/stage-env.sh port-forward --cluster-type regional --all

stage-port-forward-mc-all: check-session-manager-plugin ## Port-forward all MC services in stage env
	@./scripts/dev/stage-env.sh port-forward --cluster-type management --all

stage-e2e: check-session-manager-plugin ## Run e2e tests against stage env
	@E2E_REF="$(or $(E2E_REF),main)" E2E_REPO="$(E2E_REPO)" ./scripts/dev/stage-env.sh e2e

stage-dump-env: ## Dump EKS must-gather and DB state from stage env (CLUSTER=rc|mc)
	@./scripts/dev/stage-env.sh dump-env $(CLUSTER)

render: ## Render config templates
	@uv run scripts/render.py
