#!/usr/bin/env bash
# Exercise scripts/check.sh entirely offline by placing tests/bin/curl first in
# PATH. Each case uses fresh GitHub output and summary files.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

export PATH="${project_root}/tests/bin:${PATH}"

fail() {
  printf 'TEST FAILED: %s\n' "$1" >&2
  exit 1
}

assert_file_contains() {
  local needle="$1"
  local file="$2"
  grep -F -- "$needle" "$file" >/dev/null || fail "expected ${file} to contain: ${needle}"
}

run_case() {
  local scenario="$1"
  local policy="$2"
  local expected_status="$3"
  local expected_grade="$4"
  local expected_valid="$5"
  local expected_reachable="$6"
  local case_dir output summary state stderr_file actual_status

  case_dir="${temporary_root}/${scenario}-${policy}"
  mkdir -p "$case_dir"
  output="${case_dir}/github-output"
  summary="${case_dir}/summary"
  state="${case_dir}/curl-count"
  stderr_file="${case_dir}/stderr"
  : > "$output"
  : > "$summary"

  set +e
  CURL_SCENARIO="$scenario" \
  FAKE_CURL_STATE="$state" \
  GITHUB_OUTPUT="$output" \
  GITHUB_STEP_SUMMARY="$summary" \
  A2A_CARD_URL='https://agent.example/.well-known/agent.json' \
  A2A_FAIL_ON="$policy" \
  A2A_API_URL='https://kopass.test' \
  bash "${project_root}/scripts/check.sh" >"${case_dir}/stdout" 2>"$stderr_file"
  actual_status=$?
  set -e

  [ "$actual_status" -eq "$expected_status" ] || fail "${scenario}/${policy}: expected exit ${expected_status}, got ${actual_status}"
  assert_file_contains "grade=${expected_grade}" "$output"
  assert_file_contains "valid=${expected_valid}" "$output"
  assert_file_contains "reachable=${expected_reachable}" "$output"
  assert_file_contains 'report-url=https://kopass.app/a2a/' "$output"
  [ -s "$summary" ] || fail "${scenario}/${policy}: summary is empty"
  assert_file_contains 'Checked by [KoPass](https://kopass.app)' "$summary"

  case "$scenario" in
    pass)
      assert_file_contains 'report-url=https://kopass.app/a2a/agent/agent.example' "$output"
      ;;
    warn)
      assert_file_contains '::warning title=missing-name::name: Missing %25 value%0Anext' "${case_dir}/stdout"
      assert_file_contains 'report-url=https://kopass.app/a2a/validator?url=' "$output"
      ;;
    fail)
      assert_file_contains '::error title=bad-card::skills: A required field is missing' "${case_dir}/stdout"
      ;;
    rate-limit)
      [ "$(cat "$state")" -eq 2 ] || fail 'rate-limit: expected exactly one retry'
      ;;
    unavailable)
      [ "$(cat "$state")" -eq 2 ] || fail 'unavailable: expected exactly one retry'
      if grep -F '::' "${case_dir}/stdout" >/dev/null; then
        fail 'unavailable: should not invent annotations'
      fi
      ;;
  esac
}

run_case pass error 0 pass true true
run_case warn error 0 warn true true
run_case warn warning 1 warn true true
run_case fail never 0 fail false true
run_case fail error 1 fail false true
run_case rate-limit error 0 pass true true
run_case unavailable never 1 unknown false false

printf 'All offline tests passed.\n'
