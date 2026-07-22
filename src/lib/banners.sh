#!/bin/bash
##########################################################################################
## banners.sh - s3c-gorilla master-password banner + Touch ID prompt helper
## Sourced by env-gorilla / otp-gorilla. Corleone banner stays in godfather.sh
## and is reserved for root/sudo prompts.
##########################################################################################

: "${GORILLA_COLORIZE:=/usr/local/share/s3c-gorilla/colorize.sh}"
# Repo fallback: colorize.sh sits next to this file under ywizz/. Guard on -r
# (readable), NOT -x — it installs 0644 and is invoked as `zsh <file>`.
_BANNERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[[ -r "$GORILLA_COLORIZE" ]] || GORILLA_COLORIZE="$_BANNERS_DIR/ywizz/colorize.sh"

: "${GORILLA_SESSION_UNLOCK:=false}"
: "${GORILLA_SESSION_AGENT:=/usr/local/bin/s3c-session-agent}"

# ask_master_pw — prompt for the master password on the terminal (shared so
# session_unlock / ssh-gorilla can use it, not just env/otp).
command -v ask_master_pw >/dev/null 2>&1 || ask_master_pw() {
    command -v show_master_banner &>/dev/null && show_master_banner
    # Prefer secure keyboard entry via touchid-gorilla (H4) — blocks other apps keylogging the
    # master pw. Only present in chip mode; falls back to a plain read otherwise.
    local _t="${GORILLA_TOUCHID:-/usr/local/bin/touchid-gorilla}" spw
    if [[ -x "$_t" ]] && spw=$("$_t" master-prompt "master password" 2>/dev/tty) && [[ -n "$spw" ]]; then
        printf '%s' "$spw"; return
    fi
    local pw
    printf '🔐 KeePass master password: ' >&2
    read -rs pw
    printf '\n' >&2
    printf '%s' "$pw"
}

# get_master_pw — echo the KeePass master password to stdout.
# When GORILLA_SESSION_UNLOCK=true, a per-tty s3c-session-agent holds the password
# in obfuscated, memory-only storage so we don't re-prompt within this terminal
# tab. Otherwise (or if the agent isn't installed) it just prompts via
# ask_master_pw (defined by the calling tool). $PPID = the interactive shell, so
# the agent dies when the tab closes.
# Session-unlock is a NO-CHIP feature: it holds the master pw per-terminal-tab. On a chip (Touch
# ID) Mac the fan-out blob cache ALREADY gives "one master pw per boot, then Touch ID in every
# terminal" — a per-tty holder there would only make each new window re-prompt. So chip mode
# ignores GORILLA_SESSION_UNLOCK entirely, no matter what the config says.
_session_unlock_on() {
    [[ "$GORILLA_SESSION_UNLOCK" == "true" ]] || return 1
    command -v have_chip >/dev/null 2>&1 && have_chip && return 1   # chip → never per-tty
    return 0
}

get_master_pw() {
    local pw tty
    tty=$(tty 2>/dev/null || echo no-tty)
    if _session_unlock_on && [[ -x "$GORILLA_SESSION_AGENT" ]]; then
        if pw=$("$GORILLA_SESSION_AGENT" get "$tty" 2>/dev/null) && [[ -n "$pw" ]]; then
            printf '%s' "$pw"; return 0
        fi
    fi
    pw=$(ask_master_pw)
    if _session_unlock_on && [[ -x "$GORILLA_SESSION_AGENT" && -n "$pw" ]]; then
        printf '%s' "$pw" | "$GORILLA_SESSION_AGENT" start "$tty" "$PPID" 2>/dev/null
    fi
    printf '%s' "$pw"
}

# ---- Chip-mode fan-out (P2): one master-pw read wraps EVERY secret ----
# Whichever chip-mode tool runs first does the single prompt and fans out; every tool after
# only Touch-ID-unwraps ("one master password per session"). Boot-stamped via a sentinel so a
# reboot forces a fresh fan-out (secrets in /tmp must not survive a reboot).
: "${GORILLA_DB:=$HOME/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx}"
: "${GORILLA_ENV_GROUP:=ENV}"
: "${GORILLA_OTP_GROUP:=2FA}"
: "${GORILLA_TOUCHID:=/usr/local/bin/touchid-gorilla}"
: "${GORILLA_BLOB_DIR:=/tmp/s3c-gorilla}"
GORILLA_SENTINEL="$GORILLA_BLOB_DIR/.session-valid"

