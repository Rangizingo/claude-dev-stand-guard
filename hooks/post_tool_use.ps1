#Requires -Version 7
# post_tool_use.ps1 — Global auto-format + lint feedback after Write/Edit
#
# Two jobs:
#   1. Format the file (silent, always)
#   2. Lint the file and feed errors back to Claude for self-correction
#
# Formatters (silently skipped if not installed):
#   .py                      -> black + ruff check
#   .js .ts .jsx .tsx .json  -> prettier --write + eslint (if config exists)
#   .cs                      -> dotnet format whitespace + dotnet build
#   .rs                      -> rustfmt + cargo check
#   .go                      -> goimports or gofmt
#   .swift                   -> swiftformat

$ErrorActionPreference = 'SilentlyContinue'

$input_json = [Console]::In.ReadToEnd()
$data = $input_json | ConvertFrom-Json

$TOOL_NAME = $data.tool_name
$FILE_PATH = $data.tool_input.file_path

# Only handle Write/Edit/MultiEdit
if ($TOOL_NAME -notin @('Write', 'Edit', 'MultiEdit')) {
    exit 0
}

# Skip if no path or file doesn't exist
if ([string]::IsNullOrEmpty($FILE_PATH) -or -not (Test-Path $FILE_PATH -PathType Leaf)) {
    exit 0
}

$EXT = [System.IO.Path]::GetExtension($FILE_PATH).TrimStart('.').ToLower()

$ERRORS = ''

# Walk up from the file's directory to find the project root
$PROJECT_DIR = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($FILE_PATH))
$DRIVE_ROOT = [System.IO.Path]::GetPathRoot($PROJECT_DIR)

while ($PROJECT_DIR -ne $DRIVE_ROOT) {
    if ((Test-Path "$PROJECT_DIR/package.json") -or
        (Test-Path "$PROJECT_DIR/Cargo.toml") -or
        (Test-Path "$PROJECT_DIR/pyproject.toml") -or
        (Test-Path "$PROJECT_DIR/go.mod") -or
        (Test-Path "$PROJECT_DIR/Package.swift")) {
        break
    }
    $PROJECT_DIR = [System.IO.Path]::GetDirectoryName($PROJECT_DIR)
}

