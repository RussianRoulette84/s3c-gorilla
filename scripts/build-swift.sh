#!/usr/bin/env bash
# build-swift.sh — compile-check every Swift binary so nothing ships
# compile-unverified (B14). macOS only: the binaries link Security /
# LocalAuthentication / CryptoKit, which don't exist off-Mac.
#
#   ./scripts/build-swift.sh            # typecheck all (fast)
#   ./scripts/build-swift.sh --emit     # full compile to a temp binary
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src"
MODE="typecheck"
[[ "${1:-}" == "--emit" ]] && MODE="emit"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "build-swift.sh: skipped — Swift build requires macOS"
    exit 0
fi
command -v swiftc >/dev/null || { echo "swiftc not found — install Xcode Command Line Tools"; exit 1; }

# Source-file lists + frameworks come from the shared recipe (no drift vs install.sh).
source "$HERE/swift-targets.sh"

rc=0
for bin in $(swift_targets); do
    srcs=""; for s in $(swift_sources "$bin"); do srcs+=" $SRC/$s"; done
    fw="$(swift_frameworks "$bin")"
    printf '→ %-22s ' "$bin"
    if [[ "$MODE" == "emit" ]]; then
        out="$(mktemp)"
        if swiftc $fw $srcs -o "$out" 2>/tmp/build-swift.err; then echo "ok"; else echo "FAIL"; sed 's/^/    /' /tmp/build-swift.err; rc=1; fi
    else
        if swiftc -typecheck $fw $srcs 2>/tmp/build-swift.err; then echo "ok"; else echo "FAIL"; sed 's/^/    /' /tmp/build-swift.err; rc=1; fi
    fi
done

[[ $rc -eq 0 ]] && echo "all Swift sources compile-clean" || echo "Swift compile errors above"
exit $rc
