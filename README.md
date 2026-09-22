# Homelab Infrastructure

Ansible automation for a Komodo-based homelab, driven from one repository.

It installs Docker, Komodo Core and Periphery, applies host security and reliability baselines, and wires up GitOps resource syncs.

**The one rule:** every target that changes a live host defaults to `--check --diff`.
Nothing is mutated unless you add `APPLY=1`.

## Before you start

On the control machine you need:

- Python 3.12 or newer, with `venv`
- GNU Make, Git, and an OpenSSH client that includes `ssh-keyscan`
- The 1Password CLI
- Name resolution and SSH access to every host in your inventory

Ansible itself is pinned and installed into `.venv` by `make setup`, so you do not install it yourself.
Every Make target uses that environment.

## Quick start

```bash
make setup          # .venv, Ansible collections and roles, and hosts.yml if missing
```

Then edit `ansible/inventory/hosts.yml` with your hosts.
That file is gitignored, so it is also where a fork puts its own values instead of editing `group_vars/all.yml`.
Add a `vars` mapping beside `children` under the existing `all` key:

```yaml
vars:
  homelab_op_vault: My Homelab Vault
  komodo_resource_syncs_repo: owner/resource-syncs
  komodo_resource_syncs_git_account: owner
```

Create the 1Password items next, following [docs/1password.md](docs/1password.md).
Then work up from a connectivity check to a real run:

```bash
make known-hosts    # scan SSH host keys
make ping           # can we reach every host?
make verify         # read-only health check
make bootstrap      # dry run: Docker, Core, auth, Periphery, GitOps
make bootstrap APPLY=1
```

Read the whole dry-run diff before you add `APPLY=1`.
There is no lock between machines, so run mutating targets from one control machine at a time.

## Everyday commands

`make help` lists them all.
The ones you will reach for most:

| Command | What it does |
| --- | --- |
| `make verify` | Every read-only check. Narrow it with `LIMIT=<host>` or `TAGS=<check>`. |
| `make bootstrap` | Docker, Core, auth, Periphery, GitOps. |
| `make baseline` | The host security and reliability baseline. |
| `make upgrade` | Upgrade Core, then Periphery. |
| `make guest` | Create, snapshot, or resize a Proxmox LXC. |
| `make lint` / `make syntax` | Checks that also run in CI. |
| `make run` | Run any playbook directly. |

The `verify` tags are `security`, `reliability`, `tailscale`, `ssh_access`, `break_glass`, `dns`, `komodo`, `proxmox`, and `zfs`.

`verify` is the source of live truth.
Reach for it before you change anything, and again afterwards to confirm the result.

## Operating Komodo

`bin/komodo` is a wrapper around the Komodo API: generic read, write, and execute calls, plus shortcuts for stacks, servers, syncs, deployments, and logs.
It pulls API credentials from the `Komodo` 1Password item at call time, and `KOMODO_URL` overrides the item's `komodo_host` field.

Start with `bin/komodo --help`, then [docs/komodo-cli.md](docs/komodo-cli.md) for vault overrides, JSON parameter rules, and where the read-versus-mutation line sits.

Adding or removing a stack touches the resource-sync, app-stack, and komodo-op repositories too.
Those checkouts can live anywhere, but you need all of them before changing more than one.

## Proxmox guests

```bash
make guest GUEST_ACTION=create|snapshot|resize EXTRA_VARS='...'
```

Dry run by default, `APPLY=1` for a real operation.
Create and snapshot go through the `community.proxmox` API modules with the `Proxmox` 1Password API token.
Rootfs resize runs `pct resize` over SSH, because the collection's disk module handles Qemu disks only.
Per-action variables and full examples: [docs/guests.md](docs/guests.md).

## Running from a headless machine

The repository runs from two kinds of control machine, and only 1Password authentication differs between them:

- **A desktop machine**, where the 1Password app supplies `op` sessions interactively.
- **A headless machine** such as a CI runner or an agent host, where `op` uses `OP_SERVICE_ACCOUNT_TOKEN`.
  `make bootstrap APPLY=1` needs write access to the `Komodo` item; everything else needs only read.

Both read the same vault and the same inventory shape.

## Further reading

- [docs/architecture.md](docs/architecture.md): how the pieces fit together, independent of any one deployment.
- [docs/1password.md](docs/1password.md): the 1Password items and fields this repository expects.
- [docs/komodo-cli.md](docs/komodo-cli.md): operating the Komodo API wrapper.
- [docs/guests.md](docs/guests.md): the create, snapshot, and resize variable contracts.
- [docs/maintenance.md](docs/maintenance.md): local and scheduled maintenance operation.
- [AGENTS.md](AGENTS.md): the working agreement for coding agents operating this repository.
- `.agents/skills/komodo-stack-lifecycle/`: the reusable add and remove stack procedure, with runbooks.
- `.agents/skills/homelab-health-check/` and `.agents/skills/homelab-one-off/`: the read-only estate check and the guarded ad hoc fix, written for one-line invocation from a phone.
