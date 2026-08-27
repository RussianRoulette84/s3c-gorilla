#!/bin/bash
# 00-common.sh — shared vars + helpers for the install steps. Sourced FIRST by install.sh
# (it defines, it doesn't act). $SCRIPT_DIR is set by the orchestrator before this is sourced.

# Shared Swift build recipe (frameworks per binary) — lockstep with scripts/build-swift.sh (HR #17).
[[ -f "$SCRIPT_DIR/scripts/swift-targets.sh" ]] && source "$SCRIPT_DIR/scripts/swift-targets.sh"

SRC_DIR="$SCRIPT_DIR/src"                          # tool sources live here
BIN_DIR="/usr/local/bin"                           # CLIs (needs sudo to write)
SHARE_DIR="/usr/local/share/s3c-gorilla"           # sourced helpers: colorize.sh, godfather.sh
CONFIG_DIR="$HOME/.config/s3c-gorilla"             # user config (keep)
CONFIG_FILE="$CONFIG_DIR/config"
CONFIG_EXAMPLE="$SRC_DIR/setup/config.example"     # shipped template (under src/setup/)
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/s3c-gorilla-build.XXXXXX")"   # scratch (portable mktemp)
trap 'rm -rf "$BUILD_DIR"' EXIT

# ywizz TUI helpers — purple accent for status lines (defines C7/TREE_*/info/success/warn/error…).
source "$SCRIPT_DIR/src/lib/ywizz/ywizz.sh"
accent_color="$C7"

# sign_binary <bin> [identity] [entitlements] — codesign with hardened runtime (H3) at every
# call site, so the flags can never drift. Empty/"-" identity → ad-hoc (valid with --options
# runtime). --timestamp needs Apple's TSA; fall back to --timestamp=none so an offline install
# still gets a hardened-runtime signature (a trusted timestamp only matters for notarization).
sign_binary() {
 local bin="$1" ident="${2:-}" ent="${3:-}"
 local args=(--force --options runtime --sign)
 if [[ -n "$ident" && "$ident" != "-" ]]; then args+=("$ident"); else args+=(-); fi
 [[ -n "$ent" && -f "$ent" ]] && args+=(--entitlements "$ent")
 codesign "${args[@]}" --timestamp "$bin" 2>/dev/null && return 0
 codesign "${args[@]}" --timestamp=none "$bin" 2>/dev/null
}

# set_config KEY VALUE — idempotently set KEY=VALUE in $CONFIG_FILE (update in place if present,
# else append). VALUE is %q-quoted so a path with spaces/specials can't corrupt the file or a
# later `source` (#37). Atomic temp-file swap. Avoids macOS sed's `-i ''` portability wart (I-b).
set_config() {
 local key="$1" val="$2" line tmp
 [[ -f "$CONFIG_FILE" ]] || { mkdir -p "$CONFIG_DIR"; : > "$CONFIG_FILE"; }
 printf -v line '%s=%q' "$key" "$val"
 if grep -q "^$key=" "$CONFIG_FILE" 2>/dev/null; then
 tmp=$(mktemp); grep -v "^$key=" "$CONFIG_FILE" > "$tmp"; printf '%s\n' "$line" >> "$tmp"; mv "$tmp" "$CONFIG_FILE"
 else
 printf '%s\n' "$line" >> "$CONFIG_FILE"
 fi
}

# Section header — a continuous tree node: a │ spacer then ├ ◆ Title. This keeps every
# step part of ONE tree (orchestrator opens with ┌ ◆, 99-done closes with └ ◆) instead of
# each section drawing its own ┌-boxed island with a bare blank line above it.
section() {
 printf "%b%s%b\n" "$C7" "$TREE_MID" "$RESET"
 printf "%b%s%s%b%s%b\n" "$C7" "$TREE_BRANCH" "$DIAMOND_FILLED" "$BOLD$C7" "$1" "$RESET"
}
# Body-text line with the purple │ tree prefix (no status tag).
item() { style_item "$1"; }
# Skipped-step line (neutral dim, purple prefix).
skip() { printf "%b%s %b[SKIP]%b %s\n" "$C7" "$TREE_MID" "$DIM" "$RESET" "$1" >&2; }

