# Architecture

How the pieces of this repository fit together, independent of any one deployment.
Operator-specific facts (host names, sites, addresses, audit evidence) are deliberately absent; they belong to the operator's own notes.

## Shape and state

The repository is split along one line.

| | Lives in | Examples |
| --- | --- | --- |
| Shape | git, public | roles, playbooks, `group_vars/` defaults, templates, Makefile, docs |
| State | operator machine, gitignored | `ansible/inventory/hosts.yml`, `private/`, editor and agent settings |
| Secrets | 1Password | every credential, referenced by lookup against `homelab_op_vault` |

A fork takes the shape unchanged, supplies its own `hosts.yml` and 1Password vault, and never has to edit a committed file to run.

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
- **komodo-op** (optional) is a stack that syncs 1Password items into Komodo variables through 1Password Connect, so stacks can reference secrets without Ansible in the loop.
- **Resource syncs** pull stack, procedure, and variable definitions from git repositories; the app stacks themselves live in a separate repository.

## Inventory groups

| Group | Purpose | Playbooks that target it |
| --- | --- | --- |
| `control` | the operator machine, `localhost` | auth, gitops, verify |
| `komodo` | every managed host (`core` and `periphery` combined) | bootstrap (docker), baseline, verify |
| `core` | exactly one Komodo Core host | bootstrap (core), upgrade |
| `periphery` | every Periphery host | bootstrap (periphery), upgrade |
| `proxmox` | optional, hypervisors touched only by the baseline's read-only checks | baseline, verify |

Group defaults live in `group_vars/`; per-host overrides go in `hosts.yml`.

## Roles and playbooks

Six roles, each one concern: `docker` (Docker Engine and daemon options), `komodo_core` (the Core compose stack and its config), `komodo_api` (the single Komodo API call mechanism every other role uses), `komodo_auth` (admin login, service user, API key), `komodo_gitops` (resource syncs and the komodo-op stack), `host_baseline` (security, firewall, reliability, DNS, and their read-only verification).

Four playbooks compose them; each is idempotent and safe to re-run.

| Playbook | Effect | Mutates by default |
| --- | --- | --- |
| `bootstrap.yml` | Docker on `komodo`, Core on `core`, auth on `localhost`, Core again to pick up the new API key, Periphery on `periphery`, GitOps on `localhost` | yes, `APPLY=1` required |
| `baseline.yml` | applies `host_baseline` on `komodo`, verifies it on `proxmox` | yes, `APPLY=1` required |
| `verify.yml` | every read-only check, tagged `security`, `reliability`, `dns`, `komodo`, `proxmox` | no |
| `upgrade.yml` | Core with a fresh image pull, then Periphery tracking `komodo_periphery_version` | yes, `APPLY=1` required |

## Secrets flow

1. The operator creates the items in `docs/1password.md` in one vault.
2. Ansible reads them at run time with `community.general.onepassword` lookups; nothing is written to disk on the operator machine.
3. Rendered files on hosts (`compose.env`, `core.config.toml`) contain the values, protected by file mode and the host firewall.
4. `komodo_auth` writes the API key it creates back into the same vault, so later runs and `komodo_gitops` read one source.

## Design choices worth knowing

- **Names over addresses.** `ansible_host` is a resolvable name.
  On a tailnet an address is only reachable while `tailscaled` runs, which is exactly when MagicDNS also works, so a literal address survives no outage that the name does not.
- **Outbound Periphery.** Hosts behind NAT or on other sites need no exposed port; only Core needs a public endpoint.
- **Core bound to localhost.** TLS, authentication, and rate limiting are the reverse proxy's job.
- **Version coupling.** `komodo_periphery_version: "core"` follows the version Core reports, so a Core bump plus `make periphery-upgrade` keeps the fleet aligned.
- **Compose project name.** Stacks are named by `komodo_compose_project_name`, so manual `docker compose` calls need `-p` and `--env-file compose.env` to find them.
