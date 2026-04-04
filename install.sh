#!/usr/bin/env bash
# install.sh - Install stand-guard enforcement hooks into ~/.claude/
# Usage: bash install.sh [--dry-run]
# Merges with existing config. Idempotent per-hook. Backs up before changes.
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

# --- Prerequisites ---

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required. Install it first (e.g., apt install jq, brew install jq)." >&2
    exit 1
fi

if [ ! -f "$SETTINGS" ]; then
    echo "ERROR: $SETTINGS not found. Initialize Claude Code first." >&2
    exit 1
fi

if ! jq empty "$SETTINGS" 2>/dev/null; then
    echo "ERROR: $SETTINGS is not valid JSON." >&2
    exit 1
fi

# --- Per-hook idempotency checks ---

_has_hook() {
    local hook_type="$1" pattern="$2"
    jq -e "
        .hooks.\"$hook_type\" // [] |
        map(.hooks // [] | map(.command // \"\" | test(\"$pattern\")) | any) |
        any
    " "$SETTINGS" >/dev/null 2>&1
}

NEED_TASK=false
NEED_PLAN_CHECKBOX=false
NEED_STOP=false
NEED_STOP_REVIEW=false
NEED_POST_TOOL_USE=false
NEED_BASH_SAFETY=false
NEED_POST_COMPACT=false

_has_hook "TaskCompleted" "verify-task" || NEED_TASK=true
_has_hook "TaskCompleted" "plan-checkbox" || NEED_PLAN_CHECKBOX=true
_has_hook "Stop" "verify-stop" || NEED_STOP=true
_has_hook "Stop" "review-gate" || NEED_STOP_REVIEW=true
_has_hook "PostToolUse" "post_tool_use" || NEED_POST_TOOL_USE=true
_has_hook "PreToolUse" "bash-safety" || NEED_BASH_SAFETY=true
_has_hook "SessionStart" "post-compact" || NEED_POST_COMPACT=true

ALL_HOOKS_REGISTERED=false
if [ "$NEED_TASK" = false ] && [ "$NEED_PLAN_CHECKBOX" = false ] && [ "$NEED_STOP" = false ] && \
   [ "$NEED_STOP_REVIEW" = false ] && [ "$NEED_POST_TOOL_USE" = false ] && \
   [ "$NEED_BASH_SAFETY" = false ] && [ "$NEED_POST_COMPACT" = false ]; then
    ALL_HOOKS_REGISTERED=true
fi

# --- Backup (only if settings need updating) ---

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$SETTINGS.bak.$TIMESTAMP"

if [ "$ALL_HOOKS_REGISTERED" = false ]; then
    if [ "$DRY_RUN" = false ]; then
        cp "$SETTINGS" "$BACKUP"
        echo "Backup: $BACKUP"
    else
        echo "[DRY RUN] Would backup $SETTINGS to $SETTINGS.bak.$TIMESTAMP"
    fi
fi

# --- Hook definitions ---

TASK_HOOK='{
  "hooks": [{
    "type": "command",
    "command": "bash \"$HOME/.claude/hooks/verify-task.sh\"",
    "timeout": 120,
    "statusMessage": "stand-guard: verifying task (tests + coverage)"
  }]
}'

PLAN_CHECKBOX_HOOK='{
  "hooks": [{
    "type": "command",
    "command": "bash \"$HOME/.claude/hooks/plan-checkbox.sh\"",
    "timeout": 10,
    "statusMessage": "stand-guard: updating plan.md checkbox"
  }]
}'

STOP_CMD_HOOK='{
  "hooks": [{
    "type": "command",
    "command": "bash \"$HOME/.claude/hooks/verify-stop.sh\"",
    "timeout": 120,
    "statusMessage": "stand-guard: verifying stop (lint + test + build)"
  }]
}'

STOP_REVIEW_HOOK='{
  "hooks": [{
    "type": "command",
    "command": "bash \"$HOME/.claude/hooks/review-gate.sh\"",
    "timeout": 10,
    "statusMessage": "stand-guard: checking code review"
  }]
}'

POST_TOOL_USE_HOOK='{
  "matcher": "Write|Edit|MultiEdit",
  "hooks": [{
    "type": "command",
    "command": "bash \"$HOME/.claude/hooks/post_tool_use.sh\"",
    "timeout": 30,
    "statusMessage": "stand-guard: format + lint"
  }]
}'

