# 1Password setup

This repository reads every credential from one 1Password vault at run time.
The default vault name is `Homelab Ansible`.
A fork can set `homelab_op_vault` under `all.vars` in its gitignored `ansible/inventory/hosts.yml` without changing committed defaults.

## Control-machine authentication

An interactive machine can use the authenticated 1Password desktop integration.
A headless control machine or CI runner must expose `OP_SERVICE_ACCOUNT_TOKEN` to `op` through its private process environment.
Do not store that token in this repository or in inventory.

Most playbook operations need read access to every item described as required below.
The first applied bootstrap also creates a Komodo service-user API key and writes its key and secret into the `Komodo` item.
The control-machine identity therefore needs permission to edit that item before `make bootstrap APPLY=1` can complete.

## Items required by the current bootstrap

The current Core templates enable OIDC and configure komodo-op unconditionally.
The OIDC fields, 1Password Connect document, and komodo-op access token are therefore required for a complete bootstrap rather than optional add-ons.

### `Komodo`

Create a Login item named `Komodo` with these fields.

| Field | Type | Purpose |
| --- | --- | --- |
| `username` | Text | Initial local Komodo administrator username. |
| `password` | Password | Initial local Komodo administrator password. |
| `komodo_db_username` | Text | MongoDB username used by the Core compose stack. |
| `komodo_db_password` | Password | MongoDB password used by the Core compose stack. |
| `komodo_host` | Text | External Komodo hostname or URL. |
| `komodo_webhook_secret` | Password | Webhook signing secret. |
| `komodo_jwt_secret` | Password | JWT signing secret. |
| `komodo_oidc_provider` | Text | OIDC provider URL reachable from the Core container. |
| `komodo_oidc_redirect_host` | Text | OIDC redirect hostname. |
| `komodo_oidc_client_id` | Text | OIDC client identifier. |
| `komodo_oidc_client_secret` | Password | OIDC client secret. |
| `komodo_api_key` | Text | Service-user API key created and maintained by the bootstrap role. |
| `komodo_api_secret` | Password | Service-user API secret created and maintained by the bootstrap role. |

The API fields may be absent before the first bootstrap.
The bootstrap adds them after Core starts, then renders Core again so subsequent API automation and `bin/komodo` use the stored pair.
An existing Core that must retain a known automation identity should provide its existing pair instead of forcing recreation.

### `Network`

Create a Login item named `Network`.

| Field | Type | Purpose |
| --- | --- | --- |
| `tailnet` | Text | Tailscale network domain used for DNS search configuration. |

### `Komodo Github Provider Account`

Create a Login item named `Komodo Github Provider Account`.

| Field | Type | Purpose |
| --- | --- | --- |
| `username` | Text | Git provider account name used by Komodo. |
| `token` | Password | Git provider token used by Komodo resource syncs. |

Grant the token read access to `komodo_resource_syncs_repo` and to every repository referenced by the sync declarations it loads.
Use the narrowest repository and contents permissions that satisfy those reads.

### `Komodo Homelab Credentials File`

Create a Document item named `Komodo Homelab Credentials File`.
Attach the 1Password Connect credentials JSON document and add this field.

| Field | Type | Purpose |
| --- | --- | --- |
| `op_vault_uuid` | Text | UUID of the source vault projected by komodo-op. |

The bootstrap embeds the document and vault UUID in Core's secret store for the bundled komodo-op stack.

### `Komodo Homelab Access Token: Komodo Homelab Stacks`

Create an API Credential item named `Komodo Homelab Access Token: Komodo Homelab Stacks`.

| Field | Type | Purpose |
| --- | --- | --- |
| `credential` | Password | 1Password service-account token used by komodo-op. |

This is the runtime token that komodo-op uses inside the managed stack.
It is distinct from the control machine's `OP_SERVICE_ACCOUNT_TOKEN`, even if an operator intentionally gives both identities equivalent access.

## Feature-specific items

These items are required only when the corresponding inventory feature is used.

### `Proxmox`

Create an API Credential or Login item named `Proxmox` before applying a guest `create` or `snapshot` action.
The `resize` action uses `pct` over SSH and does not read this item.

| Field | Type | Purpose |
| --- | --- | --- |
| `api_user` | Text | Proxmox API user including its realm. |
| `api_token_id` | Text | Proxmox API token identifier. |
| `api_token_secret` | Password | Proxmox API token secret. |

Grant only the Proxmox permissions needed for the requested guest operations.
The role marks credential-bearing tasks `no_log` and never writes these values to a repository file.

### `SSH Break Glass`

Create an SSH Key item named `SSH Break Glass` only when `homelab_ssh_break_glass_enabled` is true for at least one host.

| Field | Type | Purpose |
| --- | --- | --- |
| `public key` | Text | OpenSSH Ed25519 public key installed on selected recovery hosts. |

Generate the key in 1Password so the private half remains there and can be used through the 1Password SSH agent.
The role reads only the public field.

## Setup and verification

1. Create the vault or choose an existing dedicated vault.
2. Add the required items with the exact names and case-sensitive field names above.
3. Add feature-specific items only for features enabled in the private inventory.
4. Give the control-machine identity read access to the required items and edit access to `Komodo` for the first applied bootstrap.
5. Configure the Git provider token for the repositories referenced by the fork's resource syncs.

Verify access without printing item contents.

```bash
op account list
op item get "Komodo" --vault "My Homelab Vault" >/dev/null
op item get "Network" --vault "My Homelab Vault" >/dev/null
op item get "Komodo Github Provider Account" --vault "My Homelab Vault" >/dev/null
op item get "Komodo Homelab Credentials File" --vault "My Homelab Vault" >/dev/null
op item get "Komodo Homelab Access Token: Komodo Homelab Stacks" --vault "My Homelab Vault" >/dev/null
```

Run `make bootstrap` without `APPLY=1` only after these lookups succeed.
Review that dry-run output before authorizing the exact `APPLY=1` run.
