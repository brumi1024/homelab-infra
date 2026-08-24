#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

die() {
    printf 'run: %s\n' "$*" >&2
    exit 1
}

repo_root=${MAINT_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
state_dir=${MAINT_STATE_DIR:-$HOME/.local/state/maint}
vault_dir=${MAINT_VAULT_DIR:-$HOME/projects/agentic-notes}
run_date=${MAINT_RUN_DATE:-$(date -u +%F)}
run_id=${MAINT_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}

[[ "$run_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "invalid MAINT_RUN_DATE: $run_date"
[[ "$run_id" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid MAINT_RUN_ID: $run_id"

raw_root=$state_dir/$run_date/raw
current=$raw_root/$run_id
mkdir -p "$raw_root"
[[ ! -e "$current" ]] || die "run directory already exists: $current"

latest_run() {
    local result
    result=$(find "$state_dir" -type f -name manifest.tsv -print 2>/dev/null \
        | sed 's#/manifest.tsv$##' | LC_ALL=C sort | tail -n 1 || true)
    printf '%s\n' "$result"
}

previous=$(latest_run)

MAINT_REPO_DIR="$repo_root" MAINT_RUN_DATE="$run_date" MAINT_RUN_ID="$run_id" \
    "$repo_root/scripts/maint/gather.sh" "$current" >/dev/null

set +e
"$repo_root/scripts/maint/compare.sh" "$current" "$previous"
compare_status=$?
set -e

diff_file=$current/diff.patch
failed_file=$current/failed-checks.tsv
needs_model=0
if [[ -s "$diff_file" || -s "$failed_file" ]]; then
    needs_model=1
fi
if [[ -z "$previous" && ! -s "$failed_file" ]]; then
    needs_model=0
    compare_status=0
fi

reports_dir=$vault_dir/Infra/reports
mkdir -p "$reports_dir"

status=ok
summary='No maintenance changes detected.'
verdict_file=$current/verdict.json

previous_report=$(find "$reports_dir" -type f -name '*-maint.md' -print 2>/dev/null \
    | LC_ALL=C sort | tail -n 1 || true)
overview_file=$(find "$vault_dir" -type f -iname 'Homelab Overview.md' -print 2>/dev/null \
    | LC_ALL=C sort | head -n 1 || true)

if (( needs_model == 1 )); then
    evidence=$current/evidence.txt
    {
        printf 'Run date: %s\n' "$run_date"
        printf 'Current raw evidence directory: %s\n\n' "$current"
        printf '%s\n' '<normalized-diff>'
        if [[ -s "$diff_file" ]]; then
            cat "$diff_file"
        else
            printf '%s\n' '(none)'
        fi
        printf '%s\n\n' '</normalized-diff>'
        printf '%s\n' '<failed-checks>'
        if [[ -s "$failed_file" ]]; then
            while IFS=$'\t' read -r check_name check_status; do
                check_safe=$(printf '%s' "$check_name" | tr -cs '[:alnum:]._-' '_')
                printf '[%s] %s\n' "$check_status" "$check_name"
                if [[ -r "$current/checks/$check_safe.out" ]]; then
                    cat "$current/checks/$check_safe.out"
                fi
                printf '\n'
            done < "$failed_file"
        else
            printf '%s\n' '(none)'
        fi
        printf '%s\n\n' '</failed-checks>'
        printf '%s\n' '<previous-report>'
        if [[ -n "$previous_report" && -r "$previous_report" ]]; then
            cat "$previous_report"
        else
            printf '%s\n' '(none)'
        fi
        printf '%s\n\n' '</previous-report>'
        printf '%s\n' '<homelab-overview>'
        if [[ -n "$overview_file" && -r "$overview_file" ]]; then
            cat "$overview_file"
        else
            printf '%s\n' '(not available)'
        fi
        printf '%s\n' '</homelab-overview>'
    } > "$evidence"

    interpret=${MAINT_INTERPRET_BIN:-$repo_root/scripts/maint/interpret.sh}
    prompt_file=${MAINT_PROMPT_FILE:-$repo_root/scripts/maint/prompt.md}
    schema_file=${MAINT_SCHEMA_FILE:-$repo_root/scripts/maint/verdict.schema.json}
    if [[ ! -x "$interpret" ]]; then
        status=failed
        summary='Maintenance interpreter is not executable.'
    elif "$interpret" "$prompt_file" "$schema_file" < "$evidence" > "$verdict_file" 2> "$current/interpreter.err"; then
        if jq -e '.status == "ok" or .status == "attention" or .status == "failed"' "$verdict_file" >/dev/null 2>&1; then
            status=$(jq -r '.status' "$verdict_file")
            summary=$(jq -r '.summary' "$verdict_file")
        else
            status=failed
            summary='Maintenance interpreter returned an invalid verdict.'
        fi
    else
        status=failed
        summary='Maintenance interpreter failed; inspect the saved evidence and interpreter error.'
    fi
elif (( compare_status != 0 )); then
    status=failed
    summary='Maintenance comparison failed before interpretation.'
fi

summary_one_line=$(printf '%s' "$summary" | tr '\r\n' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
printf -- '- %s: %s - %s\n' "$run_date" "$status" "$summary_one_line" >> "$reports_dir/index.md"

if [[ "$status" != ok ]]; then
    report=$reports_dir/$run_date-maint.md
    {
        printf '# Homelab maintenance report - %s\n\n' "$run_date"
        printf "Status: \`%s\`.\n\n" "$status"
        printf 'Summary: %s\n\n' "$summary_one_line"
        if [[ -r "$verdict_file" ]] && jq -e '.changes | type == "array"' "$verdict_file" >/dev/null 2>&1; then
            printf '## Changes\n\n'
            jq -r '.changes[]? | "- \(.host): \(.what) (\(.evidence))"' "$verdict_file"
            printf '\n## Stale notes\n\n'
            jq -r '.stale_notes[]? | "- \(.note): \(.claim) versus \(.observed)"' "$verdict_file"
            printf '\n## Suggested actions\n\n'
            jq -r '.suggested_actions[]? | "- " + .' "$verdict_file"
        else
            printf "Evidence: \`%s\`.\n" "$current"
            if [[ -s "$current/interpreter.err" ]]; then
                printf "Interpreter error was saved at \`%s\`.\n" "$current/interpreter.err"
            fi
        fi
    } > "$report"

    if [[ -n ${MAINT_NTFY_URL:-} ]]; then
        if command -v curl >/dev/null 2>&1; then
            curl --fail --silent --show-error -X POST \
                -H "Title: homelab $status" \
                --data-binary "$summary_one_line" "$MAINT_NTFY_URL" >/dev/null ||
                printf 'run: ntfy notification failed\n' >&2
        else
            printf 'run: curl is required for ntfy notification\n' >&2
        fi
    fi
fi

printf 'status=%s\n' "$status"
printf 'run=%s\n' "$current"
printf 'model_called=%s\n' "$needs_model"

if [[ "$status" == failed ]]; then
    exit 1
fi
