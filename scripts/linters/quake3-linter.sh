#!/bin/sh
# lint.sh — Q3IDE code linter
#
# Checks:
#   q3ide/   — clang-format, cppcheck, file length, prefix, USE_Q3IDE guards
#   quake3e/ — modified files: USE_Q3IDE guard coverage only
#   q3ide-capture/ — Rust: no unsafe outside lib.rs, limit .unwrap()
#
# Flags:
#   --cppcheck   slow static analysis (q3ide/ only)
#   --swift      SwiftLint + swift build (q3ide-metal/ only)
#   --no-pk3     skip baseq3/*.pk3 conflict scan (runs by default)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
Q3IDE_DIR="$ROOT/quake3e/code/q3ide"

RUN_CPPCHECK=0
RUN_SWIFT=0
RUN_PK3=1
for arg in "$@"; do
    [ "$arg" = "--cppcheck" ] && RUN_CPPCHECK=1
    [ "$arg" = "--swift" ]    && RUN_SWIFT=1
    [ "$arg" = "--no-pk3" ]   && RUN_PK3=0
done

ERRORS=0
WARNINGS=0
ERROR_FILES=""

# ─── colors ───────────────────────────────────────────────────────────────────
_RED=$'\033[31m'; _YEL=$'\033[33m'; _GRN=$'\033[32m'; _CYN=$'\033[36m'
_BLD=$'\033[1m';  _DIM=$'\033[2m';  _R0=$'\033[0m'
_ORG=$'\033[38;5;208m'

err()  { printf "${_RED}${_BLD}[ERR]${_R0}  %s\n" "$*"; ERRORS=$((ERRORS+1)); }
warn() { printf "${_YEL}[WRN]${_R0}  %s\n"        "$*"; WARNINGS=$((WARNINGS+1)); }
ok()   { printf "${_GRN}[ OK ]${_R0} %s\n"         "$*"; }
info() { printf "${_DIM}[   ]  %s${_R0}\n"         "$*"; }
hdr()  { printf "\n${_CYN}${_BLD}-- %s --${_R0}\n" "$*"; }

rel()  { echo "${1#$ROOT/}"; }
trim() { echo "$1" | tr -d ' \t'; }

# ─── clang-format (q3ide/ only) ───────────────────────────────────────────────