BASH_SAFETY_HOOK='{
  "matcher": "Bash",
  "hooks": [{
    "type": "command",
    "command": "bash \"$HOME/.claude/hooks/bash-safety.sh\"",
    "statusMessage": "stand-guard: safety check"
  }]
}'

POST_COMPACT_HOOK='{
  "matcher": "compact",
  "hooks": [{
    "type": "command",
    "command": "bash \"$HOME/.claude/hooks/post-compact.sh\"",
    "timeout": 10,
    "statusMessage": "stand-guard: restoring context"
  }]
}'

# --- Build jq merge expression ---

JQ_EXPR="."

if [ "$NEED_TASK" = true ]; then
    JQ_EXPR="$JQ_EXPR | .hooks.TaskCompleted = ((.hooks.TaskCompleted // []) + [\$task_hook])"
fi

if [ "$NEED_PLAN_CHECKBOX" = true ]; then
    JQ_EXPR="$JQ_EXPR | .hooks.TaskCompleted = ((.hooks.TaskCompleted // []) + [\$plan_checkbox_hook])"
fi

if [ "$NEED_STOP" = true ]; then
    JQ_EXPR="$JQ_EXPR | .hooks.Stop = ((.hooks.Stop // []) + [\$stop_cmd_hook])"
    JQ_EXPR="$JQ_EXPR | .hooks.SubagentStop = ((.hooks.SubagentStop // []) + [\$stop_cmd_hook])"
fi

if [ "$NEED_STOP_REVIEW" = true ]; then
    JQ_EXPR="$JQ_EXPR | .hooks.Stop = ((.hooks.Stop // []) + [\$stop_review_hook])"
    JQ_EXPR="$JQ_EXPR | .hooks.SubagentStop = ((.hooks.SubagentStop // []) + [\$stop_review_hook])"
fi

if [ "$NEED_POST_TOOL_USE" = true ]; then
    JQ_EXPR="$JQ_EXPR | .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [\$ptu_hook])"
fi

if [ "$NEED_BASH_SAFETY" = true ]; then
    JQ_EXPR="$JQ_EXPR | .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [\$bs_hook])"
fi

if [ "$NEED_POST_COMPACT" = true ]; then
    JQ_EXPR="$JQ_EXPR | .hooks.SessionStart = ((.hooks.SessionStart // []) + [\$compact_hook])"
fi

# --- Apply merge (only if new hooks need registering) ---

if [ "$ALL_HOOKS_REGISTERED" = false ]; then
    NEW_SETTINGS="$(jq \
        --argjson task_hook "$TASK_HOOK" \
        --argjson plan_checkbox_hook "$PLAN_CHECKBOX_HOOK" \
        --argjson stop_cmd_hook "$STOP_CMD_HOOK" \
        --argjson stop_review_hook "$STOP_REVIEW_HOOK" \
        --argjson ptu_hook "$POST_TOOL_USE_HOOK" \
        --argjson bs_hook "$BASH_SAFETY_HOOK" \
        --argjson compact_hook "$POST_COMPACT_HOOK" \
        "$JQ_EXPR" \
        "$SETTINGS")"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Hooks to add:"
        echo ""
        [ "$NEED_TASK" = true ] && echo "  hooks.TaskCompleted -> verify-task.sh"
        [ "$NEED_PLAN_CHECKBOX" = true ] && echo "  hooks.TaskCompleted -> plan-checkbox.sh"
        [ "$NEED_STOP" = true ] && echo "  hooks.Stop -> verify-stop.sh"
        [ "$NEED_STOP_REVIEW" = true ] && echo "  hooks.Stop -> review-gate.sh"
        [ "$NEED_POST_TOOL_USE" = true ] && echo "  hooks.PostToolUse -> post_tool_use.sh"
        [ "$NEED_BASH_SAFETY" = true ] && echo "  hooks.PreToolUse -> bash-safety.sh"
        [ "$NEED_POST_COMPACT" = true ] && echo "  hooks.SessionStart -> post-compact.sh (compact)"
        echo ""
    fi

    if [ "$DRY_RUN" = false ]; then
        echo "$NEW_SETTINGS" | jq . > "$SETTINGS"
        echo "Updated: $SETTINGS"
    fi
