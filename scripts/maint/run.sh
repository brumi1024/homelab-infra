#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

die() {
    printf 'run: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'run: %s\n' "$*" >&2
}

notify() {
    local notification_status=$1
    local notification_summary=$2

    [[ -n ${MAINT_NTFY_URL:-} ]] || return 0
    if ! command -v curl >/dev/null 2>&1; then
        warn 'curl is required for ntfy notification'
        return 0
    fi
    curl --fail --silent --show-error -X POST \
        -H "Title: homelab $notification_status" \
        --data-binary "$notification_summary" "$MAINT_NTFY_URL" >/dev/null ||
        warn 'ntfy notification failed'
}

lock_file=
lock_candidate=
lock_backend=
lock_fd=
lock_held=0
index_tmp=
report_tmp=

cleanup() {
    local rc=$?

    [[ -z "$index_tmp" ]] || rm -f "$index_tmp"
    [[ -z "$report_tmp" ]] || rm -f "$report_tmp"
    if (( lock_held == 1 )); then
        if [[ "$lock_backend" == flock ]]; then
            flock -u "$lock_fd" 2>/dev/null || warn "could not release maintenance lock: $lock_file"
            exec {lock_fd}>&-
        elif cmp -s "$lock_candidate" "$lock_file"; then
            rm -f "$lock_file"
        fi
    fi
    [[ -z "$lock_candidate" ]] || rm -f "$lock_candidate"
    return "$rc"
}

error_reported=0
on_error() {
    local rc=$?
    local line=$1

    trap - ERR
    if (( error_reported == 0 )); then
        error_reported=1
        warn "unexpected failure at line $line (exit $rc)"
        printf 'status=failed\n'
        printf 'reason=internal_error\n'
        [[ -z ${current:-} ]] || printf 'run=%s\n' "$current"
        printf 'model_called=%s\n' "${needs_model:-0}"
        notify failed 'Maintenance run failed before completion.'
    fi
    exit "$rc"
}

trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

