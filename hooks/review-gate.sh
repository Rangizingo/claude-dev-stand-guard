#!/usr/bin/env bash
# review-gate.sh — Code review gate for Stop/SubagentStop
# Blocks stop if substantial source changes shipped without code review.
# Silent exit 0 = allow stop. JSON with decision "block" = block stop.
set -uo pipefail

INPUT="$(cat)"

# Check stop_hook_active — prevent infinite loops
STOP_ACTIVE="$(printf '%s' "${INPUT}" | jq -r '.stop_hook_active // false' 2>/dev/null)" || true
if [[ "${STOP_ACTIVE}" == "true" ]]; then
    exit 0
fi

# Not a git repo? Skip.
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    exit 0
fi

# Check if any source files changed
SOURCE_PATTERN='\.(ts|tsx|js|jsx|py|rs|cs|swift|go|astro)$'
CHANGED_SOURCE="$(git diff --name-only HEAD 2>/dev/null | grep -E "${SOURCE_PATTERN}" || true)"

# No source changes? Skip silently.
if [[ -z "${CHANGED_SOURCE}" ]]; then
    exit 0
fi

# Count lines changed in source files
LINES_CHANGED="$(git diff --numstat HEAD 2>/dev/null | grep -E "${SOURCE_PATTERN}" | awk '{sum+=$1+$2} END{print sum+0}' || echo "0")"

# Trivial changes? Skip.
if [[ "${LINES_CHANGED}" -lt 20 ]]; then
    exit 0
fi

# Substantial source changes. Check for review evidence.
TODAY="$(date +%Y-%m-%d)"

# Check for any qa-report file modified today
for REPORT in .claude/qa-report*.md; do
    if [[ -f "${REPORT}" ]]; then
        REPORT_DATE="$(date -r "${REPORT}" +%Y-%m-%d 2>/dev/null || echo "")"
        if [[ "${REPORT_DATE}" == "${TODAY}" ]]; then
            exit 0
        fi
    fi
done

# Check git log for review mentions
if git log --oneline -5 2>/dev/null | grep -qiE 'review|qa'; then
    exit 0
fi

# Substantial changes, no review evidence — block
echo "${LINES_CHANGED} lines of source code changed without code review. Run /qa or the code-review skill before stopping." >&2
exit 2
