# Claude Dev Stand Guard

## Overview
Universal enforcement layer for Claude Code that guarantees professional engineering practices across every project. Complements the existing advisory rules (`~/.claude/rules/`), skills (`~/.claude/skills/`), and subagents (`~/.claude/agents/`) with deterministic hooks that cannot be skipped.

The advisory layer (rules, skills) tells Claude what to do. This project makes it impossible not to.

## Goal
Improve quality, security, and standardization of all code produced by Claude Code. Enforce the full professional development cycle: plan, write, verify, review, ship.

## How it fits with existing config

```
ADVISORY (already built, tells Claude what to do)
├── rules/verification.md      "Run proof before claiming done"
├── rules/debugging.md         "Root cause before fix"
├── rules/coding-standards.md  "Security, DRY, testing standards"
├── rules/architecture.md      "Modularity, config, error handling"
├── skills/task-protocol/      "TDD, plan.md coordination, auto-continue"
├── skills/code-review/        "Dispatch reviewer after features"
├── agents/qa-reviewer.md      "Full Playwright + grading rubric"
└── hooks/task_detector.py     "Auto-inject protocol on implementation prompts"

ENFORCEMENT (this project, makes it impossible to skip)
├── hooks/lib/detect-stack.sh  Auto-detect test/build/lint for any stack
├── hooks/verify-task.sh       TaskCompleted: block if tests fail or new code has no tests
└── hooks/verify-stop.sh       Stop: block if lint/test/build fail

    + Stop agent hook config    Block if substantial source changes shipped without code review
                                (auto-skips docs/config-only changes: .md, .txt, .json, .yml, .toml, .env)

EXISTING ENFORCEMENT (already built, unchanged)
├── hooks/post_tool_use.sh     Format + lint every file edit
└── hooks/bash-safety.sh       Block destructive commands
```

## Stack
- **Language:** Bash (hooks, detection library)
- **Hook types:** `command` for deterministic gates, `agent` (Sonnet) for judgment-based review check
- **Install target:** `~/.claude/` (global, all projects)
- **Required:** `jq` (JSON parsing in hooks)
- **No other external dependencies**

## Architecture
```
claude-dev-stand-guard/
├── CLAUDE.md                      # This file
├── plan.md                        # Development tasks and progress
├── README.md                      # Documentation + install guide
├── hooks/
│   ├── verify-task.sh             # TaskCompleted: run tests + check test files exist
│   ├── verify-stop.sh             # Stop: full lint + test + build gate
│   └── lib/
│       └── detect-stack.sh        # Auto-detect project type + commands
├── config/
│   └── review-agent-hook.json     # Stop agent hook config (review check)
├── install.sh                     # Installer (merges with existing config)
├── uninstall.sh                   # Clean removal
└── tests/
    ├── test-detect-stack.sh       # Test stack detection
    ├── test-verify-task.sh        # Test task verification hook
    └── test-verify-stop.sh        # Test stop verification hook
```

## Key Rules

**YOU MUST:**
- Follow Anthropic's hook patterns exactly (JSON schema, exit codes, `$ARGUMENTS`)
- Use `stop_hook_active` check in Stop hooks to prevent infinite loops
- Use `detect-stack.sh` as single source for all stack detection (DRY)
- Exit 0 to allow, exit 2 to block with stderr feedback to Claude
- Never hard-fail on missing tools (skip gracefully)
- Test every hook script independently before wiring into settings.json
- Keep hooks fast: command hooks <5s per-edit, <120s for Stop

**IMPORTANT:**
- This installs into `~/.claude/` (the user's global config). Be surgical. Merge, don't overwrite.
- The existing `post_tool_use.sh`, `bash-safety.sh`, and `task_detector.py` must not be replaced or broken.
- Agent hooks use Sonnet. Prompt hooks use Sonnet. Both are acceptable per user preference.
- All scripts must work on Linux and macOS.

## Cross-platform sync (claude-config-sync)

These hooks sync across machines via `claude-config-sync`, which manages `~/.claude/` as a git repo.

**How it works automatically:**
- `claude-config-sync` pushes `settings.json` and `hooks/` on SessionEnd, pulls on SessionStart
- Per-platform settings are preserved: `settings.linux.json`, `settings.darwin.json`, `settings.windows.json`
- Hook commands are auto-adapted on pull: `bash script.sh` becomes `powershell script.ps1` on Windows (and reverse on Unix)
- Home directory paths in settings.json are rewritten to the current machine's home

**Windows support requires `.ps1` equivalents.** The sync tool assumes a `.ps1` file exists for every `.sh` file. To support Windows, provide:
- `hooks/verify-task.ps1`
- `hooks/verify-stop.ps1`
- `hooks/lib/detect-stack.ps1`

Without these, hooks sync to Windows but silently fail (the `.ps1` files don't exist). Linux and macOS work regardless.

## Supported stacks (auto-detected)

| Marker file | Stack | Test | Build | Lint |
|---|---|---|---|---|
| `package.json` | Node/TS | `npm run test` | `npm run build` | `npm run lint` |
| `pyproject.toml` / `requirements.txt` | Python | `pytest` | skip | `ruff check .` |
| `Cargo.toml` | Rust | `cargo test` | `cargo build` | `cargo clippy` |
| `go.mod` | Go | `go test ./...` | `go build ./...` | `go vet ./...` |
| `*.csproj` | .NET | `dotnet test` | `dotnet build` | skip |
| `Package.swift` | Swift | `swift test` | `swift build` | `swiftlint` |

Commands only set if the tool is actually installed and (for Node) the script exists in package.json.

## Commands
```bash
# Run tests
bash tests/test-detect-stack.sh
bash tests/test-verify-task.sh
bash tests/test-verify-stop.sh

# Install (merges into existing ~/.claude/ config)
bash install.sh

# Uninstall (removes only what was added)
bash uninstall.sh
```

## Conventions
- Bash strict mode: `set -euo pipefail`
- `jq` for all JSON parsing
- Source `detect-stack.sh` at the top of every hook needing stack info
- Log to stderr only (stdout reserved for JSON output to Claude)
- Commits: `feat|fix|docs|refactor|test: description`

## Note: plan.md convention
All commands, skills, hooks, and agents reference `plan.md` as the single source of truth. The `/scope` command creates it, `/plan` adds tasks to it, and the runtime toolchain (`task_detector.py`, `task-protocol`, `qa-reviewer`, `code-review`) reads from it.
