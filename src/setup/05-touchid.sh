# 05-touchid.sh — detect Touch ID, build/sign touchid-gorilla + s3c-ssh-agent (chip mode),
# then offer session-unlock (works in both modes).
section "[5/10] Touch ID"

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
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Enable Touch ID mode? [Y/n] " -n 1 -r
 echo ""
 if [[ -z "$REPLY" || $REPLY =~ ^[Yy]$ ]]; then
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
 item "Codesigning identities:"
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
 printf "%b%s%b %d) %s%s\n" "$C7" "$TREE_MID" "$RESET" $((i+1)) "$name" "$star"
 done
 printf "%b%s%b 0) ad-hoc (no Developer identity — SE features will be unreliable)\n" "$C7" "$TREE_MID" "$RESET"
 if [[ $DEFAULT_CHOICE -gt 0 ]]; then
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Pick identity [1-${#IDENT_LINES[@]}, 0=ad-hoc, Enter=$DEFAULT_CHOICE]: " CHOICE
 CHOICE="${CHOICE:-$DEFAULT_CHOICE}"
 else
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -p "Pick identity [1-${#IDENT_LINES[@]}, 0=ad-hoc]: " CHOICE
 fi
 if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [[ "$CHOICE" -ge 1 ]] && [[ "$CHOICE" -le ${#IDENT_LINES[@]} ]]; then
 SIGN_IDENTITY=$(echo "${IDENT_LINES[$((CHOICE-1))]}" | awk '{print $2}')
 fi
 fi

 CODESIGN_ARGS=(--force --sign)
 if [[ -n "$SIGN_IDENTITY" ]]; then
 CODESIGN_ARGS+=("$SIGN_IDENTITY")
 [[ -f "$ENT_FILE" ]] && CODESIGN_ARGS+=(--entitlements "$ENT_FILE")
 CODESIGN_ARGS+=("$BUILD_BIN")
 if codesign "${CODESIGN_ARGS[@]}" &>/dev/null; then
 success "Signed with: $SIGN_IDENTITY"
 [[ -f "$ENT_FILE" ]] && item "Entitlements: $(basename "$ENT_FILE")"
 else
 error "codesign failed — retry with a different identity or check keychain access"
 exit 1
 fi
 else
 codesign --force --sign - "$BUILD_BIN" 2>/dev/null
 warn "Ad-hoc signed — Secure Enclave access may be unreliable"
 fi

 # Install the signed binary into $BIN_DIR. `install(1)` on macOS 14+ (Sonoma)
 # stamps the destination with `com.apple.provenance` — an xattr that
 # Gatekeeper/amfid consults at exec time. A binary with temp-dir provenance
 # installed into /usr/local/bin/ gets SIGKILL'd at launch even though
 # `codesign --verify` still passes (xattrs aren't part of the signature).
 # Strip every xattr after install to get a clean, trusted binary.
 sudo install -m 0755 -o root -g wheel "$BUILD_BIN" "$BIN_DIR/touchid-gorilla"
 sudo xattr -cr "$BIN_DIR/touchid-gorilla"
 success "touchid-gorilla → $BIN_DIR/touchid-gorilla"

 # -----------------------------------------------------------------------
 # Compile + sign + install s3c-ssh-agent alongside touchid-gorilla.
 # Same signing identity; no entitlements needed (agent only talks to SE,
 # no keychain-access-groups required).
 # -----------------------------------------------------------------------
 info "Compiling s3c-ssh-agent..."
 AGENT_SRC="$BUILD_DIR/s3c-ssh-agent.swift"
 AGENT_BIN="$BUILD_DIR/s3c-ssh-agent"
 cp "$SRC_DIR/s3c-ssh-agent.swift" "$AGENT_SRC"
 cp "$SRC_DIR/ssh-wire.swift" "$BUILD_DIR/ssh-wire.swift"   # shared wire helpers (#13)
 cp "$SRC_DIR/ssh-rsa.swift" "$BUILD_DIR/ssh-rsa.swift"     # shared RSA signing (#RSA)
 swiftc "$AGENT_SRC" "$BUILD_DIR/ssh-wire.swift" "$BUILD_DIR/ssh-rsa.swift" -o "$AGENT_BIN" $(swift_frameworks s3c-ssh-agent)
 AGENT_CODESIGN=(--force --sign)
 if [[ -n "$SIGN_IDENTITY" ]]; then
 AGENT_CODESIGN+=("$SIGN_IDENTITY" "$AGENT_BIN")
 if codesign "${AGENT_CODESIGN[@]}" &>/dev/null; then
 success "Signed s3c-ssh-agent with: $SIGN_IDENTITY"
 else
 warn "codesign s3c-ssh-agent failed — falling back to ad-hoc"
 codesign --force --sign - "$AGENT_BIN" 2>/dev/null
 fi
 else
 codesign --force --sign - "$AGENT_BIN" 2>/dev/null
 fi
 sudo install -m 0755 -o root -g wheel "$AGENT_BIN" "$BIN_DIR/s3c-ssh-agent"
 sudo xattr -cr "$BIN_DIR/s3c-ssh-agent"
 success "s3c-ssh-agent → $BIN_DIR/s3c-ssh-agent"
else
 if ! $TOUCHID_DETECTED; then
 info "No Touch ID detected (desktop Mac without Touch ID keyboard)"
 fi
 item "Tools will prompt for master password"
fi

# ----------------------------------------------------------
# Session-unlock opt-in (works in BOTH modes; held by s3c-session-agent)
# ----------------------------------------------------------
item ""
item "Session-unlock — hold the master password in a memory-only, per-terminal"
item "agent so env/otp/ssh stop re-prompting within the same tab. Obfuscated +"
item "mlock'd, never on disk; wiped on TTL / logout / screen-lock / reboot."
SESSION_UNLOCK=false
if $HAS_TOUCHID; then
 item "On a Touch ID machine this BYPASSES the per-decrypt fingerprint gate — opt-in."
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -rp "Keep unlocked for the current terminal session? [y/N] " REPLY
 [[ $REPLY =~ ^[Yy]$ ]] && SESSION_UNLOCK=true
else
 printf "%b%s %b" "$C7" "$TREE_MID" "$RESET"
 read -rp "Keep unlocked for the current terminal session? [Y/n] " REPLY
 [[ -z "$REPLY" || $REPLY =~ ^[Yy]$ ]] && SESSION_UNLOCK=true
fi
# Persist GORILLA_SESSION_UNLOCK (true/false) into the user config (idempotent).
if [[ -f "$CONFIG_FILE" ]]; then
 if grep -q '^GORILLA_SESSION_UNLOCK=' "$CONFIG_FILE"; then
 sed -i '' "s/^GORILLA_SESSION_UNLOCK=.*/GORILLA_SESSION_UNLOCK=\"$SESSION_UNLOCK\"/" "$CONFIG_FILE"
 else
 echo "GORILLA_SESSION_UNLOCK=\"$SESSION_UNLOCK\"" >> "$CONFIG_FILE"
 fi
fi
if $SESSION_UNLOCK; then success "Session-unlock: ON"; else skip "Session-unlock: off (tools always prompt)"; fi
true
