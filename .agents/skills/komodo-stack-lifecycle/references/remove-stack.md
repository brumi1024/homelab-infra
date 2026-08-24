# Remove a Komodo stack

This runbook removes one Docker Compose stack from the Komodo-managed homelab without assuming that a repository deletion also destroys the live stack.

Replace `<stack>`, `<server>`, `<service>`, and `<sync>` with the exact names from the stack declaration before running a command.

The commands in this document are examples for an operator to review.

Do not run a write or execute command from an agent session without an explicit operator approval for that stack.

## Safety boundary

Never run `make` with `APPLY=1` while following this runbook.

Do not remove a live stack until its data retention decision, backup or snapshot, and user-facing outage window are recorded.

Do not print or commit secret values from 1Password, Komodo variables, environment files, or stack logs.

Keep raw API output in a private temporary directory rather than committing it to either repository or the notes vault.

## Komodo sync deletion semantics

### Live verification status

The behavior of the current Core when a stack declaration disappears from `komodo-app-stacks` is operator verification required.

This checkout could not authenticate to the Komodo Core because the local `op` CLI could not connect to the 1Password desktop app, so this runbook makes no claim that omission deletes the stack or leaves an orphaned stack resource.

Do not infer the behavior from a different Komodo version, a different sync, or a documentation example.

Verify the behavior against the running Core before removing a production stack, preferably with a disposable stack declared only for this test.

### Read-only baseline

Run these commands before changing the disposable declaration or the real stack.

```bash
mkdir -p /private/tmp/komodo-remove-<stack>
bin/komodo read GetVersion '{}' \
  > /private/tmp/komodo-remove-<stack>/core-version.json
bin/komodo read GetResourceSync '{"sync":"<sync>"}' \
  > /private/tmp/komodo-remove-<stack>/sync-before.json
bin/komodo read GetStack '{"stack":"<stack>"}' \
  > /private/tmp/komodo-remove-<stack>/stack-before.json
bin/komodo read ListAllStackServices '{"stacks":["<stack>"],"tags":[],"terms":[],"state":[],"page":0,"limit":0}' \
  > /private/tmp/komodo-remove-<stack>/services-before.json
```

The `GetResourceSync` response contains the Core's observed sync state and pending resource updates, which is the evidence needed to distinguish a pending deletion from an already applied deletion.

The `GetStack` and `ListAllStackServices` responses record whether the Core resource and its services still exist before the test.

### Disposable-stack test

Use a disposable stack that has no production data, no public DNS name, no shared volume, and no credentials that matter outside the test.

Create the disposable declaration in the branch and path that the real sync reads, but do not push it to a production branch until the operator has reviewed the exact diff.

After the declaration has been observed by Core, capture the baseline above with `<stack>` set to the disposable name.

Remove only that declaration, push the test branch if required by the sync, and ask the operator to approve the following mutating API call.

```bash
bin/komodo run-sync <sync>
```

After the sync update completes, capture the same `GetResourceSync`, `GetStack`, and `ListAllStackServices` responses again.

Classify the observed result explicitly as one of these two outcomes.

- `deleted`: the sync reports the removal and `GetStack` no longer returns the resource.
- `orphaned`: the declaration is absent but `GetStack` still returns the resource, regardless of whether its runtime state is down.

Do not mark this runbook's sync-semantics question complete until the result, Core version, sync name, and date are recorded in the operator's private evidence or the relevant notes vault entry.

Restore the disposable declaration and run the sync again only after the operator has confirmed that the test data and test containers may be recreated.

If a disposable stack cannot be created safely, stop and leave this section marked operator verification required.

## Cross-repository removal checklist

Do this audit before the first removal commit so that a deleted Compose file does not leave a route, secret, monitor, or shared variable behind.

Use the exact stack name, service names, hostnames, and variable names from the files rather than broad guesses.

### `komodo-app-stacks`

Identify the declaration's `name`, `server`, `run_directory`, `file_paths`, `config_files`, `env_file_path`, and every `[[OP__KOMODO__...]]` reference in its `stack.toml`.

Remove the stack declaration and only files owned by that stack, including its Compose files, instance overrides, config files, and stack-local documentation.

If a shared base file is used by another stack, remove only the stack's override and labels from the shared file after checking every remaining `stack.toml` reference.

Inspect the Compose file's `ports`, `volumes`, `networks`, `homepage.*` labels, and `kuma.*` labels before deleting it.

Search for the stack and service names from the repository root before committing.

