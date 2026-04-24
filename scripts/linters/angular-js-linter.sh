#!/usr/bin/env zsh

# ------------------------------------------------------------------------------
# Web Linter Script (web-linter.sh)
#
# Description:
#   Robust linter for JavaScript and HTML files. Includes optional heuristics
#   useful for AngularJS 1.x templates (attribute-without-value, commented-out
#   directives, unclosed tags). Features colorized output, progress bar, and
#   error summary.
#
# Env:
#   SCAN_DIR    directory to scan (default: src/frontend)
#
# Usage:
# ./scripts/linters/web-linter.sh [options]
#
# Options:
#   --help, -h        Show this help and exit
#   --fast            Only check JS syntax (skip ESLint/HTMLHint)
#   --html-only       Only lint HTML files
#   --js-only         Only lint JS files
#   --no-color        Disable color output
#   --summary-only    Only print summary, not error details
#   --no-custom       Disable custom heuristics (attribute/unclosed/comment checks)
#   --no-unclosed     Disable the 'unclosed tag' heuristic only
#
# Example:
#   ./angular_linter.sh --fast --no-color
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
# Disable the 'unclosed tag' heuristic by default because it is noisy in
# multi-line Angular templates. Use --no-unclosed to explicitly disable it
# (the flag remains for backwards compatibility).
NO_UNCLOSED=1
# By default, don't report commented-out tag heuristics (very noisy in templates).
# Use --show-commented to enable them if you want to inspect disabled directives.
NO_COMMENTED=1
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
    --no-unclosed) NO_UNCLOSED=1 ;;
  --show-commented) NO_COMMENTED=0 ;;
  esac
done

if (( SHOW_HELP )); then
  sed -n '/^# ---/,/^# ------------------------------------------------------------------------------/p' "$0" | sed 's/^# //;s/^#//'
  exit 0
fi

# Color definitions (same as php_linterererererer.sh)

if ! command -v eslint >/dev/null 2>&1; then
  echo "\033[1;33m[WARN]\033[0m \033[1;37mESLint is not installed. Only basic JS syntax errors will be detected.\033[0m" >&2
  echo "\033[1;37mFor best results, install ESLint and configure it for your AngularJS/JS codebase:\033[0m" >&2
  echo "\033[1;36mnpm install -g eslint\033[0m" >&2
  echo "\033[1;37mOr see: https://eslint.org/docs/latest/user-guide/getting-started\033[0m" >&2
  echo "\033[1;37mYou can use the Airbnb or angular-eslint config for AngularJS projects.\033[0m" >&2
  echo "" >&2
fi

# We'll use lint-staged (prefer local binary) for HTML linting; remove legacy htmlhint usage.
HAVE_LINT_STAGED=0
if [[ -x "./node_modules/.bin/lint-staged" ]]; then
  HAVE_LINT_STAGED=1
elif command -v npm >/dev/null 2>&1 && npm bin >/dev/null 2>&1 && [[ -x "$(npm bin)/lint-staged" ]]; then
  HAVE_LINT_STAGED=1
elif command -v npx >/dev/null 2>&1 || command -v npm >/dev/null 2>&1; then
  HAVE_LINT_STAGED=1
else
  echo "${YELLOW}[WARN]${RESET} lint-staged not available; HTML checks will fall back to heuristics only. Install lint-staged (npm i -D lint-staged) or ensure npx is available." >&2
fi

set -uo pipefail

# Color definitions (same as php_linterer.sh)

NC=$'\033[0m'
PURPLE=$'\033[1;35m'
PINK=$'\033[38;5;213m'
MAGENTA=$'\033[1;35m'
BLUE=$'\033[1;34m'
CYAN=$'\033[1;36m'
BOLD=$'\033[1m'
RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RESET=$'\033[0m'
WHITE=$'\033[1;37m'

if (( NO_COLOR )); then
  NC=""; PURPLE=""; PINK=""; MAGENTA=""; BLUE=""; CYAN=""; BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""; WHITE=""
