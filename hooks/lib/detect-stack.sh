#!/usr/bin/env bash
# detect-stack.sh - Auto-detect project stack and set test/build/lint commands
# Sourced by hooks. Sets: DETECTED_STACK, TEST_CMD, BUILD_CMD, LINT_CMD, SOURCE_PATTERN
# All commands are only set if the tool is actually installed.
# Designed for bash 3+ (macOS compat).

# Initialize outputs
DETECTED_STACK=""
TEST_CMD=""
BUILD_CMD=""
DEPLOY_BUILD_CMD=""
LINT_CMD=""
SOURCE_PATTERN=""

# Augment PATH with common tool locations (before any _has_cmd calls)
_augment_path() {
    local candidate
    for candidate in \
        "$HOME/.local/bin" \
        "$HOME/.cargo/bin" \
        "$HOME/.bun/bin" \
        "/usr/local/bin" \
        "/opt/homebrew/bin"; do
        if [ -d "$candidate" ]; then
            case ":$PATH:" in
                *":$candidate:"*) ;;
                *) PATH="$candidate:$PATH" ;;
            esac
        fi
    done
    export PATH
}
_augment_path

# Check if a command exists
_has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Check if a Node package.json has a given script
_has_npm_script() {
    local pkg="$1" script="$2"
    if [ ! -f "$pkg" ]; then
        return 1
    fi
    if ! _has_cmd jq; then
        return 1
    fi
    jq -e ".scripts.\"$script\" // empty" "$pkg" >/dev/null 2>&1
}

# Detect Node package manager from lockfile
_detect_node_pkg_manager() {
    local dir="$1"
    if [ -f "$dir/pnpm-lock.yaml" ]; then
        echo "pnpm"
    elif [ -f "$dir/yarn.lock" ]; then
        echo "yarn"
    elif [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then
        echo "bun"
    else
        echo "npm"
    fi
}

# Build command string for the detected Node package manager
_node_cmd() {
    local mgr="$1" script="$2"
    case "$mgr" in
        npm)   echo "npm run $script" ;;
        pnpm)  echo "pnpm $script" ;;
        yarn)  echo "yarn $script" ;;
        bun)   echo "bun run $script" ;;
    esac
}

# Walk up from cwd to find a marker file. Returns the directory containing it.
# Usage: _find_marker "filename"
# For glob patterns (*.csproj), use _find_marker_glob
_find_marker() {
    local marker="$1"
    local dir
    dir="$(pwd)"
    while true; do
        if [ -f "$dir/$marker" ]; then
            echo "$dir"
            return 0
        fi
        # Stop at filesystem root
        local parent
        parent="$(dirname "$dir")"
        if [ "$parent" = "$dir" ]; then
            return 1
        fi
        dir="$parent"
    done
}

# Walk up from cwd to find a marker matching a glob. Returns the directory.
_find_marker_glob() {
    local pattern="$1"
    local dir
    dir="$(pwd)"
    while true; do
        # Use ls to check for glob match (bash 3 safe)
        local found
        found="$(ls -1 "$dir"/$pattern 2>/dev/null | head -1)" || true
        if [ -n "$found" ]; then
            echo "$dir"
            return 0
        fi
        local parent
        parent="$(dirname "$dir")"
        if [ "$parent" = "$dir" ]; then
            return 1
        fi
        dir="$parent"
    done
}

