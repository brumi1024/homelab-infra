# Homelab Infrastructure

Infrastructure-as-code solution for deploying and managing Komodo-based homelab infrastructure using Ansible. This project automates the complete deployment of Komodo Core, Komodo Periphery nodes, secret management via 1Password Connect, and GitOps-driven application stacks.

## Overview

This repository deploys a distributed container orchestration platform with:

- **Komodo Core**: Central management server with web interface (port 9120)
- **Komodo Periphery**: Distributed agent nodes for executing deployments (port 8120)
- **Docker**: Container runtime on all infrastructure nodes
- **komodo-op**: Optional 1Password Connect integration for secret management
- **Application Stacks**: GitOps-driven application deployment from GitHub repositories

The infrastructure uses a hub-and-spoke architecture where Komodo Core acts as the central controller, coordinating deployments across multiple Periphery nodes connected via Tailscale VPN.

## Prerequisites

- **Ansible** 2.9+ with community.general collection
- **1Password CLI** (`op`) configured with appropriate vault access
- **SSH access** to all target servers with sudo privileges
- **Tailscale VPN** network configured across all nodes
- **Git repositories** for komodo-op stack and application definitions

## Quick Start

1. **Install dependencies**:
   ```bash
   make setup
   ```

2. **Verify connectivity**:
   ```bash
   make check
   ```

3. **Deploy complete infrastructure**:
   ```bash
   # Complete deployment (includes 1Password secret management)
   make deploy
   ```

4. **Access Komodo Core** at `https://your-komodo-host:9120`

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Komodo Core   │────│   Tailscale VPN  │────│ Komodo Periphery│
│   (Controller)  │    │                  │    │   (Agent Nodes) │
│   Port: 9120    │    │                  │    │   Port: 8120    │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                       │                       │
         │                       │                       │
    ┌────────┐             ┌─────────────┐         ┌───────────┐
    │MongoDB │             │  komodo-op  │         │Application│
    │27017   │             │ (Optional)  │         │  Stacks   │
    └────────┘             └─────────────┘         └───────────┘
```

### Host Groups

- **control**: Ansible control node (localhost)
- **core**: Komodo Core server with MongoDB
- **periphery**: Komodo Periphery agent nodes

## Make Targets Reference

### Setup and Dependencies

| Target | Description |
|--------|-------------|
| `make setup` | Install Ansible dependencies and collections |
| `make check` | Test SSH connectivity to all hosts |
| `make lint` | Run ansible-lint and yamllint code quality checks |

### Individual Deployment Steps

| Target | Description |
|--------|-------------|
| `make docker` | Install Docker on all infrastructure nodes |
| `make core` | Deploy Komodo Core server with MongoDB |
| `make auth` | Initialize authentication (admin user, API keys) |
| `make periphery` | Deploy Komodo Periphery agents to all nodes |

### Complete Deployment

| Target | Description |
|--------|-------------|
| `make deploy` | Complete deployment with 1Password integration |
| `make check-deploy` | Dry run deployment (check mode) |

### Secret Management & GitOps

| Target | Description |
|--------|-------------|
| `make komodo-op` | Deploy resource syncs and komodo-op stack for 1Password secret sync |
| `make app-syncs` | Verify and manage application resource syncs for GitOps |

### Upgrade & Management

| Target | Description |
|--------|-------------|
| `make upgrade` | Upgrade both Core and all Periphery nodes |
| `make core-upgrade` | Upgrade Komodo Core (pulls latest images) |
| `make periphery-upgrade` | Realign Periphery binaries to the version Komodo Core currently reports |
| `make periphery-uninstall` | Remove Komodo Periphery from all nodes |

### Maintenance

| Target | Description |
|--------|-------------|
| `make status` | Check health status of all Komodo services |
| `make recovery-check` | Verify restart and recovery prerequisites without changing hosts |
| `make reliability-baseline` | Enable restart persistence, VPS swap, and shared networks |
| `make docker-dns-baseline` | Pin the Docker daemon resolver with a public fallback |
| `make host-dns-baseline` | Hand the host resolver to systemd-resolved where it runs; verify public and tailnet names resolve |
| `make clean` | Clean up temporary files and caches |

The Core migration is a one-off cutover rather than routine maintenance, so it has no Make target.
See `ansible/playbooks/migrate_core.yml` and `docs/architecture.md` for how it works.

### Advanced Options

| Target | Description |
|--------|-------------|
| `make run PLAYBOOK=<name>` | Run specific playbook with optional OPTS |

## Basic Operations

### Adding a New Server

1. **Update inventory** in `ansible/inventory/hosts.yml`:
   ```yaml
   periphery:
     hosts:
       existing-node:
         ansible_host: existing-node
       new-node:                    # Add new server
         ansible_host: new-node     # Tailscale MagicDNS name
   ```

   Use MagicDNS names rather than Tailscale addresses.
   An address is only routable through `tailscaled`, which also serves MagicDNS, so a literal address survives no outage that the name does not.
   Names also keep SSH host-key trust intact, which address-based access breaks.

2. **Deploy to new node**:
   ```bash
   make check                      # Verify connectivity
   make docker                     # Install Docker
   make periphery                  # Deploy Periphery agent
   ```

### Updating Komodo

All operations are **idempotent** - safe to run multiple times:

```bash
# Update Core server
make core-upgrade