# Prompt helpers — every interactive read draws the │ tree prefix so questions stay part of the
# wizard tree. Raw `read -p` printed bare, prefix-less lines (and `-n 1` reads left the cursor
# mid-line so the next section's │ collided with the prompt). Both write the prompt to stderr —
# the same stream `read` uses — so tee's block-buffering of stdout can't reorder them. They honor
# INSTALL_AUTO_YES (take the default, no blocking) for unattended installs.

# confirm "Question" [y|n]  — returns 0 = yes, 1 = no. Default shown as [Y/n] / [y/N].
confirm() {
 local def="${2:-y}" hint ans
 [[ "$def" == [Yy] ]] && hint="[Y/n]" || hint="[y/N]"
 if [[ -n "${INSTALL_AUTO_YES:-}" ]]; then
 printf "%b%s %s %s%b %s\n" "$C7" "$TREE_MID" "$1" "$hint" "$RESET" "$def" >&2
 [[ "$def" == [Yy] ]]; return
 fi
 printf "%b%s %s %s%b " "$C7" "$TREE_MID" "$1" "$hint" "$RESET" >&2
 read -r ans
 ans="${ans:-$def}"
 [[ "$ans" == [Yy]* ]]
}

# ask_line "Prompt" <varname> [default]  — read a free-text answer into <varname>, tree-prefixed.
ask_line() {
 local __var="$2" def="${3:-}" ans
 printf "%b%s %s%b " "$C7" "$TREE_MID" "$1" "$RESET" >&2
 if [[ -n "${INSTALL_AUTO_YES:-}" ]]; then ans="$def"; printf "%s\n" "$ans" >&2
 else read -r ans; ans="${ans:-$def}"; fi
 printf -v "$__var" '%s' "$ans"
}

# spin_until <pid> <message> — bouncing wheel while a slow background step runs, so the installer
# never looks dead. Drawn straight to /dev/tty (install.sh pipes stdout through tee, so `-t 1` is
# false and the carriage returns would otherwise trash the log). Best-effort: never fails a step.
spin_until() {
 local pid="$1" msg="$2" i=0
 local frames=(◐ ◑ ◒ ◓)
 local fd
 # /dev/tty can exist yet refuse to open (CI, cron, containers). Probe in a subshell first —
 # bash prints its redirection error before an inline `2>/dev/null` can catch it, and a bare
 # exec failure would abort the whole step under `set -e`. No terminal → no spinner, no noise.
 ( : >/dev/tty ) 2>/dev/null || return 0
 exec {fd}>/dev/tty 2>/dev/null || return 0
 printf '\033[?25l' >&$fd
 while kill -0 "$pid" 2>/dev/null; do
 printf '\r\033[K%b%s %b%s%b %s' "$C7" "$TREE_MID" "$C7" "${frames[$(( i % 4 ))]}" "$RESET" "$msg" >&$fd
 i=$(( i + 1 ))
 sleep 0.15
 done
 printf '\r\033[K\033[?25h' >&$fd
 exec {fd}>&-
 return 0
}

# run_spinner <message> <command...> — run a slow command with spin_until, keep its combined
# output in $SPINNER_OUT, and return the command's own exit status.
run_spinner() {
 local msg="$1"; shift
 SPINNER_OUT=$(mktemp)
 ( "$@" >"$SPINNER_OUT" 2>&1 ) &
 local pid=$!
 spin_until "$pid" "$msg"
 wait "$pid"
}

# Source either the live user config (if already installed) or config.example so the
# step-9 DB-existence check reflects what the tools will actually use.
if [[ -f "$CONFIG_FILE" ]]; then
 source "$CONFIG_FILE"
elif [[ -f "$CONFIG_EXAMPLE" ]]; then
 source "$CONFIG_EXAMPLE"
fi
DB_PATH="${GORILLA_DB:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx}"
:
