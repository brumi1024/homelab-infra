# Add a Komodo stack

Use this runbook to add a new application stack to the GitOps-managed Komodo estate.

The application stack definition belongs in `komodo-app-stacks`; this repository supplies the generic Komodo API wrapper used to trigger and inspect the change.

Do not put secret values, tailnet addresses, or public IPs in any repository.

## 1. Choose the stack shape

Start from a nearby service in `komodo-app-stacks/services/` with a similar runtime and storage model.

Use the base-plus-override layout when the service has more than one deployment, as used by the Caddy, proxy, AutoKuma, Nebula Sync, and Zigbee2MQTT services.

Keep shared configuration in the base `docker-compose.yaml` and put site-specific changes in the instance override and its `stack.toml`.

Check `common-vars.toml` for an available host port before choosing a new default.

Add a new `PORT_<NAME>` row to `common-vars.toml` before referencing that port from Compose.

Use private Docker networking for same-host traffic and full MagicDNS names for traffic between hosts.

Use named volumes or host paths below `${CONFIG_DIR}/<stack>` for persistent state.

Review release notes, backup requirements, and rollback steps before adding a stateful service.

## 2. Create the stack in `komodo-app-stacks`

Create `services/<name>/docker-compose.yaml` and `services/<name>/stack.toml`, or create the base and instance files required by a multi-instance stack.

Every long-running Compose service must set an explicit `container_name` and `restart` policy.

Keep container logging policy in the Docker daemon configuration rather than repeating it in each stack.

Use `env_file_path` in `stack.toml` with a unique path relative to the stack's `run_directory`.

When a Compose service imports the rendered environment file, reference `${KOMODO_ENV_FILE:-.env}` and set `KOMODO_ENV_FILE` to the same path in the stack environment block.

Reference secrets only through `[[OP__KOMODO__<STACK>__<NAME>]]` variables supplied by `komodo-op`.

Use short names for non-secret shared variables such as `[[TZ]]`, `[[CONFIG_DIR]]`, and `[[DOMAIN]]`.

Add `homepage.*` labels to user-facing services and omit them from internal-only sidecars.

Add an unauthenticated health endpoint label when the application provides one so monitoring can verify the service without credentials.

For NFS storage, follow the established `addr=${NAS_IP},rw,vers=4.1` volume pattern and source the address from a Komodo variable.

Keep the stack's `linked_repo` pointed at the existing shared app-stacks repository unless this deployment intentionally introduces another linked repository.

## 3. Validate and publish the definition

Run the app-stack repository's validator before committing.

```bash
cd /path/to/komodo-app-stacks
python3 scripts/validate_stacks.py
git diff --check
git status --short
git commit -m "Add <stack> stack"
git push origin main
```

Push only when the definition is ready for Komodo resource synchronization.

Do not run `docker compose up` manually on a target host because Komodo owns deployment state.

## 4. Complete the cross-repository create checklist

Check each item below before triggering the sync.

- `komodo-app-stacks/common-vars.toml` has a unique `PORT_<NAME>` row for every new host port.
- `komodo-app-stacks/services/<name>/stack.toml` references the correct Compose files, linked repository, environment file path, server, and update policy.
- `komodo-app-stacks/services/<name>/docker-compose.yaml` has explicit restart policies, persistent storage, health checks where available, and the required `homepage.*` and monitoring labels.
- Every secret consumed by the stack has a matching `OP__KOMODO__<STACK>__<NAME>` field supplied by the `komodo-op` flow, and no secret value was committed.
- Caddy routing and authentication are updated when the service is user-facing.
- DNS is updated when the service needs a new name.
- AutoKuma labels and tags are present when the service should be monitored.
- The `komodo-resource-syncs/syncs.toml` entry already includes the app-stacks resource path, or is updated when the source repository, branch, or resource path changes.
- `deploy-komodo-op` is changed only when the stack needs a new 1Password-to-Komodo variable mapping or another komodo-op configuration change.
- `homelab-infra` is changed only when the stack also requires infrastructure shape such as a new host, firewall rule, bootstrap input, or resource-sync definition.

Do not add a new resource sync merely for another `services/<name>/stack.toml` file when the existing `komodo-app-stacks` sync already includes `services` and `common-vars.toml`.

## 5. Trigger synchronization and deploy

Run these commands from a checkout of `homelab-infra` after the app-stack commit is visible to the remote repository.

```bash
cd /path/to/homelab-infra
bin/komodo run-sync komodo-app-stacks
bin/komodo deploy <stack>
bin/komodo logs <stack>
```

The sync pulls the resource definitions into Komodo before the deploy request is sent.

Run the deploy only after the sync response shows that the new or changed stack is known to Core.

Use the exact Komodo stack name from `services/<name>/stack.toml` for the deploy and logs commands.

Confirm that each command exits successfully and inspect the returned JSON for a successful sync or deployment state.

Review the stack log for image-pull, environment, storage, health-check, and dependency errors.

Confirm the service's health endpoint, Caddy route, Homepage entry, and AutoKuma monitor when those integrations apply.

## Config-file-only changes

Komodo Deploy runs `docker compose up -d`, which does not restart a service when only a `config_files` entry changed.

After changing a Caddyfile or another `config_files` entry, run `bin/komodo run-sync komodo-app-stacks` and then use Komodo's Restart action for that stack.

Neither Deploy nor Restart pulls the repository, so the sync must complete first.

Mount a configuration directory rather than an individual file because a repository pull replaces files and a single-file bind mount can remain attached to an old unlinked inode.

Do not add a more-specific single-file mount in an instance override when the base already mounts the configuration directory.

## Completion check

The stack definition is complete when validation passed, the cross-repository checklist is satisfied, the resource sync succeeded, the deployment succeeded, and the stack log plus applicable health and monitoring checks are clean.

Record any remaining operator action, rollback condition, or live-state exception in the appropriate private operations note rather than in this generic runbook.
