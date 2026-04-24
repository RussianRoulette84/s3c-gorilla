#!/bin/sh
# swift-linter.sh — Generic Swift linter
#
# Checks:
#   - file length (warn > 200, err > 400)
#   - swift build (typecheck)                — skipped if no Package.swift
#   - swiftlint                              — skipped if not installed
#
# Usage:
#   swift-linter.sh [--no-build] [--no-lint] [--max=N] [--sweet=N] [DIR]
#
# Defaults:
#   DIR        current directory (package root or source tree)
#   --max      400
#   --sweet    200

DIR="."
RUN_BUILD=1
RUN_LINT=1
MAX_LINES=400
SWEET_LINES=200

for arg in "$@"; do
    case "$arg" in
        --no-build)  RUN_BUILD=0 ;;
        --no-lint)   RUN_LINT=0 ;;
        --max=*)     MAX_LINES="${arg#--max=}" ;;
        --sweet=*)   SWEET_LINES="${arg#--sweet=}" ;;
        -h|--help)   sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)          printf "unknown flag: %s\n" "$arg" >&2; exit 2 ;;
        *)           DIR="$arg" ;;
    esac
done

[ ! -d "$DIR" ] && { printf "not a directory: %s\n" "$DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

ERRORS=0
WARNINGS=0
ERROR_FILES=""

# ─── colors ───────────────────────────────────────────────────────────────────
_RED=$'\033[31m'; _YEL=$'\033[33m'; _GRN=$'\033[32m'; _CYN=$'\033[36m'
_BLD=$'\033[1m';  _DIM=$'\033[2m';  _R0=$'\033[0m'
_ORG=$'\033[38;5;208m'

err()  { printf "${_RED}${_BLD}[ERR]${_R0}  %s\n" "$*"; ERRORS=$((ERRORS+1)); }
warn() { printf "${_YEL}[WRN]${_R0}  %s\n"        "$*"; WARNINGS=$((WARNINGS+1)); }
ok()   { printf "${_GRN}[ OK ]${_R0} %s\n"        "$*"; }
info() { printf "${_DIM}[   ]  %s${_R0}\n"        "$*"; }
hdr()  { printf "\n${_CYN}${_BLD}-- %s --${_R0}\n" "$*"; }
rel()  { echo "${1#$DIR/}"; }
trim() { echo "$1" | tr -d ' \t'; }

# ─── collect .swift files (recursive, skip build/VCS dirs) ───────────────────
FILES_LIST="$(mktemp)"
trap 'rm -f "$FILES_LIST"' EXIT

find "$DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/.build' -o -path '*/build' -o -path '*/DerivedData' -o -path '*/Pods' \) -prune -o \
    -type f -name '*.swift' -print \
    > "$FILES_LIST" 2>/dev/null

# ─── file length ─────────────────────────────────────────────────────────────
run_length_checks() {
    hdr "file length (max ${MAX_LINES}, sweet-spot ${SWEET_LINES})"

    local found=0 any_issues=0
    local _tmp; _tmp="$(mktemp)"

    while IFS= read -r f; do
        [ -f "$f" ] || continue
        local lines; lines=$(trim "$(wc -l < "$f")")
        echo "$lines $f"
    done < "$FILES_LIST" | sort -rn > "$_tmp"

    while IFS=' ' read -r lines f; do
        [ -z "$f" ] && continue
        found=1
        local r; r="$(rel "$f")"
        if [ "$lines" -gt "$MAX_LINES" ]; then
            err "$r: $lines lines (max $MAX_LINES — split this file)"
            ERROR_FILES="${ERROR_FILES}  too-long: $r (${lines}L)\n"
            any_issues=1
        elif [ "$lines" -gt "$SWEET_LINES" ]; then
            warn "$r: $lines lines (sweet-spot $SWEET_LINES)"
            any_issues=1
        fi
    done < "$_tmp"
    rm -f "$_tmp"

    [ "$found" -eq 0 ] && info "no files"
    [ "$any_issues" -eq 0 ] && [ "$found" -gt 0 ] && ok "all files within size limits"
}

# ─── swift build (typecheck) ─────────────────────────────────────────────────
run_swift_build() {
    hdr "swift build (typecheck)"

    if [ "$(uname -s)" != "Darwin" ]; then
        info "skipped — swift build requires macOS"
        return
    fi
    if ! command -v swift >/dev/null 2>&1; then
        info "skipped — swift not found"
        return
    fi
    if [ ! -f "$DIR/Package.swift" ]; then
        info "skipped — no Package.swift in $DIR"
        return
    fi

    local tc_out tc_exit tc_warn=0 tc_err=0
    tc_out="$(cd "$DIR" && swift build 2>&1)"
    tc_exit=$?
    while IFS= read -r line; do
        case "$line" in
            *": error:"*)   err "swift: $line"; tc_err=1
                            ERROR_FILES="${ERROR_FILES}  swift-error\n" ;;
            *": warning:"*) warn "swift: $line"; tc_warn=1 ;;
        esac
    done <<EOF
$tc_out
EOF
    if [ "$tc_exit" -ne 0 ] && [ "$tc_err" -eq 0 ]; then
        err "swift build failed (exit $tc_exit)"
        ERROR_FILES="${ERROR_FILES}  swift-build\n"
    elif [ "$tc_warn" -eq 0 ] && [ "$tc_err" -eq 0 ]; then
        ok "swift build — clean"
    fi
}

# ─── swiftlint ───────────────────────────────────────────────────────────────
run_swiftlint() {
    hdr "swiftlint"

    if [ "$(uname -s)" != "Darwin" ]; then
        info "skipped — swiftlint requires macOS"
        return
    fi
    if ! command -v swiftlint >/dev/null 2>&1; then
        info "skipped — swiftlint not found (brew install swiftlint)"
        return
    fi

    local lint_out had_warn=0 had_err=0
    lint_out="$(cd "$DIR" && swiftlint lint --quiet 2>&1)"
    while IFS= read -r line; do
        case "$line" in
            *": error:"*)   err "swiftlint: $line"; had_err=1
                            ERROR_FILES="${ERROR_FILES}  swiftlint: $line\n" ;;
            *": warning:"*) warn "swiftlint: $line"; had_warn=1 ;;
        esac
    done <<EOF
$lint_out
EOF
    [ "$had_warn" -eq 0 ] && [ "$had_err" -eq 0 ] && ok "swiftlint — clean"
}

# ─── main ─────────────────────────────────────────────────────────────────────
printf "${_ORG}${_BLD}=== Swift Linter ===${_R0}  ${_DIM}%s${_R0}\n" "$DIR"

run_length_checks
[ "$RUN_BUILD" -eq 1 ] && run_swift_build
[ "$RUN_LINT" -eq 1 ]  && run_swiftlint

echo ""
if [ "$ERRORS" -gt 0 ]; then
    printf "${_RED}${_BLD}=== %d error(s)${_R0}, ${_YEL}%d warning(s)${_R0} — files to fix:\n" "$ERRORS" "$WARNINGS"
    printf '%b' "$ERROR_FILES"
elif [ "$WARNINGS" -gt 0 ]; then
    printf "${_GRN}${_BLD}=== 0 errors${_R0}, ${_YEL}%d warning(s)${_R0}\n" "$WARNINGS"
else
    printf "${_GRN}${_BLD}=== clean ✓${_R0}\n"
fi
[ "$ERRORS" -eq 0 ]
