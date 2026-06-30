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

# Source either the live user config (if already installed) or config.example so the
# step-9 DB-existence check reflects what the tools will actually use.
if [[ -f "$CONFIG_FILE" ]]; then
 source "$CONFIG_FILE"
elif [[ -f "$CONFIG_EXAMPLE" ]]; then
 source "$CONFIG_EXAMPLE"
fi
DB_PATH="${GORILLA_DB:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx}"
:
