#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/homelab-maint-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

fake_bin=$tmp_dir/bin
fake_repo=$tmp_dir/fake-repo
state_dir=$tmp_dir/state
vault_dir=$tmp_dir/vault
calls=$tmp_dir/calls
mode_file=$tmp_dir/mode
interpret_mode_file=$tmp_dir/interpret-mode
git_mode_file=$tmp_dir/git-mode
counter_file=$tmp_dir/counter
real_mkdir=$(command -v mkdir)
maint_run_id=01-first
mkdir -p "$fake_bin" "$fake_repo/.git" "$vault_dir" "$calls"
printf 'clean\n' > "$mode_file"
printf 'valid\n' > "$interpret_mode_file"
printf 'ok\n' > "$git_mode_file"
printf '0\n' > "$counter_file"

cat > "$fake_bin/make" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$MAINT_TEST_MAKE_LOG"
if [[ -n ${MAINT_TEST_HOLD_SECONDS:-} && ! -e "$MAINT_TEST_HOLD_FILE" ]]; then
    : > "$MAINT_TEST_HOLD_FILE"
    sleep "$MAINT_TEST_HOLD_SECONDS"
fi
mode=$(cat "$MAINT_TEST_MODE_FILE")
counter=$(cat "$MAINT_TEST_COUNTER_FILE")
counter=$((counter + 1))
printf '%s\n' "$counter" > "$MAINT_TEST_COUNTER_FILE"
second=$((counter % 9))
printf 'timestamp=2026-08-24T06:30:0%sZ duration=%ss run=%s count=%s\n' "$second" "$counter" "$counter" "$counter"
if [[ "$mode" == changed && "$*" == *TAGS=security* ]]; then
    printf 'meaningful state changed\n'
fi
if [[ "$1" == verify && "$*" == *TAGS=security* ]]; then
    case "$mode" in
        failed) exit 1 ;;
        partial) exit 42 ;;
    esac
fi
EOF

cat > "$fake_bin/mkdir" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${MAINT_TEST_DISK_FULL:-0} == 1 && "$*" == *"$MAINT_STATE_DIR"* ]]; then
    printf 'mkdir: cannot create directory: No space left on device\n' >&2
    exit 1
fi
exec "$MAINT_TEST_REAL_MKDIR" "$@"
EOF

cat > "$fake_bin/ansible-inventory" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'all:\n  |--control\n'
EOF

cat > "$fake_bin/tailscale" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' '{"Peer":{"node":{"HostName":"offline-node","Online":false,"LastSeen":"2026-08-24T06:29:00Z"}}}'
EOF

cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == -C ]]; then
    printf '%s\n' "$*" >> "$MAINT_TEST_GIT_LOG"
    mode=$(cat "$MAINT_TEST_GIT_MODE_FILE")
    shift 2
    case "$1 ${2:-}" in
        "rev-parse --git-dir") printf '.git\n' ;;
        "pull --ff-only") [[ "$mode" != pull-fail ]] || exit 1 ;;
        "add --") [[ "$mode" != add-fail ]] || exit 1 ;;
        "diff --cached") exit 1 ;;
        "commit -m") [[ "$mode" != commit-fail ]] || exit 1 ;;
        "commit --amend") ;;
        "push ") [[ "$mode" != push-fail ]] || exit 1 ;;
        *) printf 'unexpected vault git command: %s\n' "$*" >&2; exit 1 ;;
    esac
    exit 0
fi
case "$1" in
    fetch) printf 'fetch preview\n' ;;
    status) printf '## main...origin/main\n' ;;
    *) printf 'unexpected git command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1 $2" in
    "pr list") exit 0 ;;
    *) printf 'unexpected gh command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$MAINT_TEST_CURL_LOG"
EOF

cat > "$tmp_dir/interpret" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '1\n' >> "$MAINT_TEST_INTERPRET_LOG"
case $(cat "$MAINT_TEST_INTERPRET_MODE_FILE") in
    failed) status=failed; summary='synthetic failed verdict' ;;
    malformed) printf 'not json\n'; exit 0 ;;
    schema-invalid) printf '%s\n' '{"status":"bad","summary":"synthetic invalid verdict"}'; exit 0 ;;
    *) status=attention; summary='synthetic change' ;;
esac
printf '%s\n' "{\"status\":\"$status\",\"summary\":\"$summary\",\"changes\":[{\"host\":\"test\",\"what\":\"fixture changed\",\"evidence\":\"fixture\"}],\"stale_notes\":[],\"suggested_actions\":[\"review the fixture\"]}"
EOF

