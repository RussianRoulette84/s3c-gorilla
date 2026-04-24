#!/bin/bash
# Comprehensive file-permissions security audit for a production server.
# Runs on the production box, not locally.
#
# Usage:
#   sudo bash scripts/security/srv/security_audit_permissions.sh
#   sudo bash scripts/security/srv/security_audit_permissions.sh > audit_report.txt 2>&1
#
# Covers: critical system files, SSH, application, nginx (all vhosts), TLS,
# iRedMail stack, Matrix Synapse, Nextcloud, Roundcube/SOGo, PHP-FPM,
# databases (MariaDB/Postgres/Redis), fail2ban, logs, SUID/SGID,
# world-writable files, sensitive dotfiles, home directories.

set -uo pipefail   # keep going on check failures, don't die on single errors

# ── config ───────────────────────────────────────────────────────
# Override these env vars for your project
REPO_DIR="${REPO_DIR:-/opt/your_app}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
# Back-compat aliases used throughout the script
MCP_USER="$APP_USER"
MCP_GROUP="$APP_GROUP"

OK_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; MISS_COUNT=0

# ── colors (NO_COLOR aware) ──────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  RED=''; GRN=''; YEL=''; BLU=''; DIM=''; BLD=''; NC=''
else
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'
  BLU=$'\033[0;34m'; DIM=$'\033[2m';   BLD=$'\033[1m'; NC=$'\033[0m'
fi

# ── header ───────────────────────────────────────────────────────
cat <<BANNER
==========================================
FILE PERMISSIONS SECURITY AUDIT
Date: $(date)
Hostname: $(hostname)
==========================================

BANNER

section() {
  printf '\n==========================================\n'
  printf '%s%s%s\n' "$BLU" "$1" "$NC"
  printf '==========================================\n'
}

# ── core check helpers ───────────────────────────────────────────
# check_file <path> <expected_perm|perm1|perm2> <expected_owner|'-'> <description>
# Multiple acceptable perms can be piped: "755|775"
# Owner "-" skips ownership check.
check_file() {
  local file="$1" expected_perm="$2" expected_owner="${3:-}" desc="$4"

  if [ ! -e "$file" ]; then
    printf '%s[MISSING]%s %s\n' "$YEL" "$NC" "$desc"
    printf '  File: %s (not found)\n\n' "$file"
    MISS_COUNT=$((MISS_COUNT+1))
    return
  fi

  local actual_perm actual_owner
  actual_perm=$(stat -c "%a" "$file" 2>/dev/null || echo "N/A")
  actual_owner=$(stat -c "%U:%G" "$file" 2>/dev/null || echo "N/A")

  local perm_ok=0
  IFS='|' read -ra perms <<< "$expected_perm"
  for p in "${perms[@]}"; do
    [ "$actual_perm" = "$p" ] && perm_ok=1 && break
  done

  if [ "$perm_ok" -eq 1 ]; then
    if [ -n "$expected_owner" ] && [ "$expected_owner" != "-" ] && [ "$actual_owner" != "$expected_owner" ]; then
      printf '%s[WARN]%s %s\n' "$YEL" "$NC" "$desc"
      printf '  File: %s\n' "$file"
      printf '  Permissions: %s (OK) | Owner: %s (Expected: %s)\n\n' "$actual_perm" "$actual_owner" "$expected_owner"
      WARN_COUNT=$((WARN_COUNT+1))
    else
      printf '%s[OK]%s %s\n' "$GRN" "$NC" "$desc"
      printf '  File: %s | Perm: %s | Owner: %s\n\n' "$file" "$actual_perm" "$actual_owner"
      OK_COUNT=$((OK_COUNT+1))
    fi
  else
    printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$desc"
    printf '  File: %s\n' "$file"
    printf '  Expected: %s | Actual: %s | Owner: %s\n\n' "$expected_perm" "$actual_perm" "$actual_owner"
    FAIL_COUNT=$((FAIL_COUNT+1))
  fi
}

# check_glob — expand a shell glob, then check_file each match.
check_glob() {
  local pattern="$1" expected_perm="$2" expected_owner="${3:-}" desc="$4"
  # shellcheck disable=SC2206
  local matches=( $pattern )
  if [ ! -e "${matches[0]}" ]; then
    printf '%s[MISSING]%s %s\n' "$YEL" "$NC" "$desc"
    printf '  Pattern: %s (no matches)\n\n' "$pattern"
    MISS_COUNT=$((MISS_COUNT+1))
    return
  fi
  for f in "${matches[@]}"; do
    check_file "$f" "$expected_perm" "$expected_owner" "$desc"
  done
}

