#!/usr/bin/env bash
# post-compact.sh — SessionStart (compact) hook for Claude Code
# Re-injects project context after context window compaction.
# Output goes to stdout and is injected into Claude's context.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read payload from stdin (contains cwd, session_id, etc.)
PAYLOAD="$(cat)"

# Extract cwd from payload
CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)" || true
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    cd "$CWD"
fi

# Source stack detection
source "$SCRIPT_DIR/lib/detect-stack.sh"

echo "=== POST-COMPACT CONTEXT ==="
echo ""

# Project name + path
echo "Project: $(basename "$(pwd)") ($(pwd))"

# Detected stack
if [ -n "$DETECTED_STACK" ]; then
    STACK_INFO="Stack: $DETECTED_STACK"
    [ -n "$TEST_CMD" ] && STACK_INFO="$STACK_INFO | test: $TEST_CMD"
    [ -n "$BUILD_CMD" ] && STACK_INFO="$STACK_INFO | build: $BUILD_CMD"
    [ -n "$LINT_CMD" ] && STACK_INFO="$STACK_INFO | lint: $LINT_CMD"
    echo "$STACK_INFO"
fi
echo ""

# CLAUDE.md summary (project-specific context lives here)
if [ -f "CLAUDE.md" ]; then
    echo "Project context (CLAUDE.md, first 30 lines):"
    head -30 CLAUDE.md
    echo ""
fi

# Recent git history
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Recent commits:"
    git log --oneline -5 2>/dev/null
    echo ""
    echo "Modified files (last 3 commits):"
    git diff --name-only HEAD~3 2>/dev/null | head -20
    echo ""
fi

# Current plan
if [ -f "plan.md" ]; then
    echo "Current plan (first 40 lines):"
    head -40 plan.md
    echo ""
fi

echo "=== END CONTEXT ==="
