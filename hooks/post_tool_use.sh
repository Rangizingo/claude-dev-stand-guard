#!/usr/bin/env bash
# post_tool_use.sh — Global auto-format + lint feedback after Write/Edit
#
# Two jobs:
#   1. Format the file (silent, always)
#   2. Lint the file and feed errors back to Claude for self-correction
#
# If a project-level PostToolUse hook exists (.claude/settings.json in the project),
# both run. Global formats, project lints with project-specific config.
#
# Formatters (silently skipped if not installed):
#   .py                      → black + ruff check
#   .js .ts .jsx .tsx .json  → prettier + eslint + typecheck (turbo cached)
#   .cs                      → dotnet format + dotnet build
#   .rs                      → rustfmt + cargo check
#   .go                      → goimports/gofmt + go vet
#   .swift                   → swiftformat + swiftlint
#   .java                    → google-java-format + gradle/maven compile
#   .kt .kts                 → ktlint + gradle compileKotlin
#   .rb                      → rubocop (format + lint)
#   .php                     → php-cs-fixer + php -l
#   .dart                    → dart format + dart analyze
#   .ex .exs                 → mix format + mix compile
#   .c .cpp .h .hpp          → clang-format + cppcheck

set -uo pipefail

INPUT="$(cat)"

TOOL_NAME="$(printf '%s' "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)" || true
FILE_PATH="$(printf '%s' "${INPUT}" | jq -r '.tool_input.file_path // empty' 2>/dev/null)" || true

if [[ "${TOOL_NAME}" != "Write" && "${TOOL_NAME}" != "Edit" && "${TOOL_NAME}" != "MultiEdit" ]]; then
    exit 0
fi

if [[ -z "${FILE_PATH}" || ! -f "${FILE_PATH}" ]]; then
    exit 0
fi

EXT="${FILE_PATH##*.}"
EXT="$(printf '%s' "$EXT" | tr '[:upper:]' '[:lower:]')"

ERRORS=""

# Find project root (walk up looking for package.json, Cargo.toml, etc.)
PROJECT_DIR="$(dirname "${FILE_PATH}")"
while [[ "${PROJECT_DIR}" != "/" && \
         ! -f "${PROJECT_DIR}/package.json" && \
         ! -f "${PROJECT_DIR}/Cargo.toml" && \
         ! -f "${PROJECT_DIR}/pyproject.toml" && \
         ! -f "${PROJECT_DIR}/go.mod" && \
         ! -f "${PROJECT_DIR}/Package.swift" && \
         ! -f "${PROJECT_DIR}/build.gradle" && \
         ! -f "${PROJECT_DIR}/build.gradle.kts" && \
         ! -f "${PROJECT_DIR}/pom.xml" && \
         ! -f "${PROJECT_DIR}/Gemfile" && \
         ! -f "${PROJECT_DIR}/composer.json" && \
         ! -f "${PROJECT_DIR}/pubspec.yaml" && \
         ! -f "${PROJECT_DIR}/mix.exs" && \
         ! -f "${PROJECT_DIR}/CMakeLists.txt" && \
         ! -f "${PROJECT_DIR}/Makefile" ]]; do
    PROJECT_DIR="$(dirname "${PROJECT_DIR}")"
done

