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
├── hooks/lib/detect-stack.sh  Auto-detect test/build/lint for 12 stacks (+ PATH augmentation)
├── hooks/verify-task.sh       TaskCompleted: block if tests fail or new code has no tests
├── hooks/plan-checkbox.sh     TaskCompleted: auto-mark matching plan.md items as done
├── hooks/verify-stop.sh       Stop: block if lint/test/build fail
├── hooks/review-gate.sh       Stop: block if substantial changes lack code review
├── hooks/post_tool_use.sh     PostToolUse: format + typecheck + lint every file edit
├── hooks/bash-safety.sh       PreToolUse: block destructive bash commands
├── hooks/post-compact.sh      SessionStart (compact): restore context after compaction
└── hooks/*.ps1                Windows equivalents (synced via claude-config-sync)
```

## Stack
- **Language:** Bash (hooks, detection library) + PowerShell (Windows equivalents)
- **Hook types:** `command` for deterministic gates
- **Install target:** `~/.claude/` (global, all projects)
- **Required:** `jq` (JSON parsing in bash hooks; PowerShell uses built-in ConvertFrom-Json)
- **No other external dependencies**

## Architecture
```
claude-dev-stand-guard/
├── CLAUDE.md                      # This file
├── plan.md                        # Development tasks and progress
├── README.md                      # Documentation + install guide
├── hooks/
│   ├── verify-task.sh (.ps1)      # TaskCompleted: run tests + check test files exist
│   ├── plan-checkbox.sh (.ps1)    # TaskCompleted: fuzzy-match task subject -> plan.md [x]
│   ├── verify-stop.sh (.ps1)      # Stop: full lint + test + build gate
│   ├── review-gate.sh (.ps1)      # Stop: block without code review
│   ├── post_tool_use.sh (.ps1)    # PostToolUse: format + typecheck + lint on edit
│   ├── bash-safety.sh (.ps1)      # PreToolUse: block dangerous commands
│   ├── post-compact.sh (.ps1)     # SessionStart: restore context after compaction
│   └── lib/
│       └── detect-stack.sh (.ps1) # Auto-detect 12 stacks + commands + PATH
├── config/
│   └── review-agent-hook.json     # Legacy agent hook config (superseded by review-gate.sh)
├── install.sh                     # Installer (merges with existing config, per-hook idempotent)
├── uninstall.sh                   # Clean removal (all hook types + .ps1 files)
└── tests/
    ├── test-detect-stack.sh       # Stack detection + package managers (82 tests)
    ├── test-verify-task.sh        # Task verification hook (13 tests)
    ├── test-plan-checkbox.sh      # Plan.md auto-checkbox hook (25 tests)
    ├── test-verify-stop.sh        # Stop verification hook (17 tests)
    ├── test-post-tool-use.sh      # Per-edit format/typecheck/lint, all languages (33 tests)
    └── test-all-hooks.sh          # End-to-end installed hooks + settings integrity (61 tests)
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
- The existing `task_detector.py` must not be replaced or broken.
- Agent hooks use Sonnet. Prompt hooks use Sonnet. Both are acceptable per user preference.
- All scripts must work on Linux, macOS, and Windows (via .ps1 equivalents).
- Every .sh hook must have a .ps1 companion for claude-config-sync cross-platform sync.

## Cross-platform sync (claude-config-sync)

These hooks sync across machines via `claude-config-sync`, which manages `~/.claude/` as a git repo.

**How it works automatically:**
- `claude-config-sync` pushes `settings.json` and `hooks/` on SessionEnd, pulls on SessionStart
- Per-platform settings are preserved: `settings.linux.json`, `settings.darwin.json`, `settings.windows.json`
- Hook commands are auto-adapted on pull: `bash script.sh` becomes `powershell script.ps1` on Windows (and reverse on Unix)
- Home directory paths in settings.json are rewritten to the current machine's home

**Windows support:** All hooks have `.ps1` equivalents. The sync tool rewrites `bash script.sh` to `powershell script.ps1` on Windows automatically.

## Supported stacks (auto-detected)

| Marker file | Stack | Test | Build | Lint | Edit-time |
|---|---|---|---|---|---|
| `package.json` | Node/TS | `{mgr} test` | `{mgr} build` | `{mgr} lint` | prettier + eslint + typecheck |
| `pyproject.toml` / `requirements.txt` | Python | `pytest` | skip | `ruff check .` | black + ruff |
| `Cargo.toml` | Rust | `cargo test` | `cargo build` | `cargo clippy` | rustfmt + cargo check |
| `go.mod` | Go | `go test ./...` | `go build ./...` | `go vet ./...` | goimports/gofmt + go vet |
| `*.csproj` | .NET | `dotnet test` | `dotnet build` | skip | dotnet format + build |
| `Package.swift` | Swift | `swift test` | `swift build` | `swiftlint` | swiftformat + swiftlint |
| `build.gradle(.kts)` | Gradle | `./gradlew test` | `./gradlew build` | skip | google-java-format/ktlint + compile |
| `pom.xml` | Maven | `mvn test` | `mvn compile` | skip | google-java-format + compile |
| `Gemfile` | Ruby | `bundle exec rspec` | skip | `rubocop` | rubocop (format + lint) |
| `composer.json` | PHP | `./vendor/bin/phpunit` | skip | `./vendor/bin/phpcs` | php-cs-fixer + php -l |
| `pubspec.yaml` | Dart/Flutter | `dart test` | `flutter build` | `dart analyze` | dart format + analyze |
| `mix.exs` | Elixir | `mix test` | `mix compile` | `mix credo` | mix format + compile |
| `CMakeLists.txt` | CMake | `ctest` | `cmake --build` | `cppcheck` | clang-format + cppcheck |
| `Makefile` | Make | `make test` | `make` | `cppcheck` | clang-format + cppcheck |

Commands only set if the tool is actually installed and (for Node) the script exists in package.json.

Node package manager is auto-detected from lockfile: `pnpm-lock.yaml` -> pnpm, `yarn.lock` -> yarn, `bun.lockb` -> bun, `package-lock.json` or none -> npm. Falls back to npm if detected manager isn't installed.

## Commands
```bash
# Run all tests (231 total)
bash tests/test-detect-stack.sh      # Stack detection (82 tests)
bash tests/test-verify-task.sh       # Task gate (13 tests)
bash tests/test-plan-checkbox.sh     # Plan.md auto-checkbox (25 tests)
bash tests/test-verify-stop.sh       # Stop gate (17 tests)
bash tests/test-post-tool-use.sh     # Edit-time hooks, all languages (33 tests)
bash tests/test-all-hooks.sh         # End-to-end installed hooks (61 tests)

# Install (merges into existing ~/.claude/ config, idempotent)
bash install.sh
bash install.sh --dry-run

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