chmod +x "$fake_bin"/* "$tmp_dir/interpret"
: > "$calls/interpreter"
: > "$calls/curl"
: > "$calls/git"
: > "$calls/make"

run_maint() {
    PATH="$fake_bin:$PATH" \
        MAINT_STATE_DIR="$state_dir" \
        MAINT_VAULT_DIR="$vault_dir" \
        MAINT_REPO_DIR="$repo_root" \
        MAINT_REPOS="$fake_repo" \
        MAINT_VERIFY_TAGS=security \
        MAINT_SKIP_DASHBOARD=1 \
        MAINT_SKIP_HA=1 \
        MAINT_RUN_DATE=2026-08-24 \
        MAINT_RUN_ID="$maint_run_id" \
        MAINT_INTERPRET_BIN="$tmp_dir/interpret" \
        MAINT_TEST_MODE_FILE="$mode_file" \
        MAINT_TEST_INTERPRET_MODE_FILE="$interpret_mode_file" \
        MAINT_TEST_GIT_MODE_FILE="$git_mode_file" \
        MAINT_TEST_COUNTER_FILE="$counter_file" \
        MAINT_TEST_INTERPRET_LOG="$calls/interpreter" \
        MAINT_TEST_MAKE_LOG="$calls/make" \
        MAINT_NTFY_URL=https://ntfy.invalid/homelab \
        MAINT_TEST_CURL_LOG="$calls/curl" \
        MAINT_TEST_GIT_LOG="$calls/git" \
        MAINT_TEST_REAL_MKDIR="$real_mkdir" \
        MAINT_TEST_HOLD_SECONDS="${MAINT_TEST_HOLD_SECONDS:-}" \
        MAINT_TEST_HOLD_FILE="$tmp_dir/hold-started" \
        MAINT_TEST_DISK_FULL="${MAINT_TEST_DISK_FULL:-0}" \
        "$repo_root/scripts/maint/run.sh"
}

# A first run has no previous snapshot. It establishes the baseline without
# calling the interpreter on the expected full initial snapshot.
first=$(run_maint)
[[ "$first" == *'status=ok'* ]]
[[ "$first" == *'publish_status=ok'* ]]
[[ "$first" == *'model_called=0'* ]]

maint_run_id=02-second
second=$(run_maint)
[[ "$second" == *'status=ok'* ]]
[[ "$second" == *'model_called=0'* ]]
[[ ! -s "$calls/interpreter" ]]
[[ ! -s "$calls/curl" ]]
[[ $(wc -l < "$vault_dir/Reports/index.md" | tr -d ' ') == 2 ]]
[[ $(grep -c ' pull --ff-only' "$calls/git" | tr -d ' ') == 2 ]]
[[ $(grep -c ' push$' "$calls/git" | tr -d ' ') == 2 ]]
grep -q -- 'commit -m Record maintenance run 2026-08-24 -- Reports' "$calls/git"

printf 'changed\n' > "$mode_file"
maint_run_id=03-changed
third=$(run_maint)
[[ "$third" == *'status=attention'* ]]
[[ "$third" == *'model_called=1'* ]]
[[ $(wc -l < "$calls/interpreter" | tr -d ' ') == 1 ]]
[[ $(wc -l < "$calls/curl" | tr -d ' ') == 1 ]]
[[ -s "$vault_dir/Reports/2026-08-24-maint.md" ]]
grep -q -- '- test: fixture changed (fixture)' "$vault_dir/Reports/2026-08-24-maint.md"

# The previous run called the model, so its directory now holds evidence.txt,
# verdict.json and interpreter.err. Those are not gathered evidence, and
# evidence.txt embeds that run's diff, so folding them into the next comparison
# made an otherwise identical run look changed and grew the bundle every day.
maint_run_id=04-quiet
quiet_run=$(run_maint)
[[ "$quiet_run" == *'status=ok'* ]]
[[ "$quiet_run" == *'model_called=0'* ]]
[[ $(wc -l < "$calls/interpreter" | tr -d ' ') == 1 ]]

quiet_dir=$(find "$state_dir" -type f -name manifest.tsv -print | sed 's#/manifest.tsv$##' | LC_ALL=C sort | tail -n 1)
[[ ! -s "$quiet_dir/diff.patch" ]]

# A command failure is recorded without aborting the gather, later checks still
# run, and the model cannot downgrade the failed check to attention.
base_report_hash=$(sha256sum "$vault_dir/Reports/2026-08-24-maint.md" | cut -d' ' -f1)
: > "$calls/make"
printf 'partial\n' > "$mode_file"
maint_run_id=05-partial
if run_maint > "$tmp_dir/partial.out"; then
    printf 'partial gather unexpectedly returned success\n' >&2
    exit 1
fi
grep -q 'status=failed' "$tmp_dir/partial.out"
grep -q $'^verify-security\t42$' "$state_dir/2026-08-24/raw/05-partial/manifest.tsv"
grep -q '^lint$' "$calls/make"
[[ $(wc -l < "$calls/interpreter" | tr -d ' ') == 2 ]]
[[ $(wc -l < "$calls/curl" | tr -d ' ') == 2 ]]
[[ $(sha256sum "$vault_dir/Reports/2026-08-24-maint.md" | cut -d' ' -f1) == "$base_report_hash" ]]
[[ -s "$vault_dir/Reports/2026-08-24-05-partial-maint.md" ]]

# Malformed and schema-invalid interpreter output fail the run and leave a
# durable report instead of being accepted as a verdict.
printf 'clean\n' > "$mode_file"
printf 'malformed\n' > "$interpret_mode_file"
maint_run_id=06-malformed
if run_maint > "$tmp_dir/malformed.out"; then
    printf 'malformed interpreter output unexpectedly succeeded\n' >&2
    exit 1
fi
grep -q 'status=failed' "$tmp_dir/malformed.out"
grep -q 'Maintenance interpreter returned an invalid verdict' \
    "$vault_dir/Reports/2026-08-24-06-malformed-maint.md"

printf 'changed\n' > "$mode_file"
printf 'schema-invalid\n' > "$interpret_mode_file"
maint_run_id=07-schema-invalid
if run_maint > "$tmp_dir/schema-invalid.out"; then
    printf 'schema-invalid interpreter output unexpectedly succeeded\n' >&2
    exit 1
fi
grep -q 'status=failed' "$tmp_dir/schema-invalid.out"
grep -q 'Maintenance interpreter returned an invalid verdict' \
    "$vault_dir/Reports/2026-08-24-07-schema-invalid-maint.md"

# A failed ff-only pull keeps the report under raw state and performs no add,
# commit, or push against a stale vault checkout.
printf 'clean\n' > "$mode_file"
printf 'valid\n' > "$interpret_mode_file"
printf 'pull-fail\n' > "$git_mode_file"
maint_run_id=08-pull-fail
vault_index_lines=$(wc -l < "$vault_dir/Reports/index.md" | tr -d ' ')
git_adds=$(grep -c ' add --' "$calls/git" || true)
if run_maint > "$tmp_dir/pull-fail.out" 2> "$tmp_dir/pull-fail.err"; then
    printf 'failed vault pull unexpectedly returned success\n' >&2
    exit 1
fi
grep -q 'publish_status=failed' "$tmp_dir/pull-fail.out"
grep -q 'Vault pull --ff-only failed' "$tmp_dir/pull-fail.err"
[[ $(wc -l < "$vault_dir/Reports/index.md" | tr -d ' ') == "$vault_index_lines" ]]
[[ $(grep -c ' add --' "$calls/git" || true) == "$git_adds" ]]
[[ -s "$state_dir/2026-08-24/raw/08-pull-fail/reports/index.md" ]]
grep -q -- '- 2026-08-24: failed - Vault pull --ff-only failed' \
    "$state_dir/2026-08-24/raw/08-pull-fail/reports/index.md"
backtick=$(printf '\140')
failed_status="Status: ${backtick}failed${backtick}"
grep -Fq "$failed_status" \
    "$state_dir/2026-08-24/raw/08-pull-fail/reports/2026-08-24-maint.md"

# Add and commit failures are reported without attempting later publication
# stages, and their on-disk artifacts record the effective failed result.
printf 'changed\n' > "$mode_file"
printf 'add-fail\n' > "$git_mode_file"
maint_run_id=09-add-fail
commits_before=$(grep -c ' commit ' "$calls/git" || true)
pushes_before=$(grep -c ' push$' "$calls/git" || true)
if run_maint > "$tmp_dir/add-fail.out" 2> "$tmp_dir/add-fail.err"; then
    printf 'failed vault add unexpectedly returned success\n' >&2
    exit 1
fi
grep -q 'status=failed' "$tmp_dir/add-fail.out"
grep -q 'Vault add failed' "$tmp_dir/add-fail.err"
grep -q -- '- 2026-08-24: failed - Vault add failed' "$vault_dir/Reports/index.md"
grep -Fq "$failed_status" "$vault_dir/Reports/2026-08-24-09-add-fail-maint.md"
[[ $(grep -c ' commit ' "$calls/git" || true) == "$commits_before" ]]
[[ $(grep -c ' push$' "$calls/git" || true) == "$pushes_before" ]]

printf 'commit-fail\n' > "$git_mode_file"
maint_run_id=10-commit-fail
pushes_before=$(grep -c ' push$' "$calls/git" || true)
if run_maint > "$tmp_dir/commit-fail.out" 2> "$tmp_dir/commit-fail.err"; then
    printf 'failed vault commit unexpectedly returned success\n' >&2
    exit 1
fi
grep -q 'status=failed' "$tmp_dir/commit-fail.out"
grep -q 'Vault commit failed' "$tmp_dir/commit-fail.err"
grep -q -- '- 2026-08-24: failed - Vault commit failed' "$vault_dir/Reports/index.md"
grep -Fq "$failed_status" "$vault_dir/Reports/2026-08-24-10-commit-fail-maint.md"
[[ $(grep -c ' push$' "$calls/git" || true) == "$pushes_before" ]]

# A push rejection is a failed unattended run even though its commit remains
# locally recoverable in the vault checkout, with the corrected failure status
# amended into that local commit.
printf 'push-fail\n' > "$git_mode_file"
maint_run_id=11-push-fail
if run_maint > "$tmp_dir/push-fail.out" 2> "$tmp_dir/push-fail.err"; then
    printf 'failed vault push unexpectedly returned success\n' >&2
    exit 1
fi
grep -q 'publish_status=failed' "$tmp_dir/push-fail.out"
grep -q 'status=failed' "$tmp_dir/push-fail.out"
grep -q 'Vault push failed' "$tmp_dir/push-fail.err"
grep -q ' push$' "$calls/git"
grep -q -- '- 2026-08-24: failed - Vault push failed' "$vault_dir/Reports/index.md"
grep -Fq "$failed_status" "$vault_dir/Reports/2026-08-24-11-push-fail-maint.md"
grep -q ' commit --amend --no-edit -- Reports' "$calls/git"

# Timer and manual invocations cannot gather concurrently.
printf 'ok\n' > "$git_mode_file"
maint_run_id=12-holder
rm -f "$tmp_dir/hold-started"
MAINT_TEST_HOLD_SECONDS=2 run_maint > "$tmp_dir/holder.out" 2> "$tmp_dir/holder.err" &
holder_pid=$!
for _ in {1..100}; do
    [[ -e "$tmp_dir/hold-started" ]] && break
    sleep 0.05
done
[[ -e "$tmp_dir/hold-started" ]]
maint_run_id=12-concurrent
make_calls=$(wc -l < "$calls/make" | tr -d ' ')
if run_maint > "$tmp_dir/concurrent.out" 2> "$tmp_dir/concurrent.err"; then
    printf 'concurrent maintenance run unexpectedly succeeded\n' >&2
    exit 1
fi
grep -q 'reason=already_running' "$tmp_dir/concurrent.out"
grep -q 'another maintenance run holds the lock' "$tmp_dir/concurrent.err"
[[ $(wc -l < "$calls/make" | tr -d ' ') == "$make_calls" ]]
wait "$holder_pid"

# A stale lock whose PID now belongs to an unrelated live process is reclaimed.
printf '%s\tstale-boot\tstale-start\tstale-token\n' "$$" > "$state_dir/run.lock"
maint_run_id=13-stale-lock
stale_lock=$(run_maint)
grep -q 'status=ok' <<< "$stale_lock"

# A state-directory ENOSPC is reported to the journal with a failed status even
# though no raw report can be written on the full filesystem.
maint_run_id=14-disk-full
if MAINT_TEST_DISK_FULL=1 run_maint > "$tmp_dir/disk-full.out" 2> "$tmp_dir/disk-full.err"; then
    printf 'disk-full maintenance run unexpectedly succeeded\n' >&2
    exit 1
fi
grep -q 'status=failed' "$tmp_dir/disk-full.out"
grep -q 'reason=internal_error' "$tmp_dir/disk-full.out"
grep -q 'No space left on device' "$tmp_dir/disk-full.err"
grep -q 'unexpected failure' "$tmp_dir/disk-full.err"

printf 'maintenance gather, compare, and run tests passed\n'
