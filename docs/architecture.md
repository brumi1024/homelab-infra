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
| `control` | the operator machine, `localhost` | auth, komodo-op, app syncs |
| `komodo` | every managed host | docker, baselines, recovery and security checks |
| `core` | exactly one Komodo Core host | core deploy, status |
| `periphery` | every Periphery host | periphery deploy and upgrade |
| `legacy_core` | optional, the previous Core host during a migration | `migrate_core.yml` |
| `proxmox` | optional, hypervisors touched only by the security baseline | security check and baseline |

Group defaults live in `group_vars/`; per-host overrides go in `hosts.yml`.

## Playbook sequence

`make deploy` runs the numbered playbooks in order; each is idempotent and can be re-run alone.

| Step | Playbook | Effect |
| --- | --- | --- |
| 1 | `01_docker.yml` | Docker Engine on every `komodo` host |
| 2 | `02_komodo_core.yml` | Core compose stack on the `core` host |
| 3 | `03_komodo_auth.yml` | admin user, service user, API key stored back into 1Password |
| 4 | `04_komodo_periphery.yml` | Periphery on every `periphery` host, version tracked from Core |
| 5 | `05_bootstrap_komodo_op.yml` | Komodo global variables and git provider needed by komodo-op |
| 6 | `06_deploy_komodo_op.yml` | resource syncs and the komodo-op stack |
| 7 | `07_app_syncs.yml` | trigger the application stack syncs |

Baselines are separate, on-demand playbooks: `security_baseline.yml` (SSH, fail2ban, unattended upgrades, optional nftables input firewall and Docker proxy firewall), `reliability_baseline.yml` (restart persistence, swap, shared networks), `docker_dns_baseline.yml` (pin the Docker daemon resolver), `host_dns_baseline.yml` (hand the host resolver to systemd-resolved where it runs, so Tailscale steers only the tailnet domain and public names follow DHCP).
Each baseline has a read-only `*_check.yml` counterpart.

## Secrets flow

1. The operator creates the items in `docs/1PASSWORD_SETUP.md` in one vault.
2. Ansible reads them at run time with `community.general.onepassword` lookups; nothing is written to disk on the operator machine.
3. Rendered files on hosts (`compose.env`) contain the values, protected by file mode and the host firewall.
4. `03_komodo_auth.yml` writes the API key it creates back into the same vault, so later playbooks and komodo-op read one source.

## Design choices worth knowing

- **Names over addresses.** `ansible_host` is a resolvable name.
  On a tailnet an address is only reachable while `tailscaled` runs, which is exactly when MagicDNS also works, so a literal address survives no outage that the name does not.
- **Outbound Periphery.** Hosts behind NAT or on other sites need no exposed port; only Core needs a public endpoint.
- **Core bound to localhost.** TLS, authentication, and rate limiting are the reverse proxy's job.
- **Version coupling.** `komodo_periphery_version: "core"` follows the version Core reports, so a Core bump plus `make periphery-upgrade` keeps the fleet aligned.
- **Compose project name.** Stacks are named by `komodo_compose_project_name`, so manual `docker compose` calls need `-p` and `--env-file compose.env` to find them.
