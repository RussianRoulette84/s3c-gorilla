##########################################################################################
## ssh-gorilla - thin SSH wrapper for .zprofile
##   - auto-prepends root@ to bare hostnames
##   - PASSWORD MODE + session-unlock: serves keys from the per-tty s3c-session-agent
##     (one prompt per tab; the master pw never leaves the agent). Chip mode keeps the
##     static SSH_AUTH_SOCK → the SE-backed LaunchAgent set in .zprofile.
##
## Source this file in your .zprofile:
##   source /usr/local/bin/ssh-gorilla.sh
##########################################################################################

# LAZY init: sourcing this in .zprofile must stay cheap (it runs in EVERY shell). We do
# NOT pull in config + banners + colorize at source time — only the first `ssh` call does,
# once, via this guard. A plain shell that never SSHes pays nothing.
_gorilla_lazy_init() {
    [[ -n "${_gorilla_loaded:-}" ]] && return
    _gorilla_loaded=1
    [[ -f "$HOME/.config/s3c-gorilla/config" ]] && source "$HOME/.config/s3c-gorilla/config"
    : "${GORILLA_SESSION_UNLOCK:=false}"
    : "${GORILLA_SESSION_AGENT:=/usr/local/bin/s3c-session-agent}"
    : "${GORILLA_TOUCHID:=/usr/local/bin/touchid-gorilla}"
    : "${GORILLA_BANNERS:=/usr/local/share/s3c-gorilla/banners.sh}"
    [[ -r "$GORILLA_BANNERS" ]] && source "$GORILLA_BANNERS"
}

# Per-tty ssh socket path — must match the agent's sha256(tty) keying (HR #5 contract;
# vector "/dev/ttys003" → e5d96d28…f03bc5, pinned in test_session_unlock.bats).
_gorilla_ssh_sock() {
    local t h
    t=$(tty 2>/dev/null || echo no-tty)
    h=$(printf '%s' "$t" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
    printf '%s/.s3c-gorilla/session/%s.ssh.sock' "$HOME" "$h"
}

ssh() {
    _gorilla_lazy_init
    # Password mode (no chip) + session-unlock: ensure the per-tty agent holds the
    # master pw and point ssh at its socket. Chip mode leaves SSH_AUTH_SOCK alone.
    if [[ "$GORILLA_SESSION_UNLOCK" == "true" && ! -x "$GORILLA_TOUCHID" && -x "$GORILLA_SESSION_AGENT" ]] \
        && command -v session_unlock >/dev/null 2>&1 && session_unlock; then
        export SSH_AUTH_SOCK="$(_gorilla_ssh_sock)"
        # The agent binds its SSH socket on a BACKGROUND thread, but session_unlock returns as
        # soon as the CONTROL socket answers. Without this wait, `ssh` races ahead, finds no
        # socket ("ssh_get_authentication_socket: No such file"), falls back to on-disk keys and
        # fails. Poll up to ~3s for the socket to appear (-S = is a socket).
        local _i=0
        while [[ ! -S "$SSH_AUTH_SOCK" && $_i -lt 60 ]]; do sleep 0.05; _i=$((_i+1)); done
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