# check_absent — fail loudly if a forbidden file exists.
check_absent() {
  local path="$1" desc="$2"
  if [ -e "$path" ]; then
    printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$desc"
    printf '  File should not exist: %s\n\n' "$path"
    FAIL_COUNT=$((FAIL_COUNT+1))
  else
    printf '%s[OK]%s %s\n' "$GRN" "$NC" "$desc"
    printf '  Absent: %s\n\n' "$path"
    OK_COUNT=$((OK_COUNT+1))
  fi
}

# ── 1. CRITICAL SYSTEM FILES ─────────────────────────────────────
section "1. CRITICAL SYSTEM FILES"
check_file  "/etc/passwd"                "644"     "root:root"   "System passwd file"
check_file  "/etc/shadow"                "640"     "root:shadow" "System shadow file"
check_file  "/etc/group"                 "644"     "root:root"   "System group file"
check_file  "/etc/gshadow"               "640"     "root:shadow" "System gshadow file"
check_file  "/etc/sudoers"               "440"     "root:root"   "Sudoers file"
check_file  "/etc/sudoers.d"             "750|755" "root:root"   "Sudoers.d directory"
check_file  "/etc/ssh/sshd_config"       "600"     "root:root"   "SSH daemon config"
check_glob  "/etc/ssh/ssh_host_*_key"    "600"     "root:root"   "SSH host key (private)"
check_glob  "/etc/ssh/ssh_host_*_key.pub" "644"    "root:root"   "SSH host key (public)"
check_file  "/root/.ssh"                 "700"     "root:root"   "root SSH directory"
check_file  "/root/.ssh/authorized_keys" "600"     "root:root"   "root authorized_keys"

# ── 2. APPLICATION ───────────────────────────────────────────────
section "2. APPLICATION ($REPO_DIR)"
# APP_ENV is owned by $APP_USER:$APP_GROUP so systemd EnvironmentFile can be
# read at service start. Mode 600 keeps it owner-only.
APP_ENV="${APP_ENV:-/etc/your_app/your_app.env}"
APP_SERVICE="${APP_SERVICE:-/etc/systemd/system/your_app.service}"
check_file "$APP_ENV"                    "600" "$APP_USER:$APP_GROUP"   "App environment file (CRITICAL — contains API keys)"
check_file "$REPO_DIR"                   "750" "root:$APP_GROUP"        "App application root"
check_file "$REPO_DIR/.venv"             "750" "$MCP_USER:$MCP_GROUP"   "Python virtual environment"
check_file "$REPO_DIR/src"               "750" "root:$APP_GROUP"        "App source code"
check_file "$APP_SERVICE"                "644" "root:root"              "App systemd unit"
check_absent "$REPO_DIR/.env"                        "App .env should NOT exist in repo (secrets live in \$APP_ENV)"
check_absent "$REPO_DIR/src/api/.env"                "src/api/.env should NOT exist"

# ── 3. NGINX ─────────────────────────────────────────────────────
section "3. NGINX CONFIGURATION"
check_file "/etc/nginx/nginx.conf"       "644" "root:root" "Nginx main config"
check_file "/etc/nginx/sites-available"  "755" "root:root" "Nginx sites-available dir"
check_file "/etc/nginx/sites-enabled"    "755" "root:root" "Nginx sites-enabled dir"
# Audit every enabled vhost, not just the primary
if [ -d /etc/nginx/sites-enabled ]; then
  for vhost in /etc/nginx/sites-enabled/*; do
    [ -e "$vhost" ] || continue
    check_file "$vhost" "644" "root:root" "Nginx vhost: $(basename "$vhost")"
  done
fi
# Shared templates (iRedMail ships these)
if [ -d /etc/nginx/templates ]; then
  for tmpl in /etc/nginx/templates/*.tmpl; do
    [ -e "$tmpl" ] || continue
    check_file "$tmpl" "644" "root:root" "Nginx template: $(basename "$tmpl")"
  done
fi
check_file "/etc/nginx/netdata.users"    "640|600" "root:www-data" "Netdata basic-auth password file"

# ── 4. SSL/TLS CERTIFICATES ──────────────────────────────────────
section "4. SSL/TLS CERTIFICATES (Let's Encrypt)"
check_file "/etc/letsencrypt"            "755"     "root:root"   "Let's Encrypt root"
check_file "/etc/letsencrypt/live"       "710|750" "-"           "live/ directory"
check_file "/etc/letsencrypt/archive"    "710|750" "-"           "archive/ directory (holds private keys)"
check_file "/etc/letsencrypt/keys"       "700"     "root:root"   "keys/ directory"
if [ -d /etc/letsencrypt/archive ]; then
  for d in /etc/letsencrypt/archive/*/; do
    [ -e "$d" ] || continue
    check_file "$d" "700|710|750" "-" "archive/$(basename "$d")"
  done
