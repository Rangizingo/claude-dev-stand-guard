#!/usr/bin/env bash
# test-all-hooks.sh — End-to-end test for all stand-guard hooks
# Tests the INSTALLED hooks at ~/.claude/hooks/ (not the repo copies)
# Run: bash tests/test-all-hooks.sh
set -uo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
DIM='\033[2m'
NC='\033[0m'

assert_exit() {
    local label="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s (expected exit %d, got %d)\n" "$label" "$expected" "$actual"
    fi
}

assert_output_contains() {
    local label="$1" pattern="$2" output="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$output" | grep -q "$pattern"; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s (output missing: '%s')\n" "$label" "$pattern"
    fi
}

assert_output_empty() {
    local label="$1" output="$2"
    TOTAL=$((TOTAL + 1))
    if [ -z "$output" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s (expected empty, got: '%s')\n" "$label" "$(echo "$output" | head -1)"
    fi
}

# Check all hooks exist
check_file() {
    local f="$1"
    TOTAL=$((TOTAL + 1))
    if [ -f "$HOOKS_DIR/$f" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} Installed: %s\n" "$f"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} Missing: %s\n" "$f"
    fi
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

# =========================================================================
printf "\n${YELLOW}=== 1. File Installation Check ===${NC}\n\n"
# =========================================================================

check_file "post_tool_use.sh"
check_file "bash-safety.sh"
check_file "verify-task.sh"
check_file "verify-stop.sh"
check_file "review-gate.sh"
check_file "post-compact.sh"
check_file "lib/detect-stack.sh"

# =========================================================================
printf "\n${YELLOW}=== 2. detect-stack.sh — Stack Detection ===${NC}\n\n"
# =========================================================================

# Node + pnpm
DIR="$TMPBASE/node-pnpm"
mkdir -p "$DIR"
cat > "$DIR/package.json" <<'EOF'
{"scripts":{"test":"vitest","build":"tsc","lint":"eslint ."}}
EOF
touch "$DIR/pnpm-lock.yaml"
OUTPUT="$(cd "$DIR" && bash -c 'source "'"$HOOKS_DIR"'/lib/detect-stack.sh"; echo "$DETECTED_STACK|$TEST_CMD|$BUILD_CMD|$LINT_CMD"')"
if command -v pnpm &>/dev/null; then
    assert_output_contains "Node+pnpm: detects pnpm" "node|pnpm test|pnpm build|pnpm lint" "$OUTPUT"
else
    assert_output_contains "Node+pnpm: fallback to npm" "node|npm run test" "$OUTPUT"
fi

# Python
DIR="$TMPBASE/python"
mkdir -p "$DIR"
touch "$DIR/pyproject.toml"
OUTPUT="$(cd "$DIR" && bash -c 'source "'"$HOOKS_DIR"'/lib/detect-stack.sh"; echo "$DETECTED_STACK"')"
assert_output_contains "Python: detected" "python" "$OUTPUT"

# Go
DIR="$TMPBASE/golang"
mkdir -p "$DIR"
touch "$DIR/go.mod"
OUTPUT="$(cd "$DIR" && bash -c 'source "'"$HOOKS_DIR"'/lib/detect-stack.sh"; echo "$DETECTED_STACK"')"
assert_output_contains "Go: detected" "go" "$OUTPUT"

# Rust
DIR="$TMPBASE/rust"
mkdir -p "$DIR"
touch "$DIR/Cargo.toml"
OUTPUT="$(cd "$DIR" && bash -c 'source "'"$HOOKS_DIR"'/lib/detect-stack.sh"; echo "$DETECTED_STACK"')"
assert_output_contains "Rust: detected" "rust" "$OUTPUT"

# .NET
DIR="$TMPBASE/dotnet"
mkdir -p "$DIR"
touch "$DIR/App.csproj"
OUTPUT="$(cd "$DIR" && bash -c 'source "'"$HOOKS_DIR"'/lib/detect-stack.sh"; echo "$DETECTED_STACK"')"
assert_output_contains ".NET: detected" "dotnet" "$OUTPUT"

# Swift
DIR="$TMPBASE/swift"
mkdir -p "$DIR"
touch "$DIR/Package.swift"
OUTPUT="$(cd "$DIR" && bash -c 'source "'"$HOOKS_DIR"'/lib/detect-stack.sh"; echo "$DETECTED_STACK"')"
assert_output_contains "Swift: detected" "swift" "$OUTPUT"

# Empty dir
DIR="$TMPBASE/empty"
mkdir -p "$DIR"
OUTPUT="$(cd "$DIR" && bash -c 'source "'"$HOOKS_DIR"'/lib/detect-stack.sh"; echo "$DETECTED_STACK"')"
TOTAL=$((TOTAL + 1))
if [ "$(echo "$OUTPUT" | tr -d '[:space:]')" = "" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}PASS${NC} Empty dir: no stack\n"
else
    FAIL=$((FAIL + 1))
    printf "${RED}FAIL${NC} Empty dir: expected no stack, got '%s'\n" "$OUTPUT"
fi

# =========================================================================
printf "\n${YELLOW}=== 3. post_tool_use.sh — Format + Lint on Edit ===${NC}\n\n"
# =========================================================================

# Should skip non-Write/Edit tools
OUTPUT="$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$HOOKS_DIR/post_tool_use.sh" 2>&1)"
EXIT=$?
assert_exit "Skip non-edit tool" 0 "$EXIT"
assert_output_empty "Skip non-edit: no output" "$OUTPUT"

# Should skip non-existent file
OUTPUT="$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/nonexistent_file_xxxxx.ts"}}' | bash "$HOOKS_DIR/post_tool_use.sh" 2>&1)"
EXIT=$?
assert_exit "Skip missing file" 0 "$EXIT"
assert_output_empty "Skip missing: no output" "$OUTPUT"

