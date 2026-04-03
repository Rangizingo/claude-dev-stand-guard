#!/usr/bin/env bash
# Tests for hooks/lib/detect-stack.sh
# Run: bash tests/test-detect-stack.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT_STACK="$SCRIPT_DIR/../hooks/lib/detect-stack.sh"

PASS=0
FAIL=0
TOTAL=0

# Colors (if terminal supports it)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s\n  expected: '%s'\n  actual:   '%s'\n" "$label" "$expected" "$actual"
    fi
}

assert_not_empty() {
    local label="$1" actual="$2"
    TOTAL=$((TOTAL + 1))
    if [ -n "$actual" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s (got: '%s')\n" "$label" "$actual"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s\n  expected non-empty, got empty\n" "$label"
    fi
}

assert_empty() {
    local label="$1" actual="$2"
    TOTAL=$((TOTAL + 1))
    if [ -z "$actual" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s\n  expected empty, got: '%s'\n" "$label" "$actual"
    fi
}

# Helper: source detect-stack in a subshell at a given directory, print vars
run_detect() {
    local dir="$1"
    (
        cd "$dir"
        # Reset vars so we get clean detection
        DETECTED_STACK=""
        TEST_CMD=""
        BUILD_CMD=""
        LINT_CMD=""
        SOURCE_PATTERN=""
        source "$DETECT_STACK"
        printf '%s\n' "$DETECTED_STACK" "$TEST_CMD" "$BUILD_CMD" "$LINT_CMD" "$SOURCE_PATTERN"
    )
}

# Parse the 5-line output from run_detect
parse_detect() {
    local output="$1"
    DETECTED_STACK="$(echo "$output" | sed -n '1p')"
    TEST_CMD="$(echo "$output" | sed -n '2p')"
    BUILD_CMD="$(echo "$output" | sed -n '3p')"
    LINT_CMD="$(echo "$output" | sed -n '4p')"
    SOURCE_PATTERN="$(echo "$output" | sed -n '5p')"
}

# Create a temp dir that gets cleaned up on exit
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

printf "\n${YELLOW}=== Phase 1: detect-stack.sh tests ===${NC}\n\n"

# --------------------------------------------------------------------------
# Test 1: Empty directory - no stack detected
# --------------------------------------------------------------------------
DIR="$TMPBASE/empty"
mkdir -p "$DIR"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Empty dir: no stack detected" "" "$DETECTED_STACK"
assert_empty "Empty dir: no TEST_CMD" "$TEST_CMD"
assert_empty "Empty dir: no BUILD_CMD" "$BUILD_CMD"
assert_empty "Empty dir: no LINT_CMD" "$LINT_CMD"

# --------------------------------------------------------------------------
# Test 2: Node/TS project with all scripts (npm via package-lock.json)
# --------------------------------------------------------------------------
DIR="$TMPBASE/node-full"
mkdir -p "$DIR"
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": {
    "test": "jest",
    "build": "tsc",
    "lint": "eslint ."
  }
}
PJSON
touch "$DIR/package-lock.json"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Node full: stack detected" "node" "$DETECTED_STACK"
assert_not_empty "Node full: SOURCE_PATTERN set" "$SOURCE_PATTERN"
# TEST_CMD depends on npm being installed (it is on most systems)
if command -v npm &>/dev/null; then
    assert_eq "Node full: TEST_CMD" "npm run test" "$TEST_CMD"
    assert_eq "Node full: BUILD_CMD" "npm run build" "$BUILD_CMD"
    assert_eq "Node full: LINT_CMD" "npm run lint" "$LINT_CMD"
else
    assert_empty "Node full (no npm): TEST_CMD empty" "$TEST_CMD"
    assert_empty "Node full (no npm): BUILD_CMD empty" "$BUILD_CMD"
    assert_empty "Node full (no npm): LINT_CMD empty" "$LINT_CMD"
fi

# --------------------------------------------------------------------------
# Test 3: Node project without test script in package.json
# --------------------------------------------------------------------------
DIR="$TMPBASE/node-no-test"
mkdir -p "$DIR"
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": {
    "build": "tsc"
  }
}
PJSON
touch "$DIR/package-lock.json"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Node no-test: stack detected" "node" "$DETECTED_STACK"
assert_empty "Node no-test: no TEST_CMD" "$TEST_CMD"
if command -v npm &>/dev/null; then
    assert_eq "Node no-test: BUILD_CMD set" "npm run build" "$BUILD_CMD"