fi


printf "\n"
printf "%s   ___   _  _________  ____   ___   ___ %s\n" "$PURPLE" "$NC"
printf "%s  / _ | / |/ / ___/ / / / /  / _ | / _ \%s\n" "$PINK" "$NC"
printf "%s / __ |/    / (_ / /_/ / /__/ __ |/ , _/%s\n" "$BLUE" "$NC"
printf "%s/_/ |_/_/|_/\___/\____/____/_/ |_/_/|_| %s\n" "$CYAN" "$NC"
printf "%s                                         %s\n" "$MAGENTA" "$NC"
printf "  %s%s            - LINTER - %s\n" "$BOLD" "$CYAN" "$NC"
printf "%s------------------------------------------------------------%s\n" "$PURPLE" "$NC"
SCAN_DIR="${SCAN_DIR:-src/frontend}"
printf "%sWEB LINTER:%s Scanning: %s%s%s\n" "$BOLD" "$NC" "$CYAN" "$SCAN_DIR" "$NC"
printf "%s------------------------------------------------------------%s\n\n" "$PURPLE" "$NC"


# Exclude patterns (relative to $SCAN_DIR)
EXCLUDE=(
  "./node_modules"
  "./.tmp"
  "./bower_components"
  "./src/compiled-tpl"
  "./fonts"
  "./icon"
  "./img"
  "./static"
  "./test"
  "./src/patch/ckeditor"
  "./src/lib"
  # Exclude common config/build/test files in root
  "./webpack.config.js"
  "./*.config.js"
  "./*.conf.js"
  "./karma.conf.js"
  "./protractor.conf.js"
  "./gulpfile.js"
  "./Gruntfile.js"
  "./rollup.config.js"
  "./vite.config.js"
  "./jest.config.js"
  "./test-setup.js"
)

# Build find command for .js and .html files
# Build find command for .js and .html files, respecting flags
FIND_CMD=(find "$SCAN_DIR")
for p in "${EXCLUDE[@]}"; do
  FIND_CMD+=( -path "$p" -prune -o )
done
if (( HTML_ONLY )); then
  FIND_CMD+=( \( -name "*.html" \) -type f -print0 )
elif (( JS_ONLY )); then
  FIND_CMD+=( \( -name "*.js" \) -type f -print0 )
else
  FIND_CMD+=( \( -name "*.js" -o -name "*.html" \) -type f -print0 )
fi

#
# How to distinguish jQuery, AngularJS, and plain JS?
# - jQuery: Look for usage of $(), $.fn, or require/import 'jquery'.
# - AngularJS: Look for angular.module, angular.*, or require/import 'angular'.
# - Plain JS: No framework-specific patterns above.
#
# This script currently lints all .js files equally. For framework-specific linting, you could scan file contents for these patterns and report them, or run different ESLint configs per type (advanced).

# Gather all files