# Epoch of the last boot — macOS kern.boottime; Linux /proc/stat btime (so tests can run).
_boot_epoch() {
    local b
    b=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec *= *\([0-9]*\).*/\1/p')
    [[ -n "$b" ]] && { echo "$b"; return; }
    awk '/^btime/{print $2}' /proc/stat 2>/dev/null
}

# _blob_fresh <path> — true iff the file exists, was created after the last boot, AND is younger
# than the idle TTL. A stale blob (pre-boot OR idle past GORILLA_BLOB_TTL, default 7200s) is
# treated as absent so /tmp secrets can't survive a reboot or sit cached forever.
_blob_fresh() {
    local f="$1" mtime boot now ttl="${GORILLA_BLOB_TTL:-7200}"
    [[ -e "$f" ]] || return 1
    boot=$(_boot_epoch); [[ -n "$boot" ]] || return 0      # can't determine → don't falsely reject
    mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)   # GNU first, then BSD/macOS
    [[ -n "$mtime" ]] || return 0
    now=$(date +%s)
    (( mtime >= boot )) && (( now - mtime < ttl ))         # post-boot AND within the idle TTL
}

# _safe_name <name> — true if the name round-trips as a blob filename component (no spaces,
# slashes or control chars). Names that fail are skipped (a blob keyed on them wouldn't unwrap).
_safe_name() { [[ "$1" =~ ^[A-Za-z0-9._@+-]+$ ]]; }

# fan_out_all <master-pw> — chip mode only. One kdbx open → chip-wrap every ENV/* , OTP/* ,
# SSH/* secret into its own blob, so the rest of the session needs only Touch ID. Idempotent
# per boot via the sentinel; flock-serialized so concurrent tools fan out once. Best-effort —
# never fails the caller.
fan_out_all() {
    local pw="$1"
    have_chip 2>/dev/null || return 0
    [[ -n "$pw" ]] || return 0
    _blob_fresh "$GORILLA_SENTINEL" && return 0            # already fanned out this boot
    mkdir -p "$GORILLA_BLOB_DIR" 2>/dev/null; chmod 700 "$GORILLA_BLOB_DIR" 2>/dev/null
    (
        flock -n 9 || exit 0
        _blob_fresh "$GORILLA_SENTINEL" && exit 0          # lost the race; someone fanned out
        mkdir -p "$GORILLA_BLOB_DIR" 2>/dev/null; chmod 700 "$GORILLA_BLOB_DIR" 2>/dev/null   # #28: re-create if a concurrent wipe removed it
        local svc data n=0
        # FAST PATH (#X): one keepassxc export → parse → wrap every (uncompressed) secret in a
        # single Argon2 unlock instead of N. The per-secret loops below then skip whatever this
        # already wrapped (via _blob_fresh). Silently skipped if the parser tool is absent;
        # gzip-compressed attachments fall through to the per-secret loops.
        local _kp="${GORILLA_KDBX_PARSE:-/usr/local/bin/s3c-kdbx-parse}" kind nm b64
        if [[ -x "$_kp" ]]; then
            while IFS=$'\t' read -r kind nm b64; do
                [[ -z "$kind" || -z "$nm" ]] && continue
                _safe_name "$nm" || continue
                printf '%s' "$b64" | base64 --decode 2>/dev/null | "$GORILLA_TOUCHID" wrap "$kind-$nm" &>/dev/null && n=$((n+1))
            done < <(printf '%s' "$pw" | keepassxc-cli export --format xml "$GORILLA_DB" 2>/dev/null | "$_kp" 2>/dev/null)
        fi
        while IFS= read -r svc; do [[ -z "$svc" ]] && continue
            _safe_name "$svc" || { echo "s3c-gorilla: skipping unsafe name '$svc'" >&2; continue; }
            _blob_fresh "$GORILLA_BLOB_DIR/env-$svc.blob" && continue     # tool already wrapped it
            data=$(printf '%s' "$pw" | keepassxc-cli attachment-export "$GORILLA_DB" "$GORILLA_ENV_GROUP/$svc" .env --stdout -q 2>/dev/null)
            [[ -n "$data" ]] && printf '%s' "$data" | "$GORILLA_TOUCHID" wrap "env-$svc" &>/dev/null && n=$((n+1))
        done < <(printf '%s' "$pw" | keepassxc-cli ls "$GORILLA_DB" "$GORILLA_ENV_GROUP/" -q 2>/dev/null | grep -v '/$')
        while IFS= read -r svc; do [[ -z "$svc" ]] && continue
            _safe_name "$svc" || continue
            _blob_fresh "$GORILLA_BLOB_DIR/otp-$svc.blob" && continue
            data=$(printf '%s' "$pw" | keepassxc-cli show "$GORILLA_DB" "$GORILLA_OTP_GROUP/$svc" -a otp -q 2>/dev/null)
            [[ -z "$data" || "$data" == ERROR* ]] && data=$(printf '%s' "$pw" | keepassxc-cli show "$GORILLA_DB" "$GORILLA_OTP_GROUP/$svc" -a TOTP-Secret -q 2>/dev/null)
            [[ -n "$data" && "$data" != ERROR* ]] && printf '%s' "$data" | "$GORILLA_TOUCHID" wrap "otp-$svc" &>/dev/null && n=$((n+1))
        done < <(printf '%s' "$pw" | keepassxc-cli ls "$GORILLA_DB" "$GORILLA_OTP_GROUP/" -q 2>/dev/null | grep -v '/$')
        while IFS= read -r svc; do [[ -z "$svc" ]] && continue
            _safe_name "$svc" || continue
            _blob_fresh "$GORILLA_BLOB_DIR/ssh-$svc.blob" && continue
            data=$(printf '%s' "$pw" | keepassxc-cli attachment-export "$GORILLA_DB" "SSH/$svc" "$svc" --stdout -q 2>/dev/null)
            [[ -n "$data" ]] && printf '%s' "$data" | "$GORILLA_TOUCHID" wrap "ssh-$svc" &>/dev/null && n=$((n+1))
        done < <(printf '%s' "$pw" | keepassxc-cli ls "$GORILLA_DB" "SSH/" -q 2>/dev/null | grep -v '/$')
        # Only mark the session valid if we actually wrapped something — a wrong password wraps
        # nothing and must NOT poison the sentinel (#1). Report the count (#16).
        if (( n > 0 )); then
            : > "$GORILLA_SENTINEL"; chmod 600 "$GORILLA_SENTINEL" 2>/dev/null
            echo "s3c-gorilla: fanned out $n secret(s) for this session" >&2
        else
            echo "s3c-gorilla: fan-out wrapped nothing (wrong master password?)" >&2
        fi
    ) 9>"$GORILLA_BLOB_DIR/.fanout.lock"
    return 0
}

