#!/usr/bin/env zsh
############################################################
# PHP Lint Script
#
# Usage:
#   ./scripts/linters/php-linter.sh [options]
#
# Options:
#   -h, --help           Show this help and exit
#   -e, --errors-only    Only print errors (suppress OK lines)
#   -r, --report         Only print the summary (no per-file output)
#   -d, --dir <dir>      Scan a custom directory (can be repeated)
#   -p, --php <phpbin>   Use a custom PHP binary (default: php)
#   -l, --limit <N>      Limit error output to first N errors
#   -c, --color-off      Disable color output
#
# Env:
#   SCAN_DIRS   space-separated list of dirs to scan (default: src/backend)
#   PHP_BIN     override the PHP binary (default: php)
############################################################

set -euo pipefail

PHP_BIN=${PHP_BIN:-php}

# Scan dirs: -d flag > $SCAN_DIRS env > default
typeset -a DIRS
DIRS=()
# parse -d / --dir (leave other flag parsing intact below if expanded later)
args=("$@")
for ((i=1; i<=${#args[@]}; i++)); do
  case "${args[$i]}" in
    -d|--dir) ((i++)); DIRS+=("${args[$i]}") ;;
  esac
done
if (( ${#DIRS[@]} == 0 )); then
  if [[ -n "${SCAN_DIRS:-}" ]]; then
    DIRS=(${=SCAN_DIRS})
  else
    DIRS=(src/backend)
  fi
fi

# Generic excludes (vendor/build/VCS). Override by editing or via env EXTRA_EXCLUDE.
EXCLUDE=(
  "*/node_modules/*"
  "*/vendor/*"
  "*/dist/*"
  "*/build/*"
  "*/out/*"
  "*/tmp/*"
  "*/cache/*"
  "*/.git/*"
  "*/.svn/*"
  "*/.hg/*"
  "*/.idea/*"
  "*/.vscode/*"
  "*/storage/*"
  "*/logs/*"
  "*/database/migrations/*"
)
if [[ -n "${EXTRA_EXCLUDE:-}" ]]; then
  for p in ${=EXTRA_EXCLUDE}; do EXCLUDE+=("$p"); done
fi

FIND_CMD=(find "${DIRS[@]}")
for p in "${EXCLUDE[@]}"; do
  FIND_CMD+=( -path "$p" -prune -o )
done
FIND_CMD+=( -type f -name "*.php" -print0 )

# Colors
NC=$'\033[0m'; PURPLE=$'\033[1;35m'; PINK=$'\033[38;5;213m'
BLUE=$'\033[1;34m'; CYAN=$'\033[1;36m'; BOLD=$'\033[1m'
RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'
MAGENTA=$'\033[1;35m'; RESET=$'\033[0m'; WHITE=$'\033[1;37m'
if [[ "${COLOR:-1}" -eq 0 ]]; then
  NC=''; PURPLE=''; PINK=''; BLUE=''; CYAN=''; BOLD=''
  RED=''; GREEN=''; YELLOW=''; MAGENTA=''; RESET=''; WHITE=''
fi

printf "\n"
printf "%s  ____  %s_   _ %s____%s\n" "$PURPLE" "$PINK" "$BLUE" "$NC"
printf "%s |  _ \\%s| | | |%s  _ \\%s\n" "$PINK" "$BLUE" "$CYAN" "$NC"
printf "%s | |_) |%s |_| |%s |_) |%s\n" "$BLUE" "$CYAN" "$MAGENTA" "$NC"
printf "%s |  __/%s|  _  |%s  __/%s\n" "$CYAN" "$MAGENTA" "$PURPLE" "$NC"
printf "%s |_|   %s|_| |_|%s_|   %s\n" "$MAGENTA" "$PURPLE" "$PINK" "$NC"
printf "  %s%s   - LINTER - %s\n" "$BOLD" "$CYAN" "$NC"
printf "%s------------------------------------------------------------%s\n" "$PURPLE" "$NC"
printf "%sPHP LINTER:%s Scanning: %s\n" "$BOLD" "$NC" "${DIRS[*]}"
printf "%s------------------------------------------------------------%s\n\n" "$PURPLE" "$NC"

total=0; ok=0; err=0
FILES=( "${(@f)$( "${FIND_CMD[@]}" | tr '\0' '\n' )}" )
NUM_FILES=${#FILES[@]}

if (( NUM_FILES == 0 )); then
  printf "%sNo .php files found under: %s%s\n" "$YELLOW" "${DIRS[*]}" "$RESET"
  exit 0
fi

done_count=0
last_progress=""
for file in "${FILES[@]}"; do
  [[ -z "$file" ]] && continue
  printf "\r%*s\r" $(tput cols 2>/dev/null || echo 80) ""
  done_count=$((done_count+1))
  total=$((total+1))
  percent=$(( 100 * done_count / NUM_FILES ))
  printf "%sErrors:%s%s%d%s - %d/%d (%d%%) %s%s%s" \
    "$BOLD" "$RESET" "$RED" "$err" "$RESET" \
    "$done_count" "$NUM_FILES" "$percent" \
    "$CYAN" "$file" "$RESET"
  out=$($PHP_BIN -l "$file" 2>&1) || true
  if echo "$out" | grep -q "No syntax errors detected"; then
    ok=$((ok+1))
  else
    err=$((err+1))
    printf "\r%*s\r" $(tput cols 2>/dev/null || echo 80) ""
    printf "%s[ERR]%s %s%s%s: %s\n" "$RED" "$RESET" "$YELLOW" "$file" "$RESET" "$(echo "$out" | head -n1)" 1>&2
  fi
done
printf "\r%*s\r\n" $(tput cols 2>/dev/null || echo 80) ""

printf "\n%s==============================%s\n" "$PURPLE" "$RESET"
printf "%s   PHP LINT SUMMARY   %s\n" "$CYAN" "$RESET"
printf "%s==============================%s\n" "$PURPLE" "$RESET"
printf "Total: %s%d%s  OK: %s%d%s  Errors: %s%d%s\n" \
  "$WHITE" "$total" "$RESET" "$GREEN" "$ok" "$RESET" \
  "$( (( err == 0 )) && echo "$WHITE" || echo "$RED" )" "$err" "$RESET"
printf "%s==============================%s\n" "$PURPLE" "$RESET"

exit $(( err > 0 ? 1 : 0 ))
