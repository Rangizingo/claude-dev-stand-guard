#Requires -Version 7
# review-gate.ps1 — Code review gate for Stop/SubagentStop
# Blocks stop if substantial source changes shipped without code review.
# Silent exit 0 = allow stop. Exit 2 with stderr = block stop.

$ErrorActionPreference = 'SilentlyContinue'

$input_json = [Console]::In.ReadToEnd()
$data = $input_json | ConvertFrom-Json

# Check stop_hook_active — prevent infinite loops
$STOP_ACTIVE = $data.stop_hook_active
if ($STOP_ACTIVE -eq $true) {
    exit 0
}

# Not a git repo? Skip.
git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    exit 0
}

# Check if any source files changed
$SOURCE_PATTERN = '\.(ts|tsx|js|jsx|py|rs|cs|swift|go|astro)$'
$CHANGED_SOURCE = git diff --name-only HEAD 2>$null | Where-Object { $_ -match $SOURCE_PATTERN }

# No source changes? Skip silently.
if (-not $CHANGED_SOURCE) {
    exit 0
}

# Count lines changed in source files
$LINES_CHANGED = 0
git diff --numstat HEAD 2>$null | Where-Object { $_ -match $SOURCE_PATTERN } | ForEach-Object {
    $parts = $_ -split '\s+'
    if ($parts.Count -ge 2) {
        $added   = [int]($parts[0] -replace '[^0-9]', '0')
        $removed = [int]($parts[1] -replace '[^0-9]', '0')
        $LINES_CHANGED += $added + $removed
    }
}

# Trivial changes? Skip.
if ($LINES_CHANGED -lt 20) {
    exit 0
}

# Substantial source changes. Check for review evidence.
$TODAY = (Get-Date).ToString('yyyy-MM-dd')

# Check for any qa-report file modified today
$reports = Get-ChildItem -Path '.claude' -Filter 'qa-report*.md' -ErrorAction SilentlyContinue
foreach ($report in $reports) {
    if ($report.LastWriteTime.ToString('yyyy-MM-dd') -eq $TODAY) {
        exit 0
    }
}

# Check git log for review mentions
$log = git log --oneline -5 2>$null
if ($log -match 'review|qa') {
    exit 0
}

# Substantial changes, no review evidence — block
[Console]::Error.WriteLine("${LINES_CHANGED} lines of source code changed without code review. Run /qa or the code-review skill before stopping.")
exit 2