fi
printf '%s[INFO]%s Private key files (should be 600 or tighter):\n' "$BLU" "$NC"
find /etc/letsencrypt/archive -name 'privkey*.pem' -exec ls -l {} \; 2>/dev/null | head -10
printf '\n'
loose_keys=$(find /etc/letsencrypt/archive -name 'privkey*.pem' ! -perm 600 ! -perm 640 2>/dev/null)
if [ -n "$loose_keys" ]; then
  printf '%s[FAIL]%s Private keys with loose perms:\n%s\n\n' "$RED" "$NC" "$loose_keys"
  FAIL_COUNT=$((FAIL_COUNT+1))
fi

# ── 5. LOG FILES ─────────────────────────────────────────────────
section "5. LOG FILES"
# Ubuntu default is root:syslog; 755 or 775 both acceptable.
check_file "/var/log"                   "755|775" "root:syslog" "/var/log directory"
check_file "/var/log/nginx"             "755"     "root:adm"    "Nginx log directory"
check_file "/var/log/syslog"            "640|644" "syslog:adm"  "System log"
check_file "/var/log/auth.log"          "640|644" "syslog:adm"  "Auth log"
check_file "${APP_LOG_FILE:-/var/log/app.log}" "644" "$MCP_USER:$MCP_GROUP" "Application log (override via \$APP_LOG_FILE)"
check_file "/var/log/fail2ban.log"      "640|644" "-"           "Fail2ban log"

# ── 6. WORLD-WRITABLE FILES ──────────────────────────────────────
section "6. WORLD-WRITABLE FILES (security risk)"
for dir in /etc /opt /var/log /var/www /root /home; do
  if [ -d "$dir" ]; then
    printf '\n%sWorld-writable files in %s:%s\n' "$DIM" "$dir" "$NC"
    found=$(find "$dir" -xdev -type f -perm -002 ! -path '*/proc/*' 2>/dev/null | head -20)
    if [ -n "$found" ]; then
      echo "$found"
      FAIL_COUNT=$((FAIL_COUNT+1))
    else
      printf '  (none)\n'
    fi
  fi
done
printf '\n'

# ── 7. SUID/SGID FILES ───────────────────────────────────────────
section "7. SUID/SGID FILES (inventory)"
printf 'SUID files:\n'
find / -xdev -type f -perm -4000 2>/dev/null | sort
printf '\nSGID files:\n'
find / -xdev -type f -perm -2000 2>/dev/null | sort
printf '\n'

# ── 8. WORLD-READABLE SECRETS ────────────────────────────────────
section "8. WORLD-READABLE FILES IN SENSITIVE LOCATIONS"
printf 'World-readable files in /etc (excluding known-safe):\n'
wr=$(find /etc -xdev -type f -perm -004 \
     ! -name '*.conf' ! -name '*.cfg' ! -name '*.cnf' ! -name '*.ini' \
     ! -name '*.list' ! -name '*.pub' \
     ! -path '/etc/ssl/certs/*' ! -path '/etc/letsencrypt/live/*' \
     ! -path '/etc/letsencrypt/archive/*' ! -path '/etc/fonts/*' \
     ! -path '/etc/apt/*' ! -path '/etc/ca-certificates/*' \
     ! -path '/etc/update-motd.d/*' ! -path '/etc/xml/*' \
     2>/dev/null | head -20)
if [ -n "$wr" ]; then
  echo "$wr"
  WARN_COUNT=$((WARN_COUNT+1))
else
  printf '  (none found)\n'
fi
printf '\n'

# ── 9. /opt OWNERSHIP ────────────────────────────────────────────
section "9. FILES OWNED BY ROOT IN /opt (should be minimal)"
find /opt -xdev -maxdepth 4 -user root -type f 2>/dev/null | head -20
printf '\n'

