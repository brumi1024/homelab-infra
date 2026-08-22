# CLAUDE.md

Ansible repository for a Komodo-based homelab, published as `homelab-infra`.
Public and forked: every commit is published for good.

## Where knowledge lives

Read in this order; each layer answers a different question.

1. Obsidian note `Agentic/Homelab Overview` (operator machine only): what is true right now. Per-site detail is in the site notes beside it.
2. `private/` (gitignored, operator machine only): dated evidence, runbooks, plans. `private/README.md` indexes it.
3. This repository: how to rebuild it. `docs/architecture.md` explains the shape without naming a deployment.

If the Obsidian MCP is not connected, say so and fall back to `private/`; `hosts.example.yml` and `group_vars/` describe a shape, never the live estate.
Forks have only layer 3, so anything an agent needs to operate this repository generically belongs in layer 3.

Stack definitions live in the sibling repositories named in `README.md` (GitOps section) and `komodo_resource_syncs_repo`.
On the operator machine they are checked out next to this one; the workspace `CLAUDE.md` one level up maps them.

## Shape versus state

Committed files hold reusable shape: roles, playbooks, `group_vars/` defaults, `hosts.example.yml`, docs.
Operator state stays out of git: `ansible/inventory/hosts.yml`, `private/`, `.claude/settings.local.json`.
Secrets are 1Password lookups against `homelab_op_vault`; a value never appears in a file, a log excerpt, or a commit message.
Hosts are addressed by MagicDNS short name. Tailscale addresses, the tailnet domain, and public IPs stay out of the repository.

## Working here

- `make lint` and `gitleaks git` pass before a commit. Both run in CI.
- Read-only runtime checks run freely: `make status`, `make check`, `make recovery-check`, `make security-check`, `ansible-inventory --graph`.
- Mutating targets change live hosts and need the task to be a change: `make deploy` and its steps, `core-upgrade`, `periphery-upgrade`, `periphery-uninstall`, every `*-baseline`.
- After verifying or changing live infrastructure, update the Obsidian overview or the relevant site note in the same session.
- Comments describe current state and rationale; history belongs to git.
- Long Markdown: one sentence per line.

## Gotchas no config confesses

- Manual compose operations on Ansible-managed stacks need `-p <komodo_compose_project_name> --env-file compose.env`; the defaults silently match nothing.
- `komodo_periphery_version: "core"` tracks whatever Core reports; `make periphery-upgrade` re-aligns after a Core bump.
- `legacy_core` exists only for `migrate_core.yml`; keep the group until the old Core's volumes are deliberately deleted.
- A Proxmox LXC with no `nameserver` in its config inherits the PVE host's `resolv.conf` at start; if the host runs Tailscale that is `100.100.100.100`, and `tailscaled` inside the container then snapshots itself as the fallback. `host_dns_baseline.yml` is the guard; set `pct set <id> --nameserver` as well.
