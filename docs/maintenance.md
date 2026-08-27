# Scheduled maintenance

The maintenance pipeline gathers read-only evidence, compares it with the previous snapshot, and calls one interpretation backend only when evidence changed or a check failed.
It never runs an Ansible mutation target.
Raw evidence stays under `MAINT_STATE_DIR`, while distilled reports can be committed to an operator-owned notes checkout.

## Prerequisites

The base runner needs Bash, GNU Make, Git, `jq`, Python 3, `gh`, Tailscale, and the repository setup completed by `make setup`.
Repository checks need authenticated Git and GitHub access for every checkout included by `MAINT_REPOS`.
Live verification needs the same SSH, Tailscale, and 1Password access as `make verify`.
Home Assistant checks additionally need the HA repository and an executable `hactl`, or they must be disabled with `MAINT_SKIP_HA=1`.
The selected interpretation backend has its own prerequisites in the backend table below.

Run `make maint-test` before changing the pipeline.
That target also requires `shellcheck`.

## First local run

Use a local-only first run before configuring a notes repository or a timer.

```bash
make setup
export MAINT_BACKEND=codex
export MAINT_SKIP_VAULT_PUBLISH=1
export MAINT_SKIP_REPOS=1
export MAINT_SKIP_DASHBOARD=1
export MAINT_SKIP_HA=1
scripts/maint/run.sh
```

The first successful run establishes the comparison baseline and does not call a model merely because the initial snapshot is new.
With `MAINT_SKIP_VAULT_PUBLISH=1`, the index and any report stay inside that run's raw state directory.
Remove the three gather skips only after the corresponding repositories and commands are available.

## Notes publication

Set `MAINT_VAULT_DIR` to an operator-owned Git checkout that has a `Reports/` directory or permits the runner to create it.
The runner pulls that checkout with `git pull --ff-only`, writes only below `Reports/`, commits only that pathspec, and pushes the resulting commit.
Its Git remote must therefore support unattended pull and push from the timer account.
The checkout may contain private operational state, but its location and content are outside this public repository.

A pull failure leaves the failed report under the raw run directory without modifying a stale checkout.
An add, commit, or push failure makes the run fail and preserves a corrected local report for operator reconciliation.
Set `MAINT_SKIP_VAULT_PUBLISH=1` when no notes repository exists or when publication is intentionally disabled.

## Backend selection

`MAINT_BACKEND` is required.
Every backend receives the same prompt and schema, is bounded by `MAINT_TIMEOUT_SECONDS`, and must return locally schema-valid JSON.

| Backend | Runtime requirement | Defaults and overrides |
| --- | --- | --- |
| `claude` | An authenticated `claude` CLI plus `timeout` or `gtimeout` | Model `sonnet`, effort `low`, and budget `0.50`; override with `MAINT_CLAUDE_BIN`, `MAINT_CLAUDE_MODEL`, `MAINT_CLAUDE_EFFORT`, and `MAINT_MAX_BUDGET_USD`. |
| `codex` | An authenticated `codex` CLI plus `timeout` or `gtimeout` | Runs an ephemeral read-only `codex exec`; override the executable with `MAINT_CODEX_BIN`. |
| `hermes` | An OpenAI-compatible server and `curl` | Endpoint `http://127.0.0.1:8642/v1`, model `hermes-agent`; override with the `MAINT_OPENAI_*` variables. |
| `local` | An OpenAI-compatible server and `curl` | Endpoint `http://127.0.0.1:11434/v1`; `MAINT_OPENAI_MODEL` is required. |

`MAINT_OPENAI_API_KEY` is optional for endpoints that do not authenticate.
When it is set, keep it in a mode `0600` environment file and never commit it.

## Timer installation

The example below assumes the checkout is at the user's `~/projects/homelab-infra` path, which systemd unit files express as `%h/projects/homelab-infra`.
Edit both repository paths when the checkout lives elsewhere.

Create `~/.config/systemd/user/homelab-maint.service` with this content.

```bash
install -d ~/.config/systemd/user ~/.config/homelab-maint
```

```ini
[Unit]
Description=Read-only homelab maintenance report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=%h/projects/homelab-infra
EnvironmentFile=%h/.config/homelab-maint/env
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/projects/homelab-infra/scripts/maint/run.sh
TimeoutStartSec=45m
```

Create `~/.config/systemd/user/homelab-maint.timer` with this content.

```ini
[Unit]
Description=Daily homelab maintenance report

[Timer]
OnCalendar=daily
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
```

Create `~/.config/homelab-maint/env` as a mode `0600` file.
Systemd environment files do not expand shell variables, so use absolute paths in its values.

```ini
MAINT_BACKEND=codex
MAINT_VAULT_DIR=/absolute/path/to/operator-notes
MAINT_PROJECTS_DIR=/absolute/path/to/projects
```

Add backend credentials or an ntfy URL only in that private environment file.
Protect it before starting the unit.

```bash
chmod 600 ~/.config/homelab-maint/env
```

