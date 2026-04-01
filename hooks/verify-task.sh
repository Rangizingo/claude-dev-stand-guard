#!/usr/bin/env bash
# verify-task.sh - TaskCompleted hook for Claude Code
# Blocks task completion when:
#   1. Tests fail
#   2. Substantial new code (>20 lines) has no test files modified
# Reads JSON payload from stdin. Exit 0 = allow, exit 2 = block.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STDERR_LIMIT=40

# Read JSON payload from stdin
PAYLOAD="$(cat)"

# Extract cwd from payload, fall back to current directory
CWD="$(echo "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)" || true
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    cd "$CWD"
fi

# Source stack detection
source "$SCRIPT_DIR/lib/detect-stack.sh"

# Helper: truncate and write to stderr
emit_stderr() {
    local msg="$1"
    echo "$msg" | head -n "$STDERR_LIMIT" >&2
}

# Check if we're in a git repo
in_git_repo() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Get list of changed files (staged + unstaged vs HEAD)
get_changed_files() {
    git diff --name-only HEAD 2>/dev/null || true
    git diff --name-only --cached HEAD 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
}

# Check if any source files changed (using SOURCE_PATTERN from detect-stack)
has_source_changes() {
    local files="$1"
    if [ -z "$SOURCE_PATTERN" ]; then
        # No stack detected; check if any non-hidden files changed
        if [ -n "$files" ]; then
            return 0
        fi
        return 1
    fi
    echo "$files" | grep -qE "$SOURCE_PATTERN"
}

# Count added source lines
count_new_source_lines() {
    if [ -z "$SOURCE_PATTERN" ]; then
        # No pattern; count all added lines
        git diff HEAD 2>/dev/null | grep -c '^+[^+]' || true
        return
    fi
    local total=0
    local files
    files="$(get_changed_files | sort -u | grep -E "$SOURCE_PATTERN" || true)"
    for f in $files; do
        if [ -f "$f" ]; then
            local lines
            lines="$(git diff HEAD -- "$f" 2>/dev/null | grep -c '^+[^+]' || true)"
            # For untracked files, count all lines
            if [ "$lines" -eq 0 ] && ! git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
                lines="$(wc -l < "$f" 2>/dev/null || echo 0)"
            fi
            total=$((total + lines))
        fi
    done
    echo "$total"
}

# Check if any test files were modified
has_test_file_changes() {
    local files="$1"
    # Common test file patterns across stacks
    echo "$files" | grep -qiE '(test|spec|_test|tests/)' 2>/dev/null
}

# --- Main logic ---

# If not in a git repo, skip all diff-based checks
if ! in_git_repo; then
    exit 0
fi

# Get changed files
CHANGED_FILES="$(get_changed_files | sort -u)"

# No changes at all? Skip (research/docs task)
if [ -z "$CHANGED_FILES" ]; then
    exit 0
fi

# Check if source files changed
if ! has_source_changes "$CHANGED_FILES"; then
    exit 0
fi

# Run tests if TEST_CMD is set
if [ -n "${TEST_CMD:-}" ]; then
    TEST_OUTPUT=""
    TEST_EXIT=0
    TEST_OUTPUT="$($TEST_CMD 2>&1)" || TEST_EXIT=$?
    if [ "$TEST_EXIT" -ne 0 ]; then
        {
            echo "Tests failed (exit $TEST_EXIT). Fix before completing this task."
            echo "---"
            echo "$TEST_OUTPUT"
        } | head -n "$STDERR_LIMIT" >&2
        exit 2
    fi
fi

# Check for substantial new code without test files
NEW_LINES="$(count_new_source_lines)"
if [ "${NEW_LINES:-0}" -gt 20 ]; then
    if ! has_test_file_changes "$CHANGED_FILES"; then
        emit_stderr "Write tests for new code before completing this task. ($NEW_LINES new source lines, 0 test files modified.)"
        exit 2
    fi
fi

# All checks passed
exit 0