# ── 10. DATABASES ────────────────────────────────────────────────
section "10. DATABASES (MariaDB / PostgreSQL / Redis)"
check_file "/etc/mysql/mariadb.conf.d"         "755"     "-"               "MariaDB config dir"
check_glob "/etc/mysql/mariadb.conf.d/*.cnf"   "644"     "-"               "MariaDB config"
check_file "/var/lib/mysql"                    "700|750" "mysql:mysql"     "MariaDB data dir"
check_glob "/etc/postgresql/*/main/postgresql.conf" "640" "postgres:postgres" "PostgreSQL config"
check_glob "/etc/postgresql/*/main/pg_hba.conf"     "640" "postgres:postgres" "PostgreSQL pg_hba"
check_glob "/var/lib/postgresql/*/main"             "700" "postgres:postgres" "PostgreSQL data dir"
check_file "/etc/redis/redis.conf"             "640|660" "redis:redis"     "Redis config"

# ── 11. MAIL STACK (iRedMail) ────────────────────────────────────
section "11. MAIL STACK (Postfix / Dovecot / OpenDKIM / Amavis)"
check_file "/etc/postfix/main.cf"              "644"     "root:root"       "Postfix main.cf"
check_file "/etc/postfix/master.cf"            "644"     "root:root"       "Postfix master.cf"
check_file "/etc/postfix/mysql"                "750"     "-"               "Postfix mysql credentials dir"
check_glob "/etc/postfix/mysql/*.cf"           "640"     "-"               "Postfix mysql credentials (DB passwords)"
check_file "/etc/dovecot/dovecot.conf"         "644"     "root:root"       "Dovecot main config"
check_file "/etc/dovecot/dovecot-mysql.conf"   "640"     "-"               "Dovecot MySQL connector"
check_file "/etc/opendkim"                     "750"     "-"               "OpenDKIM config dir"
check_glob "/etc/opendkim/keys/*/*.private"    "600"     "opendkim:opendkim" "OpenDKIM private keys"
check_file "/etc/amavis/conf.d"                "755"     "root:root"       "Amavis config dir"

# ── 12. iREDMAIL ADMIN UIs ───────────────────────────────────────
section "12. iREDMAIL WEB APPS (iRedAdmin / Roundcube / SOGo)"
check_file "/opt/www/iredadmin"                            "755"     "-"                 "iRedAdmin root"
check_file "/opt/www/iredadmin/settings.py"                "600|640" "iredadmin:iredadmin" "iRedAdmin settings (DB creds)"
check_file "/opt/www/roundcubemail"                        "755"     "-"                 "Roundcube root"
check_file "/opt/www/roundcubemail/config/config.inc.php"  "640"     "root:www-data"     "Roundcube config (DB creds)"
check_file "/etc/sogo/sogo.conf"                           "640"     "sogo:sogo"         "SOGo config (LDAP/DB creds)"

# ── 13. MATRIX SYNAPSE ───────────────────────────────────────────
section "13. MATRIX SYNAPSE"
check_file "/etc/matrix-synapse/homeserver.yaml"   "640" "matrix-synapse:matrix-synapse" "Synapse homeserver.yaml (secrets)"
check_file "/etc/matrix-synapse/conf.d"            "755" "matrix-synapse:matrix-synapse" "Synapse conf.d"
check_glob "/etc/matrix-synapse/*.signing.key"     "600" "matrix-synapse:matrix-synapse" "Synapse signing key"
check_file "/var/lib/matrix-synapse"               "750" "matrix-synapse:matrix-synapse" "Synapse data dir"
check_file "/var/www/matrix-web"                   "755" "-"                             "Element Web docroot"

# ── 14. NEXTCLOUD ────────────────────────────────────────────────
section "14. NEXTCLOUD"
check_file "/var/www/nextcloud"                    "755" "www-data:www-data" "Nextcloud docroot"
check_file "/var/www/nextcloud/config/config.php"  "640" "www-data:www-data" "Nextcloud config.php (DB creds + instance secrets)"
check_file "/var/www/nextcloud/data"               "750" "www-data:www-data" "Nextcloud data dir"
check_file "/etc/coolwsd/coolwsd.xml"              "640" "cool:cool"         "Collabora Online config"

