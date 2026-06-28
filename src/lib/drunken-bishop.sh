#!/bin/bash
##########################################################################################
## drunken-bishop.sh — OpenSSH-style "randomart" walk, animated.
## Part of s3c-gorilla. Sourced by any tool that triggers Touch ID.
##
## TWO things, kept separate so they overlap with the real scan:
##   db_start   — launch the bishop walk + locked-padlock loop in the BACKGROUND,
##                returns immediately so the caller can fire the Touch ID prompt.
##   db_stop    — kill the loop and play a short 🔒→🔓 unlock flourish.
## So the animation plays WHILE the fingerprint scan happens, and auto-stops the
## moment the scan returns. (Old synchronous one-shot kept as show_drunken_bishop.)
##
## Algorithm: canonical OpenSSH drunken-bishop walk. 17x9 field, bishop starts
## center, each 2-bit pair of 16 urandom bytes picks a diagonal move, visit counts
## mapped through " .o+=*BOX@%&#/^", start = S, end = E. Decoration, not a real key.
##
## Usage:
##   source /usr/local/share/s3c-gorilla/drunken-bishop.sh
##   db_start; result=$(touchid-gorilla unwrap ...); db_stop
##
## Writes to /dev/tty (fallback: /dev/stderr) so the caller can still capture
## stdout from the Touch ID helper without the frame mixing in.
##########################################################################################

_DB_W=17
_DB_H=9
# Lines per rendered frame: header(1) + top border(1) + H rows + bottom border(1).
_DB_FRAME_LINES=$((_DB_H + 3))
_DB_PID=""

# Resolve a writable terminal. /dev/tty exists on macOS even without a controlling
# terminal (bare `test -w` lies), so probe with an actual write.
_db_tty() {
    if (: >/dev/tty) 2>/dev/null; then printf '/dev/tty'; else printf '/dev/stderr'; fi
}

# Animate ONE complete bishop walk in place, drawing to $1=tty.
_db_walk() {
    local tty="$1"
    local W=$_DB_W H=$_DB_H start_x=8 start_y=4
    local x=$start_x y=$start_y
    local chars=' .o+=*BOX@%&#/^'
    local -a cell
    local i
    for ((i = 0; i < W * H; i++)); do cell[i]=0; done

    local raw
    raw=$(od -An -tu1 -N16 /dev/urandom | tr '\n' ' ')
    local -a bytes
    read -ra bytes <<<"$raw"

    _db_frame() {
        local buf='' rr cc vv ch idx2
        buf+=' 🔒 scanning…'$'\n'
        buf+='+'; for ((cc = 0; cc < W; cc++)); do buf+='-'; done; buf+='+'$'\n'
        for ((rr = 0; rr < H; rr++)); do
            buf+='|'
            for ((cc = 0; cc < W; cc++)); do
                idx2=$((rr * W + cc))
                if ((cc == start_x && rr == start_y)); then ch='S'
                elif ((cc == x && rr == y)); then ch='E'
                else vv=${cell[idx2]}; ch=${chars:$vv:1}; fi
                buf+=$ch
            done
            buf+='|'$'\n'
        done
        buf+='+'; for ((cc = 0; cc < W; cc++)); do buf+='-'; done; buf+='+'$'\n'
        printf '%s' "$buf" >"$tty"
    }

    _db_frame
    local b input bit idx
    for b in "${bytes[@]}"; do
        input=$b
        for ((bit = 0; bit < 4; bit++)); do
            if ((input & 1)); then x=$((x + 1)); else x=$((x - 1)); fi
            if ((input & 2)); then y=$((y + 1)); else y=$((y - 1)); fi
            ((x < 0)) && x=0
            ((y < 0)) && y=0
            ((x >= W)) && x=$((W - 1))
            ((y >= H)) && y=$((H - 1))
            idx=$((y * W + x))
            ((cell[idx] < 14)) && cell[idx]=$((cell[idx] + 1))
            input=$((input >> 2))

            printf '\033[%dA' "$_DB_FRAME_LINES" >"$tty"
            _db_frame
            sleep 0.02
        done
    done
}

# Start the looping animation in the background. The bg block redirects its own
# stdout to the tty so it can never hold a caller's command-substitution pipe
# open (which would hang `result=$(... )`). Killed cleanly by db_stop.
db_start() {
    local tty
    tty=$(_db_tty)
    {
        # Trap TERM/INT → restore cursor and exit 0 (so no "Terminated" message
        # and `wait` in db_stop reaps a normal exit).
        trap 'printf "\033[?25h" >"'"$tty"'"; exit 0' TERM INT
        printf '\033[?25l' >"$tty"   # hide cursor
        while :; do
            _db_walk "$tty"
            # rewind over the same region so the next pass overwrites, no scroll
            printf '\033[%dA' "$_DB_FRAME_LINES" >"$tty"
            sleep 0.12
        done
    } >"$tty" 2>&1 &
    _DB_PID=$!
}

# Stop the background animation and play a brief 🔒→🔓 unlock flourish.
db_stop() {
    [[ -n "$_DB_PID" ]] || return 0
    kill "$_DB_PID" 2>/dev/null
    wait "$_DB_PID" 2>/dev/null
    _DB_PID=""

    local tty f
    tty=$(_db_tty)
    printf '\033[?25h\n' >"$tty"   # ensure cursor visible, drop below last frame
    for f in ' 🔒' ' 🔐' ' 🔓'; do
        printf '\r\033[K%s' "$f" >"$tty"
        sleep 0.1
    done
    printf '\n' >"$tty"
}

# Back-compat: one synchronous walk (used for `bash drunken-bishop.sh` preview).
show_drunken_bishop() {
    local tty
    tty=$(_db_tty)
    printf '\033[?25l' >"$tty"
    _db_walk "$tty"
    printf '\033[?25h' >"$tty"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    # Demo: animate in background for ~1.5s, then unlock — shows the real flow.
    db_start
    sleep 1.5
    db_stop
fi