run_clang_format() {
    hdr "clang-format (q3ide/ only)"

    if ! command -v clang-format >/dev/null 2>&1; then
        info "skipped — clang-format not available (brew install clang-format)"
        return
    fi

    for f in "$Q3IDE_DIR"/*.c "$Q3IDE_DIR"/*.h; do
        [ -f "$f" ] || continue
        local r; r="$(rel "$f")"
        local lines; lines=$(trim "$(wc -l < "$f")")
        local violations; violations="$(clang-format --dry-run "$f" 2>/dev/null)"
        if [ -n "$violations" ]; then
            warn "$r [${lines}L]: clang-format violations (fix: clang-format -i $r)"
            echo "$violations" | head -6 | while IFS= read -r line; do info "  $line"; done
        else
            ok "$r [${lines}L]"
        fi
    done
}

# ─── cppcheck (q3ide/ only) ───────────────────────────────────────────────────

run_cppcheck() {
    hdr "cppcheck (q3ide/ only)"

    if ! command -v cppcheck >/dev/null 2>&1; then
        info "skipped — cppcheck not available (brew install cppcheck)"
        return
    fi

    local any_issues=0
    for f in "$Q3IDE_DIR"/*.c; do
        [ -f "$f" ] || continue
        local r; r="$(rel "$f")"
        printf '[...] %s\n' "$r"

        local out
        out="$(cppcheck \
            --enable=warning \
            --suppress=missingInclude \
            --suppress=missingIncludeSystem \
            --suppress=unusedFunction \
            --error-exitcode=0 \
            --quiet \
            "$f" 2>&1)"

        if [ -n "$out" ]; then
            printf '%-60s\n' " "
            echo "$out" | while IFS= read -r line; do info "  $line"; done
            warn "$r: cppcheck issues"
            any_issues=1
        fi
    done
    [ "$any_issues" -eq 0 ] && ok "q3ide/ — no issues"
}

# ─── basic checks: file length + prefix (q3ide/ only) ────────────────────────

run_basic_checks() {
    hdr "basic checks (q3ide/ only)"

    local found=0 any_issues=0
    local _tmp; _tmp="$(mktemp)"

    # Collect eligible files with line counts, sort descending by size
    for f in "$Q3IDE_DIR"/*.c "$Q3IDE_DIR"/*.h; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            q3ide_params.h|q3ide_win_mngr_internal.h|q3ide_overlay_keys.h) continue ;;
        esac
        local lines; lines=$(trim "$(wc -l < "$f")")
        echo "$lines $f"
    done | sort -rn > "$_tmp"

    while IFS=' ' read -r lines f; do
        found=1
        local r; r="$(rel "$f")"

        if [ "$lines" -gt 400 ]; then
            err "$r: $lines lines (max 400 — split this file)"
            ERROR_FILES="${ERROR_FILES}  too-long: $r (${lines}L)\n"
            any_issues=1
        elif [ "$lines" -gt 200 ]; then
            warn "$r: $lines lines (sweet-spot 200)"
            any_issues=1
        fi

        grep -n "^[a-zA-Z_][a-zA-Z0-9_ *]*  *[a-zA-Z_][a-zA-Z0-9_]* *(" "$f" 2>/dev/null | \
            grep -v "static " | \
            grep -v "^[0-9]*:#" | \
            grep -v "q3ide_\|Q3IDE_\|FBO_\|GLimp_\|RE_\|RB_\|R_" | \
            while IFS=: read -r n line; do
                warn "$r:$n: public symbol may lack q3ide_/Q3IDE_ prefix"
            done
    done < "$_tmp"
    rm -f "$_tmp"

    [ "$found" -eq 0 ] && info "no files"
    [ "$any_issues" -eq 0 ] && [ "$found" -gt 0 ] && ok "all files within size limits"

    # Every .c must include q3ide_core.h
    local missing_core=0
    for f in "$Q3IDE_DIR"/*.c; do
        [ -f "$f" ] || continue
        if ! grep -q '#include "q3ide_core.h"' "$f"; then
            warn "$(rel "$f"): missing #include \"q3ide_core.h\""
            missing_core=1
            any_issues=1
        fi
    done
    [ "$missing_core" -eq 0 ] && ok "all .c files include q3ide_core.h"
}

# ─── Makefile sync check (q3ide/ .c vs quake3e/Makefile) ────────────────────

run_makefile_checks() {
    hdr "Makefile sync (q3ide/ .c files)"

    local MAKEFILE="$ROOT/quake3e/Makefile"
    if [ ! -f "$MAKEFILE" ]; then
        info "skipped — quake3e/Makefile not found"
        return
    fi

    local any_issues=0
    for f in "$Q3IDE_DIR"/*.c; do
        [ -f "$f" ] || continue
        local base; base="$(basename "$f" .c)"
        local obj="${base}.o"
        if ! grep -q "$obj" "$MAKEFILE"; then
            err "quake3e/Makefile: missing entry for $obj ($(rel "$f"))"
            ERROR_FILES="${ERROR_FILES}  makefile-missing: $obj\n"
            any_issues=1
        fi
    done

    # Also check for stale .o entries pointing to non-existent .c files
    grep -o 'q3ide_[a-z_]*\.o' "$MAKEFILE" | sort -u | while read -r obj; do
        local base; base="${obj%.o}"
        if [ ! -f "$Q3IDE_DIR/${base}.c" ]; then
            warn "quake3e/Makefile: stale entry $obj — no matching ${base}.c"
        fi
    done

    [ "$any_issues" -eq 0 ] && ok "all q3ide/ .c files registered in Makefile"
}

# ─── autoexec.cfg bind orphans ───────────────────────────────────────────────

run_bind_checks() {
    hdr "autoexec.cfg bind orphans"

    local CFG="$ROOT/baseq3/autoexec.cfg"
    if [ ! -f "$CFG" ]; then
        info "skipped — baseq3/autoexec.cfg not found"
        return
    fi

    local any_issues=0
    while IFS= read -r line; do
        # match: bind KEY "cmd ..." or bind KEY cmd
        case "$line" in bind\ *) ;; *) continue ;; esac
        # extract command: third token, strip quotes
        cmd="$(echo "$line" | sed 's/^bind[[:space:]]*[^[:space:]]*[[:space:]]*//' | tr -d '"' | awk '{print $1}')"
        # only check q3ide commands
        case "$cmd" in q3ide*|+q3ide*|-q3ide*) ;; *) continue ;; esac
        if ! grep -rq "Cmd_AddCommand(\"${cmd}\"" "$ROOT/quake3e/code/q3ide/" 2>/dev/null; then
            warn "autoexec.cfg: bind references unknown command \"$cmd\""
            any_issues=1
        fi
    done < "$CFG"

    [ "$any_issues" -eq 0 ] && ok "all q3ide binds have registered commands"
}

# ─── q3ide_params.h duplicate defines ────────────────────────────────────────

