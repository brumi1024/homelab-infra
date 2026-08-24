# AGENTS.md

Ansible repository for a Komodo-based homelab, published as `homelab-infra`.
Public and forked: every commit is published for good.

## Where knowledge lives

Read in this order; each layer answers a different question.

1. The `agentic-notes` checkout: what is true right now, and how it got there. Its root `AGENTS.md` is the map: living state in `Estate/` and `Repos/` (`Repos/Homelab Infra.md` is this repo's own state note), work in flight in `Plans/`, load-bearing research in `Reference/`, post-mortems and the one-off ledger in `Incidents/`, closed records in `Archive/`. It is a private git repo synced through Forgejo, checked out at `~/Developer/personal/vaults/agentic-notes` on the operator machine and `~/projects/agentic-notes` on `agent-infra`.
2. This repository: how to rebuild it. `docs/architecture.md` explains the shape without naming a deployment.

Working discipline for that checkout is its own `AGENTS.md`; the short form: pull it `--ff-only` before trusting it, and commit and push there in the same session as any live change or verification.
Forks have only layer 2: no `agentic-notes` checkout, so anything an agent needs to operate this repository generically belongs here or in `docs/`.

Stack definitions live in the sibling repositories named by `README.md` and the `komodo_resource_syncs_repo` inventory variable; the workspace `AGENTS.md` one level up maps their checkouts.

## Reusable procedures

- `$komodo-stack-lifecycle` for adding, removing, or auditing a stack across the four Komodo repositories.
- `$renovate-pr-triage` for read-only risk classification of Renovate dependency pull requests.

## Shape versus state

Committed files hold reusable shape: roles, playbooks, `group_vars/` defaults, `hosts.example.yml`, docs.
Operator state stays out of git: `ansible/inventory/hosts.yml` (on operator machines, a symlink to the vault's `config/hosts.yml`), `ansible/known_hosts`, `.claude/settings.local.json`.
Secrets are 1Password lookups against `homelab_op_vault`; a value never appears in a file, a log excerpt, or a commit message.
Hosts are addressed by MagicDNS short name. Tailscale addresses, the tailnet domain, and public IPs stay out of the repository.

## Working here

- `APPLY=1` is the only mutation rule: every mutating target defaults to `--check --diff` and needs `APPLY=1` to touch a live host.
  An agent that forgets the flag gets a diff, not a changed host.
- `make verify` is the read-only source of live truth; reach for it before mutating anything and to confirm the result after.
- `make lint`, `make syntax`, and `gitleaks git` pass before a commit. All three run in CI.
- Mutating runs happen from one machine at a time; there is no lock, so coordinate before running `bootstrap`, `baseline`, or `upgrade` with `APPLY=1` from two places.
- After verifying or changing live infrastructure, update the vault in the same session: the overview or site note for estate facts, `Repos/Homelab Infra.md` for repo state.
- A fix applied by SSH is recorded in the vault's `Incidents/one-offs.md` with the date and the host, so a second occurrence becomes a grep.
  Promote it into `host_baseline` (or the relevant role) only on that second occurrence, so the baseline grows from recurring gotchas, not single incidents.
- Comments describe current state and rationale in one line; history belongs to git. Match the density of the file; default to no comment.
- Markdown: one sentence per line, plain dashes, no em dash.

## Gotchas no config confesses

- Manual compose operations on Ansible-managed stacks need `-p <komodo_compose_project_name> --env-file compose.env`; the defaults silently match nothing.
- `komodo_periphery_version: "core"` tracks whatever Core reports; `make upgrade` re-aligns after a Core bump.
- A Proxmox LXC with no `nameserver` in its config inherits the PVE host's `resolv.conf` at start; if the host runs Tailscale that is `100.100.100.100`, and `tailscaled` inside the container then snapshots itself as the fallback. `host_baseline`'s `dns.yml` is the guard; set `pct set <id> --nameserver` as well.
