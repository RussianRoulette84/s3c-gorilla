#!/bin/bash
# s3c-infisical.sh — optional bridge: sync a project's .env between the KeePassXC vault and a
# (self-hosted) Infisical instance. Sourced by env-gorilla; relies on its helpers (kdbx_extract_env,
# get_master_pw, _env_load_tmp, _env_write, _env_cleanup_tmp, $MASTER_PW, $ENV_TMP).
#
# CONNECTION lives inside the project's OWN .env, under a `# Infisical` block (config, never
# pushed as a secret):
#   INFISICAL_API_URL / INFISICAL_CLIENT_ID / INFISICAL_CLIENT_SECRET / INFISICAL_PROJECT_ID
#   [INFISICAL_ENV=prod]      (the INFISCAL_ typo spelling is tolerated)
# push/pull/sync operate on the OTHER keys only. Nothing is hardcoded.

# --- .env text helpers (bash 3.2 safe — no associative arrays) ---
# real secret KEY names (skip comments/blanks and the INFISICAL_* connection block)
_env_keys() { printf '%s\n' "$1" | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | cut -d= -f1 | grep -Ev '^(INFISICAL_|INFISCAL_)'; }
# value of KEY ($2) in env text ($1): first match, everything after the first '='
_env_val()  { printf '%s\n' "$1" | grep "^$2=" | head -1 | cut -d= -f2-; }
_env_has()  { printf '%s\n' "$1" | grep -q "^$2="; }
# replace the "$2=" line in $ENV_TMP with "$3" (awk keyed on the pre-'=' field → value '='s are safe)
_env_replace() { awk -v k="$2" -v repl="$3" 'BEGIN{FS="="} ($1==k && index($0,"=")>0){print repl; next} {print}' "$1" > "$1.n" && mv "$1.n" "$1"; }

# --- connection block → globals INF_URL/INF_CID/INF_SECRET/INF_PID/INF_ENV ---
_inf_parse() {
    local e="$1"
    INF_URL=$(_env_val "$e" INFISICAL_API_URL)
    INF_CID=$(_env_val "$e" INFISICAL_CLIENT_ID)
    INF_SECRET=$(_env_val "$e" INFISICAL_CLIENT_SECRET)
    INF_PID=$(_env_val "$e" INFISICAL_PROJECT_ID); [[ -z "$INF_PID" ]] && INF_PID=$(_env_val "$e" INFISCAL_PROJECT_ID)
    INF_ENV=$(_env_val "$e" INFISICAL_ENV); [[ -z "$INF_ENV" ]] && INF_ENV=$(_env_val "$e" INFISCAL_ENV); [[ -z "$INF_ENV" ]] && INF_ENV="prod"
    if [[ -z "$INF_URL" || -z "$INF_CID" || -z "$INF_SECRET" || -z "$INF_PID" ]]; then
        echo "env-gorilla: this project's .env has no # Infisical block (need INFISICAL_API_URL / CLIENT_ID / CLIENT_SECRET / PROJECT_ID). Add it with: env-gorilla edit <project>" >&2
        return 1
    fi
}

# exchange the machine-identity creds for a session token (creds via env, never argv → no ps leak)
_inf_token() {
    export INFISICAL_DOMAIN="$INF_URL" INFISICAL_API_URL="$INF_URL"
    INFISICAL_TOKEN=$(INFISICAL_UNIVERSAL_AUTH_CLIENT_ID="$INF_CID" INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET="$INF_SECRET" \
        infisical login --method=universal-auth --domain "$INF_URL" --plain --silent 2>/dev/null)
    export INFISICAL_TOKEN
    [[ -n "$INFISICAL_TOKEN" ]] || { echo "env-gorilla: Infisical login failed — check the # Infisical creds/URL in this project's .env" >&2; return 1; }
}

# remote secrets as KEY=VALUE lines (a .env view of the Infisical project/env)
_inf_remote() { infisical export --format=dotenv --projectId "$INF_PID" --env "$INF_ENV" --domain "$INF_URL" 2>/dev/null; }

_inf_confirm() {   # $1 verb, $2 key, $3 left, $4 right → 0 to apply
    local ans
    printf 'conflict on %s:\n    %s\n    %s\n  apply %s? [y/N] ' "$2" "$3" "$4" "$1" >/dev/tty
    read -r ans </dev/tty; [[ "$ans" =~ ^[Yy]$ ]]
}