# ── 15. MEGFIGYELŐ ───────────────────────────────────────────────
section "15. MEGFIGYELŐ (auth + ocr)"
check_file "/var/www/megfigyelo"                         "755" "www-data:www-data" "Megfigyelő docroot"
check_file "/etc/systemd/system/megfigyelo-auth.service" "644" "root:root"         "Megfigyelő auth unit"
check_file "/etc/systemd/system/megfigyelo-ocr.service"  "644" "root:root"         "Megfigyelő OCR unit"
check_glob "/var/www/megfigyelo/.env*"                   "600" "www-data:www-data" "Megfigyelő env file (if present)"

# ── 16. PHP-FPM ──────────────────────────────────────────────────
section "16. PHP-FPM"
check_glob "/etc/php/*/fpm/php-fpm.conf"   "644" "root:root" "PHP-FPM main config"
check_glob "/etc/php/*/fpm/pool.d/*.conf"  "644" "root:root" "PHP-FPM pool configs"

# ── 17. FAIL2BAN ─────────────────────────────────────────────────
section "17. FAIL2BAN"
check_file "/etc/fail2ban/jail.local"      "644" "root:root" "Fail2ban jail.local"
check_file "/etc/fail2ban/fail2ban.local"  "644" "root:root" "Fail2ban fail2ban.local"
check_glob "/etc/fail2ban/jail.d/*.local"  "644" "root:root" "Fail2ban custom jails"

# ── 18. LOOSE SECRET FILES ───────────────────────────────────────
section "18. LOOSE SECRET FILES (.env, *.key, *.pem outside known dirs)"
printf '\nWorld-readable .env/*.key/*.pem files:\n'
scratch=$(find /opt /var/www /home /root -xdev -type f \
  \( -name '.env' -o -name '.env.*' -o -name '*.key' -o -name '*.pem' \) \
  -perm -004 ! -path '*/node_modules/*' 2>/dev/null | head -30)
if [ -n "$scratch" ]; then
  echo "$scratch" | while read -r f; do
    printf '  %s %s\n' "$(stat -c '%a %U:%G' "$f" 2>/dev/null)" "$f"
  done
  WARN_COUNT=$((WARN_COUNT+1))
else
  printf '  (none)\n'
fi
printf '\n'

# ── 19. HOME DIRECTORIES ─────────────────────────────────────────
section "19. HOME DIRECTORIES"
for h in /root /home/*; do
  [ -d "$h" ] || continue
  actual=$(stat -c "%a" "$h" 2>/dev/null)
  owner=$(stat -c "%U:%G" "$h" 2>/dev/null)
  case "$actual" in
    700|750|755)
      printf '%s[OK]%s %s → %s %s\n' "$GRN" "$NC" "$h" "$actual" "$owner"
      OK_COUNT=$((OK_COUNT+1)) ;;
    *)
      printf '%s[WARN]%s %s → %s %s (too permissive, expected 700/750)\n' "$YEL" "$NC" "$h" "$actual" "$owner"
      WARN_COUNT=$((WARN_COUNT+1)) ;;
  esac
  if [ -f "$h/.ssh/authorized_keys" ]; then
    check_file "$h/.ssh/authorized_keys" "600|644" "-" "$(basename "$h") authorized_keys"
  fi
done
printf '\n'

# ── summary ──────────────────────────────────────────────────────
TOTAL=$((OK_COUNT+WARN_COUNT+FAIL_COUNT+MISS_COUNT))
cat <<EOF

==========================================
${BLD}SUMMARY${NC}
==========================================
  ${GRN}OK${NC}:      $OK_COUNT
  ${YEL}WARN${NC}:    $WARN_COUNT
  ${RED}FAIL${NC}:    $FAIL_COUNT
  ${YEL}MISSING${NC}: $MISS_COUNT
  ────────────
  Total:   $TOTAL

EOF

if [ "$FAIL_COUNT" -gt 0 ]; then
  printf '%s✗ %d FAIL(s) — action required.%s\n' "$RED" "$FAIL_COUNT" "$NC"
  exit 1
elif [ "$WARN_COUNT" -gt 0 ] || [ "$MISS_COUNT" -gt 0 ]; then
  printf '%s! %d warning(s), %d missing — review.%s\n' "$YEL" "$WARN_COUNT" "$MISS_COUNT" "$NC"
  exit 0
else
  printf '%s✓ all checks passed.%s\n' "$GRN" "$NC"
  exit 0
fi
