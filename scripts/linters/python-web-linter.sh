#!/usr/bin/env zsh

# ------------------------------------------------------------------------------
# Python-Web Linter Script (python-web-linter.sh)
#
# Description:
#   Linter for JavaScript and HTML files (despite the filename — kept for
#   skeleton compatibility; swap to a real Python linter if needed).
#   Features colorized output, progress bar, and error summary.
#
# Env:
#   SCAN_DIR    directory to scan (default: src/frontend)
#
# Usage:
# ./scripts/linters/python-web-linter.sh [options]
#
# Options:
#   --help, -h        Show this help and exit
#   --fast            Only check JS syntax (skip ESLint)
#   --html-only       Only lint HTML files
#   --js-only         Only lint JS files
#   --no-color        Disable color output
#   --summary-only    Only print summary, not error details
#   --no-custom       Disable custom heuristics (unclosed tags/malformed HTML)
# ------------------------------------------------------------------------------

# Parse flags
SHOW_HELP=0
FAST_MODE=0
HTML_ONLY=0
JS_ONLY=0
NO_COLOR=0
SUMMARY_ONLY=0
DEBUG=0
NO_CUSTOM=0
NO_UNCLOSED=0

for arg in "$@"; do
  case $arg in
    --help|-h) SHOW_HELP=1 ;;
    --fast) FAST_MODE=1 ;;
    --html-only) HTML_ONLY=1 ;;
    --js-only) JS_ONLY=1 ;;
    --no-color) NO_COLOR=1 ;;
    --summary-only) SUMMARY_ONLY=1 ;;
    --debug) DEBUG=1 ;;
    --no-custom) NO_CUSTOM=1 ;;
  esac
done

if (( SHOW_HELP )); then
  sed -n '/^# ---/,/^# ------------------------------------------------------------------------------/p' "$0" | sed 's/^# //;s/^#//'
  exit 0
fi

# Color definitions
NC=$'\033[0m'
PURPLE=$'\033[1;35m'
PINK=$'\033[38;5;213m'
BLUE=$'\033[1;34m'
CYAN=$'\033[1;36m'
BOLD=$'\033[1m'
RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RESET=$'\033[0m'
WHITE=$'\033[1;37m'

if (( NO_COLOR )); then
  NC=""; PURPLE=""; PINK=""; BLUE=""; CYAN=""; BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""; WHITE=""
fi

if ! command -v eslint >/dev/null 2>&1 && (( ! FAST_MODE )); then
  echo "${YELLOW}[WARN]${RESET} ${WHITE}ESLint is not installed. Only basic JS syntax errors will be detected via node -c.${RESET}" >&2
  FAST_MODE=1
fi

printf "\n"
printf "%s   ___   _  _________  ____   ___   ___ %s\n" "$PURPLE" "$NC"
printf "%s  / _ | / |/ / ___/ / / / /  / _ | / _ \%s\n" "$PINK" "$NC"
printf "%s / __ |/    / (_ / /_/ / /__/ __ |/ , _/%s\n" "$BLUE" "$NC"
printf "%s/_/ |_/_/|_/\___/\____/____/_/ |_/_/|_| %s\n" "$CYAN" "$NC"
printf "  %s%s            - LINTER - %s\n" "$BOLD" "$CYAN" "$NC"
printf "%s------------------------------------------------------------%s\n" "$PURPLE" "$NC"
printf "%sLINTER:%s Scans for JS and HTML errors\n" "$BOLD" "$NC"
printf "%s------------------------------------------------------------%s\n" "$PURPLE" "$NC"

# Directory to scan (override with SCAN_DIR env)
SCAN_DIR="${SCAN_DIR:-src/frontend}"

# Exclude patterns
EXCLUDE=(
  "*/node_modules/*"
  "*/dist/*"
  "*/.venv/*"
  "*/__pycache__/*"
  "*/img/*"
  "*/avatars/*"
  "*/modules/*"
)

# Build find command
FIND_CMD=(find "$SCAN_DIR")
for p in "${EXCLUDE[@]}"; do
  FIND_CMD+=( -path "$p" -prune -o )
done

# Default: check both JS and HTML files (unless --html-only or --js-only is specified)
if (( HTML_ONLY )); then
  FIND_CMD+=( \( -name "*.html" \) -type f -print0 )
elif (( JS_ONLY )); then
  FIND_CMD+=( \( -name "*.js" \) -type f -print0 )
else
  # Default behavior: check both JS and HTML files
  FIND_CMD+=( \( -name "*.js" -o -name "*.html" \) -type f -print0 )
fi

