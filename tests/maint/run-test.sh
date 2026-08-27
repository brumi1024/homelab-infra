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
counter_file=$tmp_dir/counter
mkdir -p "$fake_bin" "$fake_repo/.git" "$vault_dir" "$calls"
printf 'clean\n' > "$mode_file"
printf '0\n' > "$counter_file"

cat > "$fake_bin/make" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
mode=$(cat "$MAINT_TEST_MODE_FILE")
counter=$(cat "$MAINT_TEST_COUNTER_FILE")
counter=$((counter + 1))
printf '%s\n' "$counter" > "$MAINT_TEST_COUNTER_FILE"
second=$((counter % 9))
printf 'timestamp=2026-08-24T06:30:0%sZ duration=%ss run=%s count=%s\n' "$second" "$counter" "$counter" "$counter"
if [[ "$mode" == changed && "$*" == *TAGS=security* ]]; then
    printf 'meaningful state changed\n'
fi
if [[ "$mode" == failed && "$1" == verify && "$*" == *TAGS=security* ]]; then
    exit 1
fi
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
    shift 2
    case "$1 ${2:-}" in
        "rev-parse --git-dir") printf '.git\n' ;;
        "pull --ff-only") ;;
        "add --") ;;
        "diff --cached") exit 1 ;;
        "commit -m") ;;
        "push ") ;;
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
case $(cat "$MAINT_TEST_MODE_FILE") in
    failed) status=failed; summary='synthetic failed check' ;;
    *) status=attention; summary='synthetic change' ;;
esac
printf '%s\n' "{\"status\":\"$status\",\"summary\":\"$summary\",\"changes\":[{\"host\":\"test\",\"what\":\"fixture changed\",\"evidence\":\"fixture\"}],\"stale_notes\":[],\"suggested_actions\":[\"review the fixture\"]}"
EOF

chmod +x "$fake_bin"/* "$tmp_dir/interpret"
: > "$calls/interpreter"
: > "$calls/curl"
: > "$calls/git"

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
        MAINT_INTERPRET_BIN="$tmp_dir/interpret" \
        MAINT_TEST_MODE_FILE="$mode_file" \
        MAINT_TEST_COUNTER_FILE="$counter_file" \
        MAINT_TEST_INTERPRET_LOG="$calls/interpreter" \
        MAINT_NTFY_URL=https://ntfy.invalid/homelab \
        MAINT_TEST_CURL_LOG="$calls/curl" \
        MAINT_TEST_GIT_LOG="$calls/git" \
        "$repo_root/scripts/maint/run.sh"
}

first=$(run_maint)
[[ "$first" == *'status=ok'* ]]
[[ "$first" == *'model_called=0'* ]]
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
quiet_run=$(run_maint)
[[ "$quiet_run" == *'status=ok'* ]]
[[ "$quiet_run" == *'model_called=0'* ]]
[[ $(wc -l < "$calls/interpreter" | tr -d ' ') == 1 ]]

quiet_dir=$(find "$state_dir" -type f -name manifest.tsv -print | sed 's#/manifest.tsv$##' | LC_ALL=C sort | tail -n 1)
[[ ! -s "$quiet_dir/diff.patch" ]]

printf 'failed\n' > "$mode_file"
if run_maint > "$tmp_dir/fourth.out"; then
    printf 'failed verdict unexpectedly returned success\n' >&2
    exit 1
fi
grep -q 'status=failed' "$tmp_dir/fourth.out"
[[ $(wc -l < "$calls/interpreter" | tr -d ' ') == 2 ]]
[[ $(wc -l < "$calls/curl" | tr -d ' ') == 2 ]]

printf 'maintenance gather, compare, and run tests passed\n'
