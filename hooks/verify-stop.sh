#!/usr/bin/env bash
# verify-stop.sh - Stop hook for Claude Code
# Full lint + test + build gate before Claude stops.
# Blocks if any fail, skips if no source changes or stop_hook_active.
# Reads JSON payload from stdin. Exit 0 = allow, exit 2 = block.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STDERR_LIMIT=50

# Read JSON payload from stdin
PAYLOAD="$(cat)"

# Check stop_hook_active first (prevent infinite loops)
STOP_HOOK_ACTIVE="$(echo "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)" || true
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# Extract cwd from payload
CWD="$(echo "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)" || true
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    cd "$CWD"
fi

# Source stack detection
source "$SCRIPT_DIR/lib/detect-stack.sh"

# Check if we're in a git repo
in_git_repo() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Get changed files (staged + unstaged + untracked vs HEAD)
get_changed_files() {
    git diff --name-only HEAD 2>/dev/null || true
    git diff --name-only --cached HEAD 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
}

# If not in a git repo, skip
if ! in_git_repo; then
    exit 0
fi

# Get changed files
CHANGED_FILES="$(get_changed_files | sort -u)"

# No changes? Skip.
if [ -z "$CHANGED_FILES" ]; then
    exit 0
fi

# Check if any source files changed (using SOURCE_PATTERN or fallback)
has_source_changes() {
    if [ -z "${SOURCE_PATTERN:-}" ]; then
        # No stack detected, but files changed. Still run if commands exist.
        [ -n "$CHANGED_FILES" ]
        return
    fi
    echo "$CHANGED_FILES" | grep -qE "$SOURCE_PATTERN"
}

if ! has_source_changes; then
    exit 0
fi

# Run lint, test, build. Collect all errors before deciding.
ERRORS=""
HAD_FAILURE=0

# Lint
if [ -n "${LINT_CMD:-}" ]; then
    LINT_OUTPUT=""
    LINT_EXIT=0
    LINT_OUTPUT="$($LINT_CMD 2>&1)" || LINT_EXIT=$?
    if [ "$LINT_EXIT" -ne 0 ]; then
        HAD_FAILURE=1
        ERRORS="${ERRORS}Lint failed (exit $LINT_EXIT):
$LINT_OUTPUT

"
    fi
fi

# Tests
if [ -n "${TEST_CMD:-}" ]; then
    TEST_OUTPUT=""
    TEST_EXIT=0
    TEST_OUTPUT="$($TEST_CMD 2>&1)" || TEST_EXIT=$?
    if [ "$TEST_EXIT" -ne 0 ]; then
        HAD_FAILURE=1
        ERRORS="${ERRORS}Tests failed (exit $TEST_EXIT):
$TEST_OUTPUT

"
    fi
fi

# Build
if [ -n "${BUILD_CMD:-}" ]; then
    BUILD_OUTPUT=""
    BUILD_EXIT=0
    BUILD_OUTPUT="$($BUILD_CMD 2>&1)" || BUILD_EXIT=$?
    if [ "$BUILD_EXIT" -ne 0 ]; then
        HAD_FAILURE=1
        ERRORS="${ERRORS}Build failed (exit $BUILD_EXIT):
$BUILD_OUTPUT

"
    fi
fi

# Deploy build (platform-specific: CF Pages, Vercel, etc.)
if [ -n "${DEPLOY_BUILD_CMD:-}" ]; then
    DEPLOY_OUTPUT=""
    DEPLOY_EXIT=0
    DEPLOY_OUTPUT="$($DEPLOY_BUILD_CMD 2>&1)" || DEPLOY_EXIT=$?
    if [ "$DEPLOY_EXIT" -ne 0 ]; then
        HAD_FAILURE=1
        ERRORS="${ERRORS}Deploy build failed (exit $DEPLOY_EXIT):
$DEPLOY_OUTPUT

"
    fi
fi

# If any failed, block stop
if [ "$HAD_FAILURE" -ne 0 ]; then
    echo "Fix these issues before stopping:" >&2
    echo "$ERRORS" | head -n "$STDERR_LIMIT" >&2
    exit 2
fi

exit 0
