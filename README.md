# Homelab Infrastructure

Ansible automation for a Komodo-based homelab: Docker, Komodo Core, Komodo Periphery, host security and reliability baselines, and GitOps resource syncs, all driven from one repository.

## Quick start

```bash
make setup                            # .venv, Ansible collections and roles
cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
# edit hosts.yml with your hosts
make known-hosts                      # scan SSH host keys
make ping                             # check connectivity
make verify                           # read-only health check
make bootstrap                        # dry run: Docker, Core, auth, Periphery, GitOps
make bootstrap APPLY=1                # apply it
```

`make help` lists every target; every mutating one defaults to `--check --diff` and needs `APPLY=1` to touch a live host.

The `bin/komodo` wrapper provides generic read, write, and execute calls plus common stack, server, sync, deployment, and log commands, fetching API credentials from the `Komodo` 1Password item at call time and allowing `KOMODO_URL` to override its `komodo_host` field.

The `guest` target manages recurring Proxmox LXC operations.
Use `make guest GUEST_ACTION=create|snapshot|resize` with operation variables in `EXTRA_VARS`; it defaults to a dry run and requires `APPLY=1` for a real operation.
Creation and snapshots use the `community.proxmox` API modules with the `Proxmox` 1Password API token.
LXC rootfs resize uses `pct resize` over SSH because the collection disk module supports Qemu disks only.

## Two execution environments

This repository runs from two kinds of machine:

- **A desktop app**, where the 1Password desktop app supplies `op` CLI sessions interactively.
- **A machine with no desktop 1Password app** (a CI runner, a headless agent host), where `op` authenticates from `OP_SERVICE_ACCOUNT_TOKEN` instead. `make bootstrap APPLY=1` needs a service account with write access to the `Komodo` item; every other target needs only read access.

Both environments read the same 1Password vault and the same inventory shape; only how `op` authenticates differs.

## Scheduled maintenance runs

`scripts/maint/run.sh` gathers the read-only checks, diffs them against the previous run, and calls a model only when the diff is non-empty or a check failed.
Raw evidence stays on the running machine under `~/.local/state/maint/`; the distilled report and the one-line-per-run index are written to `Reports/` in the notes checkout named by `MAINT_VAULT_DIR`.
When that checkout is a git repository the run pulls it `--ff-only` before writing and commits only the `Reports/` pathspec, so an operator's unrelated edits are never swept into a machine commit.
A pull or push failure is logged and the run continues; set `MAINT_SKIP_VAULT_PUBLISH=1` to keep the reports local.

## Maintenance interpretation backends

`scripts/maint/interpret.sh` keeps scheduled evidence interpretation behind one backend seam selected by `MAINT_BACKEND`.
`claude` and `codex` use their CLIs with read-only tools or sandboxing.
`hermes` calls an OpenAI-compatible Hermes Agent API at `http://127.0.0.1:8642/v1` by default, while `local` calls a configurable OpenAI-compatible endpoint and requires `MAINT_OPENAI_MODEL`.
Override either endpoint with `MAINT_OPENAI_BASE_URL` and provide `MAINT_OPENAI_API_KEY` only when the endpoint requires it.
All backend output is validated locally against the supplied JSON Schema, and every run has a timeout and input-size bound.

## Further reading

- `docs/architecture.md`: how the pieces fit together, independent of any one deployment.
- `docs/1password.md`: the 1Password items and fields this repository expects.
- `AGENTS.md`: the working agreement for coding agents operating this repository.
- `.agents/skills/komodo-stack-lifecycle/`: the reusable add/remove stack procedure and its runbooks.
