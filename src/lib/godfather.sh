#!/bin/bash
##########################################################################################
## godfather.sh — Don Corleone asks for the password.
## Part of s3c-gorilla. Sourced by any tool that needs to prompt for a master
## password or a root (sudo) password. Prints the Godfather head + "offer" line
## right before `read -s` / `sudo` so the user knows why they're being asked.
##
## Usage (inside a tool):
##   source /usr/local/share/s3c-gorilla/godfather.sh
##   show_godfather           # master password prompt
##   show_godfather root      # sudo / root password prompt
##########################################################################################

_GODFATHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${GORILLA_COLORIZE:=/usr/local/share/s3c-gorilla/colorize.sh}"
# godfather.sh lives in src/lib/ (repo) or .../share/s3c-gorilla/ (installed).
# colorize.sh is at src/lib/ywizz/colorize.sh in the repo, or alongside it once
# installed — try both so the art is colorized in either layout.
[[ -r "$GORILLA_COLORIZE" ]] || GORILLA_COLORIZE="$_GODFATHER_DIR/ywizz/colorize.sh"
[[ -r "$GORILLA_COLORIZE" ]] || GORILLA_COLORIZE="$_GODFATHER_DIR/colorize.sh"

show_godfather() {
    local kind="${1:-master}"
    local line1 line2
    case "$kind" in
        root|sudo)
            line1='"I have an offer you can'"'"'t refuse..."'
            line2='      your root password, please.'
            ;;
        *)
            line1='"I have an offer you can'"'"'t refuse..."'
            line2='      the master password, please.'
            ;;
    esac

    if [[ -r "$GORILLA_COLORIZE" ]]; then
        cat << 'EOF' | zsh "$GORILLA_COLORIZE" -s 1 -e 13
    ⠀⠀⢀⢀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⢀⣠⣤⣼⣿⣿⣿⣾⣶⡤⠄⠀⠀⠀⠀⠀⠀⠀
    ⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣄⡀⠀⠀⠀⠀⠀⠀
   ⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣉⡄⠀⠀⠀⠀
   ⢀⣾⢿⣿⣿⡿⠿⠿⠿⠿⢿⣿⣿⡿⣿⢇⠀⠀⠀⠀
        ⢨⣷⡀⠀⠀⠐⣢⣬⣿⣷⡁⣾⠀⠀⠀⠀
   ⢀⡠⣤⣴⣾⣿⣿⣷⣦⣿⣿⣿⣿⣿⠿⡇⠀⠀⠀⠀
   ⠈⠙⣿⡿⠚⠿⠟⢿⣟⣿⣿⣿⣿⣿⠉⠀⠀⠀⠀⠀
     ⣹⠵⠀⠠⠼⠯⠝⣻⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀
     ⠻⢂⡄⠒⠒⠛⣿⡿⠛⠻⠋⣼⠀⠀⠀⠀⠀⠀
     ⠠⡀⠰⠶⠿⠿⠷⠞⠀⣠⣴⠟⠀⠀⠀⠀⠀⠀
     ⠈⠂⣀⠀⠀⠀⠀⢠⠟⠉⠀⠀⠀⠀⠀⠀⠀
        ⠘⠓⠂⠀⠐⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀
EOF
    else
        cat << 'EOF'
    ⠀⠀⢀⢀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⢀⣠⣤⣼⣿⣿⣿⣾⣶⡤⠄⠀⠀⠀⠀⠀⠀⠀
    ⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣄⡀⠀⠀⠀⠀⠀⠀
   ⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣉⡄⠀⠀⠀⠀
   ⢀⣾⢿⣿⣿⡿⠿⠿⠿⠿⢿⣿⣿⡿⣿⢇⠀⠀⠀⠀
        ⢨⣷⡀⠀⠀⠐⣢⣬⣿⣷⡁⣾⠀⠀⠀⠀
   ⢀⡠⣤⣴⣾⣿⣿⣷⣦⣿⣿⣿⣿⣿⠿⡇⠀⠀⠀⠀
   ⠈⠙⣿⡿⠚⠿⠟⢿⣟⣿⣿⣿⣿⣿⠉⠀⠀⠀⠀⠀
     ⣹⠵⠀⠠⠼⠯⠝⣻⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀
     ⠻⢂⡄⠒⠒⠛⣿⡿⠛⠻⠋⣼⠀⠀⠀⠀⠀⠀
     ⠠⡀⠰⠶⠿⠿⠷⠞⠀⣠⣴⠟⠀⠀⠀⠀⠀⠀
     ⠈⠂⣀⠀⠀⠀⠀⢠⠟⠉⠀⠀⠀⠀⠀⠀⠀
        ⠘⠓⠂⠀⠐⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀
EOF
    fi

    printf '\n   \033[3m%s\033[0m\n' "$line1"
    printf '   \033[3m%s\033[0m\n\n' "$line2"
}

# If run directly (not sourced), just show it — handy for previewing.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    show_godfather "${1:-master}"
fi
