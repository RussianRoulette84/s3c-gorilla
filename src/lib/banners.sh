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

# Touch ID prompt: use drunken-bishop animation if available, else one-liner.
show_touchid() {
    local bishop="/usr/local/share/s3c-gorilla/drunken-bishop.sh"
    if [[ -r "$bishop" ]]; then
        source "$bishop"
        command -v show_drunken_bishop &>/dev/null && show_drunken_bishop
    else
        printf "  Touch ID → tap your finger\n" >&2
    fi
}
