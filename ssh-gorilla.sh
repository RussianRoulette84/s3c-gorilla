##########################################################################################
## ssh-gorilla - SSH wrapper for .zprofile
## Auto-unlocks KeePassXC with Touch ID + auto-prepends root@ to bare hostnames
## Part of s3c-gorilla
##
## Source this file in your .zprofile:
##   source ~/bin/ssh-gorilla.sh
##########################################################################################
ssh() {
    # Auto-unlock KeePassXC if no keys in agent
    if ! command ssh-add -l &>/dev/null; then
        cat << 'EOF' | ~/bin/colorize.sh -s 1 -e 11
  /$$$$$$   /$$$$$$  /$$   /$$        /$$$$$$   /$$$$$$  /$$$$$$$  /$$$$$$ /$$       /$$        /$$$$$$ 
 /$$__  $$ /$$__  $$| $$  | $$       /$$__  $$ /$$__  $$| $$__  $$|_  $$_/| $$      | $$       /$$__  $$
| $$  \__/| $$  \__/| $$  | $$      | $$  \__/| $$  \ $$| $$  \ $$  | $$  | $$      | $$      | $$  \ $$
|  $$$$$$ |  $$$$$$ | $$$$$$$$      | $$ /$$$$| $$  | $$| $$$$$$$/  | $$  | $$      | $$      | $$$$$$$$
 \____  $$ \____  $$| $$__  $$      | $$|_  $$| $$  | $$| $$__  $$  | $$  | $$      | $$      | $$__  $$
 /$$  \ $$ /$$  \ $$| $$  | $$      | $$  \ $$| $$  | $$| $$  \ $$  | $$  | $$      | $$      | $$  | $$
|  $$$$$$/|  $$$$$$/| $$  | $$      |  $$$$$$/|  $$$$$$/| $$  | $$ /$$$$$$| $$$$$$$$| $$$$$$$$| $$  | $$
 \______/  \______/ |__/  |__/       \______/  \______/ |__/  |__/|______/|________/|________/|__/  |__/

    ssh-gorilla — the effortless and secure way to SSH
EOF
        echo ""
        open -a KeePassXC
        echo "⏳ Touch ID to unlock..."
        attempts=0
        while ! command ssh-add -l &>/dev/null; do
            if [[ $attempts -lt 5 ]]; then
                osascript -e 'tell application "KeePassXC" to activate' -e 'delay 0.3' -e 'tell application "System Events" to keystroke return' &>/dev/null
                ((attempts++))
            fi
            sleep 1
        done
    fi

    local args=()
    local host_set=false
    for arg in "$@"; do
        if [[ "$host_set" == false && "$arg" != -* ]]; then
            local prev=""
            [[ ${#args[@]} -gt 0 ]] && prev="${args[-1]}"
            local flag_takes_value=false
            case "$prev" in
                -p|-i|-l|-o|-F|-J|-L|-R|-D|-W|-b|-c|-e|-m|-S|-w|-E|-B|-I|-Q|-O)
                    flag_takes_value=true ;;
            esac
            if $flag_takes_value; then
                args+=("$arg")
            elif [[ "$arg" != *@* ]]; then
                args+=("root@$arg")
                host_set=true
            else
                args+=("$arg")
                host_set=true
            fi
        else
            args+=("$arg")
        fi
    done
    command ssh "${args[@]}"
}
