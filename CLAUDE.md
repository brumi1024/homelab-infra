# CLAUDE.md

Ansible repository for a Komodo-based homelab, published as `homelab-infra`.
Public and forked: every commit is published for good.

## Where knowledge lives

Read in this order; each layer answers a different question.

1. Obsidian note `Agentic/Homelab Overview` (operator machine only): what is true right now. Per-site detail is in the site notes beside it.
2. `private/` (gitignored, operator machine only): dated evidence, runbooks, plans. `private/README.md` indexes it.
3. This repository: how to rebuild it. `docs/architecture.md` explains the shape without naming a deployment.

`agent-infra` has only layer 3: no Obsidian MCP, no `private/`.
There, `make verify` is the closest thing to live truth, and findings belong in the PR body or task output, not in a file this repository does not have anywhere to put.
Forks have only layer 3 too, so anything an agent needs to operate this repository generically belongs there.

Stack definitions live in the sibling repositories named in `README.md` and `komodo_resource_syncs_repo`.
On the operator machine and `agent-infra` they are checked out next to this one; the workspace `CLAUDE.md` one level up maps them.

## Shape versus state

Committed files hold reusable shape: roles, playbooks, `group_vars/` defaults, `hosts.example.yml`, docs.
Operator state stays out of git: `ansible/inventory/hosts.yml`, `ansible/known_hosts`, `private/`, `.claude/settings.local.json`.
Secrets are 1Password lookups against `homelab_op_vault`; a value never appears in a file, a log excerpt, or a commit message.
Hosts are addressed by MagicDNS short name. Tailscale addresses, the tailnet domain, and public IPs stay out of the repository.

## Working here

- `APPLY=1` is the only mutation rule: every mutating target defaults to `--check --diff`, and needs `APPLY=1` to touch a live host.
  An agent that forgets the flag gets a diff, not a changed host.
- `make lint`, `make syntax`, and `gitleaks git` pass before a commit. All three run in CI.
- Mutating runs happen from one machine at a time; there is no lock, so coordinate before running `bootstrap`, `baseline`, or `upgrade` with `APPLY=1` from two places.
- After verifying or changing live infrastructure, update the Obsidian overview or the relevant site note in the same session, where that layer exists.
- Comments describe current state and rationale in one line; history belongs to git. Match the density of the file; default to no comment.
- Markdown: one sentence per line, plain dashes, no em dash.

## Gotchas no config confesses

- Manual compose operations on Ansible-managed stacks need `-p <komodo_compose_project_name> --env-file compose.env`; the defaults silently match nothing.
- `komodo_periphery_version: "core"` tracks whatever Core reports; `make upgrade` re-aligns after a Core bump.
- A Proxmox LXC with no `nameserver` in its config inherits the PVE host's `resolv.conf` at start; if the host runs Tailscale that is `100.100.100.100`, and `tailscaled` inside the container then snapshots itself as the fallback. `host_baseline`'s `dns.yml` is the guard; set `pct set <id> --nameserver` as well.
