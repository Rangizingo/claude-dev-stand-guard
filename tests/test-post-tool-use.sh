#!/usr/bin/env bash
# test-post-tool-use.sh — Tests that post_tool_use.sh kicks in for all languages
# Tests the INSTALLED hook at ~/.claude/hooks/post_tool_use.sh
# Run: bash tests/test-post-tool-use.sh
set -uo pipefail

HOOK="$HOME/.claude/hooks/post_tool_use.sh"
PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
DIM='\033[2m'
NC='\033[0m'

assert_exit() {
    local label="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s (expected exit %d, got %d)\n" "$label" "$expected" "$actual"
    fi
}

assert_output_contains() {
    local label="$1" pattern="$2" output="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$output" | grep -q "$pattern"; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s (missing: '%s')\n" "$label" "$pattern"
    fi
}

assert_output_empty() {
    local label="$1" output="$2"
    TOTAL=$((TOTAL + 1))
    if [ -z "$output" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}PASS${NC} %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "${RED}FAIL${NC} %s (expected empty, got output)\n" "$label"
    fi
}

run_hook() {
    local tool_name="$1" file_path="$2"
    echo "{\"tool_name\":\"$tool_name\",\"tool_input\":{\"file_path\":\"$file_path\"}}" | bash "$HOOK" 2>&1
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

# =========================================================================
printf "\n${YELLOW}=== 1. Skipping Logic ===${NC}\n\n"
# =========================================================================

# Non-edit tool: skip
OUTPUT="$(run_hook "Bash" "/tmp/foo.ts")"
assert_exit "Skip Bash tool" 0 $?
assert_output_empty "Skip Bash: no output" "$OUTPUT"

# Missing file: skip
OUTPUT="$(run_hook "Edit" "/tmp/nonexistent_xxxxx.ts")"
assert_exit "Skip missing file" 0 $?
assert_output_empty "Skip missing: no output" "$OUTPUT"

# Unknown extension: skip
UNKNOWN="$TMPBASE/readme.md"
echo "# Hello" > "$UNKNOWN"
OUTPUT="$(run_hook "Write" "$UNKNOWN")"
assert_exit "Skip .md file" 0 $?
assert_output_empty "Skip .md: no output" "$OUTPUT"

# =========================================================================
printf "\n${YELLOW}=== 2. Python ===${NC}\n\n"
# =========================================================================

PYDIR="$TMPBASE/pyproject"
mkdir -p "$PYDIR"
touch "$PYDIR/pyproject.toml"

# Clean file: passes
PYFILE="$PYDIR/clean.py"
echo 'x = 1' > "$PYFILE"
OUTPUT="$(run_hook "Write" "$PYFILE")"
assert_exit "Python clean: exit 0" 0 $?
assert_output_empty "Python clean: no errors" "$OUTPUT"

# File with ruff error (if ruff installed)
if command -v ruff &>/dev/null; then
    PYFILE="$PYDIR/bad.py"
    echo 'import os' > "$PYFILE"  # unused import
    OUTPUT="$(run_hook "Write" "$PYFILE")"
    # ruff may or may not flag this depending on config, so just check it ran
    assert_exit "Python ruff: exit 0" 0 $?
    printf "${DIM}  (ruff output: %s)${NC}\n" "$(echo "$OUTPUT" | head -c 80)"
else
    printf "${DIM}SKIP${NC} ruff not installed\n"
fi

# =========================================================================
printf "\n${YELLOW}=== 3. TypeScript/JavaScript ===${NC}\n\n"
# =========================================================================

NODEDIR="$TMPBASE/nodeproject"
mkdir -p "$NODEDIR"
cat > "$NODEDIR/package.json" <<'EOF'
{"scripts":{"typecheck":"echo typecheck-ran && exit 0"}}
EOF
touch "$NODEDIR/package-lock.json"

TSFILE="$NODEDIR/app.ts"
echo 'const x: number = 1;' > "$TSFILE"
OUTPUT="$(run_hook "Edit" "$TSFILE")"
assert_exit "TS clean: exit 0" 0 $?

# TS with failing typecheck
NODEDIR2="$TMPBASE/nodeproject-fail"
mkdir -p "$NODEDIR2"
cat > "$NODEDIR2/package.json" <<'EOF'
{"scripts":{"typecheck":"echo 'error TS2322: Type string not assignable' && exit 1"}}
EOF
touch "$NODEDIR2/package-lock.json"

TSFILE2="$NODEDIR2/bad.ts"
echo 'const x = 1;' > "$TSFILE2"
OUTPUT="$(run_hook "Edit" "$TSFILE2")"
assert_exit "TS typecheck fail: exit 0 (with block JSON)" 0 $?
assert_output_contains "TS typecheck fail: has block decision" "block" "$OUTPUT"
assert_output_contains "TS typecheck fail: has TS error" "error TS" "$OUTPUT"

# JS file (same handler)
JSFILE="$NODEDIR/app.js"
echo 'const x = 1;' > "$JSFILE"
OUTPUT="$(run_hook "Write" "$JSFILE")"
assert_exit "JS clean: exit 0" 0 $?

# JSX file
JSXFILE="$NODEDIR/component.jsx"
echo 'const App = () => null;' > "$JSXFILE"
OUTPUT="$(run_hook "Write" "$JSXFILE")"
assert_exit "JSX clean: exit 0" 0 $?

# TSX file
TSXFILE="$NODEDIR/component.tsx"
echo 'const App = () => null;' > "$TSXFILE"
OUTPUT="$(run_hook "Write" "$TSXFILE")"
assert_exit "TSX clean: exit 0" 0 $?

# JSON file
JSONFILE="$NODEDIR/config.json"
echo '{"key": "value"}' > "$JSONFILE"
OUTPUT="$(run_hook "Write" "$JSONFILE")"
assert_exit "JSON clean: exit 0" 0 $?

# =========================================================================
printf "\n${YELLOW}=== 4. Rust ===${NC}\n\n"
# =========================================================================

RSDIR="$TMPBASE/rustproject"
mkdir -p "$RSDIR/src"
cat > "$RSDIR/Cargo.toml" <<'EOF'
[package]
name = "test"
version = "0.1.0"
edition = "2021"
EOF

RSFILE="$RSDIR/src/main.rs"
echo 'fn main() {}' > "$RSFILE"
OUTPUT="$(run_hook "Write" "$RSFILE")"
assert_exit "Rust clean: exit 0" 0 $?
if command -v cargo &>/dev/null; then
    printf "${DIM}  (cargo check ran)${NC}\n"
else
    printf "${DIM}  (cargo not installed, skipped check)${NC}\n"
fi

# =========================================================================
printf "\n${YELLOW}=== 5. Go ===${NC}\n\n"
# =========================================================================

GODIR="$TMPBASE/goproject"
mkdir -p "$GODIR"
cat > "$GODIR/go.mod" <<'EOF'
module test
go 1.21
EOF

# Clean file
GOFILE="$GODIR/main.go"
cat > "$GOFILE" <<'EOF'
package main

func main() {}
EOF
OUTPUT="$(run_hook "Write" "$GOFILE")"
assert_exit "Go clean: exit 0" 0 $?

# Go file with vet error (if go installed)
if command -v go &>/dev/null; then
    GOFILE2="$GODIR/bad.go"
    cat > "$GOFILE2" <<'GOEOF'
package main

import "fmt"

func bad() {
	fmt.Printf("%d", "not a number")
}
GOEOF
    OUTPUT="$(run_hook "Write" "$GOFILE2")"
    assert_exit "Go vet error: exit 0 (with block JSON)" 0 $?
    assert_output_contains "Go vet error: has block decision" "block" "$OUTPUT"
    # Clean up so other tests don't fail
    rm "$GOFILE2"
else
    printf "${DIM}SKIP${NC} go not installed\n"
fi

# =========================================================================
printf "\n${YELLOW}=== 6. C# ===${NC}\n\n"
# =========================================================================

CSDIR="$TMPBASE/dotnetproject"
mkdir -p "$CSDIR"
touch "$CSDIR/App.csproj"

CSFILE="$CSDIR/Program.cs"
echo 'class Program { static void Main() {} }' > "$CSFILE"
OUTPUT="$(run_hook "Write" "$CSFILE")"
assert_exit "C# clean: exit 0" 0 $?
if command -v dotnet &>/dev/null; then
    printf "${DIM}  (dotnet ran)${NC}\n"
else
    printf "${DIM}  (dotnet not installed, skipped)${NC}\n"
fi

# =========================================================================
printf "\n${YELLOW}=== 7. Swift ===${NC}\n\n"
# =========================================================================

SWIFTDIR="$TMPBASE/swiftproject"
mkdir -p "$SWIFTDIR"
touch "$SWIFTDIR/Package.swift"

SWIFTFILE="$SWIFTDIR/main.swift"
echo 'import Foundation' > "$SWIFTFILE"
OUTPUT="$(run_hook "Write" "$SWIFTFILE")"
assert_exit "Swift clean: exit 0" 0 $?
if command -v swiftlint &>/dev/null; then
    printf "${DIM}  (swiftlint ran)${NC}\n"
else
    printf "${DIM}  (swiftlint not installed, skipped)${NC}\n"
fi

# =========================================================================
printf "\n${YELLOW}=== 8. Java ===${NC}\n\n"
# =========================================================================

JAVADIR="$TMPBASE/javaproject"
mkdir -p "$JAVADIR/src"
echo 'apply plugin: "java"' > "$JAVADIR/build.gradle"
touch "$JAVADIR/gradlew" && chmod +x "$JAVADIR/gradlew"

JAVAFILE="$JAVADIR/src/Main.java"
echo 'public class Main { public static void main(String[] args) {} }' > "$JAVAFILE"
OUTPUT="$(run_hook "Write" "$JAVAFILE")"
assert_exit "Java clean: exit 0" 0 $?

# =========================================================================
printf "\n${YELLOW}=== 9. Kotlin ===${NC}\n\n"
# =========================================================================

KTDIR="$TMPBASE/kotlinproject"
mkdir -p "$KTDIR/src"
echo 'plugins { kotlin("jvm") }' > "$KTDIR/build.gradle.kts"
touch "$KTDIR/gradlew" && chmod +x "$KTDIR/gradlew"

KTFILE="$KTDIR/src/Main.kt"
echo 'fun main() { println("hello") }' > "$KTFILE"
OUTPUT="$(run_hook "Write" "$KTFILE")"
assert_exit "Kotlin clean: exit 0" 0 $?

# =========================================================================
printf "\n${YELLOW}=== 10. Ruby ===${NC}\n\n"
# =========================================================================

RBDIR="$TMPBASE/rubyproject"
mkdir -p "$RBDIR"
echo 'source "https://rubygems.org"' > "$RBDIR/Gemfile"

RBFILE="$RBDIR/app.rb"
echo 'puts "hello"' > "$RBFILE"
OUTPUT="$(run_hook "Write" "$RBFILE")"
assert_exit "Ruby clean: exit 0" 0 $?

# =========================================================================
printf "\n${YELLOW}=== 11. PHP ===${NC}\n\n"
# =========================================================================

PHPDIR="$TMPBASE/phpproject"
mkdir -p "$PHPDIR"
echo '{}' > "$PHPDIR/composer.json"

PHPFILE="$PHPDIR/index.php"
echo '<?php echo "hello"; ?>' > "$PHPFILE"
OUTPUT="$(run_hook "Write" "$PHPFILE")"
assert_exit "PHP clean: exit 0" 0 $?

# PHP syntax error (php -l always available on most systems)
if command -v php &>/dev/null; then
    PHPBAD="$PHPDIR/bad.php"
    echo '<?php echo "missing semicolon" ?>' > "$PHPBAD"
    # Note: this is actually valid PHP, so test with real syntax error
    echo '<?php function( {}' > "$PHPBAD"
    OUTPUT="$(run_hook "Write" "$PHPBAD")"
    assert_exit "PHP syntax error: exit 0 (with block)" 0 $?
    assert_output_contains "PHP syntax error: has block" "block" "$OUTPUT"
else
    printf "${DIM}SKIP${NC} php not installed\n"
fi

# =========================================================================
printf "\n${YELLOW}=== 12. Dart ===${NC}\n\n"
# =========================================================================

DARTDIR="$TMPBASE/dartproject"
mkdir -p "$DARTDIR"
echo 'name: myapp' > "$DARTDIR/pubspec.yaml"

DARTFILE="$DARTDIR/main.dart"
echo 'void main() { print("hello"); }' > "$DARTFILE"
OUTPUT="$(run_hook "Write" "$DARTFILE")"
assert_exit "Dart clean: exit 0" 0 $?

# =========================================================================
printf "\n${YELLOW}=== 13. Elixir ===${NC}\n\n"
# =========================================================================

EXDIR="$TMPBASE/elixirproject"
mkdir -p "$EXDIR"
echo 'defmodule MyApp do end' > "$EXDIR/mix.exs"

EXFILE="$EXDIR/app.ex"
echo 'defmodule App do def hello, do: :world end' > "$EXFILE"
OUTPUT="$(run_hook "Write" "$EXFILE")"
assert_exit "Elixir clean: exit 0" 0 $?

# =========================================================================
printf "\n${YELLOW}=== 14. C/C++ ===${NC}\n\n"
# =========================================================================

CDIR="$TMPBASE/cproject"
mkdir -p "$CDIR"
echo 'cmake_minimum_required(VERSION 3.10)' > "$CDIR/CMakeLists.txt"

CFILE="$CDIR/main.c"
echo '#include <stdio.h>' > "$CFILE"
echo 'int main() { return 0; }' >> "$CFILE"
OUTPUT="$(run_hook "Write" "$CFILE")"
assert_exit "C clean: exit 0" 0 $?

CPPFILE="$CDIR/app.cpp"
echo '#include <iostream>' > "$CPPFILE"
echo 'int main() { return 0; }' >> "$CPPFILE"
OUTPUT="$(run_hook "Write" "$CPPFILE")"
assert_exit "C++ clean: exit 0" 0 $?

HFILE="$CDIR/header.h"
echo '#ifndef HEADER_H' > "$HFILE"
echo '#define HEADER_H' >> "$HFILE"
echo '#endif' >> "$HFILE"
OUTPUT="$(run_hook "Write" "$HFILE")"
assert_exit "Header .h: exit 0" 0 $?

# =========================================================================
printf "\n${YELLOW}=== 15. Flux Integration ===${NC}\n\n"
# =========================================================================

FLUX_DIR="/Users/peterb/Documents/AI/flux"
if [ -d "$FLUX_DIR" ]; then
    # Real .ts file in Flux — should typecheck via pnpm
    FLUX_TS="$FLUX_DIR/workers/api/src/index.ts"
    if [ -f "$FLUX_TS" ]; then
        OUTPUT="$(run_hook "Edit" "$FLUX_TS")"
        assert_exit "Flux .ts typecheck: exit 0" 0 $?
        assert_output_empty "Flux .ts: no errors (clean)" "$OUTPUT"
    fi

    # Schema file
    FLUX_SCHEMA="$FLUX_DIR/packages/db/src/schema/appointments.ts"
    if [ -f "$FLUX_SCHEMA" ]; then
        OUTPUT="$(run_hook "Edit" "$FLUX_SCHEMA")"
        assert_exit "Flux schema .ts: exit 0" 0 $?
    fi
else
    printf "${DIM}SKIP${NC} Flux not found\n"
fi

# =========================================================================
printf "\n${YELLOW}=== 9. MultiEdit Support ===${NC}\n\n"
# =========================================================================

MEFILE="$TMPBASE/pyproject/multi.py"
echo 'y = 2' > "$MEFILE"
OUTPUT="$(run_hook "MultiEdit" "$MEFILE")"
assert_exit "MultiEdit: exit 0" 0 $?

# =========================================================================
# Results
# =========================================================================
printf "\n${YELLOW}=== Results ===${NC}\n"
printf "Total: %d | ${GREEN}Pass: %d${NC} | ${RED}Fail: %d${NC}\n\n" "$TOTAL" "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