```bash
cd /path/to/komodo-app-stacks
rg -n -i '<stack>|<service>|<hostname>' .
```

### `common-vars.toml` port row

Find each `PORT_*` variable used by the stack and search for all consumers before deleting its row from `common-vars.toml`.

```bash
cd /path/to/komodo-app-stacks
rg -n 'PORT_[A-Z0-9_]+' services common-vars.toml
```

Delete a port row only when no surviving stack or shared configuration references it.

Keep a shared port row when another stack still uses it, even if the removed stack was its original consumer.

### `OP__KOMODO__*` fields

List the exact `[[OP__KOMODO__STACK__FIELD]]` references found in the removed declaration and search for each reference across all stack repositories.

```bash
rg -n -F '[[OP__KOMODO__<STACK>__<FIELD>]]' \
  /path/to/komodo-app-stacks \
  /path/to/deploy-komodo-op \
  /path/to/komodo-resource-syncs \
  /path/to/homelab-infra
```

Remove a source 1Password field only after every remaining consumer has been checked and the operator has approved the credential cleanup.

The `deploy-komodo-op` repository normally needs no file change for this cleanup because it projects the source vault into Komodo global variables.

Do not delete a `COMMON` field merely because the removed stack used it, since common fields are often consumed by Caddy, Homepage, and multiple stacks.

After the source item is changed, allow the `komodo-op` sync to refresh global variables and verify that no surviving stack has a pending unresolved variable.

### Caddy and DNS

Search every Caddyfile and proxy configuration for the stack's hostname, upstream, port variable, and any authentication or certificate rule.

```bash
rg -n -i '<stack>|<service>|<hostname>|PORT_<NAME>' \
  /path/to/komodo-app-stacks/services/caddy \
  /path/to/ha-config \
  /path/to/other-dns-or-proxy-repository
```

Remove the route, matcher, upstream, redirect, and certificate or DNS challenge references that belong only to the removed stack.

Do not remove a shared Caddy import, wildcard certificate, network, or DNS zone entry that still serves another application.

Check both authoritative DNS providers used by the site and remove an A, AAAA, CNAME, or delegated record only when it is owned by the removed stack.

After a Caddyfile change, run the `komodo-app-stacks` sync first and then restart the Caddy stack so the running process reads the refreshed config.

### AutoKuma tag

Record every `kuma.<tag>.*` label and the matching `kuma.__site` label from the removed Compose service.

Search the AutoKuma configuration and Uptime Kuma for the exact tag before removal.

```bash
rg -n -i '<tag>|<service>|kuma\.' \
  /path/to/komodo-app-stacks/services/autokuma \
  /path/to/komodo-app-stacks/services
```

Destroying the Compose stack removes its labeled container, but AutoKuma's configured deletion grace period can keep the monitor for a while.

Verify after that grace period that the monitor is gone and that no shared monitor uses the same tag.

Do not delete a monitor manually before checking whether another container or instance uses the same tag.

### Homepage label

Record and remove the service's `homepage.group`, `homepage.name`, `homepage.icon`, `homepage.href`, `homepage.description`, and widget labels when they belong only to the removed container.

Search Homepage's direct configuration as well as Compose labels because a service may be listed in `services.yaml` instead of being discovered from Docker labels.

```bash
rg -n -i '<stack>|<service>|<hostname>|homepage\.' \
  /path/to/komodo-app-stacks/services/homepage \
  /path/to/komodo-app-stacks/services
```

Remove a direct Homepage entry only when it is not shared with another service or instance.

## Destroy the live stack

Take the required backup or snapshot before this section and record its identifier privately.

Read the live stack and its services again immediately before the destructive call because a sync or deploy may have changed them since the initial audit.

```bash
bin/komodo read GetStack '{"stack":"<stack>"}'
bin/komodo read ListAllStackServices '{"stacks":["<stack>"],"tags":[],"terms":[],"state":[],"page":0,"limit":0}'
bin/komodo read GetStackActionState '{"stack":"<stack>"}'
```

Do not proceed while the stack is deploying, restarting, pulling, or already destroying.

Ask the operator to approve this API call after confirming the target name and server.

```bash
bin/komodo execute DestroyStack \
  '{"stack":"<stack>","services":[],"remove_orphans":false,"stop_time":null}'
```

An empty `services` list targets every service in the stack.

Keep `remove_orphans` false unless the operator has separately identified the orphan containers because that flag removes containers outside the declared service list.

