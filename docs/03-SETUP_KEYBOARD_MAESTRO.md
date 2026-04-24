# s3c-gorilla — Keyboard Maestro Shortcuts

## Prerequisites

- [Keyboard Maestro](https://www.keyboardmaestro.com/) installed
- s3c-gorilla installed and working
- `touchid-gorilla` compiled and signed

---

## 🔑 OTP Codes Viewer

**Shortcut:** `CTRL+Shift+T`

Shows all your 2FA/TOTP codes in a large overlay. Touch ID → codes displayed.

### Setup

1. Open Keyboard Maestro → Create New Macro
2. Name: `🦍 OTP Codes`
3. Trigger: Hot Key → `Cmd+Shift+O`
4. Action 1: **Execute Shell Script**
   - Shell: `/bin/bash`
   - Timeout: 60 seconds
   - Save results to variable: `OTP_LIST`
   - Script:

```bash
#!/bin/bash
export PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
PW=$(~/bin/touchid-gorilla 2>/dev/null)
if [[ -z "$PW" ]]; then echo "Touch ID failed"; exit 0; fi
DB="$HOME/Library/Mobile Documents/com~apple~CloudDocs/gorilla_tunnel.dat.kdbx"
entries=$(printf '%s' "$PW" | keepassxc-cli ls "$DB" "2FA/" -q 2>/dev/null)
output=""
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    code=$(printf '%s' "$PW" | keepassxc-cli show -t "$DB" "2FA/$entry" 2>/dev/null | grep -oE '^[0-9]{6}$')
    [[ -n "$code" ]] && output+="$entry: $code
"
done <<< "$entries"
echo "$output"
```

5. Action 2: **Display Text Large** → `%Variable%OTP_LIST%`

### Flow

`CTRL+Shift+T` → Touch ID prompt → all OTP codes displayed in overlay

---

## 📋 Copy Single OTP Code

**Shortcut:** `CTRL+Shift+T`

Copies a specific service's OTP code and types it into the active field. Replace `Atlassian` with your service name.

### Setup

1. Open Keyboard Maestro → Create New Macro
2. Name: `🦍 OTP Atlassian`
3. Trigger: Hot Key → `Cmd+Shift+T`
4. Action 1: **Execute Shell Script**
   - Shell: `/bin/bash`
   - Timeout: 30 seconds
   - Save results to variable: `OTP_CODE`
   - Script:

```bash
#!/bin/bash
export PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
PW=$(~/bin/touchid-gorilla 2>/dev/null)
if [[ -z "$PW" ]]; then exit 0; fi
DB="$HOME/Library/Mobile Documents/com~apple~CloudDocs/KeePassDB.kdbx"
printf '%s' "$PW" | keepassxc-cli show -t "$DB" "2FA/Atlassian" 2>/dev/null | grep -oE '^[0-9]{6}$'
```

5. Action 2: **Insert Text by Typing** → `%Variable%OTP_CODE%`

### Flow

Website asks for 2FA → `Cmd+Shift+T` → Touch ID → code typed automatically

---

## 💡 Tips

- Create separate macros per service if you want dedicated shortcuts (e.g. `Cmd+Shift+1` for Atlassian, `Cmd+Shift+2` for Cloudflare)
- The `export PATH` line is required because Keyboard Maestro runs in a clean shell environment
- Set timeout to at least 30 seconds — Touch ID + keepassxc-cli calls take time
- If the macro stops working after a macOS update, re-sign touchid-gorilla:

```bash
swiftc ~/bin/touchid-gorilla.swift -o ~/bin/touchid-gorilla -framework Security -framework LocalAuthentication
codesign -s "Apple Development: YOUR_IDENTITY" -f ~/bin/touchid-gorilla
```
