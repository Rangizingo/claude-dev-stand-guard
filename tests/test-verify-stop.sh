#!/usr/bin/env bash
# Tests for hooks/verify-stop.sh (Stop hook)
# Run: bash tests/test-verify-stop.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_STOP="$SCRIPT_DIR/../hooks/verify-stop.sh"

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

assert_exit() {
    local label="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s (exit %d)\n" "$label" "$actual"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s\n  expected exit: %d\n  actual exit:   %d\n" "$label" "$expected" "$actual"
    fi
}

assert_stderr_contains() {
    local label="$1" pattern="$2" stderr_file="$3"
    TOTAL=$((TOTAL + 1))
    if grep -q "$pattern" "$stderr_file" 2>/dev/null; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s (stderr contains '%s')\n" "$label" "$pattern"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s\n  stderr missing: '%s'\n  stderr was: %s\n" "$label" "$pattern" "$(cat "$stderr_file" 2>/dev/null)"
    fi
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

# Build a Stop payload
make_payload() {
    local cwd="$1"
    local stop_hook_active="${2:-false}"
    cat <<EOF
{
  "hook_event_name": "Stop",
  "session_id": "test-session",
  "cwd": "$cwd",
  "stop_hook_active": $stop_hook_active,
  "last_assistant_message": "Done."
}
EOF
}

# Run the hook, capture exit code and stderr
run_hook() {
    local project_dir="$1"
    local stop_hook_active="${2:-false}"
    local payload
    payload="$(make_payload "$project_dir" "$stop_hook_active")"
    local stderr_file="$TMPBASE/stderr_$RANDOM"
    local exit_code=0
    bash "$VERIFY_STOP" <<< "$payload" 2>"$stderr_file" || exit_code=$?
    echo "$exit_code:$stderr_file"
}

parse_result() {
    local result="$1"
    EXIT_CODE="${result%%:*}"
    STDERR_FILE="${result#*:}"
}

printf "\n${YELLOW}=== Phase 3: verify-stop.sh tests ===${NC}\n\n"

# --------------------------------------------------------------------------
# Test 1: stop_hook_active=true - immediate exit 0 (no commands run)
# --------------------------------------------------------------------------
DIR="$TMPBASE/stop-active"
mkdir -p "$DIR"
cd "$DIR"
git init -q
git commit --allow-empty -m "init" -q
# Set up a project that would fail lint/test/build
cat > "$DIR/package.json" <<'PJSON'
{ "scripts": { "test": "exit 1", "build": "exit 1", "lint": "exit 1" } }
PJSON
echo "broken code" > "$DIR/app.js"
RESULT="$(run_hook "$DIR" "true")"
parse_result "$RESULT"
assert_exit "stop_hook_active=true: immediate exit 0" 0 "$EXIT_CODE"

# --------------------------------------------------------------------------
# Test 2: No source changes - should skip (exit 0)
# --------------------------------------------------------------------------
DIR="$TMPBASE/no-changes-stop"
mkdir -p "$DIR"
cd "$DIR"
git init -q
cat > "$DIR/package.json" <<'PJSON'
{ "scripts": { "test": "echo pass" } }
PJSON
git add -A && git commit -m "init" -q
# No changes since commit
RESULT="$(run_hook "$DIR")"
parse_result "$RESULT"
assert_exit "No source changes: exit 0 (skip)" 0 "$EXIT_CODE"

# --------------------------------------------------------------------------
# Test 3: All passing (lint + test + build) - should allow (exit 0)
# --------------------------------------------------------------------------
DIR="$TMPBASE/all-pass"
mkdir -p "$DIR"
cd "$DIR"
git init -q
git commit --allow-empty -m "init" -q
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": {
    "test": "echo tests pass",
    "build": "echo build pass",
    "lint": "echo lint pass"
  }
}
PJSON
echo "console.log('hello')" > "$DIR/app.js"
RESULT="$(run_hook "$DIR")"
parse_result "$RESULT"
assert_exit "All passing: exit 0" 0 "$EXIT_CODE"

# --------------------------------------------------------------------------
# Test 4: Failing lint only - should block (exit 2)
# --------------------------------------------------------------------------
DIR="$TMPBASE/fail-lint"
mkdir -p "$DIR"
cd "$DIR"
git init -q
git commit --allow-empty -m "init" -q
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": {
    "test": "echo tests pass",
    "build": "echo build pass",
    "lint": "echo LINT_ERROR: bad formatting && exit 1"
  }
}
PJSON
echo "console.log('hello')" > "$DIR/app.js"
RESULT="$(run_hook "$DIR")"
parse_result "$RESULT"
assert_exit "Failing lint: exit 2 (block)" 2 "$EXIT_CODE"
assert_stderr_contains "Failing lint: stderr has lint info" "Lint failed" "$STDERR_FILE"

