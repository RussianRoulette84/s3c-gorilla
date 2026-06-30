# 08-path.sh — verify /usr/local/bin is on PATH.
section "[8/10] PATH"

if echo ":$PATH:" | grep -q ":/usr/local/bin:"; then
 success "/usr/local/bin in PATH"
else
 warn "/usr/local/bin not in PATH — unusual on macOS"
 item 'Add to .zprofile: export PATH="/usr/local/bin:$PATH"'
fi
true