run_params_checks() {
    hdr "q3ide_params.h integrity"

    local PARAMS="$ROOT/quake3e/code/q3ide/q3ide_params.h"
    if [ ! -f "$PARAMS" ]; then
        info "skipped — q3ide_params.h not found"
        return
    fi

    local any_issues=0

    # 1. Duplicate #define names across all params headers
    local dups
    dups="$(grep -h '^#define Q3IDE_' \
        "$ROOT/quake3e/code/q3ide/q3ide_params.h" \
        "$ROOT/quake3e/code/q3ide/q3ide_params_windows.h" \
        "$ROOT/quake3e/code/q3ide/q3ide_params_theme.h" 2>/dev/null \
        | awk '{print $2}' | sort | uniq -d)"
    if [ -n "$dups" ]; then
        echo "$dups" | while IFS= read -r name; do
            err "q3ide_params.h: duplicate define $name"
            ERROR_FILES="${ERROR_FILES}  dup-define: $name\n"
        done
        any_issues=1
    fi

    # 2. Unused constants (zero references outside the params headers themselves)
    local unused=0
    # Build list of names annotated with their line context (to detect NOT USED markers)
    local _ptmp; _ptmp="$(mktemp)"
    for ph in "$ROOT/quake3e/code/q3ide/q3ide_params.h" \
              "$ROOT/quake3e/code/q3ide/q3ide_params_windows.h" \
              "$ROOT/quake3e/code/q3ide/q3ide_params_theme.h"; do
        [ -f "$ph" ] || continue
        awk '
            /^#define Q3IDE_/ {
                name = $2
                # check current line and previous line for NOT USED marker
                if (prev ~ /NOT USED/ || $0 ~ /NOT USED/) next
                print name
            }
            { prev = $0 }
        ' "$ph" >> "$_ptmp"
    done

    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local hits
        hits="$(grep -rl "\b${name}\b" \
            "$ROOT/quake3e/code/q3ide/" \
            "$ROOT/q3ide-metal/Sources/" 2>/dev/null \
            | grep -v 'q3ide_params' | wc -l | tr -d ' ')"
        if [ "${hits:-0}" -eq 0 ]; then
            warn "q3ide_params.h: $name defined but never used (add /* NOT USED */ to silence)"
            unused=1
            any_issues=1
        fi
    done < "$_ptmp"
    rm -f "$_ptmp"

    [ "$any_issues" -eq 0 ] && ok "q3ide_params.h — no duplicates, all constants used"
}

# ─── Makefile stale compile rules ────────────────────────────────────────────

run_makefile_rule_checks() {
    hdr "Makefile stale compile rules"

    local MAKEFILE="$ROOT/quake3e/Makefile"
    if [ ! -f "$MAKEFILE" ]; then
        info "skipped — quake3e/Makefile not found"
        return
    fi

    local any_issues=0

    # Extract all q3ide .o names that have a compile rule (lines matching /client/foo.o:)
    grep -o '/client/q3ide_[a-z_]*\.o:' "$MAKEFILE" | tr -d ':' | sed 's|.*/||' | sort -u | while read -r obj; do
        # Check it also appears in a non-rule line (object list entry — no colon after .o)
        if ! grep -v "\.o:" "$MAKEFILE" | grep -q "$obj"; then
            warn "quake3e/Makefile: compile rule for $obj exists but $obj not in object list"
            any_issues=1
        fi
    done

    [ "$any_issues" -eq 0 ] && ok "all compile rules have matching object list entries"
}

# ─── USE_Q3IDE guard check (modified Quake3e files only) ─────────────────────

run_guard_checks() {
    hdr "USE_Q3IDE guards (modified Quake3e files)"

    local MODIFIED="
        quake3e/code/client/cl_cgame.c
        quake3e/code/client/cl_main.c
        quake3e/code/client/cl_console.c
        quake3e/code/sdl/sdl_glimp.c
        quake3e/code/renderer/tr_backend.c
        quake3e/code/renderer/tr_arb.c
        quake3e/code/renderer/tr_local.h
        quake3e/code/renderer/tr_init.c
        quake3e/code/renderer/tr_scene.c
        quake3e/code/renderervk/tr_backend.c
        quake3e/code/renderervk/tr_init.c
        quake3e/code/renderervk/tr_scene.c
        quake3e/code/renderervk/vk.c
        quake3e/code/renderercommon/tr_public.h
    "

    local found=0 any_issues=0
    for rel_path in $MODIFIED; do
        local f="$ROOT/$rel_path"
        [ -f "$f" ] || continue
        found=1

        grep -q "Q3IDE_\|GLimp_CopyToSideWindow\|GLimp_SideWindow\|GLimp_SideYaw\|copyToSideCommand_t\|RC_COPY_TO_SIDE\|FBO_ResolveToBackBuffer" "$f" 2>/dev/null || continue

        local unguarded
        unguarded="$(awk '
            /^#if(def|ndef)?[[:space:]]/ || /^#if[[:space:]]/ {
                top++
                is_q3ide[top] = ($0 ~ /USE_Q3IDE/) ? 1 : 0
                if (is_q3ide[top]) q3ide++
                next
            }
            /^#endif/ {
                if (top > 0) {
                    if (is_q3ide[top]) q3ide--
                    delete is_q3ide[top]
                    top--
                }
                next
            }
            /^(void|int|float|static)[[:space:]].*GLimp_/ { next }
            /^[[:space:]]*(\/\/|\*)/ { next }
            /Q3IDE_|GLimp_CopyToSideWindow|GLimp_SideWindow|GLimp_SideYaw|copyToSideCommand_t|RC_COPY_TO_SIDE|FBO_ResolveToBackBuffer/ {
                if (q3ide == 0) { count++; print NR": "$0 > "/tmp/q3ide_lint_guards" }
            }
            END { print count+0 }
        ' "$f")"

        if [ "${unguarded:-0}" -gt 0 ]; then
            err "$rel_path: ${unguarded} Q3IDE reference(s) outside #ifdef USE_Q3IDE"
            while IFS= read -r line; do info "  $line"; done < /tmp/q3ide_lint_guards
            ERROR_FILES="${ERROR_FILES}  guard: $rel_path\n"
            any_issues=1
        fi
    done
    [ "$found" -eq 0 ] && info "no files"
    [ "$any_issues" -eq 0 ] && [ "$found" -gt 0 ] && ok "all guards in place"
}

