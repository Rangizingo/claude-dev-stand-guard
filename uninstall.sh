#!/usr/bin/env bash
# uninstall.sh - Remove stand-guard enforcement hooks from ~/.claude/
# Only removes what install.sh added. Does not touch existing hooks.
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOKS_DIR="$CLAUDE_DIR/hooks"
LIB_DIR="$HOOKS_DIR/lib"

# --- Prerequisites ---

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required." >&2
    exit 1
fi

if [ ! -f "$SETTINGS" ]; then
    echo "ERROR: $SETTINGS not found." >&2
    exit 1
fi

# --- Check if installed ---

has_task_hook() {
    jq -e '.hooks.TaskCompleted // empty | length > 0' "$SETTINGS" >/dev/null 2>&1
}

if ! has_task_hook; then
    echo "stand-guard hooks are not installed. Nothing to remove."
    exit 0
fi

# --- Backup ---

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$SETTINGS.bak.$TIMESTAMP"
cp "$SETTINGS" "$BACKUP"
echo "Backup: $BACKUP"

# --- Remove hooks from settings.json ---

# Remove TaskCompleted entirely (we own it)
# Remove Stop entries that reference our scripts
# Keep any Stop entries that don't reference verify-stop.sh or review agent
NEW_SETTINGS="$(jq '
    del(.hooks.TaskCompleted) |
    if .hooks.Stop then
        .hooks.Stop = [
            .hooks.Stop[] |
            select(
                (.hooks // [] | any(.command // "" | test("verify-stop"))) or
                (.hooks // [] | any(.prompt // "" | test("code review gate")))
                | not
            )
        ] |
        if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
    else . end
' "$SETTINGS")"

echo "$NEW_SETTINGS" | jq . > "$SETTINGS"
echo "Updated: $SETTINGS"

# --- Remove hook scripts ---

REMOVED=0

if [ -f "$HOOKS_DIR/verify-task.sh" ]; then
    rm "$HOOKS_DIR/verify-task.sh"
    echo "Removed: $HOOKS_DIR/verify-task.sh"
    REMOVED=$((REMOVED + 1))
fi

if [ -f "$HOOKS_DIR/verify-stop.sh" ]; then
    rm "$HOOKS_DIR/verify-stop.sh"
    echo "Removed: $HOOKS_DIR/verify-stop.sh"
    REMOVED=$((REMOVED + 1))
fi

if [ -f "$LIB_DIR/detect-stack.sh" ]; then
    rm "$LIB_DIR/detect-stack.sh"
    echo "Removed: $LIB_DIR/detect-stack.sh"
    REMOVED=$((REMOVED + 1))
fi

# Only remove lib dir if empty (don't remove other people's files)
if [ -d "$LIB_DIR" ] && [ -z "$(ls -A "$LIB_DIR" 2>/dev/null)" ]; then
    rmdir "$LIB_DIR"
    echo "Removed: $LIB_DIR/ (empty)"
fi

# --- Summary ---

echo ""
echo "stand-guard uninstalled. $REMOVED files removed."
echo "Backup at: $BACKUP"
echo "Existing hooks (PostToolUse, PreToolUse, etc.) were not touched."
