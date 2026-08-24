#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script=$repo_root/scripts/maint/interpret.sh
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/homelab-interpret-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

prompt=$tmp_dir/prompt.md
schema=$tmp_dir/schema.json
fake_claude=$tmp_dir/claude
fake_codex=$tmp_dir/codex
fake_curl=$tmp_dir/curl

cat > "$prompt" <<'EOF'
Return the evidence verdict as the requested JSON object.
EOF
cat > "$schema" <<'EOF'
{
  "type": "object",
  "properties": {
    "status": {"type": "string", "enum": ["ok", "attention", "failed"]},
    "summary": {"type": "string"}
  },
  "required": ["status", "summary"],
  "additionalProperties": false
}
EOF
cat > "$fake_claude" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args=$*
[[ "$args" == *"--bare"* ]]
[[ "$args" == *"--allowedTools Read,Grep,Glob"* ]]
[[ "$args" == *"--output-format json"* ]]
[[ "$args" == *"--json-schema"* ]]
[[ "$args" == *"--max-budget-usd"* ]]
input=$(cat)
[[ "$input" == *"<evidence-bundle>"* ]]
if [[ ${MAINT_FAKE_RESULT:-valid} == invalid ]]; then
    printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":0.01,"structured_output":{"status":"bad"}}'
elif [[ ${MAINT_FAKE_RESULT:-valid} == over-budget ]]; then
    printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":0.51,"structured_output":{"status":"ok","summary":"test"}}'
else
    printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":0.01,"structured_output":{"status":"ok","summary":"test"}}'
fi
EOF
cat > "$fake_codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args=$*
[[ "$args" == *"--sandbox read-only"* ]]
[[ "$args" == *"--output-schema"* ]]
[[ "$args" == *"--ephemeral"* ]]
[[ "$args" == *"--ignore-user-config"* ]]
[[ "$args" == *"--ignore-rules"* ]]
input=$(cat)
[[ "$input" == *"<evidence-bundle>"* ]]
printf '%s\n' '{"status":"ok","summary":"test"}'
EOF
cat > "$fake_curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args=$*
[[ "$args" == *"/v1/chat/completions"* ]]
request_path=
for argument in "$@"; do
    if [[ "$argument" == @*request.json ]]; then
        request_path=${argument#@}
    fi
done
[[ -r "$request_path" ]]
jq -e '.messages[0].content | contains("<evidence-bundle>") and contains("<output-schema>")' "$request_path" >/dev/null
if [[ ${MAINT_FAKE_RESULT:-valid} == invalid ]]; then
    content='not json'
else
    content='{"status":"ok","summary":"test"}'
fi
jq -n --arg content "$content" '{choices:[{message:{content:$content}}]}'
EOF
chmod +x "$fake_claude" "$fake_codex" "$fake_curl"

claude_output=$(printf '%s\n' 'synthetic evidence' | \
    MAINT_BACKEND=claude MAINT_CLAUDE_BIN="$fake_claude" MAINT_TIMEOUT_SECONDS=10 \
    "$script" "$prompt" "$schema")
[[ $(jq -r '.status' <<<"$claude_output") == ok ]]
[[ $(jq -r '.summary' <<<"$claude_output") == test ]]

codex_output=$(printf '%s\n' 'synthetic evidence' | \
    MAINT_BACKEND=codex MAINT_CODEX_BIN="$fake_codex" MAINT_TIMEOUT_SECONDS=10 \
    "$script" "$prompt" "$schema")
[[ $(jq -r '.status' <<<"$codex_output") == ok ]]
[[ $(jq -r '.summary' <<<"$codex_output") == test ]]

hermes_output=$(printf '%s\n' 'synthetic evidence' | \
    MAINT_BACKEND=hermes MAINT_CURL_BIN="$fake_curl" MAINT_TIMEOUT_SECONDS=10 \
    "$script" "$prompt" "$schema")
[[ $(jq -r '.status' <<<"$hermes_output") == ok ]]
[[ $(jq -r '.summary' <<<"$hermes_output") == test ]]

local_output=$(printf '%s\n' 'synthetic evidence' | \
    MAINT_BACKEND=local MAINT_OPENAI_MODEL=test-local MAINT_CURL_BIN="$fake_curl" \
    MAINT_TIMEOUT_SECONDS=10 "$script" "$prompt" "$schema")
[[ $(jq -r '.status' <<<"$local_output") == ok ]]
[[ $(jq -r '.summary' <<<"$local_output") == test ]]

if printf '%s\n' 'synthetic evidence' | \
    MAINT_BACKEND=claude MAINT_CLAUDE_BIN="$fake_claude" MAINT_FAKE_RESULT=invalid \
    MAINT_TIMEOUT_SECONDS=10 "$script" "$prompt" "$schema" >/dev/null 2>&1; then
    printf 'invalid structured output unexpectedly succeeded\n' >&2
    exit 1
fi

if printf '%s\n' 'synthetic evidence' | \
    MAINT_BACKEND=claude MAINT_CLAUDE_BIN="$fake_claude" MAINT_FAKE_RESULT=over-budget \
    MAINT_TIMEOUT_SECONDS=10 "$script" "$prompt" "$schema" >/dev/null 2>&1; then
    printf 'budget breach unexpectedly succeeded\n' >&2
    exit 1
fi

if printf '%s\n' 'synthetic evidence' | \
    MAINT_BACKEND=hermes MAINT_CURL_BIN="$fake_curl" MAINT_FAKE_RESULT=invalid \
    MAINT_TIMEOUT_SECONDS=10 "$script" "$prompt" "$schema" >/dev/null 2>&1; then
    printf 'invalid OpenAI-compatible output unexpectedly succeeded\n' >&2
    exit 1
fi

printf 'interpret harness tests passed\n'