# ─── Rust basic checks (capture/) ────────────────────────────────────────────

run_rust_checks() {
    hdr "q3ide-capture/ Rust (basic)"

    local found=0 any_issues=0
    for f in "$ROOT"/q3ide-capture/src/*.rs; do
        [ -f "$f" ] || continue
        found=1
        local r; r="$(rel "$f")"
        local base; base="$(basename "$f")"

        if [ "$base" != "lib.rs" ]; then
            local nu
            nu="$(grep -c "\bunsafe\b" "$f" 2>/dev/null || true)"
            if [ "${nu:-0}" -gt 0 ]; then
                err "$r: ${nu} unsafe block(s) outside C-ABI boundary (lib.rs)"
                ERROR_FILES="${ERROR_FILES}  unsafe: $r\n"
                any_issues=1
            fi
        fi

        local u
        u="$(grep -c "\.unwrap()" "$f" 2>/dev/null || true)"
        [ "${u:-0}" -gt 3 ] && warn "$r: ${u} .unwrap() calls — prefer ? or .expect()"
    done
    [ "$found" -eq 0 ] && info "no files"
    [ "$any_issues" -eq 0 ] && [ "$found" -gt 0 ] && ok "no unsafe outside lib.rs"

    # cargo check — catches dead_code, type errors, and all compiler warnings.
    # Only runs on macOS (crate requires ScreenCaptureKit framework).
    hdr "q3ide-capture/ Rust (cargo check)"
    if [ "$(uname -s)" != "Darwin" ]; then
        info "skipped — cargo check requires macOS (ScreenCaptureKit)"
        return
    fi
    # Rustup installs cargo to ~/.cargo/bin which may not be in a non-login PATH.
    if ! command -v cargo >/dev/null 2>&1; then
        if [ -f "$HOME/.cargo/env" ]; then
            # shellcheck source=/dev/null
            . "$HOME/.cargo/env"
        elif [ -x "$HOME/.cargo/bin/cargo" ]; then
            export PATH="$HOME/.cargo/bin:$PATH"
        fi
    fi
    if ! command -v cargo >/dev/null 2>&1; then
        info "skipped — cargo not found (install via rustup.rs)"
        return
    fi

    local cargo_out
    cargo_out="$(cd "$ROOT/q3ide-capture" && cargo check 2>&1)"
    local cargo_exit=$?

    # Report each warning/error line
    local had_warn=0 had_err=0
    while IFS= read -r line; do
        case "$line" in
            *"warning:"*) warn "cargo: $line"; had_warn=1 ;;
            *"error["*|*"error:"*) err "cargo: $line"; had_err=1; any_issues=1
                ERROR_FILES="${ERROR_FILES}  cargo-error\n" ;;
        esac
    done <<EOF
$cargo_out
EOF

    if [ "$cargo_exit" -ne 0 ] && [ "$had_err" -eq 0 ]; then
        err "cargo check failed (exit $cargo_exit)"
        ERROR_FILES="${ERROR_FILES}  cargo-check\n"
    elif [ "$had_warn" -eq 0 ] && [ "$had_err" -eq 0 ]; then
        ok "cargo check — clean"
    fi
}

# ─── Swift checks (q3ide-metal/Sources/) ─────────────────────────────────────

run_swift_checks() {
    local SWIFT_SRC="$ROOT/q3ide-metal/Sources"
    local found=0 any_issues=0

    hdr "q3ide-metal/ Swift (file lengths)"
    for f in "$SWIFT_SRC"/*.swift "$SWIFT_SRC"/UML/*.swift; do
        [ -f "$f" ] || continue
        found=1
        local r; r="$(rel "$f")"
        local lines; lines=$(trim "$(wc -l < "$f")")
        if [ "$lines" -gt 400 ]; then
            err "$r: $lines lines (max 400 — split this file)"
            ERROR_FILES="${ERROR_FILES}  too-long: $r (${lines}L)\n"
            any_issues=1
        elif [ "$lines" -gt 200 ]; then
            warn "$r: $lines lines (sweet-spot 200)"
            any_issues=1
        fi
    done
    [ "$found" -eq 0 ] && info "no files"
    [ "$any_issues" -eq 0 ] && [ "$found" -gt 0 ] && ok "all Swift files within size limits"

    hdr "q3ide-metal/ Swift (typecheck)"
    if [ "$(uname -s)" != "Darwin" ]; then
        info "skipped — swift typecheck requires macOS"
    else
        local tc_out tc_exit
        tc_out="$(cd "$ROOT/q3ide-metal" && swift build 2>&1)"
        tc_exit=$?
        local tc_warn=0 tc_err=0
        while IFS= read -r line; do
            case "$line" in
                *": error:"*)
                    err "swift: $line"; tc_err=1
                    ERROR_FILES="${ERROR_FILES}  swift-error\n" ;;
                *": warning:"*)
                    warn "swift: $line"; tc_warn=1 ;;
            esac
        done << _TC_EOF
$tc_out
_TC_EOF
        if [ "$tc_exit" -ne 0 ] && [ "$tc_err" -eq 0 ]; then
            err "swift build failed (exit $tc_exit)"
            ERROR_FILES="${ERROR_FILES}  swift-build\n"
        elif [ "$tc_warn" -eq 0 ] && [ "$tc_err" -eq 0 ]; then
            ok "swift build — clean"
        fi
    fi

    hdr "q3ide-metal/ Swift (swiftlint)"
    if [ "$(uname -s)" != "Darwin" ]; then
        info "skipped — swiftlint requires macOS"
        return
    fi
    if ! command -v swiftlint >/dev/null 2>&1; then
        info "skipped — swiftlint not found (brew install swiftlint)"
        return
    fi

    local lint_out had_warn=0 had_err=0
    lint_out="$(cd "$ROOT/q3ide-metal" && swiftlint lint --quiet 2>&1)"

    while IFS= read -r line; do
        case "$line" in
            *": error:"*)
                err "swiftlint: $line"; had_err=1
                ERROR_FILES="${ERROR_FILES}  swiftlint: $line\n" ;;
            *": warning:"*)
                warn "swiftlint: $line"; had_warn=1 ;;
        esac
    done << EOF
$lint_out
EOF
    [ "$had_warn" -eq 0 ] && [ "$had_err" -eq 0 ] && ok "swiftlint — clean"
}

# ─── pk3 conflict scan (baseq3/) ─────────────────────────────────────────────

run_pk3_checks() {
    hdr "pk3 conflict scan (baseq3/)"

    local BASEQ3="$ROOT/baseq3"
    if [ ! -d "$BASEQ3" ]; then
        info "skipped — baseq3/ not found"
        return
    fi

    local npk3
    npk3="$(ls "$BASEQ3"/*.pk3 2>/dev/null | wc -l | tr -d ' \t')"
    if [ "${npk3:-0}" -eq 0 ]; then
        info "no .pk3 files found in baseq3/"
        return
    fi

    printf "${_DIM}  scanning $npk3 pk3 files…${_R0}\n"

    python3 - "$BASEQ3" "$_RED" "$_YEL" "$_GRN" "$_CYN" "$_BLD" "$_DIM" "$_R0" "$_ORG" <<'PYEOF'
import zipfile, sys, collections
from pathlib import Path

BASEQ3 = Path(sys.argv[1])
RED,YEL,GRN,CYN,BLD,DIM,R0,ORG = sys.argv[2:]

pk3s = sorted(BASEQ3.glob('*.pk3'))   # alphabetical = Quake load order; last wins

# index: normalised path → [pk3 names in load order]
files = collections.defaultdict(list)
for pk3 in pk3s:
    try:
        with zipfile.ZipFile(pk3) as z:
            for name in z.namelist():
                if not name.endswith('/'):
                    files[name.lower()].append(pk3.name)
    except Exception as e:
        print(f"{YEL}[WRN]{R0}  pk3 scan: {pk3.name}: {e}")

conflicts = {p: pks for p, pks in files.items() if len(pks) > 1}

# score each pak by how many conflicting paths it touches
pak_score = collections.Counter()
for pks in conflicts.values():
    for pk in set(pks):
        pak_score[pk] += 1

# ── top-10 table ─────────────────────────────────────────────────────────────
PAK_LABELS = {
    'pak0.pk3':                  'Quake 3 Arena — base game',
    'pak1.pk3':                  'Q3A point release',
    'pak2.pk3':                  'Q3A point release (fixes q3dm9)',
    'pak3.pk3':                  'Q3A point release',
    'pak4.pk3':                  'Q3A point release 1.32 + updated bot files',
    'pak5.pk3':                  'Q3A point release',
    'pak6.pk3':                  'Q3A point release',
    'pak7.pk3':                  'Q3A point release',
    'pak8.pk3':                  'Q3A Team Arena / final patch — wins cgame+ui QVM',
    'z-qlta_player-models.pk3':  'Quake Live player models (QL-era skins + QL common.shader)',
    'zzzpak111.pk3':             'YOUR pack — HD textures/models',
    'zzzpak222.pk3':             'YOUR pack — HD textures/models',
    'zzzpak333.pk3':             'YOUR pack — HD models (flags, ammo, gibs)',
    'zzzpak444.pk3':             'YOUR pack — HD textures/models',
    'zzzpak555.pk3':             'YOUR pack — community map mega-pack (lun, acid, cpm, ctf)',
    'zzzpak666.pk3':             'YOUR pack — HD textures',
    'zzzpak777.pk3':             'YOUR pack — HD textures',
    'zzzpak888.pk3':             'YOUR pack — HD textures',
    'zzzpak999.pk3':             'YOUR pack — HD textures',
    'zzzzzpak_normals.pk3':      'YOUR pack — AI-generated normal/specular/parallax maps',
    'wtf-q3a_v3.pk3':           'WTF Q3A — community FFA/tourney map pack (Twin Towers etc.)',
    'q3wpak0.pk3':               'Quake3World — CTF maps (q3wcp series)',
    'q3wpak1.pk3':               'Quake3World — CTF maps vol.2 (q3wcp10-13+)',
    'ospmaps0.pk3':              'OSP — Overload Server Pack maps',
    'homer.pk3':                 'Homer Simpson player model — original skin + sounds',
    'md3-homer.pk3':             'Homer Simpson player model — MD3 geometry (replaces homer.pk3 meshes)',
    'map_cpm3a.pk3':             'CPM3A — Challenge ProMode Arena duel map (revision of cpm3)',
    'map_cpm4a.pk3':             'CPM4A — Challenge ProMode Arena duel map (fast-flow tourney)',
    'map_cpm18r.pk3':            'CPM18R — Challenge ProMode Arena duel map (revision of cpm18)',
    'map_cpm20.pk3':             'CPM20 — Challenge ProMode Arena FFA/duel map',
}

print(f"\n{CYN}{BLD}  TOP 20 COMPETING PACKS{R0}  ({DIM}{len(pk3s)} total paks, {len(conflicts)} conflicting paths{R0})")
print(f"  {'conflicts':>9}  {'wins':>5}  {'loses':>5}  {'pack':<32}  description")
print(f"  {'-'*9}  {'-'*5}  {'-'*5}  {'-'*32}  {'-'*40}")
for pk, total in pak_score.most_common(20):
    wins  = sum(1 for pks in conflicts.values() if pk in pks and pks[-1] == pk)
    loses = sum(1 for pks in conflicts.values() if pk in pks and pks[-1] != pk)
    label = PAK_LABELS.get(pk, '')
    print(f"  {total:>9}  {wins:>5}  {loses:>5}  {pk:<32}  {DIM}{label}{R0}")

# ── split: base-game overrides (real issues) vs third-party noise ─────────────
# Official id Software paks (pak0-pak8). Conflicts between these are expected
# point-release updates (pak4 = 1.32 patch, pak8 = Team Arena, etc.) — never a real issue.
OFFICIAL_PAKS = {f'pak{i}.pk3' for i in range(9)}

# Community packs whose shader/gameplay overrides are verified safe.
# Add a pack here when you've confirmed its contents are intentional.
KNOWN_PAKS = {
    'zzzpak555.pk3',            # community map mega-pack — shader overrides are accidental collateral, not malicious
    'z-qlta_player-models.pk3', # QL player model pack — common.shader adds QL surface types only, safe
}

def involves_base(pks):
    return any(p in OFFICIAL_PAKS for p in pks)

def winner_is_known(pks):
    # official pak winning over another official pak = expected point-release update
    return pks[-1] in OFFICIAL_PAKS or pks[-1] in KNOWN_PAKS

# File types that can actually break gameplay when overridden.
# Everything else (textures, models, sounds, etc.) is cosmetic — override is fine.
GAMEPLAY_EXTS = {'shader', 'qvm', 'bsp', 'aas'}

def is_cosmetic(path):
    ext = path.rsplit('.', 1)[-1] if '.' in path else ''
    return ext not in GAMEPLAY_EXTS

real      = {p: pks for p, pks in conflicts.items()
             if involves_base(pks) and not winner_is_known(pks) and not is_cosmetic(p)}
noise     = {p: pks for p, pks in conflicts.items()
             if not involves_base(pks) or winner_is_known(pks) or is_cosmetic(p)}

real_ext  = collections.defaultdict(list)
for path, pks in sorted(real.items()):
    ext = path.rsplit('.', 1)[-1] if '.' in path else '(none)'
    real_ext[ext].append((path, pks))

noise_ext = collections.Counter()
for path in noise:
    ext = path.rsplit('.', 1)[-1] if '.' in path else '(none)'
    noise_ext[ext] += 1

# ── QVM: split qagame (safe) vs cgame/ui (informational) ─────────────────────
# qagame.qvm conflict is irrelevant — native qagame.dylib always wins over QVM.
# cgame + ui have no native dylib so they DO load from whatever QVM wins (pak8 = point-release patch, expected).
qvm_items = real_ext.pop('qvm', [])
qvm_safe  = [item for item in qvm_items if item[0] == 'vm/qagame.qvm']
qvm_info  = [item for item in qvm_items if item[0] != 'vm/qagame.qvm']

if qvm_info:
    print(f"\n{DIM}  QVM note (expected — pak8 is the point-release patch){R0}")
    for path, pks in qvm_info:
        print(f"  {DIM}> {path}  ←  {pks[-1]}  (QVM, no native dylib){R0}")

# ── REAL ISSUES: base game pak loses ─────────────────────────────────────────
if real:
    print(f"\n{RED}{BLD}  REAL ISSUES  (base game pak0-pak7 overridden){R0}")
    for ext in ('shader',):
        items = real_ext.get(ext, [])
        if not items:
            continue
        label = f"{RED}{BLD}{ext.upper()} — CHECK CAREFULLY{R0}"
        print(f"\n  {label}  ({len(items)} files)")
        for path, pks in items:
            print(f"  {RED}>{R0} {path}")
            print(f"      {GRN}wins :{R0}  {pks[-1]}")
            print(f"      {DIM}loses:{R0}  {', '.join(pks[:-1])}")
    other_real = [(ext, items) for ext, items in real_ext.items() if ext not in ('qvm', 'shader')]
    if other_real:
        print(f"\n  {'type':12}  {'overrides':>9}  example")
        for ext, items in sorted(other_real, key=lambda x: -len(x[1])):
            print(f"  {DIM}{ext:12}{R0}  {len(items):>9}  {DIM}{items[0][0]}{R0}")

# ── YOUR PACKS MUST WIN: flag if anything beats a zzz* pack ──────────────────
# zzz* packs are the user's HD/normals set — named to sort last intentionally.
# If a non-zzz, non-official pack beats them, something is named wrong.
YOUR_PAK_PREFIX = 'zzz'
your_pak_losses = []
for path, pks in sorted(conflicts.items()):
    losers = pks[:-1]
    winner = pks[-1]
    for loser in losers:
        if loser.startswith(YOUR_PAK_PREFIX) and not winner.startswith(YOUR_PAK_PREFIX) and winner not in OFFICIAL_PAKS:
            your_pak_losses.append((path, loser, winner))

if your_pak_losses:
    print(f"\n{RED}{BLD}  YOUR PACKS LOSING  (zzz* pack overridden by a community pack — rename to fix){R0}")
    for path, loser, winner in your_pak_losses:
        print(f"  {RED}>{R0} {path}")
        print(f"      {GRN}should win:{R0}  {loser}")
        print(f"      {RED}beaten by :{R0}  {winner}")
    has_issues = True
else:
    print(f"\n{GRN}  your zzz* packs win all conflicts{R0}")
    has_issues = False

# ── NOISE: third-party pack vs third-party pack (summary only) ────────────────
print(f"\n{DIM}  third-party vs third-party (map/player mods — ignored)")
for ext, count in noise_ext.most_common():
    print(f"    {ext:12}  {count} files")
print(f"{R0}")

import sys
sys.exit(1 if (real or your_pak_losses) else 0)

PYEOF

    local py_exit=$?
    if [ $py_exit -eq 0 ]; then
        ok "pk3 scan — clean"
    elif [ $py_exit -eq 1 ]; then
        warn "pk3 scan — real issues found (see above)"
    else
        warn "pk3 conflict scan failed — python3 required"
    fi
}

# ─── dylib / VM sanity checks ─────────────────────────────────────────────────

run_dylib_checks() {
    hdr "dylib / VM sanity"

    local BUILD_SH="$ROOT/scripts/build.sh"
    local QAGAME_DYLIB="$ROOT/baseq3/qagame.dylib"
    local any_issues=0

    # 1. fvisibility=hidden in build.sh ────────────────────────────────────────
    if grep -q '\-fvisibility=hidden' "$BUILD_SH" 2>/dev/null; then
        ok "build.sh: -fvisibility=hidden present in qagame compile flags"
    else
        err "build.sh: -fvisibility=hidden MISSING — Com_Error/Com_Printf will leak into engine namespace → SIGSEGV on weapon fire"
        ERROR_FILES="${ERROR_FILES}  dylib: missing -fvisibility=hidden in build.sh\n"
        any_issues=1
    fi

    # 2. qagame.dylib exists and is non-empty ──────────────────────────────────
    if [ ! -f "$QAGAME_DYLIB" ]; then
        warn "baseq3/qagame.dylib not found — run a full build first"
        any_issues=1
        return
    fi
    local size; size=$(wc -c < "$QAGAME_DYLIB" | tr -d ' ')
    if [ "${size:-0}" -lt 1000 ]; then
        err "baseq3/qagame.dylib exists but is suspiciously small (${size} bytes) — likely a bad build"
        ERROR_FILES="${ERROR_FILES}  dylib: corrupt qagame.dylib\n"
        any_issues=1
        return
    fi
    ok "baseq3/qagame.dylib exists (${size} bytes)"

    # 3. Symbol checks via nm (works on macOS; skipped gracefully on Linux) ────
    local NM_OUT
    NM_OUT="$(nm "$QAGAME_DYLIB" 2>/dev/null)" || {
        info "nm cannot read Mach-O on this host — symbol checks skipped (run lint on macOS for full check)"
        return
    }

    # Required exports: dllEntry and vmMain must be TEXT (T) exported symbols
    for sym in _dllEntry _vmMain; do
        if echo "$NM_OUT" | grep -q "^[0-9a-f]* T ${sym}$"; then
            ok "qagame.dylib exports ${sym}"
        else
            err "qagame.dylib: missing export ${sym} — engine cannot load game module"
            ERROR_FILES="${ERROR_FILES}  dylib: missing ${sym}\n"
            any_issues=1
        fi
    done

    # Forbidden exports: Com_Error / Com_Printf must NOT be T (exported text)
    # They may appear as U (undefined/imported) which is fine — only T is bad
    for sym in _Com_Error _Com_Printf _Com_DPrintf; do
        if echo "$NM_OUT" | grep -q "^[0-9a-f]* T ${sym}$"; then
            err "qagame.dylib: ${sym} is EXPORTED — -fvisibility=hidden not effective → SIGSEGV on weapon fire"
            ERROR_FILES="${ERROR_FILES}  dylib: leaked symbol ${sym}\n"
            any_issues=1
        fi
    done
    if [ "$any_issues" -eq 0 ]; then
        ok "qagame.dylib: no forbidden symbol leaks (Com_Error/Printf not exported)"
    fi

    # 4. cgame / ui load from QVM — informational note ─────────────────────────
    local CGAME_QVM="$ROOT/baseq3/vm/cgame.qvm"
    local UI_QVM="$ROOT/baseq3/vm/ui.qvm"
    local cgame_src=""
    [ -f "$CGAME_QVM" ] && cgame_src="local vm/cgame.qvm" || cgame_src="pak (from pk3)"
    local ui_src=""
    [ -f "$UI_QVM" ] && ui_src="local vm/ui.qvm" || ui_src="pak (from pk3)"
    info "cgame loads from: ${cgame_src}  |  ui loads from: ${ui_src}  (both are QVM — only qagame is native)"

    [ "$any_issues" -eq 0 ]
}

# ─── main ─────────────────────────────────────────────────────────────────────

printf "${_ORG}${_BLD}=== Q3IDE Linter ===${_R0}  ${_DIM}%s${_R0}\n" "$ROOT"

run_clang_format
[ "$RUN_CPPCHECK" -eq 1 ] && run_cppcheck
run_basic_checks
run_makefile_checks
run_makefile_rule_checks
run_bind_checks
run_params_checks
run_guard_checks
run_rust_checks
run_dylib_checks
[ "$RUN_SWIFT" -eq 1 ] && run_swift_checks
[ "$RUN_PK3" -eq 1 ] && run_pk3_checks

echo ""
if [ "$ERRORS" -gt 0 ]; then
    printf "${_RED}${_BLD}=== %d error(s)${_R0}, ${_YEL}%d warning(s)${_R0} — files to fix:\n" "$ERRORS" "$WARNINGS"
    printf '%b' "$ERROR_FILES"
elif [ "$WARNINGS" -gt 0 ]; then
    printf "${_GRN}${_BLD}=== 0 errors${_R0}, ${_YEL}%d warning(s)${_R0}\n" "$WARNINGS"
else
    printf "${_GRN}${_BLD}=== clean ✓${_R0}\n"
fi
[ "$ERRORS" -eq 0 ]