else
    assert_empty "Node no-test (no npm): BUILD_CMD empty" "$BUILD_CMD"
fi

# --------------------------------------------------------------------------
# Test 4: Node project with empty scripts
# --------------------------------------------------------------------------
DIR="$TMPBASE/node-empty-scripts"
mkdir -p "$DIR"
cat > "$DIR/package.json" <<'PJSON'
{
  "name": "bare-project",
  "scripts": {}
}
PJSON
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Node empty scripts: stack detected" "node" "$DETECTED_STACK"
assert_empty "Node empty scripts: no TEST_CMD" "$TEST_CMD"
assert_empty "Node empty scripts: no BUILD_CMD" "$BUILD_CMD"
assert_empty "Node empty scripts: no LINT_CMD" "$LINT_CMD"

# --------------------------------------------------------------------------
# Test 5: Python project (pyproject.toml)
# --------------------------------------------------------------------------
DIR="$TMPBASE/python-pyproject"
mkdir -p "$DIR"
touch "$DIR/pyproject.toml"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Python pyproject: stack detected" "python" "$DETECTED_STACK"
if command -v pytest &>/dev/null; then
    assert_eq "Python pyproject: TEST_CMD" "pytest" "$TEST_CMD"
else
    assert_empty "Python pyproject (no pytest): TEST_CMD empty" "$TEST_CMD"
fi
assert_empty "Python: no BUILD_CMD" "$BUILD_CMD"
if command -v ruff &>/dev/null; then
    assert_eq "Python pyproject: LINT_CMD" "ruff check ." "$LINT_CMD"
else
    assert_empty "Python pyproject (no ruff): LINT_CMD empty" "$LINT_CMD"
fi
assert_not_empty "Python: SOURCE_PATTERN set" "$SOURCE_PATTERN"

# --------------------------------------------------------------------------
# Test 6: Python project (requirements.txt only)
# --------------------------------------------------------------------------
DIR="$TMPBASE/python-requirements"
mkdir -p "$DIR"
touch "$DIR/requirements.txt"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Python requirements.txt: stack detected" "python" "$DETECTED_STACK"

# --------------------------------------------------------------------------
# Test 7: Rust project
# --------------------------------------------------------------------------
DIR="$TMPBASE/rust"
mkdir -p "$DIR"
touch "$DIR/Cargo.toml"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Rust: stack detected" "rust" "$DETECTED_STACK"
if command -v cargo &>/dev/null; then
    assert_eq "Rust: TEST_CMD" "cargo test" "$TEST_CMD"
    assert_eq "Rust: BUILD_CMD" "cargo build" "$BUILD_CMD"
    assert_eq "Rust: LINT_CMD" "cargo clippy" "$LINT_CMD"
else
    assert_empty "Rust (no cargo): TEST_CMD empty" "$TEST_CMD"
    assert_empty "Rust (no cargo): BUILD_CMD empty" "$BUILD_CMD"
    assert_empty "Rust (no cargo): LINT_CMD empty" "$LINT_CMD"
fi
assert_not_empty "Rust: SOURCE_PATTERN set" "$SOURCE_PATTERN"

# --------------------------------------------------------------------------
# Test 8: Go project
# --------------------------------------------------------------------------
DIR="$TMPBASE/golang"
mkdir -p "$DIR"
touch "$DIR/go.mod"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Go: stack detected" "go" "$DETECTED_STACK"
if command -v go &>/dev/null; then
    assert_eq "Go: TEST_CMD" "go test ./..." "$TEST_CMD"
    assert_eq "Go: BUILD_CMD" "go build ./..." "$BUILD_CMD"
    assert_eq "Go: LINT_CMD" "go vet ./..." "$LINT_CMD"
else
    assert_empty "Go (no go): TEST_CMD empty" "$TEST_CMD"
    assert_empty "Go (no go): BUILD_CMD empty" "$BUILD_CMD"
    assert_empty "Go (no go): LINT_CMD empty" "$LINT_CMD"
fi
assert_not_empty "Go: SOURCE_PATTERN set" "$SOURCE_PATTERN"

# --------------------------------------------------------------------------
# Test 9: .NET project
# --------------------------------------------------------------------------
DIR="$TMPBASE/dotnet"
mkdir -p "$DIR"
touch "$DIR/MyApp.csproj"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq ".NET: stack detected" "dotnet" "$DETECTED_STACK"
if command -v dotnet &>/dev/null; then
    assert_eq ".NET: TEST_CMD" "dotnet test" "$TEST_CMD"
    assert_eq ".NET: BUILD_CMD" "dotnet build" "$BUILD_CMD"
