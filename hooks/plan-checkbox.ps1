# plan-checkbox.ps1 - TaskCompleted hook for Claude Code (Windows)
# When a task is marked complete, fuzzy-matches its subject against
# unchecked items in plan.md and flips [ ] to [x].
# Reads JSON payload from stdin. Exit 0 = allow (never blocks).

$ErrorActionPreference = "SilentlyContinue"

# Read JSON payload from stdin
$payload = $input | Out-String | ConvertFrom-Json

$cwd = $payload.cwd
$taskSubject = $payload.task_subject

if (-not $taskSubject) { exit 0 }

if ($cwd -and (Test-Path $cwd)) { Set-Location $cwd }

# Find plan.md walking up from cwd
function Find-PlanFile {
    $dir = Get-Location
    while ($dir.Path -ne [System.IO.Path]::GetPathRoot($dir.Path)) {
        $planPath = Join-Path $dir.Path "plan.md"
        if (Test-Path $planPath) { return $planPath }
        $dir = Split-Path $dir.Path -Parent | Get-Item
    }
    return $null
}

$planFile = Find-PlanFile
if (-not $planFile) { exit 0 }

# Normalize: strip common prefixes, lowercase
$normalized = $taskSubject -replace '^(Build|Add|Fix|Wire|Create|Delete|Remove|Update|Implement|Generate|Write)\s+', '' -replace '[^a-zA-Z0-9 ]', ''
$normalized = $normalized.ToLower().Trim()

# Extract significant words (>3 chars)
$words = $normalized -split '\s+' | Where-Object { $_.Length -gt 3 }
if ($words.Count -lt 2) { exit 0 }

# Take up to 3 longest words
$sortedWords = $words | Sort-Object { $_.Length } -Descending | Select-Object -First 3

# Read plan.md and find unchecked lines matching all words
$lines = Get-Content $planFile
for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -notmatch '^\- \[ \]') { continue }

    $allMatch = $true
    foreach ($word in $sortedWords) {
        if ($line -notmatch [regex]::Escape($word)) {
            $allMatch = $false
            break
        }
    }

    if ($allMatch) {
        $lines[$i] = $line -replace '- \[ \]', '- [x]'
        $lines | Set-Content $planFile -Encoding UTF8
        Write-Host "plan-checkbox: marked done in plan.md line $($i + 1)" -ForegroundColor Green
        break
    }
}

exit 0
