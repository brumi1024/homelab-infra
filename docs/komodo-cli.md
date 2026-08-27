# Komodo API wrapper

`bin/komodo` is the repository's command-line seam for reading and operating Komodo Core without putting API credentials in arguments, environment variables, or files.
It requires Bash, `op`, `curl`, and Python 3.

## Authentication and endpoint

By default the wrapper reads the `Komodo` item from the `Homelab Ansible` 1Password vault.
`KOMODO_OP_VAULT` overrides that vault name, while `HOMELAB_OP_VAULT` is the fallback shared with other homelab tooling.
`KOMODO_URL` overrides the item's `komodo_host` field when the API should use a direct internal endpoint.

The control machine must have an authenticated 1Password CLI session or an `OP_SERVICE_ACCOUNT_TOKEN` that can read the `Komodo` item.
The item must contain `komodo_api_key`, `komodo_api_secret`, and `komodo_host` as documented in [1password.md](1password.md).

Verify the prerequisites without printing secret fields.

```bash
op account list
bin/komodo --help
bin/komodo read GetVersion '{}'
```

## Generic commands

The generic interface is:

```text
bin/komodo read TYPE JSON_PARAMS
bin/komodo write TYPE JSON_PARAMS
bin/komodo execute TYPE JSON_PARAMS
```

`JSON_PARAMS` must be one JSON object, including `{}` when the call has no parameters.
Quote it so the shell passes it as a single argument.

```bash
bin/komodo read GetStack '{"stack":"example"}'
bin/komodo read ListAllStackServices '{"stacks":["example"],"tags":[],"terms":[],"state":[],"page":0,"limit":0}'
```

`read` is the inspection lane.
`write` and `execute` can mutate Komodo resources or workloads and require the same explicit operator authorization as any other live mutation.

## Convenience commands

| Command | API behavior | Mutation |
| --- | --- | --- |
| `bin/komodo stacks` | List stack resources. | No. |
| `bin/komodo servers` | List Periphery servers. | No. |
| `bin/komodo syncs` | List resource syncs. | No. |
| `bin/komodo logs STACK` | Read the stack log. | No. |
| `bin/komodo deploy STACK` | Execute `DeployStack`. | Yes. |
| `bin/komodo run-sync NAME` | Execute `RunSync`. | Yes. |

Inspect returned JSON and the stack log after every authorized deploy or sync.
Use the exact Core resource name rather than a repository directory guess.

## Direct endpoint example

Use an internal URL only when the control machine can reach it and its transport is appropriate for that network.

```bash
KOMODO_URL=http://core-host:9120 bin/komodo servers
```

The override affects only the endpoint.
Credentials still come from 1Password.
