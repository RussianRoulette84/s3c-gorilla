#!/usr/bin/env bats
# test_paranoid.bats — --paranoid leaves nothing cached in /tmp (#7/#10).

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
    TMP="$(mktemp -d)"; mkdir -p "$TMP/bin"; export HOME="$TMP/home"; mkdir -p "$HOME"
    export GORILLA_BLOB_DIR="$TMP/blobs"; mkdir -p "$GORILLA_BLOB_DIR"
    export GORILLA_TOUCHID="$TMP/bin/touchid-gorilla"
    printf '#!/bin/bash\necho "$@" >> "%s/calls"\nexit 0\n' "$TMP" > "$TMP/bin/touchid-gorilla"
    printf '#!/bin/bash\ncase "$1" in attachment-export) echo K=V;; ls) echo proj;; esac\nexit 0\n' > "$TMP/bin/keepassxc-cli"
    chmod +x "$TMP/bin/"*
    export PATH="$TMP/bin:$PATH"
}
teardown() { [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"; }

@test "_paranoid_wipe removes cached blobs + the sentinel" {
    : > "$GORILLA_BLOB_DIR/env-a.blob"; : > "$GORILLA_BLOB_DIR/ssh-k.blob"; : > "$GORILLA_BLOB_DIR/.session-valid"
    run bash -c "source '$REPO/src/lib/banners.sh'; GORILLA_BLOB_DIR='$GORILLA_BLOB_DIR'; GORILLA_SENTINEL='$GORILLA_BLOB_DIR/.session-valid'; _paranoid_wipe; ls -a '$GORILLA_BLOB_DIR'"
    [ "$status" -eq 0 ]
    [[ "$output" != *"env-a.blob"* ]]
    [[ "$output" != *"ssh-k.blob"* ]]
    [[ "$output" != *".session-valid"* ]]
}

@test "env-gorilla --paranoid wraps no blob (chip present)" {
    : > "$TMP/calls"
    printf 'PW\n' | GORILLA_TOUCHID="$TMP/bin/touchid-gorilla" GORILLA_BANNERS="$REPO/src/lib/banners.sh" \
        bash "$REPO/src/env-gorilla" proj --paranoid -- true >/dev/null 2>&1 || true
    run grep -c '^wrap ' "$TMP/calls"
    [ "$output" = "0" ]
}
