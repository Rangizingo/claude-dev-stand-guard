#!/usr/bin/env bash
# install.sh - Install stand-guard enforcement hooks into ~/.claude/
# Usage: bash install.sh [--dry-run]
# Merges with existing config. Idempotent. Backs up before changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOKS_DIR="$CLAUDE_DIR/hooks"
LIB_DIR="$HOOKS_DIR/lib"

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
    echo "[DRY RUN] No files will be changed."
    echo ""
fi

# Marker comment used to identify our hooks in settings.json
GUARD_MARKER="stand-guard"

# --- Prerequisites ---

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required. Install it first (e.g., apt install jq, brew install jq)." >&2
    exit 1
fi

if [ ! -f "$SETTINGS" ]; then
    echo "ERROR: $SETTINGS not found. Initialize Claude Code first." >&2
    exit 1
fi

# Validate existing settings.json
if ! jq empty "$SETTINGS" 2>/dev/null; then
    echo "ERROR: $SETTINGS is not valid JSON." >&2
    exit 1
fi

# --- Check idempotency ---

is_already_installed() {
    # Check if our TaskCompleted hook already exists
    jq -e '.hooks.TaskCompleted // empty | length > 0' "$SETTINGS" >/dev/null 2>&1
}

if is_already_installed; then
    echo "stand-guard hooks are already installed."
    echo "To reinstall, run uninstall.sh first."
    exit 0
fi

# --- Backup ---

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$SETTINGS.bak.$TIMESTAMP"

if [ "$DRY_RUN" = false ]; then
    cp "$SETTINGS" "$BACKUP"
    echo "Backup: $BACKUP"
else
    echo "[DRY RUN] Would backup $SETTINGS to $SETTINGS.bak.$TIMESTAMP"
fi

# --- Build new hooks JSON ---

# TaskCompleted hook entry
TASK_HOOK='[{
  "hooks": [{
    "type": "command",
    "command": "bash \"$HOME/.claude/hooks/verify-task.sh\"",
    "timeout": 120
  }]
}]'

# Stop command hook entry
STOP_CMD_HOOK='{
  "hooks": [{
    "type": "command",
    "command": "bash \"$HOME/.claude/hooks/verify-stop.sh\"",
    "timeout": 120
  }]
}'

# Stop agent hook entry (from config file)
STOP_AGENT_HOOK_CONFIG="$SCRIPT_DIR/config/review-agent-hook.json"
STOP_AGENT_HOOK="{
  \"hooks\": [$(cat "$STOP_AGENT_HOOK_CONFIG")]
}"

# Combine Stop hooks into an array (append to existing if any)
STOP_HOOKS="[$STOP_CMD_HOOK, $STOP_AGENT_HOOK]"

# --- Merge into settings.json ---

# Use jq to merge: add TaskCompleted and Stop hooks without touching existing keys
NEW_SETTINGS="$(jq \
    --argjson task_hook "$TASK_HOOK" \
    --argjson stop_hooks "$STOP_HOOKS" \
    '.hooks.TaskCompleted = $task_hook | .hooks.Stop = ((.hooks.Stop // []) + $stop_hooks) | .hooks.SubagentStop = ((.hooks.SubagentStop // []) + $stop_hooks)' \
    "$SETTINGS")"

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would add to settings.json:"
    echo ""
    echo "  hooks.TaskCompleted: command hook -> verify-task.sh"
    echo "  hooks.Stop[0]: command hook -> verify-stop.sh"
    echo "  hooks.SubagentStop: mirrors Stop hooks (subagents get same gates)"
    echo "  hooks.Stop[1]: agent hook -> code review check (Sonnet)"
    echo ""
    echo "[DRY RUN] Would copy files:"
    echo "  $SCRIPT_DIR/hooks/verify-task.sh -> $HOOKS_DIR/verify-task.sh"
    echo "  $SCRIPT_DIR/hooks/verify-stop.sh -> $HOOKS_DIR/verify-stop.sh"
    echo "  $SCRIPT_DIR/hooks/lib/detect-stack.sh -> $LIB_DIR/detect-stack.sh"
    echo ""
    echo "[DRY RUN] Merged settings.json diff:"
    diff <(jq --sort-keys . "$SETTINGS") <(echo "$NEW_SETTINGS" | jq --sort-keys .) || true
    exit 0
fi

# --- Write settings ---

echo "$NEW_SETTINGS" | jq . > "$SETTINGS"
echo "Updated: $SETTINGS"

# --- Copy hook scripts ---

mkdir -p "$LIB_DIR"

cp "$SCRIPT_DIR/hooks/verify-task.sh" "$HOOKS_DIR/verify-task.sh"
chmod +x "$HOOKS_DIR/verify-task.sh"
echo "Installed: $HOOKS_DIR/verify-task.sh"

cp "$SCRIPT_DIR/hooks/verify-stop.sh" "$HOOKS_DIR/verify-stop.sh"
chmod +x "$HOOKS_DIR/verify-stop.sh"
echo "Installed: $HOOKS_DIR/verify-stop.sh"

cp "$SCRIPT_DIR/hooks/lib/detect-stack.sh" "$LIB_DIR/detect-stack.sh"
chmod +x "$LIB_DIR/detect-stack.sh"
echo "Installed: $LIB_DIR/detect-stack.sh"

# --- Summary ---

echo ""
echo "stand-guard installed successfully."
echo ""
echo "Hooks added:"
echo "  TaskCompleted -> verify-task.sh (blocks if tests fail or no tests written)"
echo "  Stop -> verify-stop.sh (blocks if lint/test/build fail)"
echo "  Stop -> review agent (blocks if substantial changes lack code review)"
echo ""
echo "To verify: restart Claude Code and check /hooks"
echo "To remove: bash $SCRIPT_DIR/uninstall.sh"
