> ## SUPERSEDED
> This repo seeded 7 hooks in April 2026. The live tree at `~/.claude` (repo: `my-claude-config`) is the source of truth and has evolved. Running `install.sh` would overwrite 6 diverged hooks with stale versions.
>
> `install.sh` has been renamed to `install.sh.superseded` to prevent accidental use. Do not run it against `~/.claude`.

# Stand Guard

Enforcement hooks for Claude Code. Three bash scripts that make it impossible to skip testing, linting, building, or code review.

## What it does

Your advisory config (rules, skills, agents) tells Claude what to do. Stand Guard makes it impossible not to.

| Hook | Event | What it does |
|---|---|---|
| `verify-task.sh` | TaskCompleted | Blocks if tests fail, or >20 lines of new code with zero test files modified |
| `plan-checkbox.sh` | TaskCompleted | Auto-marks matching plan.md items as `[x]` when a task completes (never blocks) |
| `verify-stop.sh` | Stop | Blocks if lint, test, or build failures |
| `review-gate.sh` | Stop | Blocks if substantial changes shipped without code review evidence |

When a hook blocks, it writes the reason to stderr. Claude reads that and fixes the issue before trying again.

## How it fits

```
ADVISORY (tells Claude what to do)
  rules/         verification, debugging, coding-standards, architecture
  skills/        task-protocol, code-review, qa
  agents/        qa-reviewer

ENFORCEMENT (makes skipping impossible)      <-- this project
  verify-task.sh     TaskCompleted gate (tests + coverage)
  plan-checkbox.sh   TaskCompleted auto-update (plan.md checkboxes)
  verify-stop.sh     Stop gate (lint + test + build)
  review-gate.sh     Stop gate (code review check)
  post_tool_use.sh   PostToolUse: format + lint on every edit
  bash-safety.sh     PreToolUse: block destructive commands
  post-compact.sh    SessionStart: restore context after compaction
```

## Supported stacks

Auto-detected from marker files. Commands only set if the tool is installed.

| Marker | Stack | Test | Build | Lint |
|---|---|---|---|---|
| `package.json` | Node/TS | `npm run test` | `npm run build` | `npm run lint` |
| `pyproject.toml` / `requirements.txt` | Python | `pytest` | - | `ruff check .` |
| `Cargo.toml` | Rust | `cargo test` | `cargo build` | `cargo clippy` |
| `go.mod` | Go | `go test ./...` | `go build ./...` | `go vet ./...` |
| `*.csproj` | .NET | `dotnet test` | `dotnet build` | - |
| `Package.swift` | Swift | `swift test` | `swift build` | `swiftlint` |

For Node projects, each npm script is only used if it exists in `package.json`. Missing tools (no cargo, no ruff, etc.) result in the command being skipped, not an error.

Monorepo support: detect-stack walks up from the current directory to find the nearest marker file.

## Install

```bash
# Prerequisites
jq --version  # must be installed

# Preview what will change
bash install.sh --dry-run

# Install
bash install.sh
```

The installer:
- Backs up `~/.claude/settings.json` with a timestamp
- Merges new hooks without touching existing config
- Copies scripts to `~/.claude/hooks/` and `~/.claude/hooks/lib/`
- Is idempotent (running twice won't duplicate hooks)

## Uninstall

```bash
bash uninstall.sh
```

Removes only what was added. Your existing PostToolUse, PreToolUse, SessionStart, and SessionEnd hooks are never touched.

## When hooks fire (and don't)

### verify-task.sh (TaskCompleted)

Fires every time a task is marked complete.

**Blocks when:**
- `TEST_CMD` is set and tests fail
- >20 lines of new source code added with zero test files modified

**Skips when:**
- No source files changed (research/docs tasks)
- No test runner detected for the stack
- Not in a git repo

### verify-stop.sh (Stop)

Fires when Claude tries to stop the session.

**Blocks when:**
- Lint fails (`LINT_CMD`)
- Tests fail (`TEST_CMD`)
- Build fails (`BUILD_CMD`)

**Skips when:**
- `stop_hook_active` is true (prevents infinite loops)
- No source files changed
- No stack detected / no commands available
- Not in a git repo

### Review agent (Stop)

Fires on Stop alongside verify-stop.sh. Uses Sonnet to make a judgment call.

**Blocks when:**
- Substantial code changes (>50 lines, new files, new endpoints) and no code review evidence found

**Skips when:**
- Changes are trivial (<20 lines, docs only, config only)
- `stop_hook_active` is true
- Review artifacts exist (`.claude/qa-report.md`, review commits)

## Customization

The hook scripts source `detect-stack.sh` for all stack detection. To add a new stack:

1. Add marker file detection in `hooks/lib/detect-stack.sh`
2. Set `TEST_CMD`, `BUILD_CMD`, `LINT_CMD`, `SOURCE_PATTERN`
3. Add tests in `tests/test-detect-stack.sh`

To change thresholds:
- "New code without tests" threshold: edit `verify-task.sh`, change the `> 20` comparison
- Stderr cap: `STDERR_LIMIT` variable at the top of each hook

## Cost

- `verify-task.sh` and `verify-stop.sh` are command hooks. Zero API cost. They run local commands.
- The review agent hook uses one Sonnet call per Stop event (~1-2k tokens). A few cents per session, only on sessions with code changes.

## Running tests

```bash
bash tests/test-detect-stack.sh    # Stack detection (52 assertions)
bash tests/test-verify-task.sh     # TaskCompleted hook (13 assertions)
bash tests/test-verify-stop.sh     # Stop hook (17 assertions)
```

## Troubleshooting

**Hook doesn't fire:** Check `/hooks` in Claude Code to see registered hooks. The hooks need the exact event names: `TaskCompleted` and `Stop`.

**Infinite loop on Stop:** The `stop_hook_active` check in verify-stop.sh should prevent this. If you see a loop, check that `stop_hook_active` is being passed in the JSON payload (it's automatic in Claude Code).

**Wrong stack detected:** detect-stack walks up from cwd. If you're in a subdirectory with its own marker file, that takes priority. This is intentional for monorepos.

**Tests pass locally but hook blocks:** The hook runs from the project's cwd, not the repo root. Make sure your test command works from the directory Claude is working in.

**"jq not found" on install:** Install jq: `apt install jq` (Linux), `brew install jq` (macOS).