# Detect stack by walking up from cwd and checking for marker files.
# Priority: check current dir first, then walk up. Closest marker wins.
# We check all markers at each level before walking up.
_detect_stack() {
    local dir
    dir="$(pwd)"

    while true; do
        # Node/TS
        if [ -f "$dir/package.json" ]; then
            DETECTED_STACK="node"
            SOURCE_PATTERN='\.(js|jsx|ts|tsx|mjs|cjs)$'
            local pkg="$dir/package.json"
            local mgr
            mgr="$(_detect_node_pkg_manager "$dir")"
            if ! _has_cmd "$mgr"; then
                mgr="npm"
            fi
            if _has_cmd "$mgr"; then
                if _has_npm_script "$pkg" "test"; then
                    TEST_CMD="$(_node_cmd "$mgr" "test")"
                fi
                if _has_npm_script "$pkg" "build"; then
                    BUILD_CMD="$(_node_cmd "$mgr" "build")"
                fi
                if _has_npm_script "$pkg" "lint"; then
                    LINT_CMD="$(_node_cmd "$mgr" "lint")"
                fi
                # Deployment-specific build (CF Pages, Vercel, etc.)
                # Stricter than standard build — catches platform-specific errors.
                # Checks common script names in priority order.
                for deploy_script in "pages:build" "deploy:build" "build:cf" "build:pages" "build:deploy" "build:production"; do
                    if _has_npm_script "$pkg" "$deploy_script"; then
                        DEPLOY_BUILD_CMD="$(_node_cmd "$mgr" "$deploy_script")"
                        break
                    fi
                done
            fi
            return 0
        fi

        # Python (pyproject.toml first, then requirements.txt)
        if [ -f "$dir/pyproject.toml" ] || [ -f "$dir/requirements.txt" ]; then
            DETECTED_STACK="python"
            SOURCE_PATTERN='\.py$'
            if _has_cmd pytest; then
                TEST_CMD="pytest"
            fi
            # No standard build command for Python
            BUILD_CMD=""
            if _has_cmd ruff; then
                LINT_CMD="ruff check ."
            fi
            return 0
        fi

        # Rust
        if [ -f "$dir/Cargo.toml" ]; then
            DETECTED_STACK="rust"
            SOURCE_PATTERN='\.rs$'
            if _has_cmd cargo; then
                TEST_CMD="cargo test"
                BUILD_CMD="cargo build"
                LINT_CMD="cargo clippy"
            fi
            return 0
        fi

        # Go
        if [ -f "$dir/go.mod" ]; then
            DETECTED_STACK="go"
            SOURCE_PATTERN='\.go$'
            if _has_cmd go; then
                TEST_CMD="go test ./..."
                BUILD_CMD="go build ./..."
                LINT_CMD="go vet ./..."
            fi
            return 0
        fi

        # .NET (glob for *.csproj)
        local csproj_match
        csproj_match="$(ls -1 "$dir"/*.csproj 2>/dev/null | head -1)" || true
        if [ -n "$csproj_match" ]; then
            DETECTED_STACK="dotnet"
            SOURCE_PATTERN='\.cs$'
            if _has_cmd dotnet; then
                TEST_CMD="dotnet test"
                BUILD_CMD="dotnet build"
            fi
            # No standard lint for .NET
            LINT_CMD=""
            return 0
        fi

        # Swift
        if [ -f "$dir/Package.swift" ]; then
            DETECTED_STACK="swift"
            SOURCE_PATTERN='\.swift$'
            if _has_cmd swift; then
                TEST_CMD="swift test"
                BUILD_CMD="swift build"
            fi
            if _has_cmd swiftlint; then
                LINT_CMD="swiftlint"
            fi
            return 0
        fi

        # Java/Kotlin (Gradle — check .kts first for Kotlin DSL)
        if [ -f "$dir/build.gradle.kts" ] || [ -f "$dir/build.gradle" ]; then
            DETECTED_STACK="gradle"
            SOURCE_PATTERN='\.(java|kt|kts)$'
            if [ -f "$dir/gradlew" ]; then
                TEST_CMD="./gradlew test"
                BUILD_CMD="./gradlew build"
                # Gradle lint only if checkstyle/ktlint plugin is configured
                LINT_CMD=""
            elif _has_cmd gradle; then
                TEST_CMD="gradle test"
                BUILD_CMD="gradle build"
                LINT_CMD=""
            fi
            return 0
        fi

        # Java (Maven)
        if [ -f "$dir/pom.xml" ]; then
            DETECTED_STACK="maven"
            SOURCE_PATTERN='\.java$'
            if _has_cmd mvn; then
                TEST_CMD="mvn test"
                BUILD_CMD="mvn compile"
                LINT_CMD=""
            fi
            return 0
        fi

        # Ruby
        if [ -f "$dir/Gemfile" ]; then
            DETECTED_STACK="ruby"
            SOURCE_PATTERN='\.rb$'
            if _has_cmd bundle; then
                TEST_CMD="bundle exec rspec"
            fi
            BUILD_CMD=""
            if _has_cmd rubocop; then
                LINT_CMD="rubocop"
            fi
            return 0
        fi

        # PHP
        if [ -f "$dir/composer.json" ]; then
            DETECTED_STACK="php"
            SOURCE_PATTERN='\.php$'
            if [ -f "$dir/vendor/bin/phpunit" ]; then
                TEST_CMD="./vendor/bin/phpunit"
            fi
            BUILD_CMD=""
            if [ -f "$dir/vendor/bin/phpcs" ]; then
                LINT_CMD="./vendor/bin/phpcs"
            fi
            return 0
        fi

        # Dart/Flutter
        if [ -f "$dir/pubspec.yaml" ]; then
            DETECTED_STACK="dart"
            SOURCE_PATTERN='\.dart$'
            if _has_cmd flutter; then
                TEST_CMD="flutter test"
                BUILD_CMD="flutter build"
                LINT_CMD="dart analyze"
            elif _has_cmd dart; then
                TEST_CMD="dart test"
                BUILD_CMD=""
                LINT_CMD="dart analyze"
            fi
            return 0
        fi

        # Elixir
        if [ -f "$dir/mix.exs" ]; then
            DETECTED_STACK="elixir"
            SOURCE_PATTERN='\.(ex|exs)$'
            if _has_cmd mix; then
                TEST_CMD="mix test"
                BUILD_CMD="mix compile"
                if _has_cmd mix; then
                    LINT_CMD="mix credo"
                fi
            fi
            return 0
        fi

        # C/C++ (CMake first, then Makefile)
        if [ -f "$dir/CMakeLists.txt" ]; then
            DETECTED_STACK="cmake"
            SOURCE_PATTERN='\.(c|cpp|cc|cxx|h|hpp)$'
            if _has_cmd cmake; then
                BUILD_CMD="cmake --build build"
                TEST_CMD="ctest --test-dir build"
            fi
            LINT_CMD=""
            if _has_cmd cppcheck; then
                LINT_CMD="cppcheck --enable=warning,style ."
            fi
            return 0
        fi

        if [ -f "$dir/Makefile" ]; then
            DETECTED_STACK="make"
            SOURCE_PATTERN='\.(c|cpp|cc|cxx|h|hpp)$'
            if _has_cmd make; then
                BUILD_CMD="make"
                TEST_CMD="make test"
            fi
            LINT_CMD=""
            if _has_cmd cppcheck; then
                LINT_CMD="cppcheck --enable=warning,style ."
            fi
            return 0
        fi

        # Walk up
        local parent
        parent="$(dirname "$dir")"
        if [ "$parent" = "$dir" ]; then
            # Reached filesystem root, no stack found
            return 0
        fi
        dir="$parent"
    done
}

# Run detection
_detect_stack
