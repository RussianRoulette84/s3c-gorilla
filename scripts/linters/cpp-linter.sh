#!/bin/sh
# cpp-linter.sh — Generic C / C++ linter
#
# Checks:
#   - clang-format (dry-run)
#   - cppcheck     (optional; slow)
#   - file length  (warn > 200, err > 400)
#
# Usage:
#   cpp-linter.sh [--cppcheck] [--max=N] [--sweet=N] [DIR]
#
# Defaults:
#   DIR        current directory
#   --max      400   (error threshold)
#   --sweet    200   (warning threshold)

DIR="."
RUN_CPPCHECK=0
MAX_LINES=400
SWEET_LINES=200

for arg in "$@"; do
    case "$arg" in
        --cppcheck)   RUN_CPPCHECK=1 ;;
        --max=*)      MAX_LINES="${arg#--max=}" ;;
        --sweet=*)    SWEET_LINES="${arg#--sweet=}" ;;
        -h|--help)    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)           printf "unknown flag: %s\n" "$arg" >&2; exit 2 ;;
        *)            DIR="$arg" ;;
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

# ─── collect source files (recursive, skip build/VCS dirs) ───────────────────
FILES_LIST="$(mktemp)"
trap 'rm -f "$FILES_LIST"' EXIT

find "$DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/build' -o -path '*/dist' -o -path '*/.build' -o -path '*/target' -o -path '*/DerivedData' \) -prune -o \
    -type f \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.h' -o -name '*.hpp' -o -name '*.hxx' \) -print \
    > "$FILES_LIST" 2>/dev/null

# ─── clang-format ────────────────────────────────────────────────────────────
run_clang_format() {
    hdr "clang-format"
    if ! command -v clang-format >/dev/null 2>&1; then
        info "skipped — clang-format not available (brew install clang-format)"
        return
    fi

    local found=0 any_issues=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        found=1
        local r; r="$(rel "$f")"
        local lines; lines=$(trim "$(wc -l < "$f")")
        local violations; violations="$(clang-format --dry-run "$f" 2>&1)"
        if [ -n "$violations" ]; then
            warn "$r [${lines}L]: clang-format violations (fix: clang-format -i $r)"
            echo "$violations" | head -6 | while IFS= read -r line; do info "  $line"; done
            any_issues=1
        fi
    done < "$FILES_LIST"
    [ "$found" -eq 0 ] && info "no files"
    [ "$any_issues" -eq 0 ] && [ "$found" -gt 0 ] && ok "no clang-format violations"
}

# ─── cppcheck ────────────────────────────────────────────────────────────────
run_cppcheck() {
    hdr "cppcheck"
    if ! command -v cppcheck >/dev/null 2>&1; then
        info "skipped — cppcheck not available (brew install cppcheck)"
        return
    fi

    local found=0 any_issues=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        case "$f" in *.c|*.cc|*.cpp|*.cxx) ;; *) continue ;; esac
        found=1
        local r; r="$(rel "$f")"
        local out
        out="$(cppcheck \
            --enable=warning \
            --suppress=missingInclude \
            --suppress=missingIncludeSystem \
            --suppress=unusedFunction \
            --error-exitcode=0 \
            --quiet \
            "$f" 2>&1)"
        if [ -n "$out" ]; then
            warn "$r: cppcheck issues"
            echo "$out" | while IFS= read -r line; do info "  $line"; done
            any_issues=1
        fi
    done < "$FILES_LIST"
    [ "$found" -eq 0 ] && info "no files"
    [ "$any_issues" -eq 0 ] && [ "$found" -gt 0 ] && ok "no cppcheck issues"
}

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

# ─── main ─────────────────────────────────────────────────────────────────────
printf "${_ORG}${_BLD}=== C/C++ Linter ===${_R0}  ${_DIM}%s${_R0}\n" "$DIR"

run_clang_format
[ "$RUN_CPPCHECK" -eq 1 ] && run_cppcheck
run_length_checks

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
