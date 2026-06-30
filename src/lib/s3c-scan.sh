#!/bin/bash
##########################################################################################
## s3c-scan.sh — exposure-audit scanner for `s3c-gorilla scan`.
## Sourced by s3c-gorilla.  REDACTION IS NON-NEGOTIABLE: this file reports a location +
## which pattern matched, and NEVER prints the matched secret bytes.
##   modes: --env (default) --ssh --git --shell-history --all
##########################################################################################

# Output helpers — fall back to plain ones if not sourced by s3c-gorilla (isolated tests).
command -v hdr >/dev/null 2>&1 || {
    C7=$'\033[38;5;177m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    hdr()    { printf "\n${C7}◆ %s${RESET}\n" "$1"; }
    ok()     { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
    warnln() { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }
    failln() { printf "  ${RED}✗${RESET} %s\n" "$1"; }
    note()   { printf "  ${DIM}· %s${RESET}\n" "$1"; }
}

# Secret-shape patterns — parallel indexed arrays (macOS /bin/bash 3.2 has no `declare -A`).
PAT_NAMES=( pem-private-key aws-access-key github-token github-pat slack-token jwt google-api stripe-key npm-token generic-secret )
PAT_REGEX=(
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'AKIA[0-9A-Z]{16}'
    'gh[ps]_[A-Za-z0-9]{36,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'
    'AIza[0-9A-Za-z_-]{35}'
    '[sr]k_live_[A-Za-z0-9]{16,}'
    '_authToken=[A-Za-z0-9+/=._-]{16,}'
    '(SECRET|PASSWORD|PASSWD|TOKEN|API_?KEY)["'"'"' ]*[:=][ "'"'"']*[A-Za-z0-9/+_=-]{12,}'
)

# GNU `stat -c` vs BSD/macOS `stat -f` are incompatible (and `-f` means filesystem-info
# on GNU), so detect once and branch — don't rely on `||` fallback.
if stat -c '%a' / >/dev/null 2>&1; then _STAT=gnu; else _STAT=bsd; fi
_mode()  { if [[ $_STAT == gnu ]]; then stat -c '%a' "$1" 2>/dev/null; else stat -f '%Lp' "$1" 2>/dev/null; fi; }
_size()  { if [[ $_STAT == gnu ]]; then stat -c '%s' "$1" 2>/dev/null; else stat -f '%z' "$1" 2>/dev/null; fi; }
_mtime() { if [[ $_STAT == gnu ]]; then stat -c '%y' "$1" 2>/dev/null | cut -d. -f1; else stat -f '%Sm' "$1" 2>/dev/null; fi; }

_scan_roots() {   # echo existing roots, one per line, de-duplicated
    local r
    {
        for r in "$HOME/Projects" "$HOME/Code" "$HOME/Workspaces" "$HOME/src"; do [[ -d "$r" ]] && echo "$r"; done
        if [[ -n "${GORILLA_SCAN_ROOTS:-}" ]]; then
            local IFS=':'
            for r in $GORILLA_SCAN_ROOTS; do [[ -d "$r" ]] && echo "$r"; done
        fi
    } | awk '!seen[$0]++'
}

scan_env() {
    hdr "scan --env (plaintext .env files)"
    local rc=0 any=false root f repo committed ignored
    while IFS= read -r root; do
        [[ -z "$root" ]] && continue
        while IFS= read -r -d '' f; do
            any=true
            repo=$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null)
            committed=false; ignored=false
            if [[ -n "$repo" ]]; then
                git -C "$repo" ls-files --error-unmatch "$f" >/dev/null 2>&1 && committed=true
                git -C "$repo" check-ignore -q "$f" 2>/dev/null && ignored=true
            fi
            if $committed; then failln "$f  ($(_size "$f")b, $(_mtime "$f")) — TRACKED IN GIT"; rc=1
            elif [[ -n "$repo" ]] && ! $ignored; then failln "$f  ($(_size "$f")b) — not .gitignore'd"; rc=1
            else warnln "$f  ($(_size "$f")b, $(_mtime "$f"))"; fi
        done < <(find "$root" -maxdepth 6 \
                     \( -type d \( -name node_modules -o -name .git -o -name vendor \) -prune \) -o \
                     \( -type f \( -name '.env' -o -name '.env.*' -o -name '*.env' \) \
                        ! -name '*.example' ! -name '*.sample' -print0 \) 2>/dev/null)
    done < <(_scan_roots)
    $any || ok "no plaintext .env found under scan roots"
    return $rc
}

