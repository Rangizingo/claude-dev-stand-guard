#Requires -Version 7
# post-compact.ps1 — SessionStart (compact) hook for Claude Code
# Re-injects project context after context window compaction.
# Output goes to stdout and is injected into Claude's context.

$ErrorActionPreference = 'SilentlyContinue'

# Read payload from stdin
$rawInput = [Console]::In.ReadToEnd()
$payload = $rawInput | ConvertFrom-Json -ErrorAction SilentlyContinue

# Extract cwd from payload
$cwd = if ($payload -and $payload.PSObject.Properties['cwd']) { $payload.cwd } else { $null }
if ($cwd -and (Test-Path $cwd -PathType Container)) {
    Set-Location $cwd
}

# Dot-source stack detection
. (Join-Path $PSScriptRoot "lib\detect-stack.ps1")

Write-Output "=== POST-COMPACT CONTEXT ==="
Write-Output ""

# Project name + path
$projName = Split-Path (Get-Location).Path -Leaf
Write-Output "Project: $projName ($((Get-Location).Path))"

# Detected stack
if ($DETECTED_STACK) {
    $info = "Stack: $DETECTED_STACK"
    if ($TEST_CMD)  { $info += " | test: $TEST_CMD" }
    if ($BUILD_CMD) { $info += " | build: $BUILD_CMD" }
    if ($LINT_CMD)  { $info += " | lint: $LINT_CMD" }
    Write-Output $info
}
Write-Output ""

# CLAUDE.md summary
if (Test-Path "CLAUDE.md") {
    Write-Output "Project context (CLAUDE.md, first 30 lines):"
    Get-Content "CLAUDE.md" -TotalCount 30
    Write-Output ""
}

# Recent git history
git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Output "Recent commits:"
    git log --oneline -5 2>$null
    Write-Output ""
    Write-Output "Modified files (last 3 commits):"
    git diff --name-only HEAD~3 2>$null | Select-Object -First 20
    Write-Output ""
}

# Current plan
if (Test-Path "plan.md") {
    Write-Output "Current plan (first 40 lines):"
    Get-Content "plan.md" -TotalCount 40
    Write-Output ""
}

Write-Output "=== END CONTEXT ==="
