#Requires -Version 7.0
# detect-stack.ps1 - Auto-detect project stack and set test/build/lint commands
# Dot-source this file. Sets: $DETECTED_STACK, $TEST_CMD, $BUILD_CMD, $LINT_CMD, $SOURCE_PATTERN
# All commands are only set if the tool is actually installed.

# Initialize outputs
$DETECTED_STACK   = ""
$TEST_CMD         = ""
$BUILD_CMD        = ""
$DEPLOY_BUILD_CMD = ""
$LINT_CMD         = ""
$SOURCE_PATTERN   = ""

# Augment PATH with common tool locations (before any _HasCmd calls)
function _AugmentPath {
    $candidates = @(
        "$env:USERPROFILE\.local\bin",
        "$env:USERPROFILE\.cargo\bin",
        "$env:USERPROFILE\.bun\bin",
        "$env:USERPROFILE\AppData\Roaming\npm",
        "C:\Program Files\nodejs",
        "C:\Program Files\Git\bin",
        "C:\ProgramData\chocolatey\bin",
        "C:\tools\bin"
    )
    $current = $env:PATH -split [System.IO.Path]::PathSeparator
    foreach ($c in $candidates) {
        if ((Test-Path $c -PathType Container) -and ($current -notcontains $c)) {
            $env:PATH = "$c$([System.IO.Path]::PathSeparator)$env:PATH"
        }
    }
}
_AugmentPath

# Check if a command exists on PATH
function _HasCmd {
    param([string]$Name)
    return ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue))
}

# Check if a package.json has a given script name
function _HasNpmScript {
    param(
        [string]$PkgPath,
        [string]$ScriptName
    )
    if (-not (Test-Path $PkgPath -PathType Leaf)) { return $false }
    try {
        $pkg = Get-Content $PkgPath -Raw | ConvertFrom-Json
        if ($null -eq $pkg.scripts) { return $false }
        return ($pkg.scripts.PSObject.Properties.Name -contains $ScriptName)
    } catch {
        return $false
    }
}

# Detect Node package manager from lockfiles in the given directory
function _DetectNodePkgManager {
    param([string]$Dir)
    if (Test-Path "$Dir\pnpm-lock.yaml" -PathType Leaf) { return "pnpm" }
    if (Test-Path "$Dir\yarn.lock"      -PathType Leaf) { return "yarn" }
    if ((Test-Path "$Dir\bun.lockb"     -PathType Leaf) -or
        (Test-Path "$Dir\bun.lock"      -PathType Leaf)) { return "bun" }
    return "npm"
}

# Build the run-script command string for the detected package manager
function _NodeCmd {
    param(
        [string]$Mgr,
        [string]$Script
    )
    switch ($Mgr) {
        "npm"  { return "npm run $Script" }
        "pnpm" { return "pnpm $Script" }
        "yarn" { return "yarn $Script" }
        "bun"  { return "bun run $Script" }
        default { return "npm run $Script" }
    }
}

# Walk up from the given directory to find a specific marker filename.
# Returns the directory that contains it, or $null if not found.
function _FindMarker {
    param([string]$Marker)
    $dir = (Get-Location).Path
    while ($true) {
        if (Test-Path (Join-Path $dir $Marker) -PathType Leaf) {
            return $dir
        }
        $parent = Split-Path $dir -Parent
        # Split-Path returns "" or $null at the filesystem root
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) {
            return $null
        }
        $dir = $parent
    }
}

# Walk up from the given directory to find files matching a wildcard filter.
# Returns the directory that contains a match, or $null if not found.
function _FindMarkerGlob {
    param([string]$Filter)
    $dir = (Get-Location).Path
    while ($true) {
        $match = Get-ChildItem -LiteralPath $dir -Filter $Filter -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($null -ne $match) {
            return $dir
        }
        $parent = Split-Path $dir -Parent
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) {
            return $null
        }
        $dir = $parent
    }
}

