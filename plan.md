# Claude Dev Stand Guard — Plan

## Current Work

**Active Task:** None (all phases complete)
**Status:** Complete
**Started:** 2026-04-01
**Notes:** Plan finalized after audit against industry best practices + Anthropic guidelines. Scope reduced from 9 phases to 5 after discovering existing advisory config covers security review, code review, TDD, and planning. This project only builds the enforcement layer underneath.
**Last File:** N/A

---

## Overview

### What
Deterministic enforcement hooks for Claude Code that guarantee the professional development cycle runs on every project. Three bash scripts + one agent hook config + an installer.

### Why
The existing advisory config (rules, skills, agents) tells Claude to verify, test, and review. But advisory instructions can be skipped in long sessions, noisy context, or when Claude judges a task as "simple." This project makes skipping impossible by using hooks that block completion and stopping until verification passes.

### How it fits
- Advisory layer (existing): rules, skills, task-protocol, code-review, qa-reviewer
- Enforcement layer (this project): hooks that block if the advisory layer's instructions weren't followed
- Existing enforcement (unchanged): post_tool_use.sh (format + lint), bash-safety.sh (block destructive commands)

### Success criteria
- All hooks install without breaking existing `~/.claude/` config
- Stack detection works for Node, Python, Rust, Go, .NET, Swift
- TaskCompleted hook blocks when tests fail
- TaskCompleted hook blocks when substantial new code has no test files modified
- Stop hook blocks when lint, test, or build fails
- Stop hook skips when no source files changed
- Stop hook doesn't infinite loop (stop_hook_active check)
- Stop agent hook blocks when substantial changes ship without code review
- Install and uninstall are clean and reversible
- All scripts pass their own test suites
- Works on Linux and macOS

---

## Phase 1: Stack Detection Library `[DONE]`

The foundation. Every hook depends on this.

### 1.1 Create detect-stack.sh `[DONE]`
- [x] Detect project type from marker files (package.json, Cargo.toml, pyproject.toml, go.mod, *.csproj, Package.swift)
- [x] Set `$TEST_CMD` — only if tool is installed and (for Node) script exists in package.json
- [x] Set `$BUILD_CMD` — same conditional logic
- [x] Set `$LINT_CMD` — same conditional logic
- [x] Set `$SOURCE_PATTERN` regex for git diff filtering per stack
- [x] Skip gracefully if tools aren't installed (empty string, not error)
- [x] Support monorepo detection (walk up from cwd to find marker files)
- [x] Work on both Linux and macOS (bash 3 compat for macOS)

### 1.2 Write detect-stack tests `[DONE]`
- [x] 16 test groups, 52 assertions — all 6 stacks, edge cases, monorepo, missing tools
- [x] All pass: `bash tests/test-detect-stack.sh`

---

## Phase 2: TaskCompleted Hook `[DONE]`

### 2.1 Create verify-task.sh `[DONE]`
- [x] All requirements implemented: JSON stdin, detect-stack, git diff, test gating, test-file enforcement, 40-line stderr cap

### 2.2 Write verify-task tests `[DONE]`
- [x] 10 test groups, 13 assertions covering all scenarios
- [x] All pass: `bash tests/test-verify-task.sh`

---

## Phase 3: Stop Verification Hook `[DONE]`

### 3.1 Create verify-stop.sh `[DONE]`
- [x] All requirements: JSON stdin, stop_hook_active guard, detect-stack, lint/test/build gating, error concatenation, 50-line stderr cap

### 3.2 Write verify-stop tests `[DONE]`
- [x] 10 test groups, 17 assertions covering all scenarios
- [x] All pass: `bash tests/test-verify-stop.sh`

---

## Phase 4: Code Review Agent Hook `[DONE]`

### 4.1 Define review-check agent hook config `[DONE]`
- [x] Agent hook JSON with Sonnet model, 60s timeout, stop_hook_active guard, review evidence checks
- [x] Valid JSON: `config/review-agent-hook.json`

---

## Phase 5: Installer + Docs `[DONE]`

### 5.1 Create install.sh `[DONE]`
- [x] Prerequisites check, backup, jq merge, --dry-run, idempotent, summary

### 5.2 Create uninstall.sh `[DONE]`
- [x] Removes only stand-guard entries, backs up, leaves existing hooks

### 5.3 Create README.md `[DONE]`
- [x] Full docs: what, why, how, stacks, install/uninstall, customization, cost, troubleshooting

---

## Notes

### plan.md convention (resolved)
All commands, skills, hooks, and agents now consistently reference `plan.md`. The `/scope` command, `/plan` command, template, and all 11 active config files were updated in the same session that created this project.

### Future: Coverage enforcement (not in scope)
Run coverage tools on changed files, check modified lines have test coverage. Per-stack coverage tool detection. Adds 10-30s. Worth doing after core enforcement is proven.

---

## Task Status Legend

- `[TODO]` — Not started
- `[IN PROGRESS]` — Currently working
- `[BLOCKED]` — Waiting on dependency
- `[DONE]` — Completed and verified

---

## Completed

> Tasks are moved here when completed. Most recent at top.
