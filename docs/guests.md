# Proxmox guest operations

The `guest` target covers three recurring LXC operations: create, snapshot, and rootfs resize.
Every invocation is a dry run unless `APPLY=1` is present.
Create and snapshot use the Proxmox API, while resize delegates `pct resize` over SSH to the selected Proxmox inventory host.

## Prerequisites

Run `make setup` and define at least one host in the inventory's optional `proxmox` group.
That host needs a resolvable `ansible_host` and root SSH access for resize operations.
Create and snapshot need the `Proxmox` 1Password item described in [1password.md](1password.md).
The API token must have the permissions required for the requested LXC operation.

Keep operation variables in a private file outside the public checkout when they contain operator-specific names or network details.
Pass that file through `EXTRA_VARS` with an absolute path because the Make recipe changes into `ansible/`.

## Create

Create a private variables file such as `/private/tmp/guest-create.yml`.

```yaml
proxmox_guest_pve_host: pve-1
proxmox_guest_node: pve-node-name
proxmox_guest_vmid: 200
proxmox_guest_hostname: new-lxc
proxmox_guest_template: local:vztmpl/debian-template.tar.zst
proxmox_guest_rootfs_storage: local-lvm
proxmox_guest_rootfs_size_gib: 32
proxmox_guest_nameserver: 192.0.2.53
proxmox_guest_searchdomain: example.internal
proxmox_guest_netif:
  net0: name=eth0,bridge=vmbr0,ip=dhcp
```

The explicit nameserver is required because a Proxmox LXC can otherwise inherit a host resolver snapshot that is unusable inside the guest.

Preview the operation first.

```bash
make guest GUEST_ACTION=create EXTRA_VARS="-e @/private/tmp/guest-create.yml"
```

The preview does not contact the Proxmox API.
It confirms the requested action and mutation boundary, so review the private variable file as part of the preview.
Run the same command with `APPLY=1` only after the operator approves that exact create operation.

## Snapshot

Create `/private/tmp/guest-snapshot.yml` with the target and snapshot metadata.

```yaml
proxmox_guest_pve_host: pve-1
proxmox_guest_vmid: 200
proxmox_guest_snapshot_name: pre-change
proxmox_guest_snapshot_description: Before the approved maintenance change
proxmox_guest_snapshot_vmstate: false
proxmox_guest_snapshot_retention: 0
```

Preview it with:

```bash
make guest GUEST_ACTION=snapshot EXTRA_VARS="-e @/private/tmp/guest-snapshot.yml"
```

Add `APPLY=1` only after approval for that VMID and snapshot name.

## Resize

Create `/private/tmp/guest-resize.yml` with the Proxmox inventory host, VMID, and final rootfs size in GiB.

```yaml
proxmox_guest_pve_host: pve-1
proxmox_guest_vmid: 200
proxmox_guest_resize_size_gib: 64
```

Preview it with:

```bash
make guest GUEST_ACTION=resize EXTRA_VARS="-e @/private/tmp/guest-resize.yml"
```

The size is the requested final size, not a `+GiB` increment.
Proxmox storage shrink is outside this role, so confirm the value is larger than the current rootfs before approving the mutation.

## Variable reference

| Variable | Used by | Required or default |
| --- | --- | --- |
| `proxmox_guest_pve_host` | All actions | Inventory host used to derive the API endpoint and to delegate `pct`; defaults to the first `proxmox` host. |
| `proxmox_guest_api_host` | Create, snapshot | Optional explicit API hostname; otherwise derived from `proxmox_guest_pve_host`. |
| `proxmox_guest_api_port` | Create, snapshot | `8006`. |
| `proxmox_guest_api_validate_certs` | Create, snapshot | `true`; set `false` only as an explicit local PKI decision. |
| `proxmox_guest_api_timeout` | Create, snapshot | `30` seconds. |
| `proxmox_guest_op_item` | Create, snapshot | `Proxmox`. |
| `proxmox_guest_node` | Create | Required Proxmox node name. |
| `proxmox_guest_vmid` | All actions | Required numeric guest ID. |
| `proxmox_guest_hostname` | Create | Required guest hostname. |
| `proxmox_guest_template` | Create | Required Proxmox template volume identifier. |
| `proxmox_guest_rootfs_storage` | Create | Required storage name. |
| `proxmox_guest_rootfs_size_gib` | Create | `32`. |
| `proxmox_guest_cores` | Create | `2`. |
| `proxmox_guest_memory_mib` | Create | `4096`. |
| `proxmox_guest_swap_mib` | Create | `1024`. |
| `proxmox_guest_unprivileged` | Create | `true`. |
| `proxmox_guest_features` | Create | `nesting=1` and `keyctl=1`. |
| `proxmox_guest_onboot` | Create | `true`. |
| `proxmox_guest_update_existing` | Create | `false`; leave false unless reconciling an existing VMID is intentional. |
| `proxmox_guest_nameserver` | Create | Required. |
| `proxmox_guest_searchdomain` | Create | `null`. |
| `proxmox_guest_netif` | Create | Required Proxmox `netif` mapping. |
| `proxmox_guest_pubkey` | Create | `null`; optional SSH public key. |
| `proxmox_guest_snapshot_name` | Snapshot | `pre-change`. |
| `proxmox_guest_snapshot_description` | Snapshot | `Snapshot created by proxmox_guest`. |
| `proxmox_guest_snapshot_vmstate` | Snapshot | `false`. |
| `proxmox_guest_snapshot_retention` | Snapshot | `0`. |
| `proxmox_guest_resize_size_gib` | Resize | Required positive final size. |

## Completion criteria

An operation is complete only when the approved mutation exits successfully and a read-only Proxmox check confirms the intended guest, snapshot, or final rootfs size.
The dry-run message alone is not evidence that Proxmox changed.
