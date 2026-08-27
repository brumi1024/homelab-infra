# Homelab Infrastructure

Ansible automation for a Komodo-based homelab: Docker, Komodo Core, Komodo Periphery, host security and reliability baselines, and GitOps resource syncs, all driven from one repository.

## Prerequisites

The control machine needs Python 3.12 or newer with `venv`, GNU Make, Git, an OpenSSH client with `ssh-keyscan`, and the 1Password CLI.
It also needs name resolution and SSH access to every inventory host.
The pinned Ansible CLI and collections are installed into `.venv` by `make setup`, and every Make target uses that environment directly.

## Quick start

```bash
make setup                            # .venv, Ansible collections and roles
# setup creates ansible/inventory/hosts.yml when it is absent
# edit hosts.yml with your hosts and private overrides
make known-hosts                      # scan SSH host keys
make ping                             # check connectivity
make verify                           # read-only health check
make bootstrap                        # dry run: Docker, Core, auth, Periphery, GitOps
make bootstrap APPLY=1                # apply it
```

`make help` lists every target; every mutating one defaults to `--check --diff` and needs `APPLY=1` to touch a live host.
Review the complete dry-run output and coordinate a single control machine before using `APPLY=1`.

The committed defaults name the reference deployment's resource-sync repository.
A fork overrides its own values in the gitignored `hosts.yml` rather than editing `group_vars/all.yml`.

```yaml
vars:
  homelab_op_vault: My Homelab Vault
  komodo_resource_syncs_repo: owner/resource-syncs
  komodo_resource_syncs_git_account: owner
```

Add this `vars` mapping beside `children` under the existing `all` key in `hosts.yml`.

Create the 1Password items before the first playbook run, using [docs/1password.md](docs/1password.md).

## Operating Komodo

The `bin/komodo` wrapper provides generic read, write, and execute calls plus common stack, server, sync, deployment, and log commands.
It fetches API credentials from the `Komodo` 1Password item at call time and allows `KOMODO_URL` to override its `komodo_host` field.
Run `bin/komodo --help`, then read [docs/komodo-cli.md](docs/komodo-cli.md) for prerequisites, vault overrides, JSON parameter rules, and the read-versus-mutation boundary.

Stack lifecycle work also needs checkouts of the resource-sync, app-stack, and komodo-op repositories referenced by the operator's sync configuration.
They can live anywhere, but the lifecycle skill must resolve their roots before changing more than one repository.

## Proxmox guests

The `guest` target manages recurring Proxmox LXC operations.
Use `make guest GUEST_ACTION=create|snapshot|resize` with operation variables in `EXTRA_VARS`; it defaults to a dry run and requires `APPLY=1` for a real operation.
Creation and snapshots use the `community.proxmox` API modules with the `Proxmox` 1Password API token.
LXC rootfs resize uses `pct resize` over SSH because the collection disk module supports Qemu disks only.
The per-action variables and complete examples are in [docs/guests.md](docs/guests.md).

## Two execution environments

This repository runs from two kinds of machine:

- **A desktop app**, where the 1Password desktop app supplies `op` CLI sessions interactively.
- **A machine with no desktop 1Password app** (a CI runner, a headless agent host), where `op` authenticates from `OP_SERVICE_ACCOUNT_TOKEN` instead. `make bootstrap APPLY=1` needs a service account with write access to the `Komodo` item; every other target needs only read access.

Both environments read the same 1Password vault and the same inventory shape; only how `op` authenticates differs.

## Scheduled maintenance runs

`scripts/maint/run.sh` gathers the read-only checks, diffs them against the previous run, and calls a model only when the diff is non-empty or a check failed.
Raw evidence stays on the running machine under `~/.local/state/maint/`; the distilled report and the one-line-per-run index are written to `Reports/` in the notes checkout named by `MAINT_VAULT_DIR`.
When that checkout is a git repository the run pulls it `--ff-only` before writing and commits only the `Reports/` pathspec, so an operator's unrelated edits are never swept into a machine commit.
Only one run can hold the state-directory lock, so a timer and a manual run cannot gather or publish concurrently.
A failed pull keeps the report under the raw run directory and does not modify the stale vault checkout.
A failed add, commit, or push makes the unattended run fail loudly; a rejected push leaves its local commit for operator reconciliation.
Set `MAINT_SKIP_VAULT_PUBLISH=1` to keep reports under the raw run directory deliberately.

## Maintenance interpretation backends

`scripts/maint/interpret.sh` keeps scheduled evidence interpretation behind one backend seam selected by `MAINT_BACKEND`.
`claude` and `codex` use their CLIs with read-only tools or sandboxing.
`hermes` calls an OpenAI-compatible Hermes Agent API at `http://127.0.0.1:8642/v1` by default, while `local` calls a configurable OpenAI-compatible endpoint and requires `MAINT_OPENAI_MODEL`.
Override either endpoint with `MAINT_OPENAI_BASE_URL` and provide `MAINT_OPENAI_API_KEY` only when the endpoint requires it.
All backend output is validated locally against the supplied JSON Schema, and every run has a timeout and input-size bound.
The complete prerequisites, systemd units, backend setup, and every supported `MAINT_*` variable are in [docs/maintenance.md](docs/maintenance.md).

## Further reading

- `docs/architecture.md`: how the pieces fit together, independent of any one deployment.
- `docs/1password.md`: the 1Password items and fields this repository expects.
- `docs/komodo-cli.md`: operating the generic Komodo API wrapper.
- `docs/guests.md`: create, snapshot, and resize variable contracts.
- `docs/maintenance.md`: local and scheduled maintenance operation.
- `AGENTS.md`: the working agreement for coding agents operating this repository.
- `.agents/skills/komodo-stack-lifecycle/`: the reusable add/remove stack procedure and its runbooks.
- `.agents/skills/homelab-health-check/` and `.agents/skills/homelab-one-off/`: the read-only estate check and the guarded ad hoc fix, written for one-line invocation from a phone.
