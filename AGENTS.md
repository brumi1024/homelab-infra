# AGENTS.md

Ansible repository for a Komodo-based homelab, published as `homelab-infra`.
Public and forked: every commit is published for good.

## Where knowledge lives

Read in this order; each layer answers a different question.

1. The `agentic-notes` checkout: what is true right now, and how it got there. `Homelab Overview` (plus per-site notes beside it) is current state; `Infra/` is dated evidence, runbooks, and plans, indexed by `Infra/README.md`. It is its own git repo, synced through a private Forgejo repository, checked out on the operator machine and on `agent-infra`.
2. This repository: how to rebuild it. `docs/architecture.md` explains the shape without naming a deployment.

`agent-infra` gets both layers once `~/projects/agentic-notes` is cloned there (a real clone, not a copy); until that lands its `CLAUDE.md` says it still has only layer 2.
Forks have only layer 2: no `agentic-notes` checkout, so anything an agent needs to operate this repository generically belongs there.

Discipline for the `agentic-notes` checkout: pull it (`--ff-only`) before trusting it, commit and push in the same session as any live change or verification, on conflict re-verify against the live system rather than guessing which side is right, and never commit machine-generated bulk output (raw check output, large diffs, images stay box-local; only distilled reports and runbooks are committed).

Stack definitions live in the sibling repositories named in `README.md` and `komodo_resource_syncs_repo`.
On the operator machine and `agent-infra` they are checked out next to this one; the workspace `AGENTS.md` one level up maps them.

## Reusable procedures

- Use `$komodo-stack-lifecycle` for adding, removing, or auditing a stack across the four Komodo repositories.
- Use `$renovate-pr-triage` for read-only risk classification of Renovate dependency pull requests.

## Shape versus state

Committed files hold reusable shape: roles, playbooks, `group_vars/` defaults, `hosts.example.yml`, docs.
Operator state stays out of git: `ansible/inventory/hosts.yml`, `ansible/known_hosts`, `.claude/settings.local.json`.
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
- A one-off fix applied by SSH stays a one-off fix: record it in `Infra/` with the date and the host.
  Record each ad hoc fix in `Infra/one-offs.md` so a second occurrence becomes a grep.
  Promote it into `host_baseline` (or the relevant role) only on its second occurrence, so the baseline grows from recurring gotchas, not single incidents.

## Gotchas no config confesses

- Manual compose operations on Ansible-managed stacks need `-p <komodo_compose_project_name> --env-file compose.env`; the defaults silently match nothing.
- `komodo_periphery_version: "core"` tracks whatever Core reports; `make upgrade` re-aligns after a Core bump.
- A Proxmox LXC with no `nameserver` in its config inherits the PVE host's `resolv.conf` at start; if the host runs Tailscale that is `100.100.100.100`, and `tailscaled` inside the container then snapshots itself as the fallback. `host_baseline`'s `dns.yml` is the guard; set `pct set <id> --nameserver` as well.