# push: local → remote. adds local-only keys; on value conflict prompts (force ⇒ local wins).
_inf_push() {
    local proj="$1" L="$2" R="$3" force="$4" k lv rv; local -a toset=()
    for k in $(_env_keys "$L"); do
        lv=$(_env_val "$L" "$k")
        if ! _env_has "$R" "$k"; then toset+=("$k=$lv")
        else rv=$(_env_val "$R" "$k"); [[ "$lv" == "$rv" ]] && continue
            if $force || _inf_confirm "push (overwrite remote)" "$k" "local=$lv" "remote=$rv"; then toset+=("$k=$lv"); fi
        fi
    done
    (( ${#toset[@]} == 0 )) && { echo "env-gorilla: nothing to push — remote already matches" >&2; return 0; }
    if infisical secrets set "${toset[@]}" --projectId "$INF_PID" --env "$INF_ENV" --domain "$INF_URL" >/dev/null 2>&1; then
        echo "env-gorilla: pushed ${#toset[@]} key(s) → Infisical ($proj/$INF_ENV)" >&2
    else echo "env-gorilla: 'infisical secrets set' failed" >&2; return 1; fi
}

# pull: remote → local .env (upsert; preserves comments, the # Infisical block, and local-only keys).
_inf_pull() {
    local proj="$1" L="$2" R="$3" force="$4" k lv rv changed=0
    for k in $(_env_keys "$R"); do
        rv=$(_env_val "$R" "$k")
        if ! _env_has "$L" "$k"; then printf '%s\n' "$k=$rv" >> "$ENV_TMP"; changed=1
        else lv=$(_env_val "$L" "$k"); [[ "$lv" == "$rv" ]] && continue
            if $force || _inf_confirm "pull (overwrite local)" "$k" "local=$lv" "remote=$rv"; then _env_replace "$ENV_TMP" "$k" "$k=$rv"; changed=1; fi
        fi
    done
    (( changed )) && { _env_write "$proj" "$ENV_TMP" && echo "env-gorilla: pulled Infisical → $proj/.env" >&2; } \
                   || echo "env-gorilla: nothing to pull — local already matches" >&2
}

# sync: local-only → push, remote-only → pull, value conflict → prompt (force ⇒ remote wins).
_inf_sync() {
    local proj="$1" L="$2" R="$3" force="$4" k lv rv changed=0; local -a toset=()
    for k in $(printf '%s\n%s\n' "$(_env_keys "$L")" "$(_env_keys "$R")" | sort -u); do
        lv=$(_env_val "$L" "$k"); rv=$(_env_val "$R" "$k")
        if _env_has "$L" "$k" && ! _env_has "$R" "$k"; then toset+=("$k=$lv")
        elif _env_has "$R" "$k" && ! _env_has "$L" "$k"; then printf '%s\n' "$k=$rv" >> "$ENV_TMP"; changed=1
        elif [[ "$lv" != "$rv" ]]; then
            if $force; then _env_replace "$ENV_TMP" "$k" "$k=$rv"; changed=1
            else
                printf 'conflict on %s:  local=%s  remote=%s\n  [l]ocal→push / [r]emote→pull / [s]kip: ' "$k" "$lv" "$rv" >/dev/tty
                local ans; read -r ans </dev/tty
                case "$ans" in l|L) toset+=("$k=$lv") ;; r|R) _env_replace "$ENV_TMP" "$k" "$k=$rv"; changed=1 ;; esac
            fi
        fi
    done
    (( changed )) && _env_write "$proj" "$ENV_TMP"
    (( ${#toset[@]} > 0 )) && { infisical secrets set "${toset[@]}" --projectId "$INF_PID" --env "$INF_ENV" --domain "$INF_URL" >/dev/null 2>&1 \
        && echo "env-gorilla: sync pushed ${#toset[@]} key(s)" >&2; }
    echo "env-gorilla: sync done ($proj/$INF_ENV)" >&2
}

# entry point from env-gorilla: cmd_infisical <push|pull|sync> <project> [--force-infisical]
cmd_infisical() {
    local op="$1" proj="$2" force=false; shift 2 2>/dev/null || true
    local a; for a in "$@"; do case "$a" in --force|--force-infisical) force=true ;; esac; done
    [[ -n "$op" && -n "$proj" ]] || { echo "usage: env-gorilla $op <project> [--force-infisical]" >&2; return 2; }
    [[ "${GORILLA_INFISICAL_ENABLED:-false}" == "true" ]] || { echo "env-gorilla: Infisical support is off — enable it by re-running install.sh (or set GORILLA_INFISICAL_ENABLED=true)" >&2; return 1; }
    command -v infisical >/dev/null 2>&1 || { echo "env-gorilla: infisical CLI not found — brew install infisical/get-cli/infisical" >&2; return 1; }
    echo "env-gorilla: tip — run 's3c-gorilla backup' before pull/sync (it rewrites your vault .env)" >&2
    _env_load_tmp "$proj" || return 1
    local L; L=$(cat "$ENV_TMP")
    if ! _inf_parse "$L" || ! _inf_token; then _env_cleanup_tmp; return 1; fi
    local R; R=$(_inf_remote)
    if [[ -z "$R" ]] && ! infisical secrets --projectId "$INF_PID" --env "$INF_ENV" --domain "$INF_URL" >/dev/null 2>&1; then
        echo "env-gorilla: could not reach Infisical or read the project — check network/projectId/env" >&2; _env_cleanup_tmp; return 1
    fi
    case "$op" in
        push) _inf_push "$proj" "$L" "$R" "$force" ;;
        pull) _inf_pull "$proj" "$L" "$R" "$force" ;;
        sync) _inf_sync "$proj" "$L" "$R" "$force" ;;
        *) echo "env-gorilla: unknown infisical op '$op'" >&2; _env_cleanup_tmp; return 2 ;;
    esac
    local rc=$?
    _env_cleanup_tmp
    return $rc
}