# Update all Periphery nodes
make periphery-upgrade

# Update everything at once
make upgrade
```

**Note**: The Ansible playbooks are designed to be idempotent, meaning you can safely run them repeatedly without causing issues. They will only make changes when necessary.

### Deploying Applications

Applications are deployed via GitOps using resource syncs:

1. **Verify resource syncs** (optional - already created by `make komodo-op`):
   ```bash
   make app-syncs
   ```

2. **Applications auto-pull** from configured GitHub repositories but require manual deployment for safety

### Health Monitoring

```bash
# Check all services
make status

# Manual health check
curl -s http://your-komodo-host:9120
```

## Configuration

### Where configuration lives

Configuration is split so the public repository holds only reusable defaults and your own hosts stay local:

| File | Committed | Purpose |
|------|-----------|---------|
| `ansible/inventory/group_vars/all.yml` | yes | Defaults for every host: ports, paths, security baseline, 1Password vault name, GitOps repositories |
| `ansible/inventory/group_vars/periphery.yml` | yes | Periphery connection mode |
| `ansible/inventory/hosts.example.yml` | yes | Starting point for your inventory |
| `ansible/inventory/hosts.yml` | no (gitignored) | Your hosts, sites, and per-host overrides |

`make setup` creates `hosts.yml` from the example when it is missing.
Override group defaults per host in `hosts.yml` rather than editing `group_vars/`, so pulling upstream changes never conflicts with your topology.

### Values you will change

```yaml
# ansible/inventory/group_vars/all.yml
homelab_op_vault: "Homelab Ansible"          # your 1Password vault
komodo_resource_syncs_repo: "you/komodo-resource-syncs"
komodo_resource_syncs_git_account: "you"
enable_komodo_op: true                        # 1Password Connect integration
komodo_port: 9120
komodo_periphery_port: 8120
```

Secrets are never stored in this repository; every credential is a `community.general.onepassword` lookup against `homelab_op_vault`.
See `docs/1PASSWORD_SETUP.md` for the items and fields expected there.

## Secret Management

The deployment includes 1Password integration by default (configured via `enable_komodo_op: true` in the inventory):

```bash
make deploy
```

This enables automatic secret synchronization from 1Password vaults. To deploy without komodo-op, you can override the setting:

```bash
# Deploy without secret management (if needed)
make run PLAYBOOK=site.yml OPTS="-e enable_komodo_op=false"
```

See [1Password Setup Guide](docs/1PASSWORD_SETUP.md) for detailed configuration requirements.

## GitOps Workflow

The infrastructure uses a centralized resource sync approach:

1. **komodo-resource-syncs**: Meta-sync repository at `brumi1024/komodo-resource-syncs`
   - Contains `syncs.toml` defining all resource syncs
   - Automatically creates and manages individual syncs
   - Single source of truth for GitOps configuration
   - Repository URLs are defined in this repo, not in local ansible inventory

2. **komodo-op-sync**: Infrastructure deployment (auto-deploy enabled)
   - Source: `brumi1024/deploy-komodo-op`
   - Provides 1Password Connect server
   - Syncs secrets from 1Password vaults
   - Creates environment variables in Komodo

3. **komodo-app-stacks**: Application deployments (manual deploy for safety)
   - Source: `brumi1024/komodo-app-stacks`
   - Auto-pulls latest definitions on changes
   - Requires manual deployment approval
   - Uses secrets synchronized via komodo-op

## Troubleshooting

### Common Issues

**Connection failures**:
```bash
make check  # Verify SSH connectivity
```

**Service not starting**:
```bash
make status  # Check service health
```

**1Password lookups failing**:
```bash
op account list  # Verify 1Password CLI authentication
```

**API Key Silent Failures (Critical)**:

If you're deploying to a fresh Komodo instance but have stale API keys in 1Password from a previous deployment, authentication setup will be silently skipped, causing failures in subsequent steps.

**Symptoms**: Subsequent playbooks fail with authentication errors despite auth playbook appearing to succeed.

**Solution**: Choose one of these approaches:

```bash
# Option 1: Use force recreate flag (recommended)
make auth OPTS="-e komodo_auth_force_recreate=true"

