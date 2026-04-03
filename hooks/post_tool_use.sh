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
#   .js .ts .jsx .tsx .json  → prettier --write + eslint (if config exists)
#   .cs                      → dotnet format whitespace
#   .rs                      → rustfmt + cargo check
#   .go                      → goimports or gofmt
#   .swift                   → swiftformat

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
         ! -f "${PROJECT_DIR}/Package.swift" ]]; do
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
        # No per-file lint: go vet ./... is too slow per-edit, handled by verify-stop.sh
        ;;
    swift)
        # Format
        command -v swiftformat &>/dev/null && swiftformat "${FILE_PATH}" 2>/dev/null || true
        # No per-file swiftlint: runs at stop time via verify-stop.sh
        ;;
esac

# Feed errors back to Claude for self-correction
if [[ -n "${ERRORS}" ]]; then
    printf '%s' "${ERRORS}" | jq -Rs '{"decision": "block", "reason": .}'
fi

exit 0
