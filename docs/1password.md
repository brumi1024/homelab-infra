# 1Password Setup Guide

This document lists all required 1Password items and fields for this infrastructure deployment. All items must be created in the **"Homelab Ansible"** vault.

## Required Vault

- **Vault Name**: `Homelab Ansible`

## Service account access

A machine with no desktop 1Password app (a CI runner, a headless agent host) authenticates `op` from a service account token instead.
`make bootstrap APPLY=1` writes the API key it creates back into the `Komodo` item, so that service account needs write access to `Komodo` specifically.
Every other target only reads; read access to the vault is enough for everything except that one write.

## Required Items

### 1. Komodo (Primary Credentials)

**Item Name**: `Komodo`  
**Item Type**: Login

#### Required Fields:

| Field Name | Type | Description | Example |
|------------|------|-------------|---------|
| `username` | Text | Komodo admin username | `admin` |
| `password` | Password | Komodo admin password | `secure-admin-password` |
| `komodo_api_key` | Text | API key for Komodo authentication | `komodo_api_12345...` |
| `komodo_api_secret` | Password | API secret for Komodo authentication | `secret_67890...` |
| `komodo_db_username` | Text | MongoDB database username | `komodo` |
| `komodo_db_password` | Password | MongoDB database password | `db-password` |
| `komodo_host` | Text | External hostname for Komodo | `komodo.yourdomain.com` |
| `komodo_webhook_secret` | Password | Webhook security secret | `webhook-secret` |
| `komodo_jwt_secret` | Password | JWT token signing secret | `jwt-secret` |

#### OIDC Fields (Optional):

| Field Name | Type | Description |
|------------|------|-------------|
| `komodo_oidc_provider` | Text | OIDC provider URL |
| `komodo_oidc_redirect_host` | Text | OIDC redirect hostname |
| `komodo_oidc_client_id` | Text | OIDC client identifier |
| `komodo_oidc_client_secret` | Password | OIDC client secret |

### 2. Network

**Item Name**: `Network`  
**Item Type**: Login

#### Required Fields:

| Field Name | Type | Description | Example |
|------------|------|-------------|---------|
| `tailnet` | Text | Tailscale network domain | `tail12345.ts.net` |

### 3. Komodo Github Provider Account

**Item Name**: `Komodo Github Provider Account`  
**Item Type**: Login

#### Required Fields:

| Field Name | Type | Description | Example |
|------------|------|-------------|---------|
| `username` | Text | GitHub username for repository access | `brumi1024` |
| `token` | Password | GitHub personal access token | `ghp_xxxxxxxxxxxx` |

**Note**: The GitHub token needs repository read access for:
- `brumi1024/deploy-komodo-op` (komodo-op stack definitions)
- `brumi1024/komodo-app-stacks` (application stack definitions)

### 4. Komodo Homelab Credentials File

**Item Name**: `Komodo Homelab Credentials File`  
**Item Type**: Document

#### Required Fields:

| Field Name | Type | Description | Example |
|------------|------|-------------|---------|
| `op_vault_uuid` | Text | 1Password vault UUID for komodo-op sync | `abcdef12-3456-7890-abcd-ef1234567890` |

#### Required Document:

- **File Name**: `1password-credentials.json`
- **Content**: 1Password Connect credentials JSON file
- **Note**: This document contains the credentials file for 1Password Connect server

### 5. Komodo Homelab Access Token: Komodo Homelab Stacks

**Item Name**: `Komodo Homelab Access Token: Komodo Homelab Stacks`  
**Item Type**: API Credential

#### Required Fields:

| Field Name | Type | Description | Example |
|------------|------|-------------|---------|
| `credential` | Password | 1Password Connect service account token | `ops_xxxxxxxxxxxxxxxxxx` |

### 6. Proxmox

**Item Name**: `Proxmox`

**Item Type**: API Credential or Login

The `proxmox_guest` role reads these fields at run time for API-backed LXC
creation and snapshots.

| Field Name | Type | Description |
|------------|------|-------------|
| `api_user` | Text | Proxmox API user, including its realm, for example `root@pam` or a dedicated service user |
| `api_token_id` | Text | Proxmox API token identifier |
| `api_token_secret` | Password | Proxmox API token secret |

Grant the token only the permissions needed for the intended guest operations.
The role never writes these values to a file or task log.

## Setup Instructions

### Step 1: Create Vault

1. Open 1Password
2. Create a new vault named **"Homelab Ansible"**
3. Ensure your Ansible control machine has access to this vault

### Step 2: Create Items

For each item listed above:

1. **Create new item** with the exact name specified
2. **Add all required fields** with the exact field names (case-sensitive)
3. **Generate secure values** for passwords and secrets
4. **Document the purpose** in the item notes if helpful

### Step 3: Special Setup for Credentials File

1. **Obtain 1Password Connect credentials**:
   - Set up 1Password Connect server
   - Download the credentials JSON file
   
2. **Create document item**:
   - Item name: `Komodo Homelab Credentials File`
   - Upload the credentials JSON file
   - Add `op_vault_uuid` field with your vault's UUID

3. **Find vault UUID**:
   ```bash
   op vault list --format=json | jq -r '.[] | select(.name=="Homelab Ansible") | .id'
   ```

### Step 4: GitHub Token Setup

1. **Generate GitHub Personal Access Token**:
   - Go to GitHub → Settings → Developer settings → Personal access tokens
   - Create token with `repo` scope
   - Copy the token value

2. **Add to 1Password**:
   - Create `Komodo Github Provider Account` item
   - Add GitHub username and token

### Step 5: Verify Setup

Test 1Password CLI access:

```bash
# Test basic authentication
op account list

# Test specific lookups
op item get "Komodo" --vault "Homelab Ansible"
op item get "Network" --vault "Homelab Ansible"
```