# Option 2: Delete entire Komodo item (will be recreated)
op item delete "Komodo" --vault "Homelab Ansible"

# Option 3: Remove just the API key field
op item edit "Komodo" --vault "Homelab Ansible" komodo_api_key=""
```

**Permission issues**:
```bash
# Ensure SSH user has sudo privileges
ansible all -i inventory/hosts.yml -m shell -a "sudo -l"
```

### Log Locations

- **Komodo Core**: `docker logs komodo-core`
- **Komodo Periphery**: `journalctl -u komodo-periphery`
- **Ansible logs**: Console output during playbook execution

## Development

### Code Quality

```bash
make lint  # Run ansible-lint and yamllint
```

### Testing Changes

```bash
make check-deploy  # Dry run to see what would change
```

### Secret Scanning

CI runs [gitleaks](https://github.com/gitleaks/gitleaks) on every push and pull request.
Run it locally before committing when in doubt: `gitleaks git` scans history, `gitleaks dir .` scans the working tree.
Known false positives are allowlisted in `.gitleaks.toml`.

## Using This Repository for Your Own Homelab

Everything committed is reusable shape; everything specific to one homelab is either a 1Password lookup or a gitignored local file.

1. Fork and clone, then `make setup`.
   This installs collections and creates `ansible/inventory/hosts.yml` from `hosts.example.yml`.
2. Edit `hosts.yml` with your hosts and sites.
   Use names that resolve on your management network, not literal addresses.
3. Set `homelab_op_vault` and the `komodo_resource_syncs_*` values in `ansible/inventory/group_vars/all.yml`, or override them in `hosts.yml` under `all: vars:` if you prefer to keep `group_vars/` untouched.
4. Create the 1Password items listed in `docs/1PASSWORD_SETUP.md`.
5. `make check`, then `make deploy`.

`docs/architecture.md` describes how the pieces fit without naming any particular deployment.
Keep your own topology notes, addresses, and audit evidence outside the repository or in the gitignored `private/` directory.

## Repository Structure

```
├── Makefile                    # Main deployment commands
├── CLAUDE.md                   # Working agreement for coding agents
├── ansible/                    # Ansible configuration
│   ├── inventory/
│   │   ├── group_vars/        # Committed defaults (all.yml, periphery.yml)
│   │   ├── hosts.example.yml  # Template for your inventory
│   │   └── hosts.yml          # Your hosts (gitignored)
│   ├── playbooks/             # Deployment playbooks (01-07) and baselines
│   ├── roles/                 # Custom Ansible roles
│   │   ├── komodo/           # Komodo Core deployment
│   │   └── komodo_auth/      # Authentication management
│   ├── tasks/                # Shared task files
│   └── site.yml              # Master orchestration playbook
├── scripts/                   # Setup and utility scripts
├── docs/                      # Architecture, 1Password setup, runbooks
└── private/                   # Operator notes, gitignored
```
