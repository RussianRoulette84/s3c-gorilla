#!/bin/bash
##########################################################################################
## s3c-gorilla — Installer
## Detects MacBook Pro (Touch ID) vs Hackintosh (manual password)
## Installs: env-gorilla, ssh-gorilla, gorilla-touchid
##########################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/bin"
DB_PATH="$HOME/Library/Mobile Documents/com~apple~CloudDocs/db.kdbx"

cat << 'EOF'

  /$$$$$$   /$$$$$$   /$$$$$$         /$$$$$$   /$$$$$$  /$$$$$$$  /$$$$$$ /$$       /$$        /$$$$$$
 /$$__  $$ /$$__  $$ /$$__  $$       /$$__  $$ /$$__  $$| $$__  $$|_  $$_/| $$      | $$       /$$__  $$
| $$  \__/|__/  \ $$| $$  \__/      | $$  \__/| $$  \ $$| $$  \ $$  | $$  | $$      | $$      | $$  \ $$
|  $$$$$$    /$$$$$/| $$            | $$ /$$$$| $$  | $$| $$$$$$$/  | $$  | $$      | $$      | $$$$$$$$
 \____  $$  |___  $$| $$            | $$|_  $$| $$  | $$| $$__  $$  | $$  | $$      | $$      | $$__  $$
 /$$  \ $$ /$$  \ $$| $$    $$      | $$  \ $$| $$  | $$| $$  \ $$  | $$  | $$      | $$      | $$  | $$
|  $$$$$$/|  $$$$$$/|  $$$$$$/      |  $$$$$$/|  $$$$$$/| $$  | $$ /$$$$$$| $$$$$$$$| $$$$$$$$| $$  | $$
 \______/  \______/  \______/        \______/  \______/ |__/  |__/|______/|________/|________/|__/  |__/

    secrets from the vault, not from the disk

EOF

echo "========================================"
echo "  INSTALLER"
echo "========================================"
echo ""

# ----------------------------------------------------------
# Step 1: Check/install KeePassXC
# ----------------------------------------------------------
echo "📦 [1/8] Checking KeePassXC..."
if ! command -v keepassxc-cli &>/dev/null; then
    echo "       Installing KeePassXC via Homebrew..."
    if ! command -v brew &>/dev/null; then
        echo "       ❌ Homebrew not found. Install it first: https://brew.sh"
        exit 1
    fi
    brew install --cask keepassxc
    echo "       ✅ KeePassXC installed"
else
    echo "       ✅ KeePassXC $(keepassxc-cli --version)"
fi

# ----------------------------------------------------------
# Step 2: Create bin directory
# ----------------------------------------------------------
echo ""
echo "📁 [2/8] Setting up ~/bin..."
mkdir -p "$BIN_DIR"
echo "       ✅ Ready"

# ----------------------------------------------------------
# Step 3: Install tools
# ----------------------------------------------------------
echo ""
echo "📦 [3/8] Installing tools..."

cp "$SCRIPT_DIR/env-gorilla" "$BIN_DIR/env-gorilla"
chmod +x "$BIN_DIR/env-gorilla"
echo "       ✅ env-gorilla"

cp "$SCRIPT_DIR/ssh-gorilla.sh" "$BIN_DIR/ssh-gorilla.sh"
echo "       ✅ ssh-gorilla"

# ----------------------------------------------------------
# Step 4: Detect Touch ID and install gorilla-touchid
# ----------------------------------------------------------
echo ""
echo "🔐 [4/8] Checking Touch ID..."

HAS_TOUCHID=false

if system_profiler SPiBridgeDataType 2>/dev/null | grep -qi "touch"; then
    HAS_TOUCHID=true
fi

if bioutil -r -s &>/dev/null 2>&1; then
    if bioutil -r -s 2>/dev/null | grep -q "biometry"; then
        HAS_TOUCHID=true
    fi
fi