# Gather files
FILES=( "${(@f)$( "${FIND_CMD[@]}" | tr '\0' '\n' )}" )
NUM_FILES=${#FILES[@]}
done_count=0
total=0
ok=0
err=0
js_err=0
html_err=0
js_files_count=0
html_files_count=0

# Handle case where no files are found
if (( NUM_FILES == 0 )); then
  printf "\n%sNo files found to lint in %s.%s\n" "$BOLD" "$SCAN_DIR" "$RESET"
  exit 0
fi

ERRORS=()
for file in "${FILES[@]}"; do
  printf "\r%*s\r" $(tput cols) ""
  done_count=$((done_count+1))
  total=$((total+1))
  
  display_file_short=$(echo "$file" | awk '{if(length($0)>40) print substr($0,1,18) "..." substr($0,length($0)-18+1,18); else print $0;}')
  
  printf "%sErrors:%s%s%d%s JS:%s%d%s HTML:%s%d%s - %d/%d Processing: %s%s%s" \
    "$WHITE" "$RESET" "$RED" "$err" "$RESET" \
    "$RED" "$js_err" "$RESET" \
    "$RED" "$html_err" "$RESET" \
    "$done_count" "$NUM_FILES" \
    "$CYAN" "$display_file_short" "$RESET"

  if [[ "$file" == *.js ]]; then
    js_files_count=$((js_files_count+1))
    if (( FAST_MODE )); then
      out=$(node -c "$file" 2>&1)
      node_status=$?
      if [[ $node_status -ne 0 ]]; then
        ERRORS+=("$file\n$out")
        err=$((err+1))
        js_err=$((js_err+1))
      else
        ok=$((ok+1))
      fi
    else
      out=$(eslint --no-error-on-unmatched-pattern --format stylish "$file" 2>&1)
      eslint_status=$?
      # Keep actionable errors
      actionable=$(echo "$out" | grep -E '^\s*[0-9]+:[0-9]+\s+error')
      if [[ $eslint_status -ne 0 && -n "$actionable" ]]; then
        ERRORS+=("$file\n$actionable")
        err=$((err+1))
        js_err=$((js_err+1))
      else
        ok=$((ok+1))
      fi
    fi
  elif [[ "$file" == *.html ]]; then
    html_files_count=$((html_files_count+1))
    details=""
    if (( ! NO_CUSTOM )); then
      # Basic unclosed tag heuristic
      unclosed_tags=$(awk 'BEGIN{maxlook=6}
      { lines[NR]=$0 }
      END{
        for(i=1;i<=NR;i++){
          if(lines[i] ~ /</ && lines[i] !~ />/){
            found=0
            for(j=i+1;j<=i+maxlook && j<=NR;j++){
              if(lines[j] ~ />/){ found=1; break }
              if(lines[j] ~ /</) break
            }
            if(!found) print i ":" lines[i]
          }
        }
      }' "$file" || true)

      if [[ -n "$unclosed_tags" ]]; then
        while IFS= read -r cline; do
          cnum=$(echo "$cline" | cut -d: -f1 | grep -oE '[0-9]+' | head -n1 || true)
          [[ -z "$cnum" ]] && continue
          ctext=$(echo "$cline" | cut -d: -f2- | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
          # Skip obvious CSS or common multi-line attributes
          if echo "$ctext" | grep -qE '=|{|}|\[|\]'; then continue; fi
          details+="error ${cnum}: possible unclosed tag or malformed line\\n    ${ctext}\\n"
        done <<< "$unclosed_tags"
      fi
    fi

    if [[ -n "$details" ]]; then
      ERRORS+=("$file\n$details")
      err=$((err+1))
      html_err=$((html_err+1))
    else
      ok=$((ok+1))
    fi
  fi
done

printf "\r%*s\r\n" $(tput cols) ""
printf "\n%s%s==============================%s\n" "$BOLD" "$PURPLE" "$RESET"
printf "%s%s   LINT SUMMARY   %s\n" "$BOLD" "$CYAN" "$RESET"
printf "%s%s==============================%s\n" "$BOLD" "$PURPLE" "$RESET"
printf "%sTotal files scanned:%s %s%d%s\n" "$BOLD" "$RESET" "$WHITE" "$total" "$RESET"
printf "%sJS files scanned:%s %s%d%s\n" "$BOLD" "$RESET" "$WHITE" "$js_files_count" "$RESET"
printf "%sHTML files scanned:%s %s%d%s\n" "$BOLD" "$RESET" "$WHITE" "$html_files_count" "$RESET"
printf "%sOK:%s %s%d%s\n" "$BOLD" "$RESET" "$GREEN" "$ok" "$RESET"
printf "%sJS Errors:%s %s%d%s\n" "$BOLD" "$RESET" "$RED" "$js_err" "$RESET"
printf "%sHTML Errors:%s %s%d%s\n" "$BOLD" "$RESET" "$RED" "$html_err" "$RESET"

if (( err > 0 && ! SUMMARY_ONLY )); then
  printf "\n%s%sERROR DETAILS:%s\n" "$BOLD" "$RED" "$RESET"
  for e in "${ERRORS[@]}"; do
    printf "%s%s%s\n" "$YELLOW" "$(echo "$e" | head -n1)" "$RESET"
    echo "$e" | tail -n +2 | sed 's/^/    /'
    printf "\n"
  done
fi
printf "%s==============================%s\n" "$PURPLE" "$RESET"

exit $(( err > 0 ? 1 : 0 ))
