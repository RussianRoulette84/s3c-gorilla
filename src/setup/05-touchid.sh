# 05-touchid.sh — detect Touch ID, build/sign touchid-gorilla + s3c-ssh-agent (chip mode),
# then offer session-unlock (works in both modes).
section "[5/11] Touch ID"

HAS_TOUCHID=false

# Two-gate detection. AppleBiometricSensor in IOKit is necessary but NOT
# sufficient: Hackintoshes and VMs can spoof that node yet have no Secure
# Enclave, so biometric auth can never actually run. The authoritative gate is
# LocalAuthentication's canEvaluatePolicy — it returns true only when Touch ID
# is genuinely usable, and it never prompts (just probes). If swiftc is missing,
# we can't compile the tool anyway, so requiring it here costs nothing.
TOUCHID_DETECTED=false
if ioreg -c AppleBiometricSensor 2>/dev/null | grep -q "AppleBiometricSensor"; then
 PROBE_SRC="$BUILD_DIR/touchid-probe.swift"
 cat > "$PROBE_SRC" <<'SWIFT'
import LocalAuthentication
let ctx = LAContext()
var err: NSError?
let ok = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
exit(ok && ctx.biometryType == .touchID ? 0 : 1)
SWIFT
 if swiftc "$PROBE_SRC" -o "$BUILD_DIR/touchid-probe" -framework LocalAuthentication 2>/dev/null \
 && "$BUILD_DIR/touchid-probe" 2>/dev/null; then
 TOUCHID_DETECTED=true
 else
 info "AppleBiometricSensor present but Touch ID is not usable (no Secure Enclave?) — password mode"
 fi
fi

if $TOUCHID_DETECTED; then
 success "Touch ID hardware detected"
 if confirm "Enable Touch ID mode?" y; then
 HAS_TOUCHID=true
 else
 skip "Touch ID mode opted out — tools will prompt for master password"
 fi
fi

