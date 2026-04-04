#!/usr/bin/env bash
# Tests for hooks/plan-checkbox.sh (TaskCompleted plan.md auto-checkbox)
# Run: bash tests/test-plan-checkbox.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_CHECKBOX="$SCRIPT_DIR/../hooks/plan-checkbox.sh"

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

assert_checked() {
    local label="$1" plan_file="$2" pattern="$3"
    TOTAL=$((TOTAL + 1))
    if grep -qi "\- \[x\].*$pattern" "$plan_file" 2>/dev/null; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s (checkbox marked [x])\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s\n  expected [x] for pattern: '%s'\n  plan.md contents:\n%s\n" "$label" "$pattern" "$(cat "$plan_file")"
    fi
}

assert_unchecked() {
    local label="$1" plan_file="$2" pattern="$3"
    TOTAL=$((TOTAL + 1))
    if grep -qi "\- \[ \].*$pattern" "$plan_file" 2>/dev/null; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s (checkbox still [ ])\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s\n  expected [ ] for pattern: '%s'\n  plan.md contents:\n%s\n" "$label" "$pattern" "$(cat "$plan_file")"
    fi
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

make_payload() {
    local cwd="$1" subject="$2"
    cat <<EOF
{
  "hook_event_name": "TaskCompleted",
  "session_id": "test-session",
  "cwd": "$cwd",
  "task_id": "test-1",
  "task_subject": "$subject"
}
EOF
}

run_hook() {
    local dir="$1" subject="$2"
    local payload
    payload="$(make_payload "$dir" "$subject")"
    local exit_code=0
    bash "$PLAN_CHECKBOX" <<< "$payload" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

printf "\n${YELLOW}=== plan-checkbox.sh tests ===${NC}\n\n"

# --------------------------------------------------------------------------
# Test 1: Exact match - task subject matches plan.md item
# --------------------------------------------------------------------------
DIR="$TMPBASE/exact-match"
mkdir -p "$DIR"
cat > "$DIR/plan.md" <<'PLAN'
# Plan
- [x] Build authentication
- [ ] Build barcode rendering for labels
- [ ] Add customer search
PLAN

EXIT_CODE="$(run_hook "$DIR" "Fix labels barcode rendering")"
assert_exit "Exact match: exits 0" 0 "$EXIT_CODE"
assert_checked "Exact match: barcode rendering checked" "$DIR/plan.md" "barcode rendering"
assert_unchecked "Exact match: customer search untouched" "$DIR/plan.md" "customer search"

# --------------------------------------------------------------------------
# Test 2: Case-insensitive matching (grep -i)
# --------------------------------------------------------------------------
DIR="$TMPBASE/case-insensitive"
mkdir -p "$DIR"
cat > "$DIR/plan.md" <<'PLAN'
# Plan
- [ ] Build ESL Tag Mapping And Sync System
- [ ] Add other feature
PLAN

EXIT_CODE="$(run_hook "$DIR" "Build esl tag mapping and sync system")"
assert_exit "Case insensitive: exits 0" 0 "$EXIT_CODE"
assert_checked "Case insensitive: ESL checked" "$DIR/plan.md" "ESL"

# --------------------------------------------------------------------------
# Test 3: Fuzzy match - task subject doesn't exactly match but key words do
# --------------------------------------------------------------------------
DIR="$TMPBASE/fuzzy-match"
mkdir -p "$DIR"
cat > "$DIR/plan.md" <<'PLAN'
# Plan
- [ ] Wire newsletter form to API endpoint
- [ ] Build dashboard
PLAN

EXIT_CODE="$(run_hook "$DIR" "Wire newsletter form to API")"
assert_exit "Fuzzy match: exits 0" 0 "$EXIT_CODE"
assert_checked "Fuzzy match: newsletter checked" "$DIR/plan.md" "newsletter"

# --------------------------------------------------------------------------
# Test 4: No match - task subject doesn't match any plan item
# --------------------------------------------------------------------------
DIR="$TMPBASE/no-match"
mkdir -p "$DIR"
cat > "$DIR/plan.md" <<'PLAN'
# Plan
- [ ] Build authentication
- [ ] Add logging
PLAN

EXIT_CODE="$(run_hook "$DIR" "Refactor database connection pooling")"
assert_exit "No match: exits 0 (never blocks)" 0 "$EXIT_CODE"
assert_unchecked "No match: auth untouched" "$DIR/plan.md" "authentication"
assert_unchecked "No match: logging untouched" "$DIR/plan.md" "logging"

# --------------------------------------------------------------------------
# Test 5: Already checked items are not re-matched
# --------------------------------------------------------------------------
DIR="$TMPBASE/already-checked"
mkdir -p "$DIR"
cat > "$DIR/plan.md" <<'PLAN'
# Plan
- [x] Build barcode rendering
- [ ] Add export functionality
PLAN

EXIT_CODE="$(run_hook "$DIR" "Build barcode rendering")"
assert_exit "Already checked: exits 0" 0 "$EXIT_CODE"
# The already-checked item should remain [x], not get double-matched
assert_unchecked "Already checked: export still unchecked" "$DIR/plan.md" "export"

# --------------------------------------------------------------------------
# Test 6: No plan.md in directory tree - exits cleanly
# --------------------------------------------------------------------------
DIR="$TMPBASE/no-plan"
mkdir -p "$DIR"

EXIT_CODE="$(run_hook "$DIR" "Some task")"
assert_exit "No plan.md: exits 0" 0 "$EXIT_CODE"

# --------------------------------------------------------------------------
# Test 7: Empty task subject - exits cleanly
# --------------------------------------------------------------------------
DIR="$TMPBASE/empty-subject"
mkdir -p "$DIR"
cat > "$DIR/plan.md" <<'PLAN'
- [ ] Something
PLAN

EXIT_CODE="$(run_hook "$DIR" "")"
assert_exit "Empty subject: exits 0" 0 "$EXIT_CODE"
assert_unchecked "Empty subject: nothing changed" "$DIR/plan.md" "Something"

# --------------------------------------------------------------------------
# Test 8: Short words only (< 4 chars) - skips matching to avoid false positives
# --------------------------------------------------------------------------
DIR="$TMPBASE/short-words"
mkdir -p "$DIR"
cat > "$DIR/plan.md" <<'PLAN'
- [ ] Fix bug in API
PLAN

EXIT_CODE="$(run_hook "$DIR" "Fix bug in API")"
assert_exit "Short words: exits 0" 0 "$EXIT_CODE"
# "Fix" "bug" "in" "API" are all <= 3 chars, so no match attempted
assert_unchecked "Short words: no match attempted" "$DIR/plan.md" "bug"

# --------------------------------------------------------------------------
# Test 9: Multiple unchecked items - only first match gets checked
# --------------------------------------------------------------------------
DIR="$TMPBASE/multi-match"
mkdir -p "$DIR"
cat > "$DIR/plan.md" <<'PLAN'
- [ ] Build customer portal authentication
- [ ] Build customer portal notifications
- [ ] Build vendor portal
PLAN

EXIT_CODE="$(run_hook "$DIR" "Build customer portal authentication")"
assert_exit "Multi match: exits 0" 0 "$EXIT_CODE"
assert_checked "Multi match: first item checked" "$DIR/plan.md" "portal authentication"
assert_unchecked "Multi match: second item untouched" "$DIR/plan.md" "portal notifications"

# --------------------------------------------------------------------------
# Test 10: Prefix stripping - "Build", "Add", "Fix" etc. stripped before matching
# --------------------------------------------------------------------------
DIR="$TMPBASE/prefix-strip"
mkdir -p "$DIR"
cat > "$DIR/plan.md" <<'PLAN'
- [ ] Payment processor adapter interface
PLAN

EXIT_CODE="$(run_hook "$DIR" "Build payment processor adapter interface")"
assert_exit "Prefix strip: exits 0" 0 "$EXIT_CODE"
assert_checked "Prefix strip: matched without Build prefix" "$DIR/plan.md" "payment processor"

# --------------------------------------------------------------------------
# Test 11: Plan.md found in parent directory
# --------------------------------------------------------------------------
DIR="$TMPBASE/parent-plan/subdir/deep"
mkdir -p "$DIR"
cat > "$TMPBASE/parent-plan/plan.md" <<'PLAN'
- [ ] Implement search indexing across entities
PLAN

EXIT_CODE="$(run_hook "$DIR" "Implement search indexing across entities")"
assert_exit "Parent dir plan.md: exits 0" 0 "$EXIT_CODE"
assert_checked "Parent dir: item checked" "$TMPBASE/parent-plan/plan.md" "search indexing"

# --------------------------------------------------------------------------
# Test 12: Never blocks - always exit 0 even if script errors internally
# --------------------------------------------------------------------------
DIR="$TMPBASE/always-allow"
mkdir -p "$DIR"
# Create plan.md with weird characters that might trip up sed
cat > "$DIR/plan.md" <<'PLAN'
- [ ] Handle $pecial ch@racters & "quotes" in plan
PLAN

EXIT_CODE="$(run_hook "$DIR" "Handle special characters and quotes in plan")"
assert_exit "Never blocks: exits 0" 0 "$EXIT_CODE"

# --------------------------------------------------------------------------
# Results
# --------------------------------------------------------------------------
printf "\n${YELLOW}=== Results ===${NC}\n"
printf "Total: %d | ${GREEN}Pass: %d${NC} | ${RED}Fail: %d${NC}\n\n" "$TOTAL" "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
