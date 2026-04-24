##########################################################################################
## ssh-gorilla - thin SSH wrapper for .zprofile
## All key handling is done by s3c-ssh-agent (LaunchAgent) via SSH_AUTH_SOCK.
## This wrapper only: auto-prepends root@ to bare hostnames.
##
## Source this file in your .zprofile:
##   source /usr/local/bin/ssh-gorilla.sh
##########################################################################################
ssh() {
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
