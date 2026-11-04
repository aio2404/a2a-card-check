#!/usr/bin/env bash
# Validate one A2A card through KoPass and publish GitHub Action outputs,
# annotations, and a job summary. This script deliberately uses only bash,
# curl, and jq so the composite action has no package-manager dependency.
set -euo pipefail

readonly KOPASS_WEB_URL="https://kopass.app"

require_environment() {
  : "${A2A_CARD_URL:?A2A_CARD_URL must be set}"
  : "${A2A_FAIL_ON:?A2A_FAIL_ON must be set}"
  : "${A2A_API_URL:?A2A_API_URL must be set}"
  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"
  : "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY must be set}"

  case "$A2A_FAIL_ON" in
    error|warning|never) ;;
    *)
      printf 'Unsupported fail-on value: %s (expected error, warning, or never).\n' "$A2A_FAIL_ON" >&2
      exit 2
      ;;
  esac
}

# Escape data embedded in a GitHub workflow command. GitHub requires these
# substitutions for percent signs, carriage returns, and line feeds.
github_command_escape() {
  local value="$1"
  value="${value//%/%25}"
  value="${value//$'\r'/%0D}"
  value="${value//$'\n'/%0A}"
  printf '%s' "$value"
}

# Keep table cells on one Markdown row and avoid accidental extra columns.
markdown_cell() {
  local value="$1"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/<br>}"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

write_outputs() {
  local grade="$1"
  local valid="$2"
  local reachable="$3"
  local report_url="$4"

  {
    printf 'grade=%s\n' "$grade"
    printf 'valid=%s\n' "$valid"
    printf 'reachable=%s\n' "$reachable"
    printf 'report-url=%s\n' "$report_url"
  } >> "$GITHUB_OUTPUT"
}

write_unavailable_summary() {
  local report_url="$1"
  local reason="$2"

  {
    printf '%s\n\n' '## A2A card check'
    printf '%s\n\n' '**Verdict:** KoPass could not return a validation result.'
    printf '%s\n\n' "$reason"
    printf '[Open the KoPass validator](%s)\n\n' "$report_url"
    printf '%s\n' 'Checked by [KoPass](https://kopass.app) — daily A2A & MCP measurements'
  } >> "$GITHUB_STEP_SUMMARY"
}

emit_findings() {
  local finding severity code field detail command message

  while IFS= read -r finding; do
    severity="$(jq -r '.severity // "info"' <<< "$finding")"
    code="$(jq -r '.code // "finding"' <<< "$finding")"
    field="$(jq -r '.field // ""' <<< "$finding")"
    detail="$(jq -r '.detail // ""' <<< "$finding")"

    case "$severity" in
      error) command='error' ;;
      warning) command='warning' ;;
      *) command='notice' ;;
    esac

    # The API sends empty strings, not nulls, for absent parts: join what exists.
    if [ -n "$field" ] && [ -n "$detail" ]; then
      message="${field}: ${detail}"
    else
      message="${field}${detail}"
    fi
    [ -n "$message" ] || message="$code"
    printf '::%s title=%s::%s\n' \
      "$command" \
      "$(github_command_escape "$code")" \
      "$(github_command_escape "$message")"
  done < <(jq -c '(.findings // [])[]?' "$response_file")
}

write_summary() {
  local grade="$1"
  local valid="$2"
  local reachable="$3"
  local report_url="$4"
  local badge_url="$5"
  local version finding severity code field detail
  local found_versions=false
  local found_findings=false

  {
    printf '%s\n\n' '## A2A card check'
    # shellcheck disable=SC2016 # Backticks are Markdown code spans, not shell.
    printf '**Verdict:** `%s` — valid: `%s`, reachable: `%s`\n\n' "$grade" "$valid" "$reachable"
    printf '%s\n\n' '### Protocol versions'

    while IFS= read -r version; do
      found_versions=true
      # shellcheck disable=SC2016 # Backticks are Markdown code spans, not shell.
      printf -- '- `%s`\n' "$(markdown_cell "$version")"
    done < <(jq -r '(.protocolVersions // .protocol_versions // []) | if type == "array" then .[] else empty end' "$response_file")
    if [ "$found_versions" = false ]; then
      printf '%s\n' '- Not reported'
    fi

    printf '\n%s\n\n' '### Findings'
    printf '%s\n' '| Severity | Code | Field | Detail |'
    printf '%s\n' '| --- | --- | --- | --- |'
    while IFS= read -r finding; do
      found_findings=true
      severity="$(jq -r '.severity // "info"' <<< "$finding")"
      code="$(jq -r '.code // "finding"' <<< "$finding")"
      field="$(jq -r '.field // "card"' <<< "$finding")"
      detail="$(jq -r '.detail // "No detail provided."' <<< "$finding")"
      printf '| %s | %s | %s | %s |\n' \
        "$(markdown_cell "$severity")" \
        "$(markdown_cell "$code")" \
        "$(markdown_cell "$field")" \
        "$(markdown_cell "$detail")"
    done < <(jq -c '(.findings // [])[]?' "$response_file")
    if [ "$found_findings" = false ]; then
      printf '%s\n' '| info | — | — | No findings reported. |'
    fi

    if [ -n "$badge_url" ]; then
      printf '\n[![KoPass A2A card grade: %s](%s)](%s)\n\n' "$grade" "$badge_url" "$report_url"
    else
      printf '\n%s\n\n' 'KoPass did not return an origin, so a badge is unavailable for this result.'
    fi
    printf '[Open the KoPass report](%s)\n\n' "$report_url"
    printf '%s\n' 'Checked by [KoPass](https://kopass.app) — daily A2A & MCP measurements'
  } >> "$GITHUB_STEP_SUMMARY"
}