# --------------------------------------------------------------------------
# Test 5: Failing tests only - should block (exit 2)
# --------------------------------------------------------------------------
DIR="$TMPBASE/fail-tests-stop"
mkdir -p "$DIR"
cd "$DIR"
git init -q
git commit --allow-empty -m "init" -q
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": {
    "test": "echo TEST_FAILURE && exit 1",
    "build": "echo build pass",
    "lint": "echo lint pass"
  }
}
PJSON
echo "console.log('hello')" > "$DIR/app.js"
RESULT="$(run_hook "$DIR")"
parse_result "$RESULT"
assert_exit "Failing tests: exit 2 (block)" 2 "$EXIT_CODE"
assert_stderr_contains "Failing tests: stderr has test info" "Tests failed" "$STDERR_FILE"

# --------------------------------------------------------------------------
# Test 6: Failing build only - should block (exit 2)
# --------------------------------------------------------------------------
DIR="$TMPBASE/fail-build"
mkdir -p "$DIR"
cd "$DIR"
git init -q
git commit --allow-empty -m "init" -q
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": {
    "test": "echo tests pass",
    "build": "echo BUILD_ERROR && exit 1",
    "lint": "echo lint pass"
  }
}
PJSON
echo "console.log('hello')" > "$DIR/app.js"
RESULT="$(run_hook "$DIR")"
parse_result "$RESULT"
assert_exit "Failing build: exit 2 (block)" 2 "$EXIT_CODE"
assert_stderr_contains "Failing build: stderr has build info" "Build failed" "$STDERR_FILE"

# --------------------------------------------------------------------------
# Test 7: Empty project (no commands detected) - should allow (exit 0)
# --------------------------------------------------------------------------
DIR="$TMPBASE/empty-project"
mkdir -p "$DIR"
cd "$DIR"
git init -q
git commit --allow-empty -m "init" -q
echo "some file" > "$DIR/readme.txt"
RESULT="$(run_hook "$DIR")"
parse_result "$RESULT"
assert_exit "Empty project (no stack): exit 0" 0 "$EXIT_CODE"

# --------------------------------------------------------------------------
# Test 8: Multiple failures - all errors concatenated in stderr
# --------------------------------------------------------------------------
DIR="$TMPBASE/multi-fail"
mkdir -p "$DIR"
cd "$DIR"
git init -q
git commit --allow-empty -m "init" -q
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": {
    "test": "echo TEST_BROKE && exit 1",
    "build": "echo BUILD_BROKE && exit 1",
    "lint": "echo LINT_BROKE && exit 1"
  }
}
PJSON
echo "console.log('hello')" > "$DIR/app.js"
RESULT="$(run_hook "$DIR")"
parse_result "$RESULT"
assert_exit "Multiple failures: exit 2 (block)" 2 "$EXIT_CODE"
assert_stderr_contains "Multiple failures: has lint error" "Lint failed" "$STDERR_FILE"
assert_stderr_contains "Multiple failures: has test error" "Tests failed" "$STDERR_FILE"
assert_stderr_contains "Multiple failures: has build error" "Build failed" "$STDERR_FILE"

# --------------------------------------------------------------------------
# Test 9: Stderr truncation at 50 lines
# --------------------------------------------------------------------------
DIR="$TMPBASE/long-stop-errors"
mkdir -p "$DIR"
cd "$DIR"
git init -q
git commit --allow-empty -m "init" -q
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": {
    "test": "for i in $(seq 1 80); do echo ERROR_LINE_$i; done && exit 1",
    "lint": "echo lint pass",
    "build": "echo build pass"
  }
}
PJSON
echo "console.log('hello')" > "$DIR/app.js"
RESULT="$(run_hook "$DIR")"
parse_result "$RESULT"
assert_exit "Long errors: exit 2 (block)" 2 "$EXIT_CODE"
LINE_COUNT="$(wc -l < "$STDERR_FILE")"
TOTAL=$((TOTAL + 1))
if [ "$LINE_COUNT" -le 55 ]; then  # 50 + some header lines
    PASS=$((PASS + 1))
    printf "${GREEN}PASS${NC} Stderr truncated (%d lines, <=55)\n" "$LINE_COUNT"
else
    FAIL=$((FAIL + 1))
    printf "${RED}FAIL${NC} Stderr not truncated (%d lines, expected <=55)\n" "$LINE_COUNT"
fi

# --------------------------------------------------------------------------
# Test 10: Not a git repo - should skip gracefully (exit 0)
# --------------------------------------------------------------------------
DIR="$TMPBASE/no-git-stop"
mkdir -p "$DIR"
cat > "$DIR/package.json" <<'PJSON'
{ "scripts": { "test": "echo pass" } }
PJSON
RESULT="$(run_hook "$DIR")"
parse_result "$RESULT"
assert_exit "No git repo: exit 0 (skip)" 0 "$EXIT_CODE"

# --------------------------------------------------------------------------
# Results
# --------------------------------------------------------------------------
printf "\n${YELLOW}=== Results ===${NC}\n"
printf "Total: %d | ${GREEN}Pass: %d${NC} | ${RED}Fail: %d${NC}\n\n" "$TOTAL" "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
