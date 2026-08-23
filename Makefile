# Komodo Infrastructure Makefile
# Simplified deployment management with direct Ansible calls

.PHONY: help setup lint syntax check \
        docker core auth periphery deploy \
        komodo-op app-syncs \
        core-upgrade periphery-upgrade periphery-uninstall \
        status recovery-check reliability-baseline \
        security-check security-baseline docker-dns-baseline host-dns-baseline clean

# Ansible configuration
ANSIBLE_DIR := ansible
INVENTORY := inventory/hosts.yml
ANSIBLE_OPTS := -i $(INVENTORY)
# Override from CLI for per-run extras, e.g.
#   make periphery-upgrade EXTRA_VARS="-e komodo_onboarding_key=O-..."
EXTRA_VARS :=
VENV := .venv
VENV_BIN := $(CURDIR)/$(VENV)/bin

# Default target
help: ## Show this help message
	@echo "Komodo Infrastructure - Deployment Commands"
	@echo "=========================================="
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Quick Start:"
	@echo "  make setup           - Install Ansible dependencies"
	@echo "  make deploy          - Complete deployment (includes komodo-op)"
	@echo "  make lint            - Run code quality checks"

# =============================================================================
# Setup and Dependencies
# =============================================================================

setup: ## Install Python deps into .venv, Ansible collections and roles, create inventory/hosts.yml if missing
	@python3 -m venv $(VENV)
	@$(VENV_BIN)/pip install -q -r requirements.txt
	@ansible-galaxy install -r $(ANSIBLE_DIR)/requirements.yml -p ~/.ansible/roles
	@ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml
	@command -v op >/dev/null 2>&1 || echo "⚠️  1Password CLI (op) not found; secret lookups will fail"
	@if [ ! -f $(ANSIBLE_DIR)/$(INVENTORY) ]; then \
		cp $(ANSIBLE_DIR)/inventory/hosts.example.yml $(ANSIBLE_DIR)/$(INVENTORY); \
		echo "📝 Created $(ANSIBLE_DIR)/$(INVENTORY) from hosts.example.yml - edit it for your hosts"; \
	fi

check: ## Check connectivity to all hosts
	@echo "🔍 Checking connectivity..."
	@cd ansible && ansible all $(ANSIBLE_OPTS) $(EXTRA_VARS) -m ping

# =============================================================================
# Code Quality
# =============================================================================

lint: ## Run ansible-lint and yamllint
	@cd ansible && $(VENV_BIN)/ansible-lint
	@$(VENV_BIN)/yamllint -c ansible/.yamllint ansible/ .github/workflows/

syntax: ## Syntax-check every playbook against hosts.example.yml
	@cd ansible && for playbook in playbooks/*.yml site.yml; do \
		[ -f "$$playbook" ] || continue; \
		$(VENV_BIN)/ansible-playbook -i inventory/hosts.example.yml "$$playbook" --syntax-check || exit 1; \
	done

# =============================================================================
# Individual Deployment Steps
# =============================================================================

docker: ## Install Docker on all nodes
	@echo "🐳 Installing Docker on all nodes..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/01_docker.yml

core: ## Deploy Komodo Core (requires Docker)
	@echo "🦎 Deploying Komodo Core..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/02_komodo_core.yml

auth: ## Initialize Komodo authentication (requires Core)
	@echo "🔑 Initializing Komodo authentication..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/03_komodo_auth.yml

periphery: ## Deploy Komodo Periphery nodes (requires auth)
	@echo "🔗 Deploying Komodo Periphery..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/04_komodo_periphery.yml

# =============================================================================
# Complete Deployment
# =============================================================================

deploy: ## Complete deployment (all steps in sequence)
	@echo "🚀 Starting complete Komodo deployment..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) site.yml


# =============================================================================
# Secret Management & GitOps
# =============================================================================

komodo-op: ## Deploy komodo-op for secret management (manual)
	@echo "🔐 Bootstrapping komodo-op variables..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/05_bootstrap_komodo_op.yml
	@echo "🔐 Deploying komodo-op stack..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/06_deploy_komodo_op.yml

app-syncs: ## Setup application resource syncs (run after komodo-op)
	@echo "🔄 Setting up application resource syncs..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/07_app_syncs.yml

# =============================================================================
# Upgrade & Management Commands
# =============================================================================

core-upgrade: ## Upgrade Komodo Core (pulls latest images)
	@echo "⬆️ Upgrading Komodo Core..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/02_komodo_core.yml --tags upgrade

periphery-upgrade: ## Upgrade Komodo Periphery nodes
	@echo "⬆️ Upgrading Komodo Periphery nodes..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/04_komodo_periphery.yml -e komodo_action=update

periphery-uninstall: ## Uninstall Komodo Periphery from nodes
	@echo "🗑️ Uninstalling Komodo Periphery..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/04_komodo_periphery.yml -e komodo_action=uninstall

upgrade: ## Upgrade Komodo Core and all Periphery nodes
	@echo "⬆️ Upgrading Komodo Core..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/02_komodo_core.yml
	@echo "⬆️ Upgrading Komodo Periphery nodes..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/04_komodo_periphery.yml -e komodo_action=update
	@echo "✅ Komodo upgrade complete!"

# =============================================================================
# Maintenance Commands
# =============================================================================

status: ## Check status of Komodo services
	@echo "🔍 Checking Komodo service status..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/status.yml

recovery-check: ## Verify hosts are restart-clean without changing them
	@echo "Checking restart and recovery prerequisites..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/recovery_check.yml

reliability-baseline: ## Enable restart persistence, swap, and shared networks
	@echo "Applying homelab reliability baseline..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/reliability_baseline.yml

security-check: ## Check homelab security baseline without changing hosts
	@echo "🔐 Checking homelab security baseline..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/security_check.yml

security-baseline: ## Apply pragmatic Linux host security baseline
	@echo "🔐 Applying homelab security baseline..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/security_baseline.yml

docker-dns-baseline: ## Pin Docker daemon DNS to the Tailnet resolver
	@echo "🐳 Pinning Docker daemon DNS to Tailnet resolver..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/docker_dns_baseline.yml

host-dns-baseline: ## Keep the host resolver independent of Tailscale's resolv.conf snapshot
	@echo "🧭 Pinning host resolver to systemd-resolved where it runs..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/host_dns_baseline.yml

clean: ## Clean up temporary files
	@echo "🧹 Cleaning up..."
	@find . -name "*.pyc" -delete
	@find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	@rm -rf ansible/.ansible/
	@echo "✅ Cleanup complete!"

# =============================================================================
# Advanced Options
# =============================================================================

# Run specific playbook with custom options
# Usage: make run PLAYBOOK=01_docker.yml OPTS="--check --diff"
run: ## Run specific playbook (requires PLAYBOOK variable)
	@if [ -z "$(PLAYBOOK)" ]; then \
		echo "❌ PLAYBOOK variable required. Usage: make run PLAYBOOK=01_docker.yml"; \
		exit 1; \
	fi
	@echo "🎯 Running $(PLAYBOOK)..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/$(PLAYBOOK) $(OPTS)

# Run in check mode (dry run)
check-deploy: ## Dry run deployment (check mode)
	@echo "🔍 Dry run - checking what would change..."
	@cd ansible && ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) site.yml --check --diff
