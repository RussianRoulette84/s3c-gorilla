#!/usr/bin/env bats
# test_fanout_wiring.bats — chip-mode fan-out (P2): one master-pw read chip-wraps every
# secret (env/otp/ssh) once + writes the sentinel; reboot-staleness guard. touchid-gorilla
# and keepassxc-cli are mocked (the real wrap needs a Secure Enclave / the M1).

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
    BANNERS="$REPO/src/lib/banners.sh"
    TMP="$(mktemp -d)"; mkdir -p "$TMP/bin"; export HOME="$TMP/home"; mkdir -p "$HOME"
    export GORILLA_BLOB_DIR="$TMP/blobs"
    export GORILLA_TOUCHID="$TMP/bin/touchid-gorilla"
    cat > "$TMP/bin/touchid-gorilla" <<EOF
#!/bin/bash
[[ "\$1" == "wrap" ]] && echo "\$2" >> "$TMP/wraps"
exit 0
EOF
    cat > "$TMP/bin/keepassxc-cli" <<'EOF'
#!/bin/bash
case "$1" in
  ls) case "$3" in
        *ENV/) printf 'proja\nprojb\n' ;;
        *2FA/) printf 'github\n' ;;
        *SSH/) printf 'id_ed25519\n' ;;
      esac ;;
  attachment-export) echo "FAKE=data" ;;
  show) echo "otpauth://totp/x?secret=ABC" ;;
esac
exit 0
EOF
    chmod +x "$TMP/bin/touchid-gorilla" "$TMP/bin/keepassxc-cli"
    export PATH="$TMP/bin:$PATH"
}
teardown() { [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"; }

src() { bash -c "source '$BANNERS'; have_chip(){ true; }; $1"; }

@test "fan_out_all wraps env+otp+ssh in one pass and writes the sentinel" {
    run src "fan_out_all SECRETPW"
    [ "$status" -eq 0 ]
    [ -f "$GORILLA_BLOB_DIR/.session-valid" ]
    grep -qx 'env-proja' "$TMP/wraps"
    grep -qx 'env-projb' "$TMP/wraps"
    grep -qx 'otp-github' "$TMP/wraps"
    grep -qx 'ssh-id_ed25519' "$TMP/wraps"
}

@test "fan_out_all is a no-op with no password (no sentinel)" {
    run src "fan_out_all ''"
    [ "$status" -eq 0 ]
    [ ! -f "$GORILLA_BLOB_DIR/.session-valid" ]
}

@test "fan_out_all skips when the sentinel is already fresh (one fan-out per boot)" {
    mkdir -p "$GORILLA_BLOB_DIR"; : > "$GORILLA_BLOB_DIR/.session-valid"
    run src "fan_out_all PW"
    [ "$status" -eq 0 ]
    [ ! -f "$TMP/wraps" ]
}

@test "_blob_fresh accepts a post-boot blob, rejects a pre-boot one" {
    mkdir -p "$GORILLA_BLOB_DIR"
    : > "$GORILLA_BLOB_DIR/new"
    touch -t 200001010000 "$GORILLA_BLOB_DIR/old"
    run src "_blob_fresh '$GORILLA_BLOB_DIR/new'"; [ "$status" -eq 0 ]
    run src "_blob_fresh '$GORILLA_BLOB_DIR/old'"; [ "$status" -ne 0 ]
}
