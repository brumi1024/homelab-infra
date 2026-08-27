#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

die() {
    printf 'interpret: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: scripts/maint/interpret.sh PROMPT_FILE SCHEMA_FILE

Read an evidence bundle from stdin and emit the selected backend's
schema-conforming JSON result on stdout.
EOF
    exit 2
}

if (( $# != 2 )); then
    usage
fi

prompt_file=$1
schema_file=$2
[[ -r "$prompt_file" ]] || die "prompt file is not readable: $prompt_file"
[[ -r "$schema_file" ]] || die "schema file is not readable: $schema_file"

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

backend=${MAINT_BACKEND:-}
[[ -n "$backend" ]] || die 'MAINT_BACKEND must be set to claude, codex, hermes, or local'

max_budget=${MAINT_MAX_BUDGET_USD:-0.50}
timeout_seconds=${MAINT_TIMEOUT_SECONDS:-1200}

[[ "$max_budget" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "invalid MAINT_MAX_BUDGET_USD: $max_budget"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || die "invalid MAINT_TIMEOUT_SECONDS: $timeout_seconds"

case "$backend" in
    claude|codex|hermes|local)
        ;;
    *)
        die "unsupported MAINT_BACKEND: $backend"
        ;;
esac

schema_kind=$(jq -r 'if type == "boolean" then "boolean" elif type == "object" then "object" else "invalid" end' "$schema_file") || die 'schema is not valid JSON'
[[ "$schema_kind" != invalid ]] || die 'schema must be a JSON Schema object or boolean'

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/homelab-interpret.XXXXXX")
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

evidence_file=$tmp_dir/evidence
input_file=$tmp_dir/input
backend_stdout=$tmp_dir/backend.stdout
backend_stderr=$tmp_dir/backend.stderr
candidate_file=$tmp_dir/candidate.json

cat > "$evidence_file"
{
    cat "$prompt_file"
    printf '\n\n<evidence-bundle>\n'
    cat "$evidence_file"
    printf '\n</evidence-bundle>\n'
} > "$input_file"

resolve_binary() {
    local requested=$1
    if [[ "$requested" == */* ]]; then
        [[ -x "$requested" ]] || die "backend executable is not executable: $requested"
        printf '%s\n' "$requested"
    else
        command -v "$requested" || die "backend executable not found: $requested"
    fi
}

run_with_timeout() {
    local -a command=("$@")
    local timeout_bin

    timeout_bin=$(command -v timeout || command -v gtimeout || true)
    [[ -n "$timeout_bin" ]] || die 'timeout or gtimeout is required for bounded backend runs'

    "$timeout_bin" --signal=TERM --kill-after=5 "$timeout_seconds" "${command[@]}" \
        < "$input_file" > "$backend_stdout" 2> "$backend_stderr"
}

validate_candidate() {
    python3 - "$schema_file" "$candidate_file" <<'PY'
import json
import re
import sys
from typing import Any


class ValidationError(Exception):
    pass


def json_pointer(root: Any, pointer: str) -> Any:
    value = root
    if pointer == "":
        return value
    if not pointer.startswith("/"):
        raise ValidationError(f"unsupported reference: #{pointer}")
    for part in pointer[1:].split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        try:
            value = value[int(part)] if isinstance(value, list) else value[part]
        except (IndexError, KeyError, TypeError, ValueError) as exc:
            raise ValidationError(f"unresolved reference: #{pointer}") from exc
    return value


def type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    return False


def validate(value: Any, schema: Any, root: Any, path: str = "$") -> None:
    if schema is True:
        return
    if schema is False:
        raise ValidationError(f"{path}: schema rejects this value")
    if not isinstance(schema, dict):
        raise ValidationError(f"{path}: schema must be an object or boolean")

    if "$ref" in schema:
        ref = schema["$ref"]
        if not isinstance(ref, str) or not ref.startswith("#"):
            raise ValidationError(f"{path}: only local JSON Schema references are supported")
        validate(value, json_pointer(root, ref[1:]), root, path)

    if "type" in schema:
        expected = schema["type"]
        expected_types = expected if isinstance(expected, list) else [expected]
        if not any(isinstance(item, str) and type_matches(value, item) for item in expected_types):
            raise ValidationError(f"{path}: expected type {expected!r}")

    if "enum" in schema and not any(value == option and type(value) is type(option) for option in schema["enum"]):
        raise ValidationError(f"{path}: value is not in enum")
    if "const" in schema and not (value == schema["const"] and type(value) is type(schema["const"])):
        raise ValidationError(f"{path}: value does not match const")

    if "allOf" in schema:
        for subschema in schema["allOf"]:
            validate(value, subschema, root, path)
    if "anyOf" in schema:
        for subschema in schema["anyOf"]:
            try:
                validate(value, subschema, root, path)
                break
            except ValidationError:
                pass
        else:
            raise ValidationError(f"{path}: no anyOf branch matched")
    if "oneOf" in schema:
        matches = 0
        for subschema in schema["oneOf"]:
            try:
                validate(value, subschema, root, path)
                matches += 1
            except ValidationError:
                pass
        if matches != 1:
            raise ValidationError(f"{path}: expected oneOf to match exactly once")
    if "not" in schema:
        try:
            validate(value, schema["not"], root, path)
        except ValidationError:
            pass
        else:
            raise ValidationError(f"{path}: value matches a forbidden schema")

    if isinstance(value, dict):
        properties = schema.get("properties", {})
        if not isinstance(properties, dict):
            raise ValidationError(f"{path}: properties must be an object")
        required = schema.get("required", [])
        if not isinstance(required, list) or any(not isinstance(item, str) for item in required):
            raise ValidationError(f"{path}: required must be an array of strings")
        for name in required:
            if name not in value:
                raise ValidationError(f"{path}: missing required property {name!r}")
        for name, subschema in properties.items():
            if name in value:
                validate(value[name], subschema, root, f"{path}.{name}")
        additional = schema.get("additionalProperties", True)
        for name, item in value.items():
            if name in properties:
                continue
            if additional is False:
                raise ValidationError(f"{path}: unexpected property {name!r}")
            if isinstance(additional, (dict, bool)):
                validate(item, additional, root, f"{path}.{name}")
        patterns = schema.get("patternProperties", {})
        if isinstance(patterns, dict):
            for pattern, subschema in patterns.items():
                for name, item in value.items():
                    if re.search(pattern, name):
                        validate(item, subschema, root, f"{path}.{name}")

    if isinstance(value, list):
        items = schema.get("items")
        if isinstance(items, (dict, bool)):
            for index, item in enumerate(value):
                validate(item, items, root, f"{path}[{index}]")
        elif isinstance(items, list):
            for index, subschema in enumerate(items):
                if index < len(value):
                    validate(value[index], subschema, root, f"{path}[{index}]")
        if "minItems" in schema and len(value) < schema["minItems"]:
            raise ValidationError(f"{path}: fewer than minItems")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            raise ValidationError(f"{path}: more than maxItems")
        if schema.get("uniqueItems"):
            serialized = {json.dumps(item, sort_keys=True) for item in value}
            if len(serialized) != len(value):
                raise ValidationError(f"{path}: items are not unique")

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            raise ValidationError(f"{path}: shorter than minLength")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            raise ValidationError(f"{path}: longer than maxLength")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            raise ValidationError(f"{path}: does not match pattern")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            raise ValidationError(f"{path}: below minimum")
        if "maximum" in schema and value > schema["maximum"]:
            raise ValidationError(f"{path}: above maximum")
        if "exclusiveMinimum" in schema:
            bound = schema["exclusiveMinimum"] if isinstance(schema["exclusiveMinimum"], (int, float)) else schema.get("minimum")
            if bound is not None and value <= bound:
                raise ValidationError(f"{path}: not above exclusiveMinimum")
        if "exclusiveMaximum" in schema:
            bound = schema["exclusiveMaximum"] if isinstance(schema["exclusiveMaximum"], (int, float)) else schema.get("maximum")
            if bound is not None and value >= bound:
                raise ValidationError(f"{path}: not below exclusiveMaximum")


try:
    with open(sys.argv[1], encoding="utf-8") as schema_handle:
        schema = json.load(schema_handle)
    with open(sys.argv[2], encoding="utf-8") as value_handle:
        value = json.load(value_handle)
    validate(value, schema, schema)
except (OSError, json.JSONDecodeError, ValidationError) as exc:
    print(f"schema validation failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

run_openai_compatible() {
    local default_url=$1
    local default_model=$2
    local curl_bin
    local base_url=${MAINT_OPENAI_BASE_URL:-$default_url}
    local model=${MAINT_OPENAI_MODEL:-$default_model}
    local max_input_bytes=${MAINT_OPENAI_MAX_INPUT_BYTES:-1048576}
    local request_file=$tmp_dir/request.json
    local auth_file=$tmp_dir/authorization.header
    local -a curl_command

    [[ "$base_url" == http://* || "$base_url" == https://* ]] || die 'MAINT_OPENAI_BASE_URL must use http or https'
    [[ -n "$model" ]] || die 'MAINT_OPENAI_MODEL must not be empty'
    [[ "$max_input_bytes" =~ ^[1-9][0-9]*$ ]] || die 'MAINT_OPENAI_MAX_INPUT_BYTES must be a positive integer'
    (( $(wc -c < "$input_file") <= max_input_bytes )) || die "backend input exceeds ${max_input_bytes} bytes"

    jq -n \
        --arg model "$model" \
        --rawfile instructions "$input_file" \
        --slurpfile schema "$schema_file" \
        '{
            model: $model,
            messages: [{
                role: "user",
                content: ($instructions + "\n\n<output-schema>\n" + ($schema[0] | tojson) + "\n</output-schema>")
            }],
            stream: false
        }' > "$request_file"

    curl_bin=$(resolve_binary "${MAINT_CURL_BIN:-curl}")
    curl_command=(
        "$curl_bin"
        --fail-with-body
        --silent
        --show-error
        --max-time "$timeout_seconds"
        --header 'Content-Type: application/json'
    )
    if [[ -n ${MAINT_OPENAI_API_KEY:-} ]]; then
        printf 'Authorization: Bearer %s\n' "$MAINT_OPENAI_API_KEY" > "$auth_file"
        curl_command+=(--header "@$auth_file")
    fi
    curl_command+=(--data-binary "@$request_file" "${base_url%/}/chat/completions")

    if "${curl_command[@]}" > "$backend_stdout" 2> "$backend_stderr"; then
        :
    else
        local rc=$?
        if (( rc == 28 )); then
            die "$backend backend exceeded ${timeout_seconds}s timeout"
        fi
        die "$backend backend failed (exit $rc)"
    fi

    jq -er '.choices[0].message.content | if type == "string" then . else tojson end' \
        "$backend_stdout" > "$candidate_file" || die "$backend backend did not return message content"
    jq -e . "$candidate_file" >/dev/null || die "$backend backend message content is not JSON"
}

case "$backend" in
    claude)
        claude_bin=$(resolve_binary "${MAINT_CLAUDE_BIN:-claude}")
        # The CLI resolves no remote meta-schema, so $schema is dropped on the
        # way in while the file on disk stays self-describing for editors.
        # shellcheck disable=SC2016  # $schema is a JSON key, not a shell variable
        schema_json=$(python3 -c 'import json,sys
schema = json.load(open(sys.argv[1]))
schema.pop("$schema", None)
print(json.dumps(schema))' "$schema_file") || die 'unable to read the JSON Schema'
        # No --bare: it reads Anthropic auth strictly from ANTHROPIC_API_KEY or
        # apiKeyHelper and never from OAuth, while the agent hosts run on a
        # claude.ai subscription login because Remote Control requires one.
        # Read-only comes from --allowedTools and --permission-mode, not --bare.
        claude_command=(
            "$claude_bin"
            -p
            --model "${MAINT_CLAUDE_MODEL:-sonnet}"
            --effort "${MAINT_CLAUDE_EFFORT:-low}"
            --permission-mode dontAsk
            --allowedTools "Read,Grep,Glob"
            --output-format json
            --json-schema "$schema_json"
            --max-budget-usd "$max_budget"
            --no-session-persistence
        )
        if run_with_timeout "${claude_command[@]}"; then
            :
        else
            rc=$?
            if (( rc == 124 || rc == 137 )); then
                die "claude backend exceeded ${timeout_seconds}s timeout"
            fi
            die "claude backend failed (exit $rc)"
        fi
        jq -e 'type == "object" and .type == "result" and .subtype == "success" and (.is_error // false) != true and has("structured_output")' \
            "$backend_stdout" >/dev/null || die 'claude backend did not return a successful structured result'
        if jq -e 'has("total_cost_usd") and .total_cost_usd != null' "$backend_stdout" >/dev/null; then
            total_cost=$(jq -r '.total_cost_usd' "$backend_stdout")
            awk -v total="$total_cost" -v limit="$max_budget" \
                'BEGIN { exit !(total ~ /^[0-9]+([.][0-9]+)?$/ && total <= limit + 0.000000001) }' \
                || die "claude backend exceeded ${max_budget} USD budget"
        fi
        jq -c '.structured_output' "$backend_stdout" > "$candidate_file" || die 'could not extract Claude structured output'
        ;;
    codex)
        codex_bin=$(resolve_binary "${MAINT_CODEX_BIN:-codex}")
        codex_command=(
            "$codex_bin"
            exec
            --ephemeral
            --ignore-user-config
            --ignore-rules
            --sandbox read-only
            --output-schema "$schema_file"
            -
        )
        if run_with_timeout "${codex_command[@]}"; then
            :
        else
            rc=$?
            if (( rc == 124 || rc == 137 )); then
                die "codex backend exceeded ${timeout_seconds}s timeout"
            fi
            die "codex backend failed (exit $rc)"
        fi
        jq -e . "$backend_stdout" >/dev/null || die 'codex backend did not return JSON'
        cp "$backend_stdout" "$candidate_file"
        ;;
    hermes)
        run_openai_compatible 'http://127.0.0.1:8642/v1' 'hermes-agent'
        ;;
    local)
        run_openai_compatible 'http://127.0.0.1:11434/v1' ''
        ;;
esac

validate_candidate || die 'backend output does not conform to the supplied schema'
jq -c . "$candidate_file"