# Should handle a real .py file (format only, no lint errors)
PYFILE="$TMPBASE/clean.py"
echo 'x = 1' > "$PYFILE"
OUTPUT="$(echo '{"tool_name":"Write","tool_input":{"file_path":"'"$PYFILE"'"}}' | bash "$HOOKS_DIR/post_tool_use.sh" 2>&1)"
EXIT=$?
assert_exit "Python clean file: exit 0" 0 "$EXIT"

# Should handle a real .go file
GOFILE="$TMPBASE/clean.go"
echo 'package main' > "$GOFILE"
OUTPUT="$(echo '{"tool_name":"Write","tool_input":{"file_path":"'"$GOFILE"'"}}' | bash "$HOOKS_DIR/post_tool_use.sh" 2>&1)"
EXIT=$?
assert_exit "Go file: exit 0" 0 "$EXIT"

# Should handle a .swift file
SWIFTFILE="$TMPBASE/clean.swift"
echo 'import Foundation' > "$SWIFTFILE"
OUTPUT="$(echo '{"tool_name":"Write","tool_input":{"file_path":"'"$SWIFTFILE"'"}}' | bash "$HOOKS_DIR/post_tool_use.sh" 2>&1)"
EXIT=$?
assert_exit "Swift file: exit 0" 0 "$EXIT"

# =========================================================================
printf "\n${YELLOW}=== 4. bash-safety.sh — Dangerous Command Blocking ===${NC}\n\n"
# =========================================================================

# Safe command
OUTPUT="$(echo '{"tool_input":{"command":"git status"}}' | bash "$HOOKS_DIR/bash-safety.sh" 2>/dev/null)"
EXIT=$?
assert_exit "Safe command: exit 0" 0 "$EXIT"

# Force push to main
OUTPUT="$(echo '{"tool_input":{"command":"git push --force origin main"}}' | bash "$HOOKS_DIR/bash-safety.sh" 2>/dev/null)"
EXIT=$?
assert_exit "Force push main: blocked (exit 2)" 2 "$EXIT"

# git reset --hard
OUTPUT="$(echo '{"tool_input":{"command":"git reset --hard HEAD~5"}}' | bash "$HOOKS_DIR/bash-safety.sh" 2>/dev/null)"
EXIT=$?
assert_exit "git reset --hard: blocked (exit 2)" 2 "$EXIT"

