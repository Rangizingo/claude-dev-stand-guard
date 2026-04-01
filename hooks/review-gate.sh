#!/usr/bin/env bash
# review-gate.sh — Pre-check for code review agent hook
# Runs as a command hook BEFORE the agent hook on Stop/SubagentStop.
# If no source files changed, outputs allow decision so the agent hook
# doesn't need to spin up at all.
#
# Exit 0 with no output = let other hooks run (including agent)
# Exit 0 with JSON decision = skip further hooks in this group
set -uo pipefail

INPUT="$(cat)"

# Check stop_hook_active
STOP_ACTIVE="$(printf '%s' "${INPUT}" | jq -r '.stop_hook_active // false' 2>/dev/null)" || true
if [[ "${STOP_ACTIVE}" == "true" ]]; then
    echo '{"decision": "allow", "reason": "Stop hook already active."}'
    exit 0
fi

# Check if we're in a git repo
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo '{"decision": "allow", "reason": "Not a git repo, skipping review check."}'
    exit 0
fi

# Check if any source files changed
SOURCE_PATTERN='\.(ts|tsx|js|jsx|py|rs|cs|swift|go|astro)$'
CHANGED_SOURCE="$(git diff --name-only HEAD 2>/dev/null | grep -E "${SOURCE_PATTERN}" || true)"

if [[ -z "${CHANGED_SOURCE}" ]]; then
    echo '{"decision": "allow", "reason": "Only docs/config changed, no review needed."}'
    exit 0
fi

# Count lines changed in source files
LINES_CHANGED="$(git diff --numstat HEAD 2>/dev/null | grep -E "${SOURCE_PATTERN}" | awk '{sum+=$1+$2} END{print sum+0}' || echo "0")"

if [[ "${LINES_CHANGED}" -lt 20 ]]; then
    echo '{"decision": "allow", "reason": "Trivial source changes (<20 lines), no review needed."}'
    exit 0
fi

# Substantial source changes. Check for review evidence.
TODAY="$(date +%Y-%m-%d)"

# Check for qa-report
if [[ -f ".claude/qa-report.md" ]]; then
    REPORT_DATE="$(date -r ".claude/qa-report.md" +%Y-%m-%d 2>/dev/null || echo "")"
    if [[ "${REPORT_DATE}" == "${TODAY}" ]]; then
        echo '{"decision": "allow", "reason": "Code review evidence found (qa-report.md)."}'
        exit 0
    fi
fi

# Check git log for review mentions
if git log --oneline -5 2>/dev/null | grep -qiE 'review|qa'; then
    echo '{"decision": "allow", "reason": "Code review evidence found in recent commits."}'
    exit 0
fi

# Substantial changes, no review evidence
echo "{\"decision\": \"block\", \"reason\": \"${LINES_CHANGED} lines of source code changed without code review. Run /qa or the code-review skill before stopping.\"}"
exit 0
