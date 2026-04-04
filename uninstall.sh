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

# --- Check if anything is installed ---

_has_any_hook() {
    jq -e '
        (.hooks.TaskCompleted // [] | map(.hooks // [] | map(.command // "" | test("verify-task|plan-checkbox")) | any) | any) or
        (.hooks.Stop // [] | map(.hooks // [] | map(.command // "" | test("verify-stop|review-gate")) | any) | any) or
        (.hooks.PostToolUse // [] | map(.hooks // [] | map(.command // "" | test("post_tool_use")) | any) | any) or
        (.hooks.PreToolUse // [] | map(.hooks // [] | map(.command // "" | test("bash-safety")) | any) | any) or
        (.hooks.SessionStart // [] | map(.hooks // [] | map(.command // "" | test("post-compact")) | any) | any)
    ' "$SETTINGS" >/dev/null 2>&1
}

if ! _has_any_hook; then
    echo "stand-guard hooks are not installed. Nothing to remove."
    exit 0
fi

# --- Backup ---

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$SETTINGS.bak.$TIMESTAMP"
cp "$SETTINGS" "$BACKUP"
echo "Backup: $BACKUP"

# --- Remove hooks from settings.json ---

# Remove our entries from each hook type, clean up empty arrays
NEW_SETTINGS="$(jq '
    # TaskCompleted: remove entries with verify-task or plan-checkbox
    | if .hooks.TaskCompleted then
        .hooks.TaskCompleted = [
            .hooks.TaskCompleted[] |
            select(.hooks // [] | map(.command // "" | test("verify-task|plan-checkbox")) | any | not)
        ] |
        if (.hooks.TaskCompleted | length) == 0 then del(.hooks.TaskCompleted) else . end
      else . end

    # Stop: remove verify-stop and review-gate entries
    | if .hooks.Stop then
        .hooks.Stop = [
            .hooks.Stop[] |
            select(.hooks // [] | map(.command // "" | test("verify-stop|review-gate")) | any | not)
        ] |
        if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
      else . end

    # SubagentStop: same as Stop
    | if .hooks.SubagentStop then
        .hooks.SubagentStop = [
            .hooks.SubagentStop[] |
            select(.hooks // [] | map(.command // "" | test("verify-stop|review-gate")) | any | not)
        ] |
        if (.hooks.SubagentStop | length) == 0 then del(.hooks.SubagentStop) else . end
      else . end

    # PostToolUse: remove post_tool_use entries
    | if .hooks.PostToolUse then
        .hooks.PostToolUse = [
            .hooks.PostToolUse[] |
            select(.hooks // [] | map(.command // "" | test("post_tool_use")) | any | not)
        ] |
        if (.hooks.PostToolUse | length) == 0 then del(.hooks.PostToolUse) else . end
      else . end

    # PreToolUse: remove bash-safety entries
    | if .hooks.PreToolUse then
        .hooks.PreToolUse = [
            .hooks.PreToolUse[] |
            select(.hooks // [] | map(.command // "" | test("bash-safety")) | any | not)
        ] |
        if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
      else . end

    # SessionStart: remove post-compact entries (preserve claude-config-sync)
    | if .hooks.SessionStart then
        .hooks.SessionStart = [
            .hooks.SessionStart[] |
            select(.hooks // [] | map(.command // "" | test("post-compact")) | any | not)
        ] |
        if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
      else . end
' "$SETTINGS")"

echo "$NEW_SETTINGS" | jq . > "$SETTINGS"
echo "Updated: $SETTINGS"

# --- Remove hook scripts ---

REMOVED=0

# Bash hooks
for f in verify-task.sh plan-checkbox.sh verify-stop.sh review-gate.sh post_tool_use.sh bash-safety.sh post-compact.sh; do
    if [ -f "$HOOKS_DIR/$f" ]; then
        rm "$HOOKS_DIR/$f"
        echo "Removed: $HOOKS_DIR/$f"
        REMOVED=$((REMOVED + 1))
    fi
done

# PowerShell hooks
for f in verify-task.ps1 plan-checkbox.ps1 verify-stop.ps1 review-gate.ps1 post_tool_use.ps1 bash-safety.ps1 post-compact.ps1; do
    if [ -f "$HOOKS_DIR/$f" ]; then
        rm "$HOOKS_DIR/$f"
        echo "Removed: $HOOKS_DIR/$f"
        REMOVED=$((REMOVED + 1))
    fi
done

# Lib files
for f in detect-stack.sh detect-stack.ps1; do
    if [ -f "$LIB_DIR/$f" ]; then
        rm "$LIB_DIR/$f"
        echo "Removed: $LIB_DIR/$f"
        REMOVED=$((REMOVED + 1))
    fi
done

# Only remove lib dir if empty
if [ -d "$LIB_DIR" ] && [ -z "$(ls -A "$LIB_DIR" 2>/dev/null)" ]; then
    rmdir "$LIB_DIR"
    echo "Removed: $LIB_DIR/ (empty)"
fi

# --- Summary ---

echo ""
echo "stand-guard uninstalled. $REMOVED files removed."
echo "Backup at: $BACKUP"