# Detect stack by walking up from cwd and checking for marker files.
# Priority: closest marker to cwd wins. All markers are checked at each level
# before walking up.
function _DetectStack {
    $dir = (Get-Location).Path

    while ($true) {
        # Node/TS
        if (Test-Path "$dir\package.json" -PathType Leaf) {
            $script:DETECTED_STACK  = "node"
            $script:SOURCE_PATTERN  = '\.(js|jsx|ts|tsx|mjs|cjs)$'
            $pkg = "$dir\package.json"
            $mgr = _DetectNodePkgManager $dir
            if (-not (_HasCmd $mgr)) { $mgr = "npm" }
            if (_HasCmd $mgr) {
                if (_HasNpmScript $pkg "test")  { $script:TEST_CMD  = _NodeCmd $mgr "test" }
                if (_HasNpmScript $pkg "build") { $script:BUILD_CMD = _NodeCmd $mgr "build" }
                if (_HasNpmScript $pkg "lint")  { $script:LINT_CMD  = _NodeCmd $mgr "lint" }
                # Deployment-specific build (CF Pages, Vercel, etc.)
                foreach ($ds in @("pages:build", "deploy:build", "build:cf", "build:pages", "build:deploy", "build:production")) {
                    if (_HasNpmScript $pkg $ds) {
                        $script:DEPLOY_BUILD_CMD = _NodeCmd $mgr $ds
                        break
                    }
                }
            }
            return
        }

        # Python (pyproject.toml first, then requirements.txt)
        if ((Test-Path "$dir\pyproject.toml" -PathType Leaf) -or
            (Test-Path "$dir\requirements.txt" -PathType Leaf)) {
            $script:DETECTED_STACK = "python"
            $script:SOURCE_PATTERN = '\.py$'
            if (_HasCmd "pytest") { $script:TEST_CMD  = "pytest" }
            $script:BUILD_CMD = ""
            if (_HasCmd "ruff")   { $script:LINT_CMD  = "ruff check ." }
            return
        }

        # Rust
        if (Test-Path "$dir\Cargo.toml" -PathType Leaf) {
            $script:DETECTED_STACK = "rust"
            $script:SOURCE_PATTERN = '\.rs$'
            if (_HasCmd "cargo") {
                $script:TEST_CMD  = "cargo test"
                $script:BUILD_CMD = "cargo build"
                $script:LINT_CMD  = "cargo clippy"
            }
            return
        }

        # Go
        if (Test-Path "$dir\go.mod" -PathType Leaf) {
            $script:DETECTED_STACK = "go"
            $script:SOURCE_PATTERN = '\.go$'
            if (_HasCmd "go") {
                $script:TEST_CMD  = "go test ./..."
                $script:BUILD_CMD = "go build ./..."
                $script:LINT_CMD  = "go vet ./..."
            }
            return
        }

        # .NET (glob for *.csproj)
        $csproj = Get-ChildItem -LiteralPath $dir -Filter "*.csproj" -ErrorAction SilentlyContinue |
                  Select-Object -First 1
        if ($null -ne $csproj) {
            $script:DETECTED_STACK = "dotnet"
            $script:SOURCE_PATTERN = '\.cs$'
            if (_HasCmd "dotnet") {
                $script:TEST_CMD  = "dotnet test"
                $script:BUILD_CMD = "dotnet build"
            }
            $script:LINT_CMD = ""
            return
        }

        # Swift
        if (Test-Path "$dir\Package.swift" -PathType Leaf) {
            $script:DETECTED_STACK = "swift"
            $script:SOURCE_PATTERN = '\.swift$'
            if (_HasCmd "swift")     { $script:TEST_CMD  = "swift test"; $script:BUILD_CMD = "swift build" }
            if (_HasCmd "swiftlint") { $script:LINT_CMD  = "swiftlint" }
            return
        }

        # Java/Kotlin (Gradle — check .kts first for Kotlin DSL)
        if ((Test-Path "$dir\build.gradle.kts" -PathType Leaf) -or
            (Test-Path "$dir\build.gradle"     -PathType Leaf)) {
            $script:DETECTED_STACK = "gradle"
            $script:SOURCE_PATTERN = '\.(java|kt|kts)$'
            if (Test-Path "$dir\gradlew.bat" -PathType Leaf) {
                $script:TEST_CMD  = ".\gradlew.bat test"
                $script:BUILD_CMD = ".\gradlew.bat build"
            } elseif (Test-Path "$dir\gradlew" -PathType Leaf) {
                $script:TEST_CMD  = "./gradlew test"
                $script:BUILD_CMD = "./gradlew build"
            } elseif (_HasCmd "gradle") {
                $script:TEST_CMD  = "gradle test"
                $script:BUILD_CMD = "gradle build"
            }
            $script:LINT_CMD = ""
            return
        }

        # Java (Maven)
        if (Test-Path "$dir\pom.xml" -PathType Leaf) {
            $script:DETECTED_STACK = "maven"
            $script:SOURCE_PATTERN = '\.java$'
            if (_HasCmd "mvn") {
                $script:TEST_CMD  = "mvn test"
                $script:BUILD_CMD = "mvn compile"
            }
            $script:LINT_CMD = ""
            return
        }

        # Ruby
        if (Test-Path "$dir\Gemfile" -PathType Leaf) {
            $script:DETECTED_STACK = "ruby"
            $script:SOURCE_PATTERN = '\.rb$'
            if (_HasCmd "bundle") { $script:TEST_CMD = "bundle exec rspec" }
            $script:BUILD_CMD = ""
            if (_HasCmd "rubocop") { $script:LINT_CMD = "rubocop" }
            return
        }

        # PHP
        if (Test-Path "$dir\composer.json" -PathType Leaf) {
            $script:DETECTED_STACK = "php"
            $script:SOURCE_PATTERN = '\.php$'
            if (Test-Path "$dir\vendor\bin\phpunit" -PathType Leaf) {
                $script:TEST_CMD = ".\vendor\bin\phpunit"
            }
            $script:BUILD_CMD = ""
            if (Test-Path "$dir\vendor\bin\phpcs" -PathType Leaf) {
                $script:LINT_CMD = ".\vendor\bin\phpcs"
            }
            return
        }

        # Dart/Flutter
        if (Test-Path "$dir\pubspec.yaml" -PathType Leaf) {
            $script:DETECTED_STACK = "dart"
            $script:SOURCE_PATTERN = '\.dart$'
            if (_HasCmd "flutter") {
                $script:TEST_CMD  = "flutter test"
                $script:BUILD_CMD = "flutter build"
                $script:LINT_CMD  = "dart analyze"
            } elseif (_HasCmd "dart") {
                $script:TEST_CMD  = "dart test"
                $script:BUILD_CMD = ""
                $script:LINT_CMD  = "dart analyze"
            }
            return
        }

        # Elixir
        if (Test-Path "$dir\mix.exs" -PathType Leaf) {
            $script:DETECTED_STACK = "elixir"
            $script:SOURCE_PATTERN = '\.(ex|exs)$'
            if (_HasCmd "mix") {
                $script:TEST_CMD  = "mix test"
                $script:BUILD_CMD = "mix compile"
                $script:LINT_CMD  = "mix credo"
            }
            return
        }

        # C/C++ (CMake first, then Makefile)
        if (Test-Path "$dir\CMakeLists.txt" -PathType Leaf) {
            $script:DETECTED_STACK = "cmake"
            $script:SOURCE_PATTERN = '\.(c|cpp|cc|cxx|h|hpp)$'
            if (_HasCmd "cmake") {
                $script:BUILD_CMD = "cmake --build build"
                $script:TEST_CMD  = "ctest --test-dir build"
            }
            $script:LINT_CMD = ""
            if (_HasCmd "cppcheck") { $script:LINT_CMD = "cppcheck --enable=warning,style ." }
            return
        }

        if (Test-Path "$dir\Makefile" -PathType Leaf) {
            $script:DETECTED_STACK = "make"
            $script:SOURCE_PATTERN = '\.(c|cpp|cc|cxx|h|hpp)$'
            if (_HasCmd "make") {
                $script:BUILD_CMD = "make"
                $script:TEST_CMD  = "make test"
            }
            $script:LINT_CMD = ""
            if (_HasCmd "cppcheck") { $script:LINT_CMD = "cppcheck --enable=warning,style ." }
            return
        }

        # Walk up
        $parent = Split-Path $dir -Parent
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) {
            # Reached filesystem root — no stack found
            return
        }
        $dir = $parent
    }
}

# Run detection
_DetectStack
