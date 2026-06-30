#!/bin/bash
##########################################################################################
## s3c-keychain.sh — migrate Apple Keychain creds into the kdbx. Sourced by s3c-gorilla.
## macOS only (uses `security`). REDACTION: check/fix never read or print secret values;
## only `import` reads one value, and pipes it (never echoes it).
##   modes: check (default) · fix · import <service>
##########################################################################################

command -v hdr >/dev/null 2>&1 || {
    C7=$'\033[38;5;177m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    hdr()    { printf "\n${C7}◆ %s${RESET}\n" "$1"; }
    ok()     { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
    warnln() { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }
    failln() { printf "  ${RED}✗${RESET} %s\n" "$1"; }
    note()   { printf "  ${DIM}· %s${RESET}\n" "$1"; }
}
: "${GORILLA_DB:=$HOME/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx}"

# Categorize an item by its label+service text → git|ssh|cloud|kdbx, or "" if not migratable.
_kc_categorize() {
    local h; h=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$h" in
        *github.com*|*gitlab*|*bitbucket*|*codeberg*|*gitea*) echo git ;;
        *com.apple.ssh.passphrases*|*com.openssh.ssh-agent*) echo ssh ;;
        *"amazon web services"*|*com.google.cloudsdk*|*azurecloud*|*anthropic*|*openai*|*aws*) echo cloud ;;
        *keepassxc*|*keepass*) echo kdbx ;;
        *git*) echo git ;;
        *) echo "" ;;
    esac
}

# Emit "category<TAB>label<TAB>service<TAB>class" per migratable item from dump-keychain.
# `class` is genp|inet → picks the right delete command later. No passwords are read.
_kc_scan() {
    security dump-keychain 2>/dev/null | awk '
        function val(line,   s) { s=line; sub(/.*="/, "", s); sub(/"$/, "", s); return s }
        function clsval(line,  s) { s=line; sub(/.*: "/, "", s); sub(/".*/, "", s); return s }
        function flush() {
            if (label != "" || svce != "" || srvr != "")
                printf "%s\t%s\t%s\t%s\n", label, (srvr != "" ? srvr : svce), acct, cls
            label=""; svce=""; srvr=""; acct=""
        }
        /^class:/             { flush(); cls=clsval($0) }
        /0x00000007 <blob>=/  { label=val($0) }
        /"svce"<blob>=/       { svce=val($0) }
        /"srvr"<blob>=/       { srvr=val($0) }
        /"acct"<blob>=/       { acct=val($0) }
        END { flush() }
    ' | while IFS=$'\t' read -r label svc acct cls; do
        local cat; cat=$(_kc_categorize "$label $svc")
        [[ -n "$cat" ]] && printf '%s\t%s\t%s\t%s\n' "$cat" "$label" "$svc" "$cls"
    done
}

keychain_check() {
    command -v security >/dev/null 2>&1 || { note "macOS only (no 'security' command)"; return 0; }
    hdr "keychain check (creds that belong in the kdbx)"
    # dump-keychain text format varies by macOS version; if we can't even read it, say so
    # plainly rather than implying a clean Keychain (#11).
    if ! security dump-keychain >/dev/null 2>&1; then
        warnln "couldn't read the Keychain (locked / access denied?) — nothing scanned"; return 0
    fi
    local n=0 cat label svc cls
    while IFS=$'\t' read -r cat label svc cls; do
        [[ -z "$cat" ]] && continue
        n=$((n + 1))
        failln "[$cat] ${label:-?}  (${svc:-?}) — move to kdbx, then 's3c-gorilla keychain fix'"
    done < <(_kc_scan)
    [[ $n -eq 0 ]] && { ok "nothing in the Keychain that should be in the kdbx"; return 0; }
    note "$n item(s) found. No secret values were read."
    return 1
}

keychain_fix() {
    command -v security >/dev/null 2>&1 || { note "macOS only"; return 0; }
    command -v keepassxc-cli >/dev/null 2>&1 || { failln "keepassxc-cli not found"; return 1; }
    hdr "keychain fix (interactive — explicit y/N per delete)"
    local pw; printf '  🔐 KeePass master password (to verify entries exist): '; read -rs pw; echo
    # Basenames of every kdbx entry — we require an EXACT match before offering a delete, so a
    # coincidental substring can never delete a Keychain item that isn't actually backed up (#2).
    local kdbx; kdbx=$(echo "$pw" | keepassxc-cli ls "$GORILLA_DB" -R -q 2>/dev/null | sed 's#.*/##')
    local migrated=0 left=0 cat label svc cls
    while IFS=$'\t' read -r cat label svc cls; do
        [[ -z "$cat" ]] && continue
        printf '\n  [%s] %s (%s)\n' "$cat" "$label" "$svc"
        if printf '%s\n' "$kdbx" | grep -qxF "$svc" 2>/dev/null; then
            printf '    in kdbx ✓ — '; read -p "delete the Keychain copy? [y/N] " -n 1 -r; echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                if [[ "$cls" == "inet" ]]; then security delete-internet-password -s "$svc" >/dev/null 2>&1
                else security delete-generic-password -s "$svc" >/dev/null 2>&1; fi
                ok "deleted from Keychain"; migrated=$((migrated + 1))
            else left=$((left + 1)); fi
        else
            warnln "not found in kdbx — add it first (skipping, nothing deleted)"; left=$((left + 1))
        fi
    done < <(_kc_scan)
    unset pw
    note "$migrated removed from Keychain, $left left"
    return 0
}

keychain_import() {
    local svc="$1"
    [[ -n "$svc" ]] || { echo "usage: s3c-gorilla keychain import <service>" >&2; return 2; }
    command -v security >/dev/null 2>&1 || { note "macOS only"; return 0; }
    command -v keepassxc-cli >/dev/null 2>&1 || { failln "keepassxc-cli not found"; return 1; }
    hdr "keychain import: $svc"
    local val
    val=$(security find-internet-password -s "$svc" -w 2>/dev/null) \
        || val=$(security find-generic-password -s "$svc" -w 2>/dev/null)
    [[ -n "$val" ]] || { failln "no Keychain item for service '$svc'"; return 1; }
    local pw; printf '  🔐 KeePass master password: '; read -rs pw; echo
    printf '%s\n' "$pw" | keepassxc-cli mkdir "$GORILLA_DB" "Imported" -q &>/dev/null || true   # ensure group exists (#5)
    local entry="Imported/$svc"
    # db password on the first stdin line, entry password on the second (-p reads it). The
    # secret value is piped, never printed.
    if printf '%s\n%s\n' "$pw" "$val" | keepassxc-cli add "$GORILLA_DB" "$entry" -p -q >/dev/null 2>&1; then
        ok "imported into kdbx: $entry"
    else failln "failed to write $entry to the kdbx"; unset pw val; return 1; fi
    unset pw val
    read -p "  delete the Keychain copy now? [y/N] " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        security delete-internet-password -s "$svc" >/dev/null 2>&1 \
            || security delete-generic-password -s "$svc" >/dev/null 2>&1
        ok "deleted from Keychain"
    fi
    return 0
}

cmd_keychain() {
    case "${1:-check}" in
        check|"") keychain_check ;;
        fix)      keychain_fix ;;
        import)   shift; keychain_import "$@" ;;
        *) echo "usage: s3c-gorilla keychain [check|fix|import <service>]" >&2; return 2 ;;
    esac
}
