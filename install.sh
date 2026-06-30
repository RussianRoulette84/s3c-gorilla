#!/bin/bash
##########################################################################################
## s3c-gorilla — Installer
## Detects Touch ID hardware and offers to install touchid-gorilla; can be
## skipped interactively to fall back to master-password prompts.
## Installs: env-gorilla, ssh-gorilla, touchid-gorilla
##########################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_DIR="$SCRIPT_DIR/src/setup"

# Shared vars + TUI helpers + the config-derived DB_PATH (HR #15: install.sh is now a lean
# orchestrator; each install step lives in its own src/setup/NN-*.sh file, sourced in order).
source "$SETUP_DIR/00-common.sh"

# Mirror all install output to ./logs/s3c-gorilla.log for post-mortem.
# /dev/tty preserved for read prompts, so interactivity is unaffected.
mkdir -p "$SCRIPT_DIR/logs"
LOG_FILE="$SCRIPT_DIR/logs/s3c-gorilla.log"
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
echo "===== install.sh run: $(date) =====" >> "$LOG_FILE"

cat << 'EOF' | zsh "$SCRIPT_DIR/src/lib/ywizz/colorize.sh" -s 1 -e 20
    ⢀⣠⣴⠶⠚⠛⢶⣄
    ⢸⣿⣿⣿⡆  ⠙⢷⣄
   ⣰⣿⣿⣿⣿⣿⣿⣷⣶⣶⣿⣦⡀
  ⣴⣿⠿⠿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣤⣤⣄⣀⡀
 ⠘⣥⣤⠶⣶⣼⣿⣿⠟⠁ ⠉⠛⠿⣿⣿⣿⡟⠛⠻⢷⡄
 ⢠⡞⠛⠒⣿⣿⣿⠏     ⣠⣾⣿⣿⣿⡄  ⠻⣦⡀
⢠⡎ ⣴⣶⣿⣿⡟    ⢠⣾⣿⣿⣿⣿⣿⣷   ⠈⠻⣷⣄⡀⢀⣀⣠⣤⣤⣤⣤⣄⣀
⢮⣉⣹⣿⣿⣿⣿⡇ ⢠⣀⣴⣿⣿⣿⣿⣿⣿⣿⣿     ⠈⠛⠟⠛⠛⠋⠉⠉⠉⠉⠉⠻⣷⣄
 ⠹⣿⣿⣿⡟⢸ ⢀⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡄              ⠈⢿⣧⡀
  ⠘⠿⠟⠃⢸ ⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷  ⡴      ⢀⣠⣤⣄⡀  ⢻⣿⣆
      ⢸⣷⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣧⣴⡇   ⣀⣴⣾⣿⣿⣿⣿⣿⣶⣄ ⢻⣿⣷⡀
      ⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⣿⣿⣿⣿⣿⣿⢁⣠⣶⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣾⣿⣿⣿⣆         /$$$$$$   /$$$$$$   /$$$$$$         /$$$$$$   /$$$$$$  /$$$$$$$  /$$$$$$ /$$       /$$        /$$$$$$
     ⢠⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠟⣰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡀       /$$__  $$ /$$__  $$ /$$__  $$       /$$__  $$ /$$__  $$| $$__  $$|_  $$_/| $$      | $$       /$$__  $$
    ⢀⡿⠁⣿⣿⣿⣿⣿⣿⣿⣿⠟⠁⣰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇      | $$  \__/|__/  \ $$| $$  \__/      | $$  \__/| $$  \ $$| $$  \ $$  | $$  | $$      | $$      | $$  \ $$
    ⣸⠃ ⣿⣿⣿⣿⣿⣿⣿⠃ ⠈⠛⠛⢻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣇⡀     |  $$$$$$    /$$$$$/| $$            | $$ /$$$$| $$  | $$| $$$$$$$/  | $$  | $$      | $$      | $$$$$$$$
    ⣿  ⣿⣿⣿⣿⣿⣿⣿ ⣾⣿⣿⣷⡀⠙⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠛⣡⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡅⠙⠳⢦⡀   \____  $$  |___  $$| $$            | $$|_  $$| $$  | $$| $$__  $$  | $$  | $$      | $$      | $$__  $$
   ⢰⡏  ⣿⣿⣿⣿⣿⣿⡇ ⣿⣿⣿⣿⣿⣶⣄⠈⠛⠿⢿⣿⡿⠿⠟⠋⣁⣴⣾⣿⡟⠁⠸⣿⣿⣿⣿⣿⣿⣿⣇  ⠈⣷   /$$  \ $$ /$$  \ $$| $$    $$      | $$  \ $$| $$  | $$| $$  \ $$  | $$  | $$      | $$      | $$  | $$
   ⢸⡇  ⣿⣿⣿⣿⣿⣿⠃ ⢿⣿⣿⣿⣿⣿⣿     ⣠⣴⣶⣿⣿⣿⣿⡏   ⠈⠙⢿⣿⣿⣿⣿⣿⣆  ⢸⡆  |  $$$$$$/|  $$$$$$/|  $$$$$$/      |  $$$$$$/|  $$$$$$/| $$  | $$ /$$$$$$| $$$$$$$$| $$$$$$$$| $$  | $$
   ⣼⠇ ⢀⣿⣿⣿⣿⣿⠃  ⠸⣿⣿⣿⣿⣿⣿⡀    ⣿⣿⣿⣿⣿⣿⡿       ⠈⢿⣿⣿⣿⣿⣷⣦⣄⣷   \______/  \______/  \______/        \______/  \______/ |__/  |__/|______/|________/|________/|__/  |__/
   ⢻⣷⣶⣼⣿⣿⣿⣿⣧⡀   ⢿⣿⣿⣿⣿⣿⣿⣦ ⢀⣴⣿⣿⣿⣿⣿⣿⡇        ⣠⣿⣿⣿⣿⣿⣿⣿⣿⠆
    ⠻⠿⠿⢿⣿⣿⣿⣿⡿   ⠘⢿⣿⣿⣿⣿⣿⠇ ⢸⣿⣿⣿⣿⣿⣿⣿⠁       ⠸⠿⠿⢿⣿⣿⣿⣿⡿⠋  secrets from the vault into memory, not the disk

