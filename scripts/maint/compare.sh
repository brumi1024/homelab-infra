#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

die() {
    printf 'compare: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: scripts/maint/compare.sh CURRENT_DIR [PREVIOUS_DIR]

Normalize check output, write CURRENT_DIR/diff.patch and
CURRENT_DIR/failed-checks.tsv, and return 1 when attention is needed.
EOF
    exit 2
}

(( $# == 1 || $# == 2 )) || usage

current=$1
previous=${2:-}
[[ -d "$current" ]] || die "current directory does not exist: $current"
[[ -z "$previous" || -d "$previous" ]] || die "previous directory does not exist: $previous"
[[ -r "$current/manifest.tsv" ]] || die "current manifest is missing: $current/manifest.tsv"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/homelab-maint-compare.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

normalize_file() {
    local source=$1

    sed -E \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?/<timestamp>/g' \
        -e 's/[0-9]+([.][0-9]+)?[[:space:]]*(ms|msec|msecs|s|sec|secs|second|seconds|min|mins|minute|minutes|h|hr|hrs|hour|hours)([^[:alnum:]_]|$)/<duration>\3/g' \
        -e 's/([Rr]un|[Aa]ttempt|[Rr]equest|[Jj]ob|[Ee]xecution|[Ss]equence|[Cc]ounter|[Cc]ount|[Tt]otal|[Nn]umber)[[:space:]]*[:=][[:space:]]*[0-9]+/\1=<counter>/g' \
        "$source"
}

# Snapshot the gathered evidence only. run.sh writes its own artifacts into the
# same directory, and evidence.txt embeds the previous run's diff, so comparing
# a whole run directory folds every earlier run into the next one's diff and the
# bundle grows without bound. An allowlist cannot rot as new artifacts appear.
snapshot() {
    local source_dir=$1
    local destination=$2
    local file
    local relative
    local -a sources=()

    if [[ -d "$source_dir/checks" ]]; then
        sources+=("$source_dir/checks")
    fi
    if [[ -f "$source_dir/manifest.tsv" ]]; then
        sources+=("$source_dir/manifest.tsv")
    fi

    : > "$destination"
    (( ${#sources[@]} > 0 )) || return 0

    while IFS= read -r file; do
        relative=${file#"$source_dir/"}
        printf '%s\n' "--- $relative" >> "$destination"
        normalize_file "$file" >> "$destination"
    done < <(find "${sources[@]}" -type f -print | LC_ALL=C sort)
}

current_snapshot=$tmp_dir/current.snapshot
previous_snapshot=$tmp_dir/previous.snapshot
snapshot "$current" "$current_snapshot"

if [[ -n "$previous" ]]; then
    [[ -r "$previous/manifest.tsv" ]] || die "previous manifest is missing: $previous/manifest.tsv"
    snapshot "$previous" "$previous_snapshot"
else
    : > "$previous_snapshot"
fi

diff_file=$current/diff.patch
if diff -u -L previous.snapshot -L current.snapshot "$previous_snapshot" "$current_snapshot" > "$diff_file"; then
    : > "$diff_file"
else
    diff_status=$?
    if (( diff_status != 1 )); then
        die "diff failed with status $diff_status"
    fi
fi

failed_file=$current/failed-checks.tsv
awk -F '\t' 'NR > 1 && $2 != "0" && $2 != "skip" { print }' "$current/manifest.tsv" > "$failed_file"

if [[ -s "$diff_file" || -s "$failed_file" ]]; then
    exit 1
fi
exit 0