scan_ssh() {
    hdr "scan --ssh (~/.ssh audit)"
    local rc=0 d="$HOME/.ssh" f m
    [[ -d "$d" ]] || { ok "no ~/.ssh directory"; return 0; }
    m=$(_mode "$d"); [[ "$m" == "700" ]] && ok "~/.ssh mode 0700" || warnln "~/.ssh mode $m (want 0700)"
    shopt -s nullglob
    for f in "$d"/*; do
        [[ -f "$f" ]] || continue
        head -1 "$f" 2>/dev/null | grep -q 'PRIVATE KEY' || continue
        m=$(_mode "$f")
        if [[ "$m" != "600" ]]; then
            # ssh-keygen refuses to read an over-permissive key, so we can't verify
            # encryption until perms are fixed — flag perms and move on (no false verdict).
            warnln "$(basename "$f") mode $m (want 0600) — fix perms, then re-scan to verify encryption"; rc=1; continue
        fi
        # 0600 → an empty passphrase succeeds ONLY on an unencrypted key (the probe env-gorilla uses).
        if ssh-keygen -y -P '' -f "$f" </dev/null >/dev/null 2>&1; then failln "$(basename "$f") — UNENCRYPTED private key"; rc=1
        else ok "$(basename "$f") — encrypted"; fi
    done
    if [[ -f "$d/known_hosts" ]] && grep -qvE '^\|1\|' "$d/known_hosts" 2>/dev/null; then
        warnln "known_hosts not fully hashed (set HashKnownHosts yes)"
    fi
    [[ -f "$d/config" ]] && { m=$(_mode "$d/config"); [[ "$m" == "600" ]] || warnln "~/.ssh/config mode $m (want 0600)"; }
    return $rc
}

scan_git() {
    hdr "scan --git (git history secret-shapes — REDACTED)"
    local rc=0 any=false root gd repo i hits h combined="" shown
    # One alternation of all patterns: a clean repo costs a single history walk (stops at
    # the first match), not one walk per pattern. Per-pattern attribution runs only on the
    # rare repos that actually match.
    for i in "${!PAT_REGEX[@]}"; do combined+="${combined:+|}(${PAT_REGEX[$i]})"; done
    while IFS= read -r root; do
        [[ -z "$root" ]] && continue
        while IFS= read -r -d '' gd; do
            repo=$(dirname "$gd")
            [[ -z "$(git -C "$repo" log --all -E -G"$combined" --format=%h -1 2>/dev/null)" ]] && continue
            shown=0
            for i in "${!PAT_NAMES[@]}"; do
                (( shown >= 3 )) && { note "$(basename "$repo"): capped at 3 pattern types — more may match"; break; }
                hits=$(git -C "$repo" log --all -E -G"${PAT_REGEX[$i]}" --format=%h 2>/dev/null | head -5)
                [[ -z "$hits" ]] && continue
                any=true; rc=1; shown=$((shown+1))
                while IFS= read -r h; do [[ -n "$h" ]] && failln "$(basename "$repo") @ $h — [REDACTED — ${PAT_NAMES[$i]}]"; done <<< "$hits"
            done
        done < <(find "$root" -maxdepth 4 -type d -name node_modules -prune -o -type d -name .git -print0 2>/dev/null)
    done < <(_scan_roots)
    $any || ok "no secret-shaped strings in git history"
    return $rc
}

# Redaction core: grep -n gives "<line>:<content>"; sed strips to the line NUMBER only,
# so the matched secret content is consumed and never reaches stdout.
_redact_lines() { sed -E 's/^([0-9]+):.*/\1/'; }

scan_shell_history() {
    hdr "scan --shell-history (REDACTED)"
    local rc=0 any=false hf i nums n
    local export_re='export [A-Z_]{3,}=.{0,4}[A-Za-z0-9/+=_-]{20,}'
    for hf in "$HOME/.zsh_history" "$HOME/.bash_history" "$HOME/.local/share/fish/fish_history"; do
        [[ -f "$hf" ]] || continue
        nums=$(grep -nE "$export_re" "$hf" 2>/dev/null | _redact_lines | head -20)
        if [[ -n "$nums" ]]; then any=true; rc=1; while IFS= read -r n; do failln "$hf:$n — [REDACTED — long-export]"; done <<< "$nums"; fi
        for i in "${!PAT_NAMES[@]}"; do
            nums=$(grep -nE "${PAT_REGEX[$i]}" "$hf" 2>/dev/null | _redact_lines | head -20)
            [[ -z "$nums" ]] && continue
            any=true; rc=1
            while IFS= read -r n; do failln "$hf:$n — [REDACTED — ${PAT_NAMES[$i]}]"; done <<< "$nums"
        done
    done
    $any || ok "no secrets in shell history"
    return $rc
}

cmd_scan() {
    case "${1:---env}" in
        --env|"")        scan_env ;;
        --ssh)           scan_ssh ;;
        --git)           scan_git ;;
        --shell-history) scan_shell_history ;;
        --all)
            local rc=0
            scan_env || rc=1; scan_ssh || rc=1; scan_git || rc=1; scan_shell_history || rc=1
            return $rc ;;
        *) echo "usage: s3c-gorilla scan [--env|--ssh|--git|--shell-history|--all]" >&2; return 2 ;;
    esac
}