repo_root=${MAINT_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
state_dir=${MAINT_STATE_DIR:-$HOME/.local/state/maint}
vault_dir=${MAINT_VAULT_DIR:-$HOME/projects/agentic-notes}
run_date=${MAINT_RUN_DATE:-$(date -u +%F)}
run_id=${MAINT_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}

[[ "$run_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "invalid MAINT_RUN_DATE: $run_date"
[[ "$run_id" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid MAINT_RUN_ID: $run_id"

raw_root=$state_dir/$run_date/raw
current=$raw_root/$run_id
mkdir -p "$state_dir"

boot_id() {
    local detected=

    if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        detected=$(tr -d '\r\n\t ' < /proc/sys/kernel/random/boot_id)
    elif command -v sysctl >/dev/null 2>&1; then
        detected=$(sysctl -n kern.boottime 2>/dev/null | tr -d '\r\n\t ' || true)
    fi
    printf '%s\n' "${detected:-unknown-boot}"
}

process_start_id() {
    local process_id=$1
    local detected=

    if [[ -r "/proc/$process_id/stat" ]]; then
        detected=$(awk '{ print $22 }' "/proc/$process_id/stat" 2>/dev/null || true)
    else
        detected=$(ps -o lstart= -p "$process_id" 2>/dev/null | tr -s ' ' '_' | tr -d '\r\n\t' || true)
    fi
    printf '%s\n' "${detected:-pid-$process_id}"
}

lock_owner_is_live() {
    local holder_pid=
    local holder_boot=
    local holder_start=
    local holder_token=
    local current_boot
    local current_start

    [[ -r "$lock_file" ]] || return 1
    IFS=$'\t' read -r holder_pid holder_boot holder_start holder_token < "$lock_file" || return 1
    [[ "$holder_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -n "$holder_boot" && -n "$holder_start" && -n "$holder_token" ]] || return 1
    kill -0 "$holder_pid" 2>/dev/null || return 1
    current_boot=$(boot_id)
    current_start=$(process_start_id "$holder_pid")
    [[ -n "$current_boot" && "$holder_boot" == "$current_boot" ]] || return 1
    [[ -n "$current_start" && "$holder_start" == "$current_start" ]]
}

acquire_lock() {
    local self_boot
    local self_start

    lock_file=$state_dir/run.lock
    if command -v flock >/dev/null 2>&1; then
        exec {lock_fd}>> "$lock_file"
        if flock -n "$lock_fd"; then
            lock_backend=flock
            lock_held=1
            return 0
        fi
        exec {lock_fd}>&-
        return 1
    fi

    lock_candidate=$state_dir/.run.lock.$run_id.$$
    self_boot=$(boot_id)
    self_start=$(process_start_id $$)
    [[ -n "$self_boot" && -n "$self_start" ]] || die 'cannot identify the maintenance lock owner'
    printf '%s\t%s\t%s\t%s\n' "$$" "$self_boot" "$self_start" "$run_id" > "$lock_candidate"

    for _ in 1 2; do
        if ln "$lock_candidate" "$lock_file" 2>/dev/null; then
            lock_held=1
            return 0
        fi
        [[ -e "$lock_file" ]] || die "cannot create maintenance lock: $lock_file"
        lock_owner_is_live && return 1
        rm -f "$lock_file"
    done
    return 1
}

if ! acquire_lock; then
    warn "another maintenance run holds the lock: $lock_file"
    printf 'status=failed\n'
    printf 'reason=already_running\n'
    printf 'model_called=0\n'
    trap - ERR
    exit 75
fi

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

if "$repo_root/scripts/maint/compare.sh" "$current" "$previous"; then
    compare_status=0
else
    compare_status=$?
fi

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

reports_dir=$vault_dir/Reports
publish_status=skipped
publish_summary=
publish_failure_stage=
vault_publish_ready=0

vault_git() {
    git -C "$vault_dir" "$@"
}

prepare_vault() {
    if [[ ${MAINT_SKIP_VAULT_PUBLISH:-0} == 1 ]]; then
        publish_status=skipped
        publish_summary='Vault publishing was disabled by MAINT_SKIP_VAULT_PUBLISH.'
        return 0
    fi
    if ! command -v git >/dev/null 2>&1; then
        publish_status=failed
        publish_failure_stage=prepare
        publish_summary='Vault publishing failed because git is unavailable.'
        warn "$publish_summary"
        return 0
    fi
    if ! vault_git rev-parse --git-dir >/dev/null 2>&1; then
        publish_status=failed
        publish_failure_stage=prepare
        publish_summary='Vault publishing failed because MAINT_VAULT_DIR is not a git checkout.'
        warn "$publish_summary"
        return 0
    fi
    if ! vault_git pull --ff-only >/dev/null 2>&1; then
        publish_status=failed
        publish_failure_stage=pull
        publish_summary='Vault pull --ff-only failed; the run kept its report local and did not modify the vault.'
        warn "$publish_summary"
        return 0
    fi
    publish_status=pending
    vault_publish_ready=1
}

prepare_vault
if (( vault_publish_ready == 0 )); then
    reports_dir=$current/reports
fi

publish_reports() {
    (( vault_publish_ready == 1 )) || return 0
    if ! vault_git add -- Reports >/dev/null 2>&1; then
        publish_status=failed
        publish_failure_stage=add
        publish_summary='Vault add failed; the report remains uncommitted in the local checkout.'
        warn "$publish_summary"
        return 0
    fi
    if vault_git diff --cached --quiet -- Reports; then
        publish_status=ok
        return 0
    fi
    if ! vault_git commit -m "Record maintenance run $run_date" -- Reports >/dev/null 2>&1; then
        publish_status=failed
        publish_failure_stage=commit
        publish_summary='Vault commit failed; the report remains staged in the local checkout.'
        warn "$publish_summary"
        return 0
    fi
    if ! vault_git push >/dev/null 2>&1; then
        publish_status=failed
        publish_failure_stage=push
        publish_summary='Vault push failed; the maintenance commit is local and must be reconciled.'
        warn "$publish_summary"
        return 0
    fi
    publish_status=ok
}

mkdir -p "$reports_dir"

status=ok
summary='No maintenance changes detected.'
verdict_file=$current/verdict.json

previous_report=
overview_file=
if [[ "$publish_status" != failed ]]; then
    previous_report=$(find "$vault_dir/Reports" -type f -name '*-maint.md' -print 2>/dev/null \
        | LC_ALL=C sort | tail -n 1 || true)
    overview_file=$(find "$vault_dir" -type f -iname 'Homelab Overview.md' -print 2>/dev/null \
        | LC_ALL=C sort | head -n 1 || true)
fi

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

if [[ -s "$failed_file" && "$status" != failed ]]; then
    status=failed
    summary="One or more maintenance checks failed. $summary"
fi

summary_one_line=$(printf '%s' "$summary" | tr '\r\n' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

index_base=$current/reports-index-before.md
if [[ -r "$reports_dir/index.md" ]]; then
    cp "$reports_dir/index.md" "$index_base"
else
    : > "$index_base"
fi

report=
write_report_artifacts() {
    local artifact_status=$status
    local artifact_summary=$summary_one_line

    if [[ "$publish_status" == failed ]]; then
        artifact_status=failed
        artifact_summary=$publish_summary
    fi

    index_tmp=$(mktemp "$reports_dir/.index.${run_id}.XXXXXX")
    cat "$index_base" > "$index_tmp"
    printf -- '- %s: %s - %s\n' "$run_date" "$artifact_status" "$artifact_summary" >> "$index_tmp"
    mv "$index_tmp" "$reports_dir/index.md"
    index_tmp=

    if [[ "$artifact_status" == ok ]]; then
        return 0
    fi
    if [[ -z "$report" ]]; then
        report=$reports_dir/$run_date-maint.md
        if [[ -e "$report" ]]; then
            report=$reports_dir/$run_date-$run_id-maint.md
        fi
        [[ ! -e "$report" ]] || die "maintenance report already exists: $report"
    fi
    report_tmp=$(mktemp "$reports_dir/.maint-report.${run_id}.XXXXXX")
    {
        printf '# Homelab maintenance report - %s\n\n' "$run_date"
        printf "Status: \`%s\`.\n\n" "$artifact_status"
        printf 'Summary: %s\n\n' "$artifact_summary"
        if [[ "$publish_status" == failed ]]; then
            printf "Application status before publishing: \`%s\`.\n\n" "$status"
            printf 'Application summary: %s\n\n' "$summary_one_line"
        fi
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
    } > "$report_tmp"
    mv "$report_tmp" "$report"
    report_tmp=
}

write_report_artifacts
publish_reports

if [[ "$publish_status" == failed ]]; then
    write_report_artifacts
    if (( vault_publish_ready == 1 )); then
        if vault_git add -- Reports >/dev/null 2>&1; then
            if [[ "$publish_failure_stage" == push ]] &&
                ! vault_git commit --amend --no-edit -- Reports >/dev/null 2>&1; then
                warn 'Vault commit amendment failed; the corrected failure report remains staged.'
            fi
        else
            warn 'Vault add failed while recording the publishing failure; the corrected report remains unstaged.'
        fi
    fi
    status=failed
    summary_one_line=$publish_summary
fi

notification_status=$status
notification_summary=$summary_one_line
if [[ "$notification_status" != ok ]]; then
    notify "$notification_status" "$notification_summary"
fi

printf 'status=%s\n' "$status"
printf 'publish_status=%s\n' "$publish_status"
printf 'run=%s\n' "$current"
printf 'model_called=%s\n' "$needs_model"

if [[ "$status" == failed || "$publish_status" == failed ]]; then
    trap - ERR
    exit 1
fi