Ensure the user service manager remains available when the account is logged out if the host does not already enable lingering.
Enabling linger may require an administrator on the control machine.
Then load and exercise the units.

```bash
systemctl --user daemon-reload
systemctl --user start homelab-maint.service
journalctl --user -u homelab-maint.service --no-pager
systemctl --user enable --now homelab-maint.timer
systemctl --user list-timers homelab-maint.timer
```

The manual service run must finish successfully before the timer is enabled.

## Environment-variable reference

### Runner and report variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `MAINT_REPO_DIR` | Repository containing the running script | Root used to locate gather, compare, prompt, and schema files. |
| `MAINT_STATE_DIR` | `$HOME/.local/state/maint` | Private raw snapshots, diffs, backend evidence, and local failure reports. |
| `MAINT_VAULT_DIR` | `$HOME/projects/agentic-notes` | Optional operator notes checkout whose `Reports/` path is published. |
| `MAINT_RUN_DATE` | Current UTC date | Test or replay date in `YYYY-MM-DD` format. |
| `MAINT_RUN_ID` | UTC timestamp plus PID | Unique raw-directory name; permitted characters are letters, digits, `_`, `.`, `:`, and `-`. |
| `MAINT_INTERPRET_BIN` | `scripts/maint/interpret.sh` | Alternate executable implementing the interpreter contract. |
| `MAINT_PROMPT_FILE` | `scripts/maint/prompt.md` | Prompt prepended to the evidence bundle. |
| `MAINT_SCHEMA_FILE` | `scripts/maint/verdict.schema.json` | JSON Schema used for backend output validation. |
| `MAINT_NTFY_URL` | Unset | Full ntfy publish URL used only for `attention` or `failed` outcomes. |
| `MAINT_SKIP_VAULT_PUBLISH` | `0` | Set to `1` to keep reports under raw state and avoid all notes Git operations. |

### Gather variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `MAINT_PROJECTS_DIR` | `$HOME/projects` | Parent directory used for named repository defaults. |
| `MAINT_VERIFY_TAGS` | `security reliability dns komodo proxmox` | Space-separated extra `make verify TAGS=<tag>` passes after the untagged verify run. |
| `MAINT_REPOS` | `homelab-infra:komodo-app-stacks:komodo-resource-syncs:deploy-komodo-op` | Colon-separated repository names below `MAINT_PROJECTS_DIR` or absolute repository paths. |
| `MAINT_SKIP_REPOS` | `0` | Set to `1` to omit Git fetch, status, and Renovate PR checks. |
| `MAINT_SKIP_DASHBOARD` | `0` | Set to `1` to omit the Renovate dashboard issue check. |
| `MAINT_DASHBOARD_REPO` | `$MAINT_PROJECTS_DIR/komodo-app-stacks` | Repository in which the dashboard issue is queried. |
| `MAINT_RENOVATE_ISSUE_SEARCH` | `Renovate dashboard` | Search phrase used to find the open dashboard issue. |
| `MAINT_RENOVATE_ISSUE` | Unset | Exact issue number that bypasses dashboard search. |
| `MAINT_SKIP_HA` | `0` | Set to `1` to omit Home Assistant drift and validation checks. |
| `MAINT_HA_REPO_DIR` | `$MAINT_PROJECTS_DIR/ha-config` | Home Assistant repository used as the working directory. |
| `MAINT_HACTL_BIN` | `hactl` | Executable or executable path used for Home Assistant checks. |

### Interpreter and backend variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `MAINT_BACKEND` | None | Required selector: `claude`, `codex`, `hermes`, or `local`. |
| `MAINT_TIMEOUT_SECONDS` | `1200` | Positive timeout applied to the selected backend. |
| `MAINT_MAX_BUDGET_USD` | `0.50` | Non-negative Claude CLI budget ceiling. |
| `MAINT_CLAUDE_BIN` | `claude` | Claude CLI executable or path. |
| `MAINT_CLAUDE_MODEL` | `sonnet` | Claude model name. |
| `MAINT_CLAUDE_EFFORT` | `low` | Claude effort setting. |
| `MAINT_CODEX_BIN` | `codex` | Codex CLI executable or path. |
| `MAINT_CURL_BIN` | `curl` | Curl executable or path for OpenAI-compatible backends. |
| `MAINT_OPENAI_BASE_URL` | Backend-specific | Base URL whose `/chat/completions` endpoint is called. |
| `MAINT_OPENAI_MODEL` | `hermes-agent` for Hermes, required for local | Model sent to the OpenAI-compatible endpoint. |
| `MAINT_OPENAI_API_KEY` | Unset | Optional bearer token sent through a private curl header file. |
| `MAINT_OPENAI_MAX_INPUT_BYTES` | `1048576` | Positive maximum prompt plus evidence size for OpenAI-compatible calls. |

## Completion criteria

A scheduled installation is complete when a manual service run succeeds, a second unchanged run produces no model call, a controlled evidence change produces one schema-valid verdict, and the configured report destination receives the expected index or failure report.
Any skipped gather lane must be named as an intentional limitation rather than treated as verified health.
