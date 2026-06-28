#!/bin/bash
##########################################################################################
## banners.sh - SSH GORILLA master-password banner + Touch ID prompt helper
## Sourced by env-gorilla / otp-gorilla. Corleone banner stays in godfather.sh
## and is reserved for root/sudo prompts.
##########################################################################################

: "${GORILLA_COLORIZE:=/usr/local/share/s3c-gorilla/colorize.sh}"

# Shown before the terminal "KeePass master password:" prompt.
show_master_banner() {
    cat >&2 << 'EOF'

  /$$$$$$   /$$$$$$  /$$   /$$        /$$$$$$   /$$$$$$  /$$$$$$$  /$$$$$$ /$$       /$$        /$$$$$$
 /$$__  $$ /$$__  $$| $$  | $$       /$$__  $$ /$$__  $$| $$__  $$|_  $$_/| $$      | $$       /$$__  $$
| $$  \__/| $$  \__/| $$  | $$      | $$  \__/| $$  \ $$| $$  \ $$  | $$  | $$      | $$      | $$  \ $$
|  $$$$$$ |  $$$$$$ | $$$$$$$$      | $$ /$$$$| $$  | $$| $$$$$$$/  | $$  | $$      | $$      | $$$$$$$$
 \____  $$ \____  $$| $$__  $$      | $$|_  $$| $$  | $$| $$__  $$  | $$  | $$      | $$      | $$__  $$
 /$$  \ $$ /$$  \ $$| $$  | $$      | $$  \ $$| $$  | $$| $$  \ $$  | $$  | $$      | $$      | $$  | $$
|  $$$$$$/|  $$$$$$/| $$  | $$      |  $$$$$$/|  $$$$$$/| $$  | $$ /$$$$$$| $$$$$$$$| $$$$$$$$| $$  | $$
 \______/  \______/ |__/  |__/       \______/  \______/ |__/  |__/|______/|________/|________/|__/  |__/

EOF
}

# Touch ID prompt: START the drunken-bishop animation in the BACKGROUND so it
# overlaps with the scan. Pair every show_touchid with stop_touchid after the
# Touch ID helper returns. Falls back to a one-liner if the animation is absent.
show_touchid() {
    local bishop="/usr/local/share/s3c-gorilla/drunken-bishop.sh"
    [[ -r "$bishop" ]] || bishop="${BASH_SOURCE[0]%/*}/drunken-bishop.sh"  # repo fallback
    if [[ -r "$bishop" ]]; then
        source "$bishop"
        command -v db_start &>/dev/null && db_start
    else
        printf "  Touch ID → tap your finger\n" >&2
    fi
}

# Stop the background animation (and play the unlock flourish). Safe no-op if the
# animation never started.
stop_touchid() {
    command -v db_stop &>/dev/null && db_stop
}