case "${EXT}" in
    py)
        # Format
        command -v black &>/dev/null && black --quiet "${FILE_PATH}" 2>/dev/null || true
        # Lint with feedback
        if command -v ruff &>/dev/null; then
            LINT_OUT="$(ruff check "${FILE_PATH}" 2>&1)" || ERRORS="Ruff errors in $(basename "${FILE_PATH}"):\n${LINT_OUT}"
        fi
        ;;
    js|ts|jsx|tsx)
        # Format
        if [[ -f "${PROJECT_DIR}/node_modules/.bin/prettier" ]]; then
            (cd "${PROJECT_DIR}" && npx prettier --write "${FILE_PATH}" 2>/dev/null) || true
        fi
        # Lint with feedback (only if eslint is installed locally in the project)
        if [[ -f "${PROJECT_DIR}/node_modules/.bin/eslint" ]]; then
            LINT_OUT="$(cd "${PROJECT_DIR}" && npx eslint "${FILE_PATH}" 2>&1)" || ERRORS="ESLint errors in $(basename "${FILE_PATH}"):\n${LINT_OUT}"
        fi
        # Typecheck (turbo cached, fast after first run)
        if [[ -z "${ERRORS}" && -f "${PROJECT_DIR}/package.json" ]]; then
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            source "$SCRIPT_DIR/lib/detect-stack.sh"
            if _has_npm_script "${PROJECT_DIR}/package.json" "typecheck"; then
                local_mgr="$(_detect_node_pkg_manager "${PROJECT_DIR}")"
                _has_cmd "$local_mgr" || local_mgr="npm"
                if _has_cmd "$local_mgr"; then
                    TC_OUT="$(cd "${PROJECT_DIR}" && $local_mgr run typecheck 2>&1)" || {
                        TC_ERRORS="$(echo "${TC_OUT}" | grep 'error TS' | head -10)"
                        ERRORS="TypeScript errors after editing $(basename "${FILE_PATH}"):\n${TC_ERRORS}"
                    }
                fi
            fi
        fi
        ;;
    json)
        # Format only, no lint
        if [[ -f "${PROJECT_DIR}/node_modules/.bin/prettier" ]]; then
            (cd "${PROJECT_DIR}" && npx prettier --write "${FILE_PATH}" 2>/dev/null) || true
        fi
        ;;
    cs)
        # Format
        command -v dotnet &>/dev/null && dotnet format whitespace --folder --include "${FILE_PATH}" 2>/dev/null || true
        # Build check with feedback
        if command -v dotnet &>/dev/null; then
            BUILD_OUT="$(dotnet build --no-restore -verbosity:quiet 2>&1)" || {
                BUILD_ERRORS="$(echo "${BUILD_OUT}" | grep -E 'error CS' | head -10)"
                ERRORS="Build errors after editing $(basename "${FILE_PATH}"):\n${BUILD_ERRORS}"
            }
        fi
        ;;
    rs)
        # Format
        command -v rustfmt &>/dev/null && rustfmt "${FILE_PATH}" 2>/dev/null || true
        # Check with feedback
        if [[ -f "${PROJECT_DIR}/Cargo.toml" ]]; then
            CHECK_OUT="$(cd "${PROJECT_DIR}" && cargo check 2>&1)" || {
                CHECK_ERRORS="$(echo "${CHECK_OUT}" | grep '^error' | head -10)"
                ERRORS="Cargo check errors after editing $(basename "${FILE_PATH}"):\n${CHECK_ERRORS}"
            }
        fi
        ;;
    go)
        # Format: prefer goimports (adds/removes imports), fall back to gofmt
        if command -v goimports &>/dev/null; then
            goimports -w "${FILE_PATH}" 2>/dev/null || true
        elif command -v gofmt &>/dev/null; then
            gofmt -w "${FILE_PATH}" 2>/dev/null || true
        fi
        # Vet (Go's build cache makes this fast after first run)
        if command -v go &>/dev/null && [[ -f "${PROJECT_DIR}/go.mod" ]]; then
            VET_OUT="$(cd "${PROJECT_DIR}" && go vet ./... 2>&1)" || {
                VET_ERRORS="$(echo "${VET_OUT}" | head -10)"
                ERRORS="go vet errors after editing $(basename "${FILE_PATH}"):\n${VET_ERRORS}"
            }
        fi
        ;;
    swift)
        # Format
        command -v swiftformat &>/dev/null && swiftformat "${FILE_PATH}" 2>/dev/null || true
        # Lint with feedback
        if command -v swiftlint &>/dev/null; then
            SL_OUT="$(swiftlint lint --path "${FILE_PATH}" --quiet 2>&1)" || {
                SL_ERRORS="$(echo "${SL_OUT}" | head -10)"
                ERRORS="SwiftLint errors in $(basename "${FILE_PATH}"):\n${SL_ERRORS}"
            }
        fi
        ;;
    java)
        # Format
        if command -v google-java-format &>/dev/null; then
            google-java-format --replace "${FILE_PATH}" 2>/dev/null || true
        fi
        # Build check (Gradle or Maven, whichever is present)
        if [[ -f "${PROJECT_DIR}/gradlew" ]]; then
            BUILD_OUT="$(cd "${PROJECT_DIR}" && ./gradlew compileJava 2>&1)" || {
                BUILD_ERRORS="$(echo "${BUILD_OUT}" | grep -E 'error:' | head -10)"
                ERRORS="Build errors after editing $(basename "${FILE_PATH}"):\n${BUILD_ERRORS}"
            }
        elif [[ -f "${PROJECT_DIR}/pom.xml" ]] && command -v mvn &>/dev/null; then
            BUILD_OUT="$(cd "${PROJECT_DIR}" && mvn compile -q 2>&1)" || {
                BUILD_ERRORS="$(echo "${BUILD_OUT}" | grep -E 'ERROR|error:' | head -10)"
                ERRORS="Build errors after editing $(basename "${FILE_PATH}"):\n${BUILD_ERRORS}"
            }
        fi
        ;;
    kt|kts)
        # Format
        if command -v ktlint &>/dev/null; then
            ktlint --format "${FILE_PATH}" 2>/dev/null || true
        fi
        # Build check via Gradle
        if [[ -f "${PROJECT_DIR}/gradlew" ]]; then
            BUILD_OUT="$(cd "${PROJECT_DIR}" && ./gradlew compileKotlin 2>&1)" || {
                BUILD_ERRORS="$(echo "${BUILD_OUT}" | grep -E 'error:' | head -10)"
                ERRORS="Build errors after editing $(basename "${FILE_PATH}"):\n${BUILD_ERRORS}"
            }
        fi
        ;;
    rb)
        # Format + lint (rubocop does both)
        if command -v rubocop &>/dev/null; then
            rubocop --autocorrect --force-exclusion "${FILE_PATH}" 2>/dev/null || true
            LINT_OUT="$(rubocop --format simple "${FILE_PATH}" 2>&1)" || {
                LINT_ERRORS="$(echo "${LINT_OUT}" | grep -E '^[^:]+:[0-9]+' | head -10)"
                ERRORS="RuboCop errors in $(basename "${FILE_PATH}"):\n${LINT_ERRORS}"
            }
        fi
        ;;
    php)
        # Format
        if [[ -f "${PROJECT_DIR}/vendor/bin/php-cs-fixer" ]]; then
            (cd "${PROJECT_DIR}" && ./vendor/bin/php-cs-fixer fix "${FILE_PATH}" --quiet 2>/dev/null) || true
        fi
        # Lint (syntax check, always available)
        if command -v php &>/dev/null; then
            LINT_OUT="$(php -l "${FILE_PATH}" 2>&1)" || {
                ERRORS="PHP syntax errors in $(basename "${FILE_PATH}"):\n${LINT_OUT}"
            }
        fi
        ;;
    dart)
        # Format
        if command -v dart &>/dev/null; then
            dart format "${FILE_PATH}" 2>/dev/null || true
        fi
        # Analyze with feedback
        if command -v dart &>/dev/null; then
            ANA_OUT="$(dart analyze "${FILE_PATH}" 2>&1)" || {
                ANA_ERRORS="$(echo "${ANA_OUT}" | grep -E 'error|warning' | head -10)"
                ERRORS="Dart analysis errors in $(basename "${FILE_PATH}"):\n${ANA_ERRORS}"
            }
        fi
        ;;
    ex|exs)
        # Format
        if command -v mix &>/dev/null && [[ -f "${PROJECT_DIR}/mix.exs" ]]; then
            (cd "${PROJECT_DIR}" && mix format "${FILE_PATH}" 2>/dev/null) || true
        fi
        # Compile check
        if command -v mix &>/dev/null && [[ -f "${PROJECT_DIR}/mix.exs" ]]; then
            COMP_OUT="$(cd "${PROJECT_DIR}" && mix compile --warnings-as-errors 2>&1)" || {
                COMP_ERRORS="$(echo "${COMP_OUT}" | grep -E 'error:' | head -10)"
                ERRORS="Elixir compile errors after editing $(basename "${FILE_PATH}"):\n${COMP_ERRORS}"
            }
        fi
        ;;
    c|cpp|cc|cxx|h|hpp)
        # Format
        if command -v clang-format &>/dev/null; then
            clang-format -i "${FILE_PATH}" 2>/dev/null || true
        fi
        # Lint
        if command -v cppcheck &>/dev/null; then
            CPP_OUT="$(cppcheck --enable=warning,style "${FILE_PATH}" 2>&1)" || true
            # cppcheck writes to stderr even on success, check for actual errors
            if echo "${CPP_OUT}" | grep -q 'error:'; then
                CPP_ERRORS="$(echo "${CPP_OUT}" | grep 'error:' | head -10)"
                ERRORS="cppcheck errors in $(basename "${FILE_PATH}"):\n${CPP_ERRORS}"
            fi
        fi
        ;;
esac

# Feed errors back to Claude for self-correction
if [[ -n "${ERRORS}" ]]; then
    printf '%s' "${ERRORS}" | jq -Rs '{"decision": "block", "reason": .}'
fi

exit 0