if $HAS_TOUCHID; then

 FRESH_INSTALL=true
 [[ -f "$BIN_DIR/touchid-gorilla" ]] && FRESH_INSTALL=false

 info "Compiling touchid-gorilla..."
 BUILD_SRC="$BUILD_DIR/touchid-gorilla.swift"
 BUILD_BIN="$BUILD_DIR/touchid-gorilla"
 cp "$SRC_DIR/touchid-gorilla.swift" "$BUILD_SRC"

 swiftc "$BUILD_SRC" -o "$BUILD_BIN" $(swift_frameworks touchid-gorilla)

 # Codesigning identity picker.
 # "Developer ID Application" is the only identity that lets a CLI binary with
 # keychain-access-groups entitlement launch on macOS without an embedded
 # provisioning profile — so we recommend it exclusively.
 ENT_FILE="$SRC_DIR/touchid-gorilla.entitlements"

 IDENT_LINES=()
 while IFS= read -r line; do
 IDENT_LINES+=("$line")
 done < <(security find-identity -v -p codesigning 2>/dev/null | grep -E '^[[:space:]]*[0-9]+\)')

 SIGN_IDENTITY=""
 if [[ ${#IDENT_LINES[@]} -eq 0 ]]; then
 warn "No codesigning identities found — falling back to ad-hoc"
 else
 # The whole menu goes to stderr — same stream as `read -p`'s prompt. install.sh pipes stdout
 # through `tee`, which block-buffers it, so a stdout menu flushes AFTER the prompt and the
 # options end up printed below "Pick identity:" (the bug: "0) ad-hoc" landing under the prompt).
 item "Codesigning identities:" >&2
 DEFAULT_CHOICE=0
 for i in "${!IDENT_LINES[@]}"; do
 ln="${IDENT_LINES[$i]}"
 hash=$(echo "$ln" | awk '{print $2}')
 name=$(echo "$ln" | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+//')
 star=""
 if [[ "$name" == *"Developer ID Application"* ]]; then
 star=" [recommended — only cert type that works for CLI binaries]"
 [[ $DEFAULT_CHOICE -eq 0 ]] && DEFAULT_CHOICE=$((i+1))
 fi
 printf "%b%s%b %d) %s%s\n" "$C7" "$TREE_MID" "$RESET" $((i+1)) "$name" "$star" >&2
 done
 printf "%b%s%b 0) ad-hoc (no Developer identity — SE features will be unreliable)\n" "$C7" "$TREE_MID" "$RESET" >&2
 if [[ $DEFAULT_CHOICE -gt 0 ]]; then
 ask_line "Pick identity [1-${#IDENT_LINES[@]}, 0=ad-hoc, Enter=$DEFAULT_CHOICE]:" CHOICE "$DEFAULT_CHOICE"
 else
 ask_line "Pick identity [1-${#IDENT_LINES[@]}, 0=ad-hoc]:" CHOICE
 fi
 if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [[ "$CHOICE" -ge 1 ]] && [[ "$CHOICE" -le ${#IDENT_LINES[@]} ]]; then
 SIGN_IDENTITY=$(echo "${IDENT_LINES[$((CHOICE-1))]}" | awk '{print $2}')
 fi
 fi

 if [[ -n "$SIGN_IDENTITY" ]]; then
 if sign_binary "$BUILD_BIN" "$SIGN_IDENTITY" "$ENT_FILE"; then
 success "Signed with: $SIGN_IDENTITY"
 [[ -f "$ENT_FILE" ]] && item "Entitlements: $(basename "$ENT_FILE")"
 else
 error "codesign failed — retry with a different identity or check keychain access"
 exit 1
 fi
 else
 sign_binary "$BUILD_BIN"
 warn "Ad-hoc signed — Secure Enclave access may be unreliable"
 fi

 # Install the signed binary into $BIN_DIR. `install(1)` on macOS 14+ (Sonoma)
 # stamps the destination with `com.apple.provenance` — an xattr that
 # Gatekeeper/amfid consults at exec time. A binary with temp-dir provenance
 # installed into /usr/local/bin/ gets SIGKILL'd at launch even though
 # `codesign --verify` still passes (xattrs aren't part of the signature).
 # Strip every xattr after install to get a clean, trusted binary.
 sudo install -m 0555 -o root -g wheel "$BUILD_BIN" "$BIN_DIR/touchid-gorilla"
 sudo xattr -cr "$BIN_DIR/touchid-gorilla"
 success "touchid-gorilla → $BIN_DIR/touchid-gorilla"

 # -----------------------------------------------------------------------
 # Compile + sign + install s3c-ssh-agent alongside touchid-gorilla.
 # Same signing identity; no entitlements needed (agent only talks to SE,
 # no keychain-access-groups required).
 # -----------------------------------------------------------------------
 info "Compiling s3c-ssh-agent..."
 AGENT_BIN="$BUILD_DIR/s3c-ssh-agent"
 # Source list from swift-targets.sh (the one place that knows the file split), so the installer
 # can't fall behind build-swift.sh when this file is split.
 AGENT_SRCS=""; for _s in $(swift_sources s3c-ssh-agent); do AGENT_SRCS="$AGENT_SRCS $SRC_DIR/$_s"; done
 swiftc $AGENT_SRCS -o "$AGENT_BIN" $(swift_frameworks s3c-ssh-agent)
 if [[ -n "$SIGN_IDENTITY" ]]; then
 if sign_binary "$AGENT_BIN" "$SIGN_IDENTITY"; then
 success "Signed s3c-ssh-agent with: $SIGN_IDENTITY"
 else
 warn "codesign s3c-ssh-agent failed — falling back to ad-hoc"
 sign_binary "$AGENT_BIN"
 fi
 else
 sign_binary "$AGENT_BIN"
 fi
 sudo install -m 0555 -o root -g wheel "$AGENT_BIN" "$BIN_DIR/s3c-ssh-agent"
 sudo xattr -cr "$BIN_DIR/s3c-ssh-agent"
 success "s3c-ssh-agent → $BIN_DIR/s3c-ssh-agent"

 # #43 L3: pin the agent's cdhash so the running agent can detect a swapped binary. Computed by
 # the agent itself (--cdhash) → the pin format always matches its own self-check. Written here,
 # BEFORE the LaunchAgent is bootstrapped in step 10, and overwritten every install so it rotates
 # in lockstep with the freshly-signed binary. Empty output (platform won't surface cdhashes) →
 # no pin written → agent runs unverified (never a brick).
 AGENT_CDHASH="$("$BIN_DIR/s3c-ssh-agent" --cdhash 2>/dev/null)"
 if [[ -n "$AGENT_CDHASH" ]]; then
 printf '%s\n' "$AGENT_CDHASH" | sudo tee "$SHARE_DIR/agent.cdhash" >/dev/null
 sudo chown root:wheel "$SHARE_DIR/agent.cdhash"; sudo chmod 0644 "$SHARE_DIR/agent.cdhash"
 success "Pinned agent cdhash → $SHARE_DIR/agent.cdhash"
 else
 warn "Could not read agent cdhash — integrity pin not written (agent runs unverified)"
 fi
else
 if ! $TOUCHID_DETECTED; then
 info "No Touch ID detected (desktop Mac without Touch ID keyboard)"
 fi
 item "Tools will prompt for master password"
fi

# ----------------------------------------------------------
# Session-unlock — a NO-CHIP feature: hold the master pw per-terminal-tab so env/otp stop
# re-prompting within a tab. Chip Macs IGNORE it (the fan-out blob cache already gives one master
# pw per boot + Touch ID in every terminal), so we don't even offer it there — enabling it would
# only make new windows re-prompt. Always persisted so a re-install can't leave a stale 'true'.
# ----------------------------------------------------------
SESSION_UNLOCK=false
if ! $HAS_TOUCHID; then
 item ""
 item "Session-unlock — hold the master password in a memory-only, per-terminal"
 item "agent so env/otp stop re-prompting within the same tab. Obfuscated +"
 item "mlock'd, never on disk; wiped on TTL / logout / screen-lock / reboot."
 confirm "Keep unlocked for the current terminal session?" y && SESSION_UNLOCK=true
fi
set_config GORILLA_SESSION_UNLOCK "$SESSION_UNLOCK"
if $HAS_TOUCHID; then skip "Session-unlock: off (chip mode uses the per-sign Touch ID gate)"
elif $SESSION_UNLOCK; then success "Session-unlock: ON"
else skip "Session-unlock: off (tools always prompt)"; fi
true