else
    assert_empty ".NET (no dotnet): TEST_CMD empty" "$TEST_CMD"
    assert_empty ".NET (no dotnet): BUILD_CMD empty" "$BUILD_CMD"
fi
assert_empty ".NET: no LINT_CMD" "$LINT_CMD"
assert_not_empty ".NET: SOURCE_PATTERN set" "$SOURCE_PATTERN"

# --------------------------------------------------------------------------
# Test 10: Swift project
# --------------------------------------------------------------------------
DIR="$TMPBASE/swift"
mkdir -p "$DIR"
touch "$DIR/Package.swift"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Swift: stack detected" "swift" "$DETECTED_STACK"
if command -v swift &>/dev/null; then
    assert_eq "Swift: TEST_CMD" "swift test" "$TEST_CMD"
    assert_eq "Swift: BUILD_CMD" "swift build" "$BUILD_CMD"
else
    assert_empty "Swift (no swift): TEST_CMD empty" "$TEST_CMD"
    assert_empty "Swift (no swift): BUILD_CMD empty" "$BUILD_CMD"
fi
if command -v swiftlint &>/dev/null; then
    assert_eq "Swift: LINT_CMD" "swiftlint" "$LINT_CMD"
else
    assert_empty "Swift (no swiftlint): LINT_CMD empty" "$LINT_CMD"
fi
assert_not_empty "Swift: SOURCE_PATTERN set" "$SOURCE_PATTERN"

# --------------------------------------------------------------------------
# Test 11: Monorepo detection (marker in parent dir)
# --------------------------------------------------------------------------
DIR="$TMPBASE/monorepo"
mkdir -p "$DIR/packages/sub"
touch "$DIR/package.json"
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": { "test": "jest" }
}
PJSON
OUTPUT="$(run_detect "$DIR/packages/sub")"
parse_detect "$OUTPUT"
assert_eq "Monorepo: stack detected from parent" "node" "$DETECTED_STACK"

# --------------------------------------------------------------------------
# Test 12: Monorepo stops at filesystem root (no infinite walk)
# --------------------------------------------------------------------------
DIR="$TMPBASE/no-markers-deep/a/b/c"
mkdir -p "$DIR"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Deep no-markers: no stack detected" "" "$DETECTED_STACK"

# --------------------------------------------------------------------------
# Test 13: Closest marker wins (subproject overrides parent)
# --------------------------------------------------------------------------
DIR="$TMPBASE/nested-stacks"
mkdir -p "$DIR/frontend"
touch "$DIR/go.mod"
cat > "$DIR/frontend/package.json" <<'PJSON'
{
  "scripts": { "test": "vitest" }
}
PJSON
OUTPUT="$(run_detect "$DIR/frontend")"
parse_detect "$OUTPUT"
assert_eq "Nested stacks: closest marker wins" "node" "$DETECTED_STACK"

# --------------------------------------------------------------------------
# Test 14: Script does not error on source (exit code 0)
# --------------------------------------------------------------------------
DIR="$TMPBASE/exit-code-check"
mkdir -p "$DIR"
EXIT_CODE=0
(cd "$DIR" && source "$DETECT_STACK") || EXIT_CODE=$?
TOTAL=$((TOTAL + 1))
if [ "$EXIT_CODE" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}PASS${NC} Exit code 0 on empty dir\n"
else
    FAIL=$((FAIL + 1))
    printf "${RED}FAIL${NC} Exit code %d on empty dir (expected 0)\n" "$EXIT_CODE"
fi

# --------------------------------------------------------------------------
# Test 15: Python pyproject.toml takes priority over requirements.txt
# --------------------------------------------------------------------------
DIR="$TMPBASE/python-both"
mkdir -p "$DIR"
touch "$DIR/pyproject.toml"
touch "$DIR/requirements.txt"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Python both markers: stack detected" "python" "$DETECTED_STACK"
# Should still work fine, just detect python once
TOTAL=$((TOTAL + 1))
if [ "$DETECTED_STACK" = "python" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}PASS${NC} Python both markers: no double detection\n"
else
    FAIL=$((FAIL + 1))
    printf "${RED}FAIL${NC} Python both markers: unexpected stack '%s'\n" "$DETECTED_STACK"
fi

