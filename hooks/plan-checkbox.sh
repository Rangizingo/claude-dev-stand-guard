#!/usr/bin/env bash
# plan-checkbox.sh - TaskCompleted hook for Claude Code
# When a task is marked complete, fuzzy-matches its subject against
# unchecked items in plan.md and flips [ ] to [x].
# Reads JSON payload from stdin. Exit 0 = allow (never blocks).
set -euo pipefail

# Read JSON payload from stdin
PAYLOAD="$(cat)"

# Extract cwd and task subject from payload
CWD="$(echo "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)" || true
TASK_SUBJECT="$(echo "$PAYLOAD" | jq -r '.task_subject // empty' 2>/dev/null)" || true

# Nothing to do if no subject
if [ -z "$TASK_SUBJECT" ]; then
    exit 0
fi

# Navigate to project directory
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    cd "$CWD"
fi

# Find plan.md - walk up from cwd to repo root
find_plan() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/plan.md" ]; then
            echo "$dir/plan.md"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

PLAN_FILE="$(find_plan 2>/dev/null)" || true

# No plan.md found - nothing to do
if [ -z "$PLAN_FILE" ]; then
    exit 0
fi

# Extract key phrases from task subject for fuzzy matching.
# Strip common prefixes (Build, Add, Fix, Wire, Create, etc.) and
# split into searchable tokens. We need at least 2 tokens to match.
normalize() {
    echo "$1" \
        | sed -E 's/^(Build|Add|Fix|Wire|Create|Delete|Remove|Update|Implement|Generate|Write) //i' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9 ]//g' \
        | tr -s ' '
}

NORMALIZED="$(normalize "$TASK_SUBJECT")"

# Build a grep -i pattern from the normalized subject.
# Use the longest 2-3 significant words (>3 chars) as AND conditions.
# This avoids false matches on common short words.
WORDS=()
for word in $NORMALIZED; do
    if [ "${#word}" -gt 3 ]; then
        WORDS+=("$word")
    fi
done

# Need at least 2 significant words to match
if [ "${#WORDS[@]}" -lt 2 ]; then
    exit 0
fi

# Take up to 3 most significant words (longest first for specificity)
IFS=$'\n' SORTED_WORDS=($(printf '%s\n' "${WORDS[@]}" | awk '{ print length, $0 }' | sort -rn | head -3 | awk '{ print $2 }'))
unset IFS

# Find unchecked lines that contain ALL significant words (case-insensitive)
MATCH_LINE=""
MATCH_NUM=0

while IFS= read -r line_data; do
    line_num="${line_data%%:*}"
    line_text="${line_data#*:}"

    # Check if this unchecked line contains all our search words
    all_match=true
    for word in "${SORTED_WORDS[@]}"; do
        if ! echo "$line_text" | grep -qi "$word"; then
            all_match=false
            break
        fi
    done

    if [ "$all_match" = true ]; then
        MATCH_LINE="$line_text"
        MATCH_NUM="$line_num"
        break  # Take first match
    fi
done < <(grep -n '^\- \[ \]' "$PLAN_FILE" 2>/dev/null || true)

# No match found — remind Claude to check manually
if [ -z "$MATCH_LINE" ] || [ "$MATCH_NUM" -eq 0 ]; then
    echo "plan-checkbox: no auto-match for \"$TASK_SUBJECT\". If this task completed plan.md items, check them off manually." >&2
    exit 0
fi

# Replace [ ] with [x] on the matched line using sed
# Use line number for precision (avoids matching wrong line)
if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "${MATCH_NUM}s/- \[ \]/- [x]/" "$PLAN_FILE"
else
    sed -i "${MATCH_NUM}s/- \[ \]/- [x]/" "$PLAN_FILE"
fi

echo "plan-checkbox: marked done in plan.md line $MATCH_NUM" >&2

# Always exit 0 - this hook should never block task completion
exit 0