# fanout_wait — block up to 30s for an in-progress fan-out to finish, so a tool that needs a blob
# doesn't race past a running producer into a redundant Argon2 unlock (#19). Distinct from
# fan_out_all's non-blocking producer lock. Returns 0 when the lock is free (fan-out done or none
# running), 1 + a clear message on timeout. flock -w auto-releases if the holder dies, so a crashed
# producer can't wedge waiters past its own death.
fanout_wait() {
    local lock="$GORILLA_BLOB_DIR/.fanout.lock"
    [[ -e "$lock" ]] || return 0
    ( flock -w 30 9 || { echo "s3c-gorilla: bootstrap lock stuck (>30s) — proceeding without waiting" >&2; exit 1; } ) 9>"$lock"
}

# _paranoid_wipe — drop EVERY cached blob (env/otp/ssh) + the fan-out sentinel so a prior
# normal run leaves nothing reusable behind when you switch to --paranoid (#7/#10). Best-effort;
# truncates to empty if `trash` is unavailable (never leaves a usable blob).
_paranoid_wipe() {
    shopt -s nullglob
    local f
    for f in "$GORILLA_BLOB_DIR"/*.blob "$GORILLA_SENTINEL"; do
        [[ -e "$f" ]] && { trash "$f" 2>/dev/null || : > "$f"; }
    done
}

# session_unlock — ensure the per-tty agent holds the master password. Prompts
# ONCE and pipes the pw straight into the agent (never returned to this shell).
# Returns 0 when the agent is (now) unlocked, non-zero otherwise. (B1)
session_unlock() {
    local tty pw
    [[ "$GORILLA_SESSION_UNLOCK" == "true" && -x "$GORILLA_SESSION_AGENT" ]] || return 1
    tty=$(tty 2>/dev/null || echo no-tty)
    "$GORILLA_SESSION_AGENT" get "$tty" >/dev/null 2>&1 && return 0   # already unlocked
    pw=$(ask_master_pw); [[ -z "$pw" ]] && return 1
    printf '%s' "$pw" | "$GORILLA_SESSION_AGENT" start "$tty" "$PPID" 2>/dev/null
    unset pw
    "$GORILLA_SESSION_AGENT" get "$tty" >/dev/null 2>&1
}

# session_extract <env|otp> <GROUP/name> — the agent runs keepassxc-cli itself and
# returns the secret; the master pw never enters this shell (B1). Non-zero if the
# agent isn't unlocked (caller should session_unlock first or fall back).
session_extract() {
    local kind="$1" entry="$2" tty out
    [[ "$GORILLA_SESSION_UNLOCK" == "true" && -x "$GORILLA_SESSION_AGENT" ]] || return 1
    tty=$(tty 2>/dev/null || echo no-tty)
    out=$("$GORILLA_SESSION_AGENT" "extract-$kind" "$tty" "$entry" 2>/dev/null) || return 1
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

# session_list <group> — enumerate GROUP/ entries via the agent (pw stays inside it).
session_list() {
    local group="$1" tty out
    [[ "$GORILLA_SESSION_UNLOCK" == "true" && -x "$GORILLA_SESSION_AGENT" ]] || return 1
    tty=$(tty 2>/dev/null || echo no-tty)
    out=$("$GORILLA_SESSION_AGENT" list "$tty" "$group" 2>/dev/null) || return 1
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

# The gorilla ("monkey") art — duplicated from install.sh's top banner with the
# block-letter overlay stripped, kept inline so this lib has no art dependency.
_gorilla_art() {
    cat <<'BANNER'

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
      ⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⣿⣿⣿⣿⣿⣿⢁⣠⣶⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣾⣿⣿⣿⣆
     ⢠⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠟⣰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡀
    ⢀⡿⠁⣿⣿⣿⣿⣿⣿⣿⣿⠟⠁⣰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇
    ⣸⠃ ⣿⣿⣿⣿⣿⣿⣿⠃ ⠈⠛⠛⢻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣇⡀
    ⣿  ⣿⣿⣿⣿⣿⣿⣿ ⣾⣿⣿⣷⡀⠙⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠛⣡⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡅⠙⠳⢦⡀
   ⢰⡏  ⣿⣿⣿⣿⣿⣿⡇ ⣿⣿⣿⣿⣿⣶⣄⠈⠛⠿⢿⣿⡿⠿⠟⠋⣁⣴⣾⣿⡟⠁⠸⣿⣿⣿⣿⣿⣿⣿⣇  ⠈⣷
   ⢸⡇  ⣿⣿⣿⣿⣿⣿⠃ ⢿⣿⣿⣿⣿⣿⣿     ⣠⣴⣶⣿⣿⣿⣿⡏   ⠈⠙⢿⣿⣿⣿⣿⣿⣆  ⢸⡆
   ⣼⠇ ⢀⣿⣿⣿⣿⣿⠃  ⠸⣿⣿⣿⣿⣿⣿⡀    ⣿⣿⣿⣿⣿⣿⡿       ⠈⢿⣿⣿⣿⣿⣷⣦⣄⣷
   ⢻⣷⣶⣼⣿⣿⣿⣿⣧⡀   ⢿⣿⣿⣿⣿⣿⣿⣦ ⢀⣴⣿⣿⣿⣿⣿⣿⡇        ⣠⣿⣿⣿⣿⣿⣿⣿⣿⠆
    ⠻⠿⠿⢿⣿⣿⣿⣿⡿   ⠘⢿⣿⣿⣿⣿⣿⠇ ⢸⣿⣿⣿⣿⣿⣿⣿⠁       ⠸⠿⠿⢿⣿⣿⣿⣿⡿⠋

   s3c-gorilla · secrets from the vault into memory, not the disk
BANNER
}

# Shown before the terminal "KeePass master password:" prompt. Colorized via
# colorize.sh exactly like the installer; both paths write to stderr so tool
# stdout stays capturable.
show_master_banner() {
    if [[ -r "$GORILLA_COLORIZE" ]]; then
        _gorilla_art | zsh "$GORILLA_COLORIZE" -s 1 -e 24 >&2
    else
        _gorilla_art >&2
    fi
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
        printf "  Touch ID → tap your finger
" >&2
    fi
}

# Stop the background animation (and play the unlock flourish). Safe no-op if the
# animation never started.
stop_touchid() {
    command -v db_stop &>/dev/null && db_stop
}