EOF

printf "%b%s%s%b%b%b\n" "$C7" "$TREE_TOP" "$DIAMOND_FILLED" "$BOLD$C7" "s3c-gorilla INSTALLER" "$RESET"
item ""
item "A macOS-only toolkit for developers and security freaks who don't like"
item "their secrets sitting on the disk."
item ""
item "Every SSH key, .env, and 2FA secret lives in KeePassXC — the well-known"
item "encrypted vault made by the lovely French (even the Germans approved it)."
item "When a secret is needed, s3c-gorilla injects it into memory after one Touch"
item "ID (master password the first time), locked by an encryption key that lives"
item "inside Apple's Secure Enclave chip :D"
item ""
item "Where did your secrets go? Not onto your disk, that's for sure ;)"

# Run each install step in order. They are SOURCED (not subshelled) so state set by an early
# step (HAS_TOUCHID, SESSION_UNLOCK, DB_PATH, BUILD_DIR…) carries to later ones — exactly like
# the old monolith. Each step file ends in `true` so a benign non-zero last line doesn't trip
# `set -e` (Concern #34). 00-common.sh is already sourced above, so skip it here.
#
# If `set -e` aborts a step, the ERR trap names WHICH step died so it's never a silent bail —
# earlier steps are already applied; the user fixes the issue and re-runs (#7).
CURRENT_STEP="(startup)"
trap 'rc=$?; [[ $rc -ne 0 ]] && printf "\n✗ install aborted during: %s (exit %s)\n  Earlier steps are done — fix the issue and re-run ./install.sh\n" "$CURRENT_STEP" "$rc" >&2' ERR
for step in "$SETUP_DIR"/[0-9][0-9]-*.sh; do
    [[ "$(basename "$step")" == "00-common.sh" ]] && continue
    CURRENT_STEP="$(basename "$step")"
    source "$step"
done
trap - ERR