# DROP TABLE
OUTPUT="$(echo '{"tool_input":{"command":"psql -c \"DROP TABLE users\""}}' | bash "$HOOKS_DIR/bash-safety.sh" 2>/dev/null)"
EXIT=$?
assert_exit "DROP TABLE: blocked (exit 2)" 2 "$EXIT"

# Empty command
OUTPUT="$(echo '{"tool_input":{"command":""}}' | bash "$HOOKS_DIR/bash-safety.sh" 2>/dev/null)"
EXIT=$?
assert_exit "Empty command: exit 0" 0 "$EXIT"

# =========================================================================
printf "\n${YELLOW}=== 5. verify-task.sh — Task Completion Gate ===${NC}\n\n"
# =========================================================================

# No git repo: should pass
DIR="$TMPBASE/no-git-task"
mkdir -p "$DIR"
OUTPUT="$(echo '{"cwd":"'"$DIR"'"}' | bash "$HOOKS_DIR/verify-task.sh" 2>/dev/null)"
EXIT=$?
assert_exit "No git repo: exit 0 (skip)" 0 "$EXIT"

# Git repo, no changes: should pass
DIR="$TMPBASE/clean-task"
mkdir -p "$DIR"
cd "$DIR" && git init -q && git commit --allow-empty -m "init" -q
OUTPUT="$(echo '{"cwd":"'"$DIR"'"}' | bash "$HOOKS_DIR/verify-task.sh" 2>/dev/null)"
EXIT=$?
assert_exit "No changes: exit 0 (skip)" 0 "$EXIT"

# Git repo, passing tests
DIR="$TMPBASE/pass-task"
mkdir -p "$DIR"
cd "$DIR" && git init -q && git commit --allow-empty -m "init" -q
cat > "$DIR/package.json" <<'EOF'
{"scripts":{"test":"echo pass"}}
EOF
touch "$DIR/package-lock.json"
echo "console.log('hi')" > "$DIR/app.js"
OUTPUT="$(echo '{"cwd":"'"$DIR"'"}' | bash "$HOOKS_DIR/verify-task.sh" 2>/dev/null)"
EXIT=$?
assert_exit "Passing tests: exit 0" 0 "$EXIT"

# Git repo, failing tests
DIR="$TMPBASE/fail-task"
mkdir -p "$DIR"
cd "$DIR" && git init -q && git commit --allow-empty -m "init" -q
cat > "$DIR/package.json" <<'EOF'
{"scripts":{"test":"echo FAIL && exit 1"}}
EOF
touch "$DIR/package-lock.json"
echo "console.log('hi')" > "$DIR/app.js"
OUTPUT="$(echo '{"cwd":"'"$DIR"'"}' | bash "$HOOKS_DIR/verify-task.sh" 2>&1)"
EXIT=$?
assert_exit "Failing tests: exit 2 (block)" 2 "$EXIT"

# =========================================================================
printf "\n${YELLOW}=== 6. verify-stop.sh — Stop Gate ===${NC}\n\n"
# =========================================================================

# stop_hook_active: immediate pass
DIR="$TMPBASE/stop-active"
mkdir -p "$DIR"
OUTPUT="$(echo '{"cwd":"'"$DIR"'","stop_hook_active":true}' | bash "$HOOKS_DIR/verify-stop.sh" 2>/dev/null)"
EXIT=$?
assert_exit "stop_hook_active=true: exit 0" 0 "$EXIT"

# All passing
DIR="$TMPBASE/stop-pass"
mkdir -p "$DIR"
cd "$DIR" && git init -q && git commit --allow-empty -m "init" -q
cat > "$DIR/package.json" <<'EOF'
{"scripts":{"test":"echo pass","build":"echo pass","lint":"echo pass"}}
EOF
touch "$DIR/package-lock.json"
echo "console.log('hi')" > "$DIR/app.js"
OUTPUT="$(echo '{"cwd":"'"$DIR"'","stop_hook_active":false}' | bash "$HOOKS_DIR/verify-stop.sh" 2>/dev/null)"
EXIT=$?
assert_exit "All passing: exit 0" 0 "$EXIT"

# Lint fails
DIR="$TMPBASE/stop-lint-fail"
mkdir -p "$DIR"
cd "$DIR" && git init -q && git commit --allow-empty -m "init" -q
cat > "$DIR/package.json" <<'EOF'
{"scripts":{"test":"echo pass","build":"echo pass","lint":"echo LINT_ERROR && exit 1"}}
EOF
touch "$DIR/package-lock.json"
echo "console.log('hi')" > "$DIR/app.js"
OUTPUT="$(echo '{"cwd":"'"$DIR"'","stop_hook_active":false}' | bash "$HOOKS_DIR/verify-stop.sh" 2>&1)"
EXIT=$?
assert_exit "Lint fails: exit 2 (block)" 2 "$EXIT"

# =========================================================================
printf "\n${YELLOW}=== 7. review-gate.sh — Code Review Gate ===${NC}\n\n"
# =========================================================================

# stop_hook_active: pass
OUTPUT="$(echo '{"stop_hook_active":true}' | bash "$HOOKS_DIR/review-gate.sh" 2>/dev/null)"
EXIT=$?
assert_exit "stop_hook_active=true: exit 0" 0 "$EXIT"

# No git repo: pass
DIR="$TMPBASE/no-git-review"
mkdir -p "$DIR"
OUTPUT="$(cd "$DIR" && echo '{"stop_hook_active":false}' | bash "$HOOKS_DIR/review-gate.sh" 2>/dev/null)"
EXIT=$?
assert_exit "No git repo: exit 0" 0 "$EXIT"

# No source changes: pass
DIR="$TMPBASE/review-clean"
mkdir -p "$DIR"
cd "$DIR" && git init -q && echo "readme" > README.md && git add -A && git commit -m "init" -q
OUTPUT="$(cd "$DIR" && echo '{"stop_hook_active":false}' | bash "$HOOKS_DIR/review-gate.sh" 2>/dev/null)"
EXIT=$?
assert_exit "No source changes: exit 0" 0 "$EXIT"

# Trivial source changes (<20 lines): pass
DIR="$TMPBASE/review-trivial"
mkdir -p "$DIR"
cd "$DIR" && git init -q && echo "x=1" > app.py && git add -A && git commit -m "init" -q
echo "x=2" > app.py
OUTPUT="$(cd "$DIR" && echo '{"stop_hook_active":false}' | bash "$HOOKS_DIR/review-gate.sh" 2>/dev/null)"
EXIT=$?
assert_exit "Trivial changes: exit 0" 0 "$EXIT"

# =========================================================================
printf "\n${YELLOW}=== 8. post-compact.sh — Context Recovery ===${NC}\n\n"
# =========================================================================

# Works in a git repo with CLAUDE.md and plan.md
DIR="$TMPBASE/compact-full"
mkdir -p "$DIR"
cd "$DIR" && git init -q
echo "# My Project" > CLAUDE.md
echo "# Plan" > plan.md
cat > package.json <<'EOF'
{"scripts":{"test":"jest"}}
EOF
touch package-lock.json
git add -A && git commit -m "init" -q

OUTPUT="$(echo '{"cwd":"'"$DIR"'"}' | bash "$HOOKS_DIR/post-compact.sh" 2>&1)"
EXIT=$?
assert_exit "Post-compact: exit 0" 0 "$EXIT"
assert_output_contains "Post-compact: has project name" "compact-full" "$OUTPUT"
assert_output_contains "Post-compact: has stack" "node" "$OUTPUT"
assert_output_contains "Post-compact: has CLAUDE.md" "My Project" "$OUTPUT"
assert_output_contains "Post-compact: has plan" "Plan" "$OUTPUT"
assert_output_contains "Post-compact: has git log" "init" "$OUTPUT"

# Works in empty dir (no git, no files)
DIR="$TMPBASE/compact-empty"
mkdir -p "$DIR"
OUTPUT="$(echo '{"cwd":"'"$DIR"'"}' | bash "$HOOKS_DIR/post-compact.sh" 2>&1)"
EXIT=$?
assert_exit "Post-compact empty dir: exit 0" 0 "$EXIT"
assert_output_contains "Post-compact empty: has project name" "compact-empty" "$OUTPUT"

# =========================================================================
printf "\n${YELLOW}=== 9. Flux Project Integration ===${NC}\n\n"
# =========================================================================

FLUX_DIR="/Users/peterb/Documents/AI/flux"
if [ -d "$FLUX_DIR" ]; then
    # Stack detection
    OUTPUT="$(cd "$FLUX_DIR" && bash -c 'source "'"$HOOKS_DIR"'/lib/detect-stack.sh"; echo "$DETECTED_STACK|$TEST_CMD|$BUILD_CMD|$LINT_CMD"')"
    assert_output_contains "Flux: detects pnpm" "pnpm" "$OUTPUT"
    assert_output_contains "Flux: has test cmd" "pnpm test" "$OUTPUT"
    assert_output_contains "Flux: has build cmd" "pnpm build" "$OUTPUT"
    assert_output_contains "Flux: has lint cmd" "pnpm lint" "$OUTPUT"

    # Post-compact produces rich output
    OUTPUT="$(echo '{"cwd":"'"$FLUX_DIR"'"}' | bash "$HOOKS_DIR/post-compact.sh" 2>&1)"
    assert_output_contains "Flux compact: has CLAUDE.md" "Jewelry" "$OUTPUT"
    assert_output_contains "Flux compact: has stack" "pnpm" "$OUTPUT"
    assert_output_contains "Flux compact: has git history" "feat\|fix\|docs" "$OUTPUT"

    # Verify no local hooks remain
    TOTAL=$((TOTAL + 1))
    if [ ! -f "$FLUX_DIR/.claude/hooks/post-edit-check.sh" ] && \
       [ ! -f "$FLUX_DIR/.claude/hooks/pre-stop-check.sh" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} Flux: no local hooks (stand-guard handles it)\n"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} Flux: local hooks still exist\n"
    fi
else
    printf "${DIM}SKIP${NC} Flux project not found at %s\n" "$FLUX_DIR"
fi

# =========================================================================
printf "\n${YELLOW}=== 10. settings.json Integrity ===${NC}\n\n"
# =========================================================================

SETTINGS="$HOME/.claude/settings.json"

# Valid JSON
TOTAL=$((TOTAL + 1))
if jq empty "$SETTINGS" 2>/dev/null; then
    PASS=$((PASS + 1))
    printf "${GREEN}PASS${NC} settings.json: valid JSON\n"
else
    FAIL=$((FAIL + 1))
    printf "${RED}FAIL${NC} settings.json: invalid JSON\n"
fi

# All hook types present
for hook_type in PostToolUse PreToolUse TaskCompleted Stop SubagentStop SessionStart; do
    TOTAL=$((TOTAL + 1))
    if jq -e ".hooks.\"$hook_type\" | length > 0" "$SETTINGS" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} settings.json: %s hooks present\n" "$hook_type"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} settings.json: %s hooks missing\n" "$hook_type"
    fi
done

# All statusMessages present
SM_COUNT="$(jq '[.hooks | to_entries[] | .value[] | .hooks[]? | select(.statusMessage) | .statusMessage] | length' "$SETTINGS")"
TOTAL=$((TOTAL + 1))
if [ "$SM_COUNT" -ge 7 ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}PASS${NC} settings.json: %d statusMessages found (>=7)\n" "$SM_COUNT"
else
    FAIL=$((FAIL + 1))
    printf "${RED}FAIL${NC} settings.json: only %d statusMessages (expected >=7)\n" "$SM_COUNT"
fi

# =========================================================================
# Results
# =========================================================================
printf "\n${YELLOW}=== Results ===${NC}\n"
printf "Total: %d | ${GREEN}Pass: %d${NC} | ${RED}Fail: %d${NC}\n\n" "$TOTAL" "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
