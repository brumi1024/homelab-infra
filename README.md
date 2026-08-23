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

## Two execution environments

This repository runs from two kinds of machine:

- **A desktop app**, where the 1Password desktop app supplies `op` CLI sessions interactively.
- **A machine with no desktop 1Password app** (a CI runner, a headless agent host), where `op` authenticates from `OP_SERVICE_ACCOUNT_TOKEN` instead. `make bootstrap APPLY=1` needs a service account with write access to the `Komodo` item; every other target needs only read access.

Both environments read the same 1Password vault and the same inventory shape; only how `op` authenticates differs.

## Further reading

- `docs/architecture.md`: how the pieces fit together, independent of any one deployment.
- `docs/1password.md`: the 1Password items and fields this repository expects.
- `CLAUDE.md`: the working agreement for coding agents operating this repository.
