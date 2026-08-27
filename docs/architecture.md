# Architecture

How the pieces of this repository fit together, independent of any one deployment.
Operator-specific facts (host names, sites, addresses, audit evidence) are deliberately absent; they belong to the operator's own notes.

## Shape and state

The repository is split along one line.

| | Lives in | Examples |
| --- | --- | --- |
| Shape | git, public | roles, playbooks, `group_vars/` defaults, templates, Makefile, docs |
| State | operator machine, gitignored or external | `ansible/inventory/hosts.yml`, `ansible/known_hosts`, local agent settings, optional operations notes |
| Secrets | 1Password | every credential, referenced by lookup against `homelab_op_vault` |

A fork reuses the roles and playbooks, supplies its own `hosts.yml` and 1Password vault, and overrides reference-deployment defaults in that private inventory.
No deployment state or secret needs to enter a committed file.

## Control plane

```
                 1Password (secrets)
                        |
   operator ── Ansible ─┼──> Docker hosts ──> Komodo Periphery ──┐
                        |                                        | outbound WebSocket
                        └──> Core host ──> Komodo Core + MongoDB <┘
                                              |
                                  resource syncs (git) ──> stacks
```

- **Ansible** is the bootstrap layer: Docker, Komodo Core, Komodo Periphery, host security and reliability baselines.
  It runs from the operator machine over SSH and reaches hosts by name on the management network (a Tailscale tailnet in the reference deployment).
- **Komodo Core** is the single controller: web UI and API on `komodo_port`, MongoDB beside it, bound to localhost and fronted by a reverse proxy.
- **Komodo Periphery** runs on every workload host, including the Core host when it also runs stacks.
  It runs in outbound mode and dials the public Core address, so hosts need no inbound port for Komodo.
- **komodo-op** is the bundled stack that syncs 1Password items into Komodo variables through 1Password Connect, so stacks can reference secrets without Ansible in the loop.
- **Resource syncs** pull stack, procedure, and variable definitions from git repositories; the app stacks themselves live in a separate repository.

## Inventory groups

| Group | Purpose | Playbooks that target it |
| --- | --- | --- |
| `control` | the operator machine, `localhost` | auth, gitops, verify |
| `ssh_access` | hosts whose Tailscale SSH state or break-glass key is explicitly managed | baseline, verify |
| `komodo` | every managed host (`core` and `periphery` combined) | bootstrap (docker), baseline, verify |
| `core` | exactly one Komodo Core host | bootstrap (core), upgrade |
| `periphery` | every Periphery host | bootstrap (periphery), upgrade |
| `proxmox` | optional hypervisors used by read-only checks and as guest-operation targets | baseline, verify, guest |

Group defaults live in `group_vars/`; per-host overrides go in `hosts.yml`.

## Roles and playbooks

Seven roles, each one concern: `docker` (Docker Engine and daemon options), `komodo_core` (the Core compose stack and its config), `komodo_api` (the single Komodo API call mechanism every other role uses), `komodo_auth` (admin login, service user, API key), `komodo_gitops` (resource syncs and the komodo-op stack), `host_baseline` (SSH access, security, firewall, reliability, DNS, and their read-only verification), and `proxmox_guest` (recurring LXC create, snapshot, and resize operations).

Five playbooks compose them.
The infrastructure reconciliation playbooks are designed to be idempotent and safe to re-run through their mutation gate.
The guest playbook is an imperative operation and must be reviewed for its exact action and target every time.

| Playbook | Effect | Mutates by default |
| --- | --- | --- |
| `bootstrap.yml` | Docker on `komodo`, Core on `core`, auth on `localhost`, Core again to pick up the new API key, Periphery on `periphery`, GitOps on `localhost` | yes, `APPLY=1` required |
| `baseline.yml` | applies `host_baseline` on `komodo`, applies only SSH access tasks to other `ssh_access` hosts, and verifies Proxmox | yes, `APPLY=1` required |
| `verify.yml` | every read-only check, including explicitly managed SSH access | no |
| `upgrade.yml` | Core with a fresh image pull, then Periphery tracking `komodo_periphery_version` | yes, `APPLY=1` required |
| `guest.yml` | create or snapshot an LXC through the Proxmox API, or resize its rootfs through `pct` over SSH | yes, `APPLY=1` required |

## Secrets flow

1. The operator creates the items in `docs/1password.md` in one vault.
2. Ansible reads them at run time with `community.general.onepassword` lookups; nothing is written to disk on the operator machine.
3. Rendered files on hosts (`compose.env`, `core.config.toml`) contain the values, protected by file mode and the host firewall.
4. `komodo_auth` writes the API key it creates back into the same vault, so later runs and `komodo_gitops` read one source.

## Design choices worth knowing

- **Names over addresses.** `ansible_host` is a resolvable name.
  On a tailnet an address is only reachable while `tailscaled` runs, which is exactly when MagicDNS also works, so a literal address survives no outage that the name does not.
- **Two SSH lanes.** Tailscale SSH is the explicitly enabled normal path; its hosts have no root authorized keys unless selected for tier-0 recovery, in which case the exclusive break-glass public key has its private half in 1Password.
  The `ssh_access` group scopes those tasks without applying the rest of the host baseline to hypervisors or dedicated agent hosts.
- **Outbound Periphery.** Hosts behind NAT or on other sites need no exposed port; only Core needs a public endpoint.
- **Core bound to localhost.** TLS, authentication, and rate limiting are the reverse proxy's job.
- **Version coupling.** `komodo_periphery_version: "core"` follows the version Core reports, so a Core bump plus `make upgrade` keeps the fleet aligned.
- **Compose project name.** Stacks are named by `komodo_compose_project_name`, so manual `docker compose` calls need `-p` and `--env-file compose.env` to find them.

## Operator guides

- [1Password setup](1password.md) defines the vault, required items, and conditional items.
- [Komodo API wrapper](komodo-cli.md) documents authenticated reads and explicitly authorized mutations.
- [Proxmox guest operations](guests.md) documents the create, snapshot, and resize contracts.
- [Scheduled maintenance](maintenance.md) documents local runs, timer installation, backends, and every `MAINT_*` variable.
