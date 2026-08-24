#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

die() {
    printf 'gather: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: scripts/maint/gather.sh OUTPUT_DIR

Run the read-only maintenance checks and store their output under OUTPUT_DIR.
EOF
    exit 2
}

(( $# == 1 )) || usage

output_dir=$1
repo_root=${MAINT_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
projects_dir=${MAINT_PROJECTS_DIR:-$HOME/projects}
run_date=${MAINT_RUN_DATE:-$(date -u +%F)}
run_id=${MAINT_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}
verify_tags=${MAINT_VERIFY_TAGS:-security reliability dns komodo proxmox}
repos=${MAINT_REPOS:-homelab-infra:komodo-app-stacks:komodo-resource-syncs:deploy-komodo-op}

[[ -d "$repo_root" ]] || die "repository does not exist: $repo_root"
mkdir -p "$output_dir/checks"

manifest=$output_dir/manifest.tsv
printf 'name\tstatus\n' > "$manifest"

safe_name() {
    printf '%s' "$1" | tr -cs '[:alnum:]. _-' '_' | tr ' ' '_'
}

record_skip() {
    local name=$1
    local reason=$2
    local safe

    safe=$(safe_name "$name")
    printf 'skipped: %s\n' "$reason" > "$output_dir/checks/$safe.out"
    printf 'skip\n' > "$output_dir/checks/$safe.status"
    printf '%s\tskip\n' "$name" >> "$manifest"
}

run_check() {
    local name=$1
    local cwd=$2
    shift 2

    local safe
    local output
    local status

    safe=$(safe_name "$name")
    output=$output_dir/checks/$safe.out
    status=0
    if (cd "$cwd" && "$@") > "$output" 2>&1; then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "$status" > "$output_dir/checks/$safe.status"
    printf '%s\t%s\n' "$name" "$status" >> "$manifest"
}

run_tailscale() {
    local output=$output_dir/checks/tailscale-offline.out
    local status=0
    local json_file

    json_file=$(mktemp "${TMPDIR:-/tmp}/homelab-maint-tailscale.XXXXXX")
    trap 'rm -f "$json_file"' RETURN
    if tailscale status --json > "$json_file" 2>&1; then
        if command -v jq >/dev/null 2>&1; then
            if ! jq -c '
                (.Peer // {})
                | to_entries
                | map(select(.value.Online != true)
                    | {host: (.value.HostName // .key), online: false,
                       last_seen: (.value.LastSeen // "")})
            ' "$json_file" > "$output" 2>&1; then
                status=1
            fi
        else
            printf 'jq is required to extract offline peers\n' > "$output"
            status=1
        fi
    else
        status=$?
        cp "$json_file" "$output"
    fi
    rm -f "$json_file"
    trap - RETURN
    printf '%s\n' "$status" > "$output_dir/checks/tailscale-offline.status"
    printf 'tailscale-offline\t%s\n' "$status" >> "$manifest"
}

run_dashboard_issue() {
    local dashboard_repo=$1
    local output=$output_dir/checks/renovate-dashboard.out
    local status=0
    local issue_number
    local issue_search=${MAINT_RENOVATE_ISSUE_SEARCH:-Renovate dashboard}

    if [[ ! -d "$dashboard_repo" ]]; then
        record_skip renovate-dashboard "dashboard repository is not present"
        return
    fi

    if [[ -n ${MAINT_RENOVATE_ISSUE:-} ]]; then
        issue_number=$MAINT_RENOVATE_ISSUE
    else
        issue_number=$(cd "$dashboard_repo" && gh issue list --state open --search "$issue_search" --limit 1 --json number --jq '.[0].number' 2>/dev/null) || status=$?
    fi

    if (( status != 0 )); then
        printf 'unable to find Renovate dashboard issue\n' > "$output"
    elif [[ -z "$issue_number" || "$issue_number" == null ]]; then
        printf 'No matching Renovate dashboard issue found.\n' > "$output"
    elif (cd "$dashboard_repo" && gh issue view "$issue_number" --json body --jq .body) > "$output" 2>&1; then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "$status" > "$output_dir/checks/renovate-dashboard.status"
    printf 'renovate-dashboard\t%s\n' "$status" >> "$manifest"
}

run_check verify "$repo_root" make verify
for tag in $verify_tags; do
    run_check "verify-$tag" "$repo_root" make verify "TAGS=$tag"
done
run_check lint "$repo_root" make lint
run_check inventory-graph "$repo_root/ansible" ansible-inventory -i inventory/hosts.yml --graph
run_tailscale

if [[ ${MAINT_SKIP_REPOS:-0} == 1 ]]; then
    record_skip repositories 'repository checks disabled by MAINT_SKIP_REPOS'
else
    old_ifs=$IFS
    IFS=:
    read -r -a repo_list <<< "$repos"
    IFS=$old_ifs
    for repo_spec in "${repo_list[@]}"; do
        if [[ "$repo_spec" == */* ]]; then
            repo_path=$repo_spec
        else
            repo_path=$projects_dir/$repo_spec
        fi
        repo_name=$(safe_name "${repo_spec##*/}")
        if [[ ! -d "$repo_path/.git" ]]; then
            record_skip "repo-$repo_name" "repository is not present: $repo_path"
            continue
        fi
        run_check "repo-$repo_name-fetch" "$repo_path" git fetch --dry-run
        run_check "repo-$repo_name-status" "$repo_path" git status --short --branch
        run_check "repo-$repo_name-renovate" "$repo_path" gh pr list --author app/renovate --state open
    done
fi

if [[ ${MAINT_SKIP_DASHBOARD:-0} == 1 ]]; then
    record_skip renovate-dashboard 'dashboard check disabled by MAINT_SKIP_DASHBOARD'
else
    dashboard_repo=${MAINT_DASHBOARD_REPO:-$projects_dir/komodo-app-stacks}
    run_dashboard_issue "$dashboard_repo"
fi

if [[ ${MAINT_SKIP_HA:-0} == 1 ]]; then
    record_skip home-assistant 'Home Assistant checks disabled by MAINT_SKIP_HA'
else
    ha_repo=${MAINT_HA_REPO_DIR:-$projects_dir/ha-config}
    hactl_bin=${MAINT_HACTL_BIN:-hactl}
    if [[ ! -d "$ha_repo" || ! -x "$hactl_bin" && -z $(command -v "$hactl_bin" 2>/dev/null || true) ]]; then
        record_skip home-assistant 'Home Assistant repository or hactl is not present'
    else
        run_check home-drift "$ha_repo" "$hactl_bin" drift -i home
        run_check sequoia-drift "$ha_repo" "$hactl_bin" drift -i sequoia
        run_check home-validate "$ha_repo" "$hactl_bin" validate -i home
        run_check sequoia-validate "$ha_repo" "$hactl_bin" validate -i sequoia
    fi
fi

cat > "$output_dir/meta.json" <<EOF
{
  "schema_version": 1,
  "run_date": "$run_date",
  "run_id": "$run_id"
}
EOF

printf '%s\n' "$output_dir"
