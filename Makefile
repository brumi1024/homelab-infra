.PHONY: help setup known-hosts lint syntax maint-test ping verify bootstrap baseline upgrade guest periphery-uninstall run

ANSIBLE_DIR := ansible
INVENTORY := inventory/hosts.yml
ANSIBLE_OPTS := -i $(INVENTORY)
# Override from CLI for per-run extras, e.g.
#   make upgrade EXTRA_VARS="-e komodo_onboarding_key=O-..."
EXTRA_VARS :=
LIMIT :=
TAGS :=
LIMIT_OPTS := $(if $(LIMIT),--limit $(LIMIT))
TAGS_OPTS := $(if $(TAGS),--tags $(TAGS))
VENV := .venv
VENV_BIN := $(CURDIR)/$(VENV)/bin

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Install Python deps into .venv, Ansible collections and roles, create inventory/hosts.yml if missing
	@python3 -m venv $(VENV)
	@$(VENV_BIN)/pip install -q -r requirements.txt
	@if [ -d ~/.ansible/collections/ansible_collections/community/general ] && \
		[ ! -f ~/.ansible/collections/ansible_collections/community/general/MANIFEST.json ]; then \
		quarantine=~/.local/state/homelab-infra/ansible-quarantine/community-general-$$(date -u +%Y%m%dT%H%M%SZ); \
		mkdir -p "$$(dirname "$$quarantine")"; \
		mv ~/.ansible/collections/ansible_collections/community/general "$$quarantine"; \
	fi
	@$(VENV_BIN)/ansible-galaxy install -r $(ANSIBLE_DIR)/requirements.yml -p ~/.ansible/roles --force
	@$(VENV_BIN)/ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml
	@command -v op >/dev/null 2>&1 || echo "1Password CLI (op) not found; secret lookups will fail"
	@if [ ! -f $(ANSIBLE_DIR)/$(INVENTORY) ]; then \
		cp $(ANSIBLE_DIR)/inventory/hosts.example.yml $(ANSIBLE_DIR)/$(INVENTORY); \
		echo "Created $(ANSIBLE_DIR)/$(INVENTORY) from hosts.example.yml - edit it for your hosts"; \
	fi

known-hosts: ## Scan every ansible_host in the inventory into ansible/known_hosts
	@cd ansible && $(VENV_BIN)/ansible-inventory $(ANSIBLE_OPTS) --list \
		| $(VENV_BIN)/python3 -c "import json, sys; inv = json.load(sys.stdin); print('\n'.join(sorted({h['ansible_host'] for h in inv['_meta']['hostvars'].values() if 'ansible_host' in h})))" \
		| xargs -I{} ssh-keyscan -H {} > known_hosts 2>/dev/null; \
	sort -u -o known_hosts known_hosts

lint: ## Run ansible-lint and yamllint
	@cd ansible && $(VENV_BIN)/ansible-lint
	@$(VENV_BIN)/yamllint -c ansible/.yamllint ansible/ .github/workflows/

syntax: ## Syntax-check every playbook against hosts.example.yml
	@cd ansible && for playbook in playbooks/*.yml; do \
		$(VENV_BIN)/ansible-playbook -i inventory/hosts.example.yml "$$playbook" --syntax-check || exit 1; \
	done

maint-test: ## Shellcheck and run the hermetic scheduled-maintenance tests
	@shellcheck scripts/maint/*.sh tests/maint/*.sh
	@bash tests/maint/run-test.sh
	@bash tests/maint/interpret-test.sh

ping: ## Check connectivity to all hosts
	@cd ansible && $(VENV_BIN)/ansible all $(ANSIBLE_OPTS) $(EXTRA_VARS) -m ping

verify: ## Run every read-only check (TAGS=security|reliability|tailscale|ssh_access|break_glass|dns|komodo|proxmox, LIMIT=host)
	@cd ansible && $(VENV_BIN)/ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) $(LIMIT_OPTS) $(TAGS_OPTS) playbooks/verify.yml

bootstrap: ## Install Docker, Core, auth, Periphery, and GitOps. APPLY=1 to mutate, otherwise --check --diff
	@cd ansible && $(VENV_BIN)/ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) $(LIMIT_OPTS) $(TAGS_OPTS) playbooks/bootstrap.yml $(if $(filter 1,$(APPLY)),,--check --diff)

baseline: ## Apply the host baseline. APPLY=1 to mutate, otherwise --check --diff
	@cd ansible && $(VENV_BIN)/ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) $(LIMIT_OPTS) $(TAGS_OPTS) playbooks/baseline.yml $(if $(filter 1,$(APPLY)),,--check --diff)

upgrade: ## Upgrade Core then Periphery. APPLY=1 to mutate, otherwise --check --diff
	@cd ansible && $(VENV_BIN)/ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) $(LIMIT_OPTS) $(TAGS_OPTS) playbooks/upgrade.yml $(if $(filter 1,$(APPLY)),,--check --diff)

guest: ## Create, snapshot, or resize an LXC. Set GUEST_ACTION; APPLY=1 to mutate, otherwise --check --diff
	@if [ -z "$(GUEST_ACTION)" ]; then \
		echo "GUEST_ACTION required (create, snapshot, or resize)"; \
		exit 1; \
	fi
	@if [ "$(APPLY)" = "1" ]; then \
		cd $(ANSIBLE_DIR) && APPLY=1 $(VENV_BIN)/ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) $(LIMIT_OPTS) $(TAGS_OPTS) \
			-e "proxmox_guest_action=$(GUEST_ACTION) proxmox_guest_apply=true" playbooks/guest.yml; \
	else \
		cd $(ANSIBLE_DIR) && APPLY=0 $(VENV_BIN)/ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) $(LIMIT_OPTS) $(TAGS_OPTS) \
			-e "proxmox_guest_action=$(GUEST_ACTION) proxmox_guest_apply=false" --check --diff playbooks/guest.yml; \
	fi

periphery-uninstall: ## Remove Komodo Periphery from every node. Requires APPLY=1
	@if [ "$(APPLY)" != "1" ]; then \
		echo "Refusing to uninstall Periphery without APPLY=1"; \
		exit 1; \
	fi
	@cd ansible && $(VENV_BIN)/ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) $(LIMIT_OPTS) --tags periphery -e komodo_action=uninstall playbooks/bootstrap.yml

run: ## Run any playbook directly. APPLY=1 to mutate, otherwise --check --diff
	@if [ -z "$(PLAYBOOK)" ]; then \
		echo "PLAYBOOK variable required. Usage: make run PLAYBOOK=verify.yml"; \
		exit 1; \
	fi
	@cd ansible && $(VENV_BIN)/ansible-playbook $(ANSIBLE_OPTS) $(EXTRA_VARS) playbooks/$(PLAYBOOK) $(OPTS) $(if $(filter 1,$(APPLY)),,--check --diff)
