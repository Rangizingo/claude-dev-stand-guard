#Requires -Version 7
# verify-stop.ps1 - Stop hook for Claude Code
# Full lint + test + build gate before Claude stops.
# Blocks if any fail, skips if no source changes or stop_hook_active.
# Reads JSON payload from stdin. Exit 0 = allow, exit 2 = block.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SCRIPT_DIR = $PSScriptRoot
$STDERR_LIMIT = 50

# Read JSON payload from stdin
$rawInput = [Console]::In.ReadToEnd()
$payload = $rawInput | ConvertFrom-Json

# Check stop_hook_active first (prevent infinite loops)
# Use PSObject.Properties to avoid strict-mode errors when property is absent
$stopHookActive = if ($payload.PSObject.Properties['stop_hook_active']) { $payload.stop_hook_active } else { $false }
if ($stopHookActive -eq $true) {
    exit 0
}

# Extract cwd from payload
$cwd = if ($payload.PSObject.Properties['cwd']) { $payload.cwd } else { $null }
if ($cwd -and (Test-Path -Path $cwd -PathType Container)) {
    Set-Location -Path $cwd
}

# Dot-source stack detection - sets $DETECTED_STACK, $TEST_CMD, $BUILD_CMD, $LINT_CMD, $SOURCE_PATTERN
. (Join-Path $SCRIPT_DIR "lib\detect-stack.ps1")

# Check if we're in a git repo
function Test-InGitRepo {
    git rev-parse --is-inside-work-tree 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

# Get changed files (staged + unstaged + untracked vs HEAD)
function Get-ChangedFiles {
    $files = @()
    $files += git diff --name-only HEAD 2>$null
    $files += git diff --name-only --cached HEAD 2>$null
    $files += git ls-files --others --exclude-standard 2>$null
    return ($files | Where-Object { $_ } | Sort-Object -Unique)
}

# If not in a git repo, skip
if (-not (Test-InGitRepo)) {
    exit 0
}

# Get changed files
$changedFiles = Get-ChangedFiles

# No changes? Skip.
if ($changedFiles.Count -eq 0) {
    exit 0
}

# Check if any source files changed
function Test-HasSourceChanges {
    if (-not $SOURCE_PATTERN) {
        # No stack detected, but files changed - still run if commands exist
        return $changedFiles.Count -gt 0
    }
    return ($changedFiles | Where-Object { $_ -match $SOURCE_PATTERN }).Count -gt 0
}

if (-not (Test-HasSourceChanges)) {
    exit 0
}

# Run lint, test, build. Collect ALL errors before deciding.
$errors = ''
$hadFailure = $false

# Helper: run a command string and return output + exit code
function Invoke-CheckCmd {
    param([string]$Cmd)
    $parts = $Cmd -split ' '
    $output = & $parts[0] $parts[1..($parts.Count - 1)] 2>&1 | Out-String
    return @{ Output = $output; ExitCode = $LASTEXITCODE }
}

# Lint
if ($LINT_CMD) {
    $result = Invoke-CheckCmd -Cmd $LINT_CMD
    if ($result.ExitCode -ne 0) {
        $hadFailure = $true
        $errors += "Lint failed (exit $($result.ExitCode)):`n$($result.Output)`n`n"
    }
}

# Tests
if ($TEST_CMD) {
    $result = Invoke-CheckCmd -Cmd $TEST_CMD
    if ($result.ExitCode -ne 0) {
        $hadFailure = $true
        $errors += "Tests failed (exit $($result.ExitCode)):`n$($result.Output)`n`n"
    }
}

# Build
if ($BUILD_CMD) {
    $result = Invoke-CheckCmd -Cmd $BUILD_CMD
    if ($result.ExitCode -ne 0) {
        $hadFailure = $true
        $errors += "Build failed (exit $($result.ExitCode)):`n$($result.Output)`n`n"
    }
}

# Deploy build (platform-specific: CF Pages, Vercel, etc.)
if ($DEPLOY_BUILD_CMD) {
    $result = Invoke-CheckCmd -Cmd $DEPLOY_BUILD_CMD
    if ($result.ExitCode -ne 0) {
        $hadFailure = $true
        $errors += "Deploy build failed (exit $($result.ExitCode)):`n$($result.Output)`n`n"
    }
}

# If any failed, block stop
if ($hadFailure) {
    [Console]::Error.WriteLine("Fix these issues before stopping:")
    $truncated = ($errors -split "`n" | Select-Object -First $STDERR_LIMIT) -join "`n"
    [Console]::Error.WriteLine($truncated)
    exit 2
}

exit 0
