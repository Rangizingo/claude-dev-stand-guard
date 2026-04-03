#Requires -Version 7
# verify-task.ps1 - TaskCompleted hook for Claude Code
# Blocks task completion when:
#   1. Tests fail
#   2. Substantial new code (>20 lines) has no test files modified
# Reads JSON payload from stdin. Exit 0 = allow, exit 2 = block.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SCRIPT_DIR = $PSScriptRoot
$STDERR_LIMIT = 40

# Read JSON payload from stdin
$rawInput = [Console]::In.ReadToEnd()
$payload = $rawInput | ConvertFrom-Json

# Extract cwd from payload, fall back to current directory
# Use null-coalescing to avoid strict-mode errors when property is absent
$cwd = if ($payload.PSObject.Properties['cwd']) { $payload.cwd } else { $null }
if ($cwd -and (Test-Path -Path $cwd -PathType Container)) {
    Set-Location -Path $cwd
}

# Dot-source stack detection - sets $DETECTED_STACK, $TEST_CMD, $BUILD_CMD, $LINT_CMD, $SOURCE_PATTERN
. (Join-Path $SCRIPT_DIR "lib\detect-stack.ps1")

# Helper: write truncated message to stderr
function Emit-Stderr {
    param([string]$Message)
    $lines = $Message -split "`n" | Select-Object -First $STDERR_LIMIT
    [Console]::Error.WriteLine(($lines -join "`n"))
}

# Check if we're in a git repo
function Test-InGitRepo {
    git rev-parse --is-inside-work-tree 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

# Get list of changed files (staged + unstaged vs HEAD, plus untracked)
function Get-ChangedFiles {
    $files = @()
    $files += git diff --name-only HEAD 2>$null
    $files += git diff --name-only --cached HEAD 2>$null
    $files += git ls-files --others --exclude-standard 2>$null
    return ($files | Where-Object { $_ } | Sort-Object -Unique)
}

# Check if any source files changed
function Test-HasSourceChanges {
    param([string[]]$Files)
    if (-not $SOURCE_PATTERN) {
        # No stack detected; any file counts
        return $Files.Count -gt 0
    }
    return ($Files | Where-Object { $_ -match $SOURCE_PATTERN }).Count -gt 0
}

# Count added source lines across changed source files
function Get-NewSourceLines {
    param([string[]]$ChangedFiles)
    if (-not $SOURCE_PATTERN) {
        # No pattern; count all added lines from git diff HEAD
        $diffLines = git diff HEAD 2>$null
        if (-not $diffLines) { return 0 }
        return ($diffLines | Where-Object { $_ -match '^\+[^\+]' }).Count
    }

    $sourceFiles = $ChangedFiles | Where-Object { $_ -match $SOURCE_PATTERN }
    $total = 0
    foreach ($f in $sourceFiles) {
        if (-not (Test-Path $f)) { continue }

        $diffOut = git diff HEAD -- $f 2>$null
        $added = ($diffOut | Where-Object { $_ -match '^\+[^\+]' }).Count

        if ($added -eq 0) {
            # Might be an untracked file - check
            git ls-files --error-unmatch $f 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                # Untracked: count all lines
                $added = (Get-Content $f -ErrorAction SilentlyContinue).Count
                if (-not $added) { $added = 0 }
            }
        }
        $total += $added
    }
    return $total
}

# Check if any test files were modified
function Test-HasTestFileChanges {
    param([string[]]$Files)
    return ($Files | Where-Object { $_ -match '(test|spec|_test|tests[\\/])' }).Count -gt 0
}

# --- Main logic ---

# If not in a git repo, skip all diff-based checks
if (-not (Test-InGitRepo)) {
    exit 0
}

# Get changed files
$changedFiles = Get-ChangedFiles

# No changes at all? Skip (research/docs task)
if ($changedFiles.Count -eq 0) {
    exit 0
}

# Check if source files changed
if (-not (Test-HasSourceChanges -Files $changedFiles)) {
    exit 0
}

# Run tests if TEST_CMD is set
if ($TEST_CMD) {
    $cmdParts = $TEST_CMD -split ' '
    $testOutput = & $cmdParts[0] $cmdParts[1..($cmdParts.Count - 1)] 2>&1 | Out-String
    $testExit = $LASTEXITCODE
    if ($testExit -ne 0) {
        $msg = "Tests failed (exit $testExit). Fix before completing this task.`n---`n$testOutput"
        Emit-Stderr -Message $msg
        exit 2
    }
}

# Check for substantial new code without test files
$newLines = Get-NewSourceLines -ChangedFiles $changedFiles
if ($newLines -gt 20) {
    if (-not (Test-HasTestFileChanges -Files $changedFiles)) {
        Emit-Stderr -Message "Write tests for new code before completing this task. ($newLines new source lines, 0 test files modified.)"
        exit 2
    }
}

# All checks passed
exit 0