if $HAS_TOUCHID; then
    echo "       ✅ Touch ID detected"
    echo "       Compiling gorilla-touchid..."

    cp "$SCRIPT_DIR/gorilla-touchid.swift" "$BIN_DIR/gorilla-touchid.swift"

    swiftc "$BIN_DIR/gorilla-touchid.swift" \
        -o "$BIN_DIR/gorilla-touchid" \
        -framework Security \
        -framework LocalAuthentication

    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/')

    if [[ -n "$SIGN_IDENTITY" ]]; then
        codesign -s "$SIGN_IDENTITY" -f "$BIN_DIR/gorilla-touchid" 2>/dev/null
        echo "       ✅ Compiled and signed: $SIGN_IDENTITY"
    else
        codesign -s - -f "$BIN_DIR/gorilla-touchid" 2>/dev/null
        echo "       ⚠️  Ad-hoc signed (Touch ID may need developer identity)"
    fi

    echo ""
    echo "       🔐 Store your master password for Touch ID access:"
    "$BIN_DIR/gorilla-touchid" store
else
    echo "       ℹ️  No Touch ID (Hackintosh mode)"
    echo "       Tools will prompt for master password"
fi

# ----------------------------------------------------------
# Step 5: SSH config check
# ----------------------------------------------------------
echo ""
echo "🔑 [5/8] SSH config..."

SSH_CONFIG="$HOME/.ssh/config"
if [[ -f "$SSH_CONFIG" ]]; then
    if grep -q "AddKeysToAgent\|UseKeychain" "$SSH_CONFIG"; then
        echo "       ⚠️  Remove AddKeysToAgent/UseKeychain from $SSH_CONFIG"
        echo ""
        echo "       Recommended:"
        echo "       Host *"
        echo "         IdentitiesOnly yes"
        echo "         HashKnownHosts yes"
        echo "         ServerAliveInterval 60"
        echo "         ServerAliveCountMax 3"
    else
        echo "       ✅ Looks good"
    fi
else
    echo "       ⚠️  No config found — create ~/.ssh/config"
fi

# ----------------------------------------------------------
# Step 6: Shell integration
# ----------------------------------------------------------
echo ""
echo "🐚 [6/8] Shell integration..."

if grep -q "ssh-gorilla" "$HOME/.zprofile" 2>/dev/null; then
    echo "       ✅ ssh-gorilla already in .zprofile"
else
    read -p "       Add ssh-gorilla to .zprofile? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "" >> "$HOME/.zprofile"
        echo "# s3c-gorilla: SSH wrapper with KeePassXC auto-unlock" >> "$HOME/.zprofile"
        echo "source \"\$HOME/bin/ssh-gorilla.sh\"" >> "$HOME/.zprofile"
        echo "       ✅ Added (restart terminal or: source ~/.zprofile)"
    else
        echo "       ⏭️  Skipped"
    fi
fi

# ----------------------------------------------------------
# Step 7: PATH check
# ----------------------------------------------------------
echo ""
echo "🛤️  [7/8] PATH..."

if echo "$PATH" | grep -q "$HOME/bin"; then
    echo "       ✅ ~/bin in PATH"
else
    echo "       ⚠️  ~/bin not in PATH"
    echo '       Add to .zprofile: export PATH="$HOME/bin:$PATH"'
fi

# ----------------------------------------------------------
# Step 8: Database check
# ----------------------------------------------------------
echo ""
echo "🗄️  [8/8] KeePassXC database..."

if [[ -f "$DB_PATH" ]]; then
    echo "       ✅ Found: db.kdbx"
else
    echo "       ⚠️  Not found at: $DB_PATH"
    echo "       Create one in KeePassXC or update GORILLA_DB in env-gorilla"
fi

# ----------------------------------------------------------
# Done
# ----------------------------------------------------------
echo ""
echo "========================================"
if $HAS_TOUCHID; then
    echo "  🦍 INSTALLED — Touch ID mode"
else
    echo "  🦍 INSTALLED — Hackintosh mode"
fi
echo "========================================"
echo ""
echo "┌─────────────────────────────────────────────────────────┐"
echo "│                                                         │"
echo "│  ssh-gorilla                                            │"
echo "│    ssh myserver.com           auto-unlock + connect     │"
echo "│                                                         │"
echo "│  env-gorilla                                            │"
echo "│    env-gorilla app -- cmd     run with secrets          │"
echo "│    env-gorilla --setup        setup Touch ID            │"
echo "│    env-gorilla --list         list projects             │"
echo "│                                                         │"
echo "│  Adding .env to KeePassXC:                              │"
echo '│    keepassxc-cli add "$DB" "ENV/project_x"              │'
echo '│    keepassxc-cli attachment-import "$DB" \              │'
echo '│      "ENV/project_x" .env /path/to/.env                │'
echo "│                                                         │"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