FILES=( "${(@f)$( "${FIND_CMD[@]}" | tr '\0' '\n' )}" )
NUM_FILES=${#FILES[@]}
done_count=0
last_progress=""
total=0
ok=0

err=0
js_err=0
html_err=0

# Handle case where no files are found
if (( NUM_FILES == 0 )); then
  printf "\n%s%s==============================%s\n" "$BOLD" "$PURPLE" "$RESET"
  printf "%s%s   ANGULAR LINT SUMMARY   %s\n" "$BOLD" "$CYAN" "$RESET"
  printf "%s%s==============================%s\n" "$BOLD" "$PURPLE" "$RESET"
  printf "%sNo files found to lint.%s\n" "$BOLD" "$RED" "$RESET"
  printf "%s==============================%s\n" "$PURPLE" "$RESET"
  exit 0
fi


# Linting logic: collect errors, suppress 'quotes' rule, print summary at end
ERRORS=()
for file in "${FILES[@]}"; do
  printf "\r%*s\r" $(tput cols) ""
  done_count=$((done_count+1))
  total=$((total+1))
  percent=$(( 100 * done_count / NUM_FILES ))
  # Truncate filename to 40 chars for display
  display_file="$file"
  display_file_short=$(echo "$display_file" | awk '{if(length($0)>40) print substr($0,1,18) "..." substr($0,length($0)-18+1,18); else print $0;}')
  # Compact, robust progress line (no dynamic width math). Show filename and restore original error colors.
  # Format: Errors:5 JS:3 HTML:2 - 7/263 Processing: ./path
  printf "%sErrors:%s%s%d%s JS:%s%d%s HTML:%s%d%s - %d/%d Processing: %s%s%s" \
    "$WHITE" "$RESET" "$RED" "$err" "$RESET" \
    "$RED" "$js_err" "$RESET" \
    "$RED" "$html_err" "$RESET" \
    "$done_count" "$NUM_FILES" \
    "$CYAN" "$display_file_short" "$RESET"
  # Lint logic: use eslint for .js, htmlhint for .html
  if [[ "$file" == *.js ]]; then
    out=$(eslint --no-error-on-unmatched-pattern --format stylish "$file" 2>&1)
    eslint_status=$?
    # Filter out 'quotes', 'is not defined', 'is defined but never used', 'was used before it was defined', and ESLint summary lines
  filtered=$(echo "$out" | grep -Ev '\bquotes\b|is not defined|is defined but never used|was used before it was defined|✖ [0-9]+ problems|[0-9]+ errors? and [0-9]+ warnings? potentially fixable')
  # Only keep lines that look like real ESLint errors (e.g., '  111:17  error ...')
  actionable=$(echo "$filtered" | grep -E '^\s*[0-9]+:[0-9]+\s+error')
    # Only add to summary if actionable errors remain after filtering
    if [[ $eslint_status -ne 0 && -n "$actionable" ]]; then
      ERRORS+=("$file\n$actionable")
      err=$((err+1))
      js_err=$((js_err+1))
    else
      ok=$((ok+1))
    fi
  elif [[ "$file" == *.html ]]; then
    out=""
    # Run lint-staged for this single HTML file. Prefer local node_modules binary,
    # then npm exec, then npx. Capture output for parsing below. If lint-staged is
    # unavailable fall back to heuristics already implemented in this script.
    if [[ -x "./node_modules/.bin/lint-staged" ]]; then
      out=$(./node_modules/.bin/lint-staged --files "$file" 2>&1) || true
    elif command -v npm >/dev/null 2>&1; then
      out=$(npm exec --no-install --silent -- lint-staged --files "$file" 2>&1) || true
    elif command -v npx >/dev/null 2>&1; then
      out=$(npx --no-install lint-staged --files "$file" 2>&1) || true
    else
      out=""
    fi
    # Collect actionable htmlhint output. Some htmlhint versions don't include the word 'error',
    # so treat any non-empty output from htmlhint as actionable. If htmlhint isn't present,
    # out will be empty and we only rely on our custom heuristics.
    actionable_lines=$(printf '%s' "$out" | sed -E '/^\s*$/d' || true)
    if (( DEBUG )); then
      printf "\n[DEBUG] File: %s\n" "$file"
      printf "[DEBUG] HAVE_HTMLHINT=%d\n" "$HAVE_HTMLHINT"
      printf "[DEBUG] htmlhint output (first 5 lines):\n"
      printf '%s\n' "$out" | sed -n '1,5p' | sed 's/^/    /'
      printf "[DEBUG] actionable_lines (first 5):\n"
      printf '%s\n' "$actionable_lines" | sed -n '1,5p' | sed 's/^/    /'
    fi
    # Custom AngularJS template checks (collect per-pattern with reasons)
  if (( NO_CUSTOM )); then
    custom_angular_errors1=""
    custom_angular_errors2=""
    custom_angular_errors3=""
    custom_angular_comments=""
    custom_element_tags=""
  else
    custom_angular_errors1=$(grep -nE '<[a-zA-Z0-9\\-]+[[:space:]]+[^>]*[a-zA-Z0-9_\\-]+[[:space:]]+>' "$file" | grep -Ev '="|\\{\\{' || true)
    custom_angular_errors2=$(grep -nE '<[a-zA-Z0-9\\-]+[[:space:]]+[^>]*[a-zA-Z0-9_\\-]{5,}[^[:space:]=]' "$file" | grep -Ev 'ng-|data-|class|id|style|src|href|alt|title|type|name|value|for|width|height|placeholder|disabled|checked|selected|readonly|multiple|required|pattern|step|max|min|onclick|onchange|oninput|onblur|onfocus|tabindex|role|aria-' || true)
    custom_angular_errors3=$(grep -nE '^[^<]*[a-zA-Z0-9_\\-]+[[:space:]]+[^>]*>' "$file" | grep -Ev '^[[:space:]]*<' || true)
    # Additional heuristics
    # 4. Commented-out tags that contain an inner tag (often commented directives)
    if (( NO_COMMENTED )); then
      custom_angular_comments=""
    else
      custom_angular_comments=$(grep -nE '<!--[^>]*<[^>]*>[^>]*-->' "$file" || true)
    fi
    # 5. Custom element/directive tags (contain a hyphen in the element name)
    custom_element_tags=$(grep -nE '<[A-Za-z0-9]+-[A-Za-z0-9-]*[^>]*>' "$file" | grep -Ev '^\s*<!--' || true)
  fi
  # 6. Lines with an opening '<' and no closing '>' on the same line (possible malformed HTML)
  #    Replace the naive per-line grep (which flags many multi-line tags)
  #    with a lookahead-aware awk check: for any line that contains '<' but
  #    no '>', search the next N lines for a closing '>' and only flag it
  #    if no closing '>' is found within that window. This reduces false
  #    positives for tags whose attributes are split across multiple lines.
  if (( NO_UNCLOSED )); then
    unclosed_tags=""
  else
    unclosed_tags=$(awk 'BEGIN{maxlook=6}
    { lines[NR]=$0 }
    END{
      for(i=1;i<=NR;i++){
        if(lines[i] ~ /</ && lines[i] !~ />/){
          found=0
          for(j=i+1;j<=i+maxlook && j<=NR;j++){
            if(lines[j] ~ />/){ found=1; break }
            # if next opening tag appears before a close, stop scanning
            if(lines[j] ~ /</) break
          }
          if(!found) print i ":" lines[i]
        }
      }
    }' "$file" || true)
  fi

    # Build detailed report: include each htmlhint actionable line with line snippet when possible
    if [[ -n "$actionable_lines" ]]; then
      details=""
      while IFS= read -r line; do
        # Extract the first numeric token as line number, if present
        lineno=$(echo "$line" | grep -oE '[0-9]+' | head -n1 || true)
        # Trim message and strip leading 'error' if present
        message=$(echo "$line" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//' | sed -E 's/^[eE]rror[: ]*//')
        if [[ -n "$lineno" ]]; then
          # ensure lineno is numeric
          lineno=$(echo "$lineno" | head -n1)
          snippet=$(sed -n "${lineno}p" "$file" 2>/dev/null | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
          if [[ -n "$snippet" ]]; then
            details+="error ${lineno}: ${message}\\n    ${snippet}\\n"
          else
            details+="error ${lineno}: ${message}\\n"
          fi
        else
          details+="error ${message}\\n"
        fi
      done <<< "$actionable_lines"
      ERRORS+=("$file"$'\n'"$details")
      err=$((err+1))
      html_err=$((html_err+1))
    elif [[ -n "$custom_angular_errors1" || -n "$custom_angular_comments" || -n "$unclosed_tags" || -n "$custom_angular_errors3" ]]; then
      # Conservative custom heuristics reporting (avoid noisy checks like custom elements or unknown attrs)
      details="Custom AngularJS template issue(s):\\n"
      typeset -A seen
      # 1) attribute-without-value
      if [[ -n "$custom_angular_errors1" ]]; then
        while IFS= read -r cline; do
          cnum=$(echo "$cline" | cut -d: -f1 | grep -oE '[0-9]+' | head -n1 || true)
          [[ -z "$cnum" ]] && continue
          # dedupe
          if [[ -n "${seen[$cnum]:-}" ]]; then continue; fi
          seen[$cnum]=1
          ctext=$(echo "$cline" | cut -d: -f2- | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
          # if it contains '=', it's probably a normal attribute assignment; skip
          if echo "$ctext" | grep -q '='; then
            continue
          fi
          snippet=$(sed -n "${cnum}p" "$file" 2>/dev/null | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
          details+="error ${cnum}: attribute without value: ${ctext}\\n    ${snippet}\\n"
        done <<< "$custom_angular_errors1"
      fi
      # 2) commented-out tags (likely disabled directives)
      if [[ -n "$custom_angular_comments" ]]; then
        while IFS= read -r cline; do
          cnum=$(echo "$cline" | cut -d: -f1 | grep -oE '[0-9]+' | head -n1 || true)
          [[ -z "$cnum" ]] && continue
          if [[ -n "${seen[$cnum]:-}" ]]; then continue; fi
          seen[$cnum]=1
          ctext=$(echo "$cline" | cut -d: -f2- | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
          snippet=$(sed -n "${cnum}p" "$file" 2>/dev/null | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
          details+="error ${cnum}: commented-out tag (possible disabled directive): ${ctext}\\n    ${snippet}\\n"
        done <<< "$custom_angular_comments"
      fi
      # 3) malformed/stray text (often CSS accidentally pasted into template)
      if [[ -n "$custom_angular_errors3" ]]; then
        while IFS= read -r cline; do
          cnum=$(echo "$cline" | cut -d: -f1 | grep -oE '[0-9]+' | head -n1 || true)
          [[ -z "$cnum" ]] && continue
          if [[ -n "${seen[$cnum]:-}" ]]; then continue; fi
          seen[$cnum]=1
          ctext=$(echo "$cline" | cut -d: -f2- | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
          snippet=$(sed -n "${cnum}p" "$file" 2>/dev/null | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
          details+="error ${cnum}: malformed tag or stray text: ${ctext}\\n    ${snippet}\\n"
        done <<< "$custom_angular_errors3"
      fi
      # 4) unclosed tags (after filtering obvious CSS/attr lines)
      if [[ -n "$unclosed_tags" ]]; then
        while IFS= read -r cline; do
          cnum=$(echo "$cline" | cut -d: -f1 | grep -oE '[0-9]+' | head -n1 || true)
          [[ -z "$cnum" ]] && continue
          if [[ -n "${seen[$cnum]:-}" ]]; then continue; fi
          seen[$cnum]=1
          ctext=$(echo "$cline" | cut -d: -f2- | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
          # skip if contains '=' or looks like CSS selector
          if echo "$ctext" | grep -q '=' || echo "$ctext" | grep -qE '\{|\}'; then
            continue
          fi
          details+="error ${cnum}: unclosed tag or malformed line: ${ctext}\\n"
        done <<< "$unclosed_tags"
      fi
      # If unclosed-tag heuristics are disabled, strip those lines from details
      if (( NO_UNCLOSED )); then
        details=$(printf '%s' "$details" | sed '/unclosed tag or malformed line/d')
      fi
      # Only record as an error if we accumulated something useful
      if [[ "$details" != "Custom AngularJS template issue(s):\\n" ]]; then
        ERRORS+=("$file"$'\n'"$details")
        err=$((err+1))
        html_err=$((html_err+1))
      else
        ok=$((ok+1))
      fi
    else
      ok=$((ok+1))
    fi
  else
    ok=$((ok+1))
  fi
done


# Print summary and errors at the end
# Note: use the manual counters (err/js_err/html_err) which we increment per-file
printf "\r%*s\r\n" $(tput cols) ""
printf "\n%s%s==============================%s\n" "$BOLD" "$PURPLE" "$RESET"
printf "%s%s   ANGULAR LINT SUMMARY   %s\n" "$BOLD" "$CYAN" "$RESET"
printf "%s%s==============================%s\n" "$BOLD" "$PURPLE" "$RESET"
printf "%sTotal files scanned:%s %s%d%s\n" "$BOLD" "$RESET" "$WHITE" "$total" "$RESET"
printf "%sOK:%s %s%d%s\n" "$BOLD" "$RESET" "$GREEN" "$ok" "$RESET"
printf "%sJS Errors:%s %s%d%s\n" "$BOLD" "$RESET" "$RED" "$js_err" "$RESET"
printf "%sHTML Errors:%s %s%d%s\n" "$BOLD" "$RESET" "$RED" "$html_err" "$RESET"
if (( err == 0 )); then
  printf "%sErrors:%s %s%d%s\n" "$BOLD" "$RESET" "$WHITE" "$err" "$RESET"
else
  printf "%sErrors:%s %s%d%s\n" "$BOLD" "$RESET" "$RED" "$err" "$RESET"
  printf "\n%sERROR DETAILS:%s\n" "$BOLD" "$RED"
  for e in "${ERRORS[@]}"; do
      # Only print if there are actionable error lines (not just the file path)
    file_path=$(echo "$e" | head -n1)
      error_lines=$(echo "$e" | tail -n +2 | grep -vE '^\s*$')
      if [[ -n "$error_lines" ]]; then
        printf "%s%s%s\n" "$YELLOW" "$file_path" "$RESET"
  echo "$error_lines" | awk -v RED="\033[1;31m" -v RESET="\033[0m" -v YELLOW="\033[1;33m" -v CYAN="\033[36m" -v WHITE="\033[37m" '
          /^\s*[0-9]+:[0-9]+/ {
            split($0, a, /\s+/);
            # Print: error (red), line (yellow), type (cyan), message (white)
            printf("    %serror%s %sLine %s%s %s%s%s %s\n", RED, RESET, YELLOW, a[1], RESET, CYAN, a[3], RESET, substr($0, index($0,$4)));
            next
          }
          { if (length($0) > 0) printf("    %serror%s %s\n", RED, RESET, $0); }
        '
        printf "\n"
      fi
  done
fi
printf "%s==============================%s\n" "$PURPLE" "$RESET"



# Print minimal summary block at the very end, with colors
printf "\n%s==============================%s\n" "$PURPLE" "$RESET"
printf "%s   ANGULAR LINT SUMMARY   %s\n" "$CYAN" "$RESET"
printf "%s==============================%s\n" "$PURPLE" "$RESET"
printf "%sTotal files scanned:%s %s%d%s\n" "$BOLD" "$RESET" "$WHITE" "$total" "$RESET"
printf "%sOK:%s %s%d%s\n" "$BOLD" "$RESET" "$GREEN" "$ok" "$RESET"
  printf "%sJS Errors:%s %s%d%s\n" "$BOLD" "$RESET" "$RED" "$js_err" "$RESET"
  printf "%sHTML Errors:%s %s%d%s\n" "$BOLD" "$RESET" "$RED" "$html_err" "$RESET"
printf "%sErrors:%s %s%d%s\n" "$BOLD" "$RESET" "$RED" "$err" "$RESET"

# Print heuristics state for clarity
printf "\n%sHeuristics:%s " "$BOLD" "$RESET"
if (( NO_CUSTOM )); then
  printf "custom=OFF"
else
  printf "custom=ON"
fi
printf "  "
if (( NO_UNCLOSED )); then
  printf "unclosed=OFF"
else
  printf "unclosed=ON"
fi
printf "  "
if (( NO_COMMENTED )); then
  printf "commented=OFF"
else
  printf "commented=ON"
fi
printf "\n"

exit 0