Poll the returned update with the Komodo UI or the update-read API available on the installed Core, then confirm the stack action state is no longer destroying.

## Volumes and `${CONFIG_DIR}/<stack>`

Komodo's `DestroyStack` operation is `docker compose down` for the selected stack.

The operation stops and removes the stack's containers and the Compose-managed project network, subject to the selected services and orphan flag.

It does not pass `--volumes`, so named volumes are retained unless an operator separately removes them.

External networks and external volumes are not owned by the stack and are not removed by this operation.

Bind mounts are host paths, not Docker volumes, and are not removed by `docker compose down`.

In this setup, `${CONFIG_DIR}/<stack>` and its contents therefore remain on the host after the stack is destroyed.

NFS-backed named volumes also retain their data at the remote export unless an operator separately removes the volume and the remote data.

Treat retained named volumes and `${CONFIG_DIR}/<stack>` as preserved data until the operator has confirmed a backup and explicitly approved their removal.

Do not run `docker compose down -v`, `docker volume prune`, or a recursive deletion of `${CONFIG_DIR}` as part of this runbook.

If the data must be erased, inventory the exact named volumes and host paths first, remove only the approved targets through the host's normal maintenance procedure, and record what was removed.

## Remove the declaration and Core resource

After the live stack is down, remove the declaration and complete the cross-repository checklist before pushing the app-stacks change.

Run the sync only after the operator has reviewed the commit and confirmed the live sync target.

```bash
bin/komodo run-sync <sync>
```

Read the sync result and confirm that the removed stack appears in the applied deletion update rather than only in a pending diff.

If the live verification classified omission as `deleted`, confirm the stack is absent and do not issue a second delete call.

If the live verification classified omission as `orphaned`, remove the remaining Core resource only after the operator confirms that the stack is down and no rollback is needed.

```bash
bin/komodo write DeleteStack '{"id":"<stack>"}'
```

`DeleteStack` removes the Komodo resource record and is not a substitute for `DestroyStack`.

Do not use `DeleteStack` to bypass a failed or still-running destroy operation.

## Post-removal verification

Run these checks after the sync has completed and any approved Core-resource deletion has settled.

```bash
bin/komodo read GetResourceSync '{"sync":"<sync>"}' \
  > /private/tmp/komodo-remove-<stack>/sync-after.json
bin/komodo read ListStacks '{}' \
  > /private/tmp/komodo-remove-<stack>/stacks-after.json
```

`GetStack` must fail for the removed name when the intended outcome is no Core resource.

```bash
if bin/komodo read GetStack '{"stack":"<stack>"}' \
  > /private/tmp/komodo-remove-<stack>/unexpected-stack.json 2>/private/tmp/komodo-remove-<stack>/unexpected-stack.err; then
  echo "stack still exists in Komodo Core: <stack>" >&2
  exit 1
fi
```

The sync response must have no pending update for the removed stack and no pending variable or file error caused by its deletion.

The stack service list must contain no service belonging to the removed stack.

Check the target host through the read-only Komodo API for any remaining stack service or container associated with the removed project.

```bash
bin/komodo read ListAllStackServices '{"stacks":["<stack>"],"tags":[],"terms":[],"state":[],"page":0,"limit":0}'
```

Search every in-scope repository and configuration checkout for the exact stack, service, hostname, port variable, AutoKuma tag, Homepage label, and OP variable names.

```bash
rg -n -i '<stack>|<service>|<hostname>|<tag>|PORT_<NAME>|OP__KOMODO__<STACK>' \
  /path/to/homelab-infra \
  /path/to/komodo-app-stacks \
  /path/to/komodo-resource-syncs \
  /path/to/deploy-komodo-op \
  /path/to/ha-config \
  /path/to/other-dns-or-proxy-repository
```

Review each remaining match manually because a shared variable, Caddy include, or documentation link may legitimately contain part of the old name.

Check DNS resolution for the removed hostname from both relevant sites and confirm that no record still points at the old service.

Check Caddy's active configuration and logs for the removed route after the restart.

Check Uptime Kuma after AutoKuma's deletion grace period and check Homepage after its next reload.

Record the final Core version, sync name, stack name, applied update status, data-retention decision, and any operator cleanup in the private evidence or the relevant notes vault entry.

## Verification status for this runbook

The repository-side checks for this document can run without live credentials.

The Komodo sync deletion test and disposable-stack dry run remain unverified until the operator provides a working read-only 1Password or Komodo session and approves a disposable test.
