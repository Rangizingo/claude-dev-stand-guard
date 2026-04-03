#!/usr/bin/env bash
# bash-safety.sh — Block dangerous bash commands globally
# PreToolUse hook on Bash — exit 2 to hard block

INPUT="$(cat)"
CMD="$(printf '%s' "${INPUT}" | jq -r '.tool_input.command // empty' 2>/dev/null)" || true

[[ -z "${CMD}" ]] && exit 0

# Hard blocks — irreversible or extremely dangerous operations
if echo "${CMD}" | grep -qE '(rm -rf /[^a-z]|rm -rf /\s*$|DROP TABLE|DROP DATABASE|truncate /|mkfs\.|dd if=.* of=/dev/)'; then
    echo "Blocked: destructive system command detected. Use a safer alternative." >&2
    exit 2
fi

# Block force push to main/master
if echo "${CMD}" | grep -qE 'git push.*--force.*(main|master)|git push.*-f.*(main|master)'; then
    echo "Blocked: force push to main/master. This could destroy remote history." >&2
    exit 2
fi

# Block hard reset without confirmation
if echo "${CMD}" | grep -qE 'git reset --hard'; then
    echo "Blocked: git reset --hard can destroy uncommitted work. Use git stash first." >&2
    exit 2
fi

exit 0
