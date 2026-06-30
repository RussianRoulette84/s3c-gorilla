# 09-database.sh — check the kdbx exists where the tools expect it.
section "[9/10] KeePassXC database"

if [[ -f "$DB_PATH" ]]; then
 success "Found: $(basename "$DB_PATH")"
else
 warn "Not found at: $DB_PATH"
 item "Create one in KeePassXC or update GORILLA_DB in $CONFIG_FILE"
fi
true