request_once() {
  : > "$response_file"
  : > "$headers_file"

  if http_status="$(curl \
    --silent \
    --show-error \
    --location \
    --request POST \
    --header 'Content-Type: application/json' \
    --data "$request_body" \
    --output "$response_file" \
    --dump-header "$headers_file" \
    --write-out '%{http_code}' \
    "$endpoint")"; then
    return 0
  fi

  http_status='000'
  return 1
}

retry_after_seconds() {
  local retry_after
  retry_after="$(awk 'tolower($1) == "retry-after:" { gsub("\\r", "", $2); print $2; exit }' "$headers_file")"
  if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
    if [ "$retry_after" -gt 60 ]; then
      printf '60'
    else
      printf '%s' "$retry_after"
    fi
  else
    printf '0'
  fi
}

require_environment

api_base="${A2A_API_URL%/}"
endpoint="${api_base}/api/v1/web/a2a/validator"
request_body="$(jq -n --arg url "$A2A_CARD_URL" --arg locale 'en' '{url: $url, locale: $locale}')"
encoded_url="$(jq -rn --arg value "$A2A_CARD_URL" '$value | @uri')"
validator_url="${KOPASS_WEB_URL}/a2a/validator?url=${encoded_url}"

response_file="$(mktemp)"
headers_file="$(mktemp)"
trap 'rm -f "$response_file" "$headers_file"' EXIT

# At most one retry is made: rate limits honour Retry-After (capped at a minute),
# while a transport error or a server-side error is retried once immediately.
if ! request_once; then
  if ! request_once; then
    write_outputs 'unknown' 'false' 'false' "$validator_url"
    write_unavailable_summary "$validator_url" 'The KoPass API request failed twice because of a network error.'
    printf 'KoPass API request failed after one retry (network error).\n' >&2
    exit 1
  fi
elif [ "$http_status" = '429' ]; then
  wait_seconds="$(retry_after_seconds)"
  printf 'KoPass rate limit reached; retrying once after %s seconds.\n' "$wait_seconds" >&2
  sleep "$wait_seconds"
  if ! request_once; then
    write_outputs 'unknown' 'false' 'false' "$validator_url"
    write_unavailable_summary "$validator_url" 'The KoPass API request failed after waiting for its rate limit.'
    printf 'KoPass API request failed after a rate-limit retry (network error).\n' >&2
    exit 1
  fi
elif [[ "$http_status" =~ ^5[0-9][0-9]$ ]]; then
  if ! request_once; then
    write_outputs 'unknown' 'false' 'false' "$validator_url"
    write_unavailable_summary "$validator_url" 'The KoPass API request failed during its server-error retry.'
    printf 'KoPass API request failed after a server-error retry (network error).\n' >&2
    exit 1
  fi
fi

if [ "$http_status" != '200' ]; then
  write_outputs 'unknown' 'false' 'false' "$validator_url"
  write_unavailable_summary "$validator_url" "The KoPass API returned HTTP ${http_status}."
  printf 'KoPass API did not return a validation result (HTTP %s).\n' "$http_status" >&2
  exit 1
fi

if ! jq -e 'type == "object"' "$response_file" >/dev/null 2>&1; then
  write_outputs 'unknown' 'false' 'false' "$validator_url"
  write_unavailable_summary "$validator_url" 'The KoPass API returned an invalid JSON response.'
  printf 'KoPass API returned invalid JSON.\n' >&2
  exit 1
fi

# Camel-case is the published contract; snake-case fallbacks keep the action
# compatible with a compatible proxy or transitional response serializer.
grade="$(jq -r '.grade // "unknown"' "$response_file")"
valid="$(jq -r 'if (.valid // .is_valid // false) == true then "true" else "false" end' "$response_file")"
reachable="$(jq -r 'if (.reachable // .is_reachable // false) == true then "true" else "false" end' "$response_file")"
known="$(jq -r 'if (.known // .is_known // false) == true then "true" else "false" end' "$response_file")"
origin="$(jq -r '.origin // .origin_url // empty' "$response_file")"

report_url="$validator_url"
badge_origin="$origin"
if [ "$known" = true ] && [ -n "$origin" ]; then
  origin_host="$(jq -rn --arg origin "$origin" 'try ($origin | capture("^[A-Za-z][A-Za-z0-9+.-]*://(?<host>[^/?#]+)").host) catch ""')"
  if [ -n "$origin_host" ]; then
    report_url="${KOPASS_WEB_URL}/a2a/agent/${origin_host}"
  fi
fi

if [ -n "$badge_origin" ]; then
  badge_token="$(printf '%s' "$badge_origin" | base64 | tr '+/' '-_' | tr -d '=\n')"
  badge_url="${KOPASS_WEB_URL}/a2a/badge/${badge_token}.svg"
else
  badge_url=''
fi

write_outputs "$grade" "$valid" "$reachable" "$report_url"
emit_findings
write_summary "$grade" "$valid" "$reachable" "$report_url" "$badge_url"

has_warning=false
if jq -e 'any((.findings // [])[]; .severity == "warning")' "$response_file" >/dev/null; then
  has_warning=true
fi

case "$A2A_FAIL_ON" in
  never)
    exit 0
    ;;
  error)
    if [ "$valid" != true ] || [ "$reachable" != true ]; then
      printf 'Validation policy failed: the A2A card is invalid or unreachable.\n' >&2
      exit 1
    fi
    ;;
  warning)
    if [ "$valid" != true ] || [ "$reachable" != true ] || [ "$has_warning" = true ]; then
      printf 'Validation policy failed: the card is invalid, unreachable, or has warnings.\n' >&2
      exit 1
    fi
    ;;
esac