# --------------------------------------------------------------------------
# Test 16: package.json without scripts key at all
# --------------------------------------------------------------------------
DIR="$TMPBASE/node-no-scripts-key"
mkdir -p "$DIR"
cat > "$DIR/package.json" <<'PJSON'
{
  "name": "no-scripts"
}
PJSON
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Node no scripts key: stack detected" "node" "$DETECTED_STACK"
assert_empty "Node no scripts key: no TEST_CMD" "$TEST_CMD"
assert_empty "Node no scripts key: no BUILD_CMD" "$BUILD_CMD"
assert_empty "Node no scripts key: no LINT_CMD" "$LINT_CMD"

# --------------------------------------------------------------------------
# Test 17: pnpm project (pnpm-lock.yaml)
# --------------------------------------------------------------------------
DIR="$TMPBASE/node-pnpm"
mkdir -p "$DIR"
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": { "test": "vitest", "build": "tsc", "lint": "eslint ." }
}
PJSON
touch "$DIR/pnpm-lock.yaml"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "pnpm: stack detected" "node" "$DETECTED_STACK"
if command -v pnpm &>/dev/null; then
    assert_eq "pnpm: TEST_CMD" "pnpm test" "$TEST_CMD"
    assert_eq "pnpm: BUILD_CMD" "pnpm build" "$BUILD_CMD"
    assert_eq "pnpm: LINT_CMD" "pnpm lint" "$LINT_CMD"
elif command -v npm &>/dev/null; then
    # Falls back to npm if pnpm not installed
    assert_eq "pnpm fallback: TEST_CMD" "npm run test" "$TEST_CMD"
else
    assert_empty "pnpm (no mgr): TEST_CMD empty" "$TEST_CMD"
fi

# --------------------------------------------------------------------------
# Test 18: yarn project (yarn.lock)
# --------------------------------------------------------------------------
DIR="$TMPBASE/node-yarn"
mkdir -p "$DIR"
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": { "test": "jest", "build": "webpack" }
}
PJSON
touch "$DIR/yarn.lock"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "yarn: stack detected" "node" "$DETECTED_STACK"
if command -v yarn &>/dev/null; then
    assert_eq "yarn: TEST_CMD" "yarn test" "$TEST_CMD"
    assert_eq "yarn: BUILD_CMD" "yarn build" "$BUILD_CMD"
elif command -v npm &>/dev/null; then
    assert_eq "yarn fallback: TEST_CMD" "npm run test" "$TEST_CMD"
else
    assert_empty "yarn (no mgr): TEST_CMD empty" "$TEST_CMD"
fi

# --------------------------------------------------------------------------
# Test 19: bun project (bun.lockb)
# --------------------------------------------------------------------------
DIR="$TMPBASE/node-bun"
mkdir -p "$DIR"
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": { "test": "bun test", "build": "bun build" }
}
PJSON
touch "$DIR/bun.lockb"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "bun: stack detected" "node" "$DETECTED_STACK"
if command -v bun &>/dev/null; then
    assert_eq "bun: TEST_CMD" "bun run test" "$TEST_CMD"
    assert_eq "bun: BUILD_CMD" "bun run build" "$BUILD_CMD"
elif command -v npm &>/dev/null; then
    assert_eq "bun fallback: TEST_CMD" "npm run test" "$TEST_CMD"
else
    assert_empty "bun (no mgr): TEST_CMD empty" "$TEST_CMD"
fi

# --------------------------------------------------------------------------
# Test 20: No lockfile defaults to npm
# --------------------------------------------------------------------------
DIR="$TMPBASE/node-no-lock"
mkdir -p "$DIR"
cat > "$DIR/package.json" <<'PJSON'
{
  "scripts": { "test": "jest" }
}
PJSON
# No lockfile at all
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "No lockfile: stack detected" "node" "$DETECTED_STACK"
if command -v npm &>/dev/null; then
    assert_eq "No lockfile: defaults to npm" "npm run test" "$TEST_CMD"
fi

# --------------------------------------------------------------------------
# Test 21: Gradle project (build.gradle)
# --------------------------------------------------------------------------
DIR="$TMPBASE/gradle"
mkdir -p "$DIR"
echo 'apply plugin: "java"' > "$DIR/build.gradle"
touch "$DIR/gradlew" && chmod +x "$DIR/gradlew"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Gradle: stack detected" "gradle" "$DETECTED_STACK"
assert_not_empty "Gradle: SOURCE_PATTERN set" "$SOURCE_PATTERN"
assert_eq "Gradle: TEST_CMD via gradlew" "./gradlew test" "$TEST_CMD"
assert_eq "Gradle: BUILD_CMD via gradlew" "./gradlew build" "$BUILD_CMD"

# --------------------------------------------------------------------------
# Test 22: Gradle Kotlin DSL (build.gradle.kts)
# --------------------------------------------------------------------------
DIR="$TMPBASE/gradle-kts"
mkdir -p "$DIR"
echo 'plugins { kotlin("jvm") }' > "$DIR/build.gradle.kts"
touch "$DIR/gradlew" && chmod +x "$DIR/gradlew"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Gradle KTS: stack detected" "gradle" "$DETECTED_STACK"

# --------------------------------------------------------------------------
# Test 23: Maven project (pom.xml)
# --------------------------------------------------------------------------
DIR="$TMPBASE/maven"
mkdir -p "$DIR"
echo '<project></project>' > "$DIR/pom.xml"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Maven: stack detected" "maven" "$DETECTED_STACK"
if command -v mvn &>/dev/null; then
    assert_eq "Maven: TEST_CMD" "mvn test" "$TEST_CMD"
    assert_eq "Maven: BUILD_CMD" "mvn compile" "$BUILD_CMD"
else
    assert_empty "Maven (no mvn): TEST_CMD empty" "$TEST_CMD"
fi

# --------------------------------------------------------------------------
# Test 24: Ruby project (Gemfile)
# --------------------------------------------------------------------------
DIR="$TMPBASE/ruby"
mkdir -p "$DIR"
echo 'source "https://rubygems.org"' > "$DIR/Gemfile"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Ruby: stack detected" "ruby" "$DETECTED_STACK"
assert_not_empty "Ruby: SOURCE_PATTERN set" "$SOURCE_PATTERN"

# --------------------------------------------------------------------------
# Test 25: PHP project (composer.json)
# --------------------------------------------------------------------------
DIR="$TMPBASE/php"
mkdir -p "$DIR"
echo '{}' > "$DIR/composer.json"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "PHP: stack detected" "php" "$DETECTED_STACK"
assert_not_empty "PHP: SOURCE_PATTERN set" "$SOURCE_PATTERN"

# --------------------------------------------------------------------------
# Test 26: Dart/Flutter project (pubspec.yaml)
# --------------------------------------------------------------------------
DIR="$TMPBASE/dart"
mkdir -p "$DIR"
echo 'name: myapp' > "$DIR/pubspec.yaml"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Dart: stack detected" "dart" "$DETECTED_STACK"
assert_not_empty "Dart: SOURCE_PATTERN set" "$SOURCE_PATTERN"

# --------------------------------------------------------------------------
# Test 27: Elixir project (mix.exs)
# --------------------------------------------------------------------------
DIR="$TMPBASE/elixir"
mkdir -p "$DIR"
echo 'defmodule MyApp do end' > "$DIR/mix.exs"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Elixir: stack detected" "elixir" "$DETECTED_STACK"
assert_not_empty "Elixir: SOURCE_PATTERN set" "$SOURCE_PATTERN"

# --------------------------------------------------------------------------
# Test 28: CMake project (CMakeLists.txt)
# --------------------------------------------------------------------------
DIR="$TMPBASE/cmake"
mkdir -p "$DIR"
echo 'cmake_minimum_required(VERSION 3.10)' > "$DIR/CMakeLists.txt"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "CMake: stack detected" "cmake" "$DETECTED_STACK"
assert_not_empty "CMake: SOURCE_PATTERN set" "$SOURCE_PATTERN"

# --------------------------------------------------------------------------
# Test 29: Makefile project
# --------------------------------------------------------------------------
DIR="$TMPBASE/makefile"
mkdir -p "$DIR"
printf 'all:\n\techo build\ntest:\n\techo test\n' > "$DIR/Makefile"
OUTPUT="$(run_detect "$DIR")"
parse_detect "$OUTPUT"
assert_eq "Makefile: stack detected" "make" "$DETECTED_STACK"
if command -v make &>/dev/null; then
    assert_eq "Makefile: BUILD_CMD" "make" "$BUILD_CMD"
    assert_eq "Makefile: TEST_CMD" "make test" "$TEST_CMD"
fi

# --------------------------------------------------------------------------
# Results
# --------------------------------------------------------------------------
printf "\n${YELLOW}=== Results ===${NC}\n"
printf "Total: %d | ${GREEN}Pass: %d${NC} | ${RED}Fail: %d${NC}\n\n" "$TOTAL" "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
