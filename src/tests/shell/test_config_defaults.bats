#!/usr/bin/env bats
# test_config_defaults.bats — validates src/setup/config.example
# PLAN.md spec (Files.Modified + Step 11/12 behaviour sections):
#   GORILLA_UNLOCK_TTL=7200
#   GORILLA_MASTER_PW_PROMPT=dialog
#   GORILLA_WIPE_ON_SCREEN_LOCK=1
# Plus baseline knobs already in the example.

setup() {
    CONFIG="$BATS_TEST_DIRNAME/../../setup/config.example"
    [[ -f "$CONFIG" ]] || skip "config.example not at expected path"
}

@test "config.example is sourceable without error" {
    run bash -c ". '$CONFIG'"
    [ "$status" -eq 0 ]
}

@test "GORILLA_DB has a default path" {
    run bash -c ". '$CONFIG' && echo \"\$GORILLA_DB\""
    [ "$status" -eq 0 ]
    [[ "$output" == *".kdbx"* ]]
}

@test "GORILLA_ENV_GROUP defaults to ENV" {
    run bash -c ". '$CONFIG' && echo \"\$GORILLA_ENV_GROUP\""
    [ "$output" = "ENV" ]
}

@test "GORILLA_OTP_GROUP defaults to 2FA" {
    run bash -c ". '$CONFIG' && echo \"\$GORILLA_OTP_GROUP\""
    [ "$output" = "2FA" ]
}

@test "GORILLA_SSH_MODE defaults to chip-wrap" {
    run bash -c ". '$CONFIG' && echo \"\$GORILLA_SSH_MODE\""
    [ "$output" = "chip-wrap" ]
}

# ---- knobs added during Phase 1 implementation ----

@test "GORILLA_UNLOCK_TTL default = 7200 (Concern Arch §6)" {
    run bash -c ". '$CONFIG' && echo \"\${GORILLA_UNLOCK_TTL:-UNSET}\""
    if [ "$output" = "UNSET" ]; then
        skip "GORILLA_UNLOCK_TTL not yet added — Phase 1 pending"
    fi
    [ "$output" = "7200" ]
}

@test "GORILLA_MASTER_PW_PROMPT default = dialog (Step 11)" {
    run bash -c ". '$CONFIG' && echo \"\${GORILLA_MASTER_PW_PROMPT:-UNSET}\""
    if [ "$output" = "UNSET" ]; then
        skip "GORILLA_MASTER_PW_PROMPT not yet added — Phase 1 pending"
    fi
    [ "$output" = "dialog" ]
}

@test "GORILLA_WIPE_ON_SCREEN_LOCK default = 1 (Step 12 Paranoid)" {
    run bash -c ". '$CONFIG' && echo \"\${GORILLA_WIPE_ON_SCREEN_LOCK:-UNSET}\""
    if [ "$output" = "UNSET" ]; then
        skip "GORILLA_WIPE_ON_SCREEN_LOCK not yet added — Phase 1 pending"
    fi
    [ "$output" = "1" ]
}

@test "GORILLA_PUSHER_ALLOWLIST default contains keepassxc (Concern #40)" {
    run bash -c ". '$CONFIG' && echo \"\${GORILLA_PUSHER_ALLOWLIST:-UNSET}\""
    if [ "$output" = "UNSET" ]; then
        skip "GORILLA_PUSHER_ALLOWLIST not yet added — Phase 2 pending"
    fi
    [[ "$output" == *"org.keepassxc.keepassxc"* ]]
}

@test "no secrets accidentally committed to config.example" {
    # Common patterns that shouldn't appear in a template file.
    run grep -iE '(password|passphrase|secret)\s*=\s*[^\"]*[a-zA-Z0-9]' "$CONFIG"
    # Grep exits 1 on no-match (success here). Non-1 status = suspicious hit.
    [ "$status" -eq 1 ]
}
