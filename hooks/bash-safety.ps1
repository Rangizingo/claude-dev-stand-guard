#Requires -Version 7
# bash-safety.ps1 — Block dangerous commands globally
# PreToolUse hook on Bash — exit 2 to hard block

$input_json = [Console]::In.ReadToEnd()
$data = $input_json | ConvertFrom-Json

$CMD = $data.tool_input.command

if ([string]::IsNullOrEmpty($CMD)) {
    exit 0
}

# Hard blocks — irreversible or extremely dangerous operations
if ($CMD -match '(rm -rf /[^a-z]|rm -rf /\s*$|DROP TABLE|DROP DATABASE|truncate /|mkfs\.|dd if=.* of=/dev/)') {
    Write-Error 'Blocked: destructive system command detected. Use a safer alternative.'
    exit 2
}

# Block force push to main/master
if ($CMD -match 'git push.*--force.*(main|master)|git push.*-f.*(main|master)') {
    Write-Error 'Blocked: force push to main/master. This could destroy remote history.'
    exit 2
}

# Block hard reset without confirmation
if ($CMD -match 'git reset --hard') {
    Write-Error 'Blocked: git reset --hard can destroy uncommitted work. Use git stash first.'
    exit 2
}

exit 0