else
    echo "Hook registrations up to date."
fi

# --- Copy hook scripts (always, to pick up updates) ---

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would copy hook scripts to $HOOKS_DIR/"
    exit 0
fi

mkdir -p "$LIB_DIR"

UPDATED=0

# Bash hooks
for src in verify-task.sh plan-checkbox.sh verify-stop.sh review-gate.sh post_tool_use.sh bash-safety.sh post-compact.sh; do
    if [ -f "$SCRIPT_DIR/hooks/$src" ]; then
        if ! cmp -s "$SCRIPT_DIR/hooks/$src" "$HOOKS_DIR/$src" 2>/dev/null; then
            cp "$SCRIPT_DIR/hooks/$src" "$HOOKS_DIR/$src"
            chmod +x "$HOOKS_DIR/$src"
            echo "Updated: $HOOKS_DIR/$src"
            UPDATED=$((UPDATED + 1))
        fi
    fi
done

if ! cmp -s "$SCRIPT_DIR/hooks/lib/detect-stack.sh" "$LIB_DIR/detect-stack.sh" 2>/dev/null; then
    cp "$SCRIPT_DIR/hooks/lib/detect-stack.sh" "$LIB_DIR/detect-stack.sh"
    chmod +x "$LIB_DIR/detect-stack.sh"
    echo "Updated: $LIB_DIR/detect-stack.sh"
    UPDATED=$((UPDATED + 1))
fi

# PowerShell hooks (for Windows via claude-config-sync)
for src in verify-task.ps1 plan-checkbox.ps1 verify-stop.ps1 review-gate.ps1 post_tool_use.ps1 bash-safety.ps1 post-compact.ps1; do
    if [ -f "$SCRIPT_DIR/hooks/$src" ]; then
        if ! cmp -s "$SCRIPT_DIR/hooks/$src" "$HOOKS_DIR/$src" 2>/dev/null; then
            cp "$SCRIPT_DIR/hooks/$src" "$HOOKS_DIR/$src"
            echo "Updated: $HOOKS_DIR/$src"
            UPDATED=$((UPDATED + 1))
        fi
    fi
done

if [ -f "$SCRIPT_DIR/hooks/lib/detect-stack.ps1" ]; then
    if ! cmp -s "$SCRIPT_DIR/hooks/lib/detect-stack.ps1" "$LIB_DIR/detect-stack.ps1" 2>/dev/null; then
        cp "$SCRIPT_DIR/hooks/lib/detect-stack.ps1" "$LIB_DIR/detect-stack.ps1"
        echo "Updated: $LIB_DIR/detect-stack.ps1"
        UPDATED=$((UPDATED + 1))
    fi
fi

# --- Summary ---

echo ""
if [ "$ALL_HOOKS_REGISTERED" = true ] && [ "$UPDATED" -eq 0 ]; then
    echo "stand-guard is up to date. Nothing to do."
elif [ "$UPDATED" -gt 0 ]; then
    echo "stand-guard updated $UPDATED hook script(s)."
else
    echo "stand-guard installed successfully."
fi
echo ""
if [ "$ALL_HOOKS_REGISTERED" = false ]; then
    echo "Hooks registered:"
    [ "$NEED_TASK" = true ] && echo "  TaskCompleted -> verify-task.sh"
    [ "$NEED_PLAN_CHECKBOX" = true ] && echo "  TaskCompleted -> plan-checkbox.sh"
    [ "$NEED_STOP" = true ] && echo "  Stop -> verify-stop.sh"
    [ "$NEED_STOP_REVIEW" = true ] && echo "  Stop -> review-gate.sh"
    [ "$NEED_POST_TOOL_USE" = true ] && echo "  PostToolUse -> post_tool_use.sh"
    [ "$NEED_BASH_SAFETY" = true ] && echo "  PreToolUse -> bash-safety.sh"
    [ "$NEED_POST_COMPACT" = true ] && echo "  SessionStart -> post-compact.sh"
    echo ""
fi
echo "To verify: restart Claude Code and check /hooks"
echo "To remove: bash $SCRIPT_DIR/uninstall.sh"