switch ($EXT) {
    'py' {
        # Format
        if (Get-Command black -ErrorAction SilentlyContinue) {
            black --quiet $FILE_PATH 2>$null
        }
        # Lint with feedback
        if (Get-Command ruff -ErrorAction SilentlyContinue) {
            $lint_out = ruff check $FILE_PATH 2>&1
            if ($LASTEXITCODE -ne 0) {
                $file_name = [System.IO.Path]::GetFileName($FILE_PATH)
                $ERRORS = "Ruff errors in ${file_name}:`n${lint_out}"
            }
        }
    }

    { $_ -in @('js', 'ts', 'jsx', 'tsx') } {
        # Format — only if prettier is locally installed
        if (Test-Path "$PROJECT_DIR/node_modules/.bin") {
            Push-Location $PROJECT_DIR
            try {
                npx prettier --write $FILE_PATH 2>$null
            } finally {
                Pop-Location
            }
        }
        # Lint with feedback — only if eslint is locally installed
        if (Test-Path "$PROJECT_DIR/node_modules/.bin/eslint") {
            Push-Location $PROJECT_DIR
            try {
                $lint_out = npx eslint $FILE_PATH 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $file_name = [System.IO.Path]::GetFileName($FILE_PATH)
                    $ERRORS = "ESLint errors in ${file_name}:`n${lint_out}"
                }
            } finally {
                Pop-Location
            }
        }
        # Typecheck (turbo cached, fast after first run)
        if (-not $ERRORS -and (Test-Path "$PROJECT_DIR/package.json")) {
            . (Join-Path $PSScriptRoot "lib\detect-stack.ps1")
            $pkgJson = Get-Content "$PROJECT_DIR/package.json" -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($pkgJson -and $pkgJson.scripts -and $pkgJson.scripts.PSObject.Properties.Name -contains 'typecheck') {
                $mgr = _DetectNodePkgManager $PROJECT_DIR
                if (-not (_HasCmd $mgr)) { $mgr = "npm" }
                if (_HasCmd $mgr) {
                    Push-Location $PROJECT_DIR
                    try {
                        $tc_out = & $mgr run typecheck 2>&1 | Out-String
                        if ($LASTEXITCODE -ne 0) {
                            $tc_errors = ($tc_out -split "`n" | Where-Object { $_ -match 'error TS' } | Select-Object -First 10) -join "`n"
                            $file_name = [System.IO.Path]::GetFileName($FILE_PATH)
                            $ERRORS = "TypeScript errors after editing ${file_name}:`n${tc_errors}"
                        }
                    } finally {
                        Pop-Location
                    }
                }
            }
        }
    }

    'json' {
        # Format only, no lint
        if (Test-Path "$PROJECT_DIR/node_modules/.bin") {
            Push-Location $PROJECT_DIR
            try {
                npx prettier --write $FILE_PATH 2>$null
            } finally {
                Pop-Location
            }
        }
    }

    'cs' {
        if (Get-Command dotnet -ErrorAction SilentlyContinue) {
            # Format
            dotnet format whitespace --folder --include $FILE_PATH 2>$null
            # Build check with feedback
            $build_out = dotnet build --no-restore -verbosity:quiet 2>&1
            if ($LASTEXITCODE -ne 0) {
                $build_errors = $build_out | Select-String 'error CS' | Select-Object -First 10 | Out-String
                $file_name = [System.IO.Path]::GetFileName($FILE_PATH)
                $ERRORS = "Build errors after editing ${file_name}:`n${build_errors}"
            }
        }
    }

    'rs' {
        # Format
        if (Get-Command rustfmt -ErrorAction SilentlyContinue) {
            rustfmt $FILE_PATH 2>$null
        }
        # Check with feedback
        if (Test-Path "$PROJECT_DIR/Cargo.toml") {
            Push-Location $PROJECT_DIR
            try {
                $check_out = cargo check 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $check_errors = $check_out | Where-Object { $_ -match '^error' } | Select-Object -First 10 | Out-String
                    $file_name = [System.IO.Path]::GetFileName($FILE_PATH)
                    $ERRORS = "Cargo check errors after editing ${file_name}:`n${check_errors}"
                }
            } finally {
                Pop-Location
            }
        }
    }

    'go' {
        # Format: prefer goimports, fall back to gofmt
        if (Get-Command goimports -ErrorAction SilentlyContinue) {
            goimports -w $FILE_PATH 2>$null
        } elseif (Get-Command gofmt -ErrorAction SilentlyContinue) {
            gofmt -w $FILE_PATH 2>$null
        }
        # Vet (Go's build cache makes this fast after first run)
        if ((Get-Command go -ErrorAction SilentlyContinue) -and (Test-Path "$PROJECT_DIR/go.mod")) {
            Push-Location $PROJECT_DIR
            try {
                $vet_out = go vet ./... 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    $vet_errors = ($vet_out -split "`n" | Select-Object -First 10) -join "`n"
                    $file_name = [System.IO.Path]::GetFileName($FILE_PATH)
                    $ERRORS = "go vet errors after editing ${file_name}:`n${vet_errors}"
                }
            } finally {
                Pop-Location
            }
        }
    }

    'swift' {
        # Format
        if (Get-Command swiftformat -ErrorAction SilentlyContinue) {
            swiftformat $FILE_PATH 2>$null
        }
        # Lint with feedback
        if (Get-Command swiftlint -ErrorAction SilentlyContinue) {
            $sl_out = swiftlint lint --path $FILE_PATH --quiet 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                $sl_errors = ($sl_out -split "`n" | Select-Object -First 10) -join "`n"
                $file_name = [System.IO.Path]::GetFileName($FILE_PATH)
                $ERRORS = "SwiftLint errors in ${file_name}:`n${sl_errors}"
            }
        }
    }
}

# Feed errors back to Claude for self-correction
if (-not [string]::IsNullOrEmpty($ERRORS)) {
    @{ decision = 'block'; reason = $ERRORS } | ConvertTo-Json -Compress
}

exit 0
