#!/bin/bash
##########################################################################################
## drunken-bishop.sh — OpenSSH-style "randomart" walk, animated.
## Part of s3c-gorilla. Sourced by any tool that triggers Touch ID so the user sees
## ~1s of the bishop wandering the grid right before the Touch ID modal appears.
##
## Algorithm: the canonical OpenSSH drunken-bishop walk (key_fingerprint_randomart).
##   17x9 field, bishop starts center, each 2-bit pair of the 16-byte input picks a
##   diagonal move, visit counts mapped through " .o+=*BOX@%&#/^", start = S, end = E.
## Bytes are fresh urandom on every call — this is decoration, not a real fingerprint.
##
## Usage:
##   source /usr/local/share/s3c-gorilla/drunken-bishop.sh
##   show_drunken_bishop
##
## Writes to /dev/tty (fallback: /dev/stderr) so the caller can still capture stdout
## from the subsequent Touch ID helper without getting the frame mixed in.
##########################################################################################

show_drunken_bishop() {
    (
        local W=17 H=9
        local start_x=8 start_y=4
        local x=$start_x y=$start_y
        local chars=' .o+=*BOX@%&#/^'
        # /dev/tty exists on macOS even without a controlling terminal (bare `test -w`
        # lies), so probe with an actual write and fall back to stderr.
        local tty=/dev/tty
        if ! (: >/dev/tty) 2>/dev/null; then
            tty=/dev/stderr
        fi

        local -a cell
        local i
        for ((i = 0; i < W * H; i++)); do cell[i]=0; done

        local raw
        raw=$(od -An -tu1 -N16 /dev/urandom | tr '\n' ' ')
        local -a bytes
        read -ra bytes <<<"$raw"

        trap 'printf "\033[?25h" >"'"$tty"'"; exit 0' INT
        printf '\033[?25l' >"$tty"

        _db_draw() {
            local buf='' rr cc vv ch idx2
            buf+='+'
            for ((cc = 0; cc < W; cc++)); do buf+='-'; done
            buf+='+'$'\n'
            for ((rr = 0; rr < H; rr++)); do
                buf+='|'
                for ((cc = 0; cc < W; cc++)); do
                    idx2=$((rr * W + cc))
                    if ((cc == start_x && rr == start_y)); then
                        ch='S'
                    elif ((cc == x && rr == y)); then
                        ch='E'
                    else
                        vv=${cell[idx2]}
                        ch=${chars:$vv:1}
                    fi
                    buf+=$ch
                done
                buf+='|'$'\n'
            done
            buf+='+'
            for ((cc = 0; cc < W; cc++)); do buf+='-'; done
            buf+='+'$'\n'
            printf '%s' "$buf" >"$tty"
        }

        _db_draw

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

                printf '\033[%dA' $((H + 2)) >"$tty"
                _db_draw
                sleep 0.015
            done
        done

        printf '\033[?25h' >"$tty"
    )
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    show_drunken_bishop
fi
