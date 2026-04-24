#!/bin/bash
# One-liner comprehensive security audit command for Ubuntu 22
# Copy and paste this entire command on your server (run as root/sudo)
#
# Override the app paths for your project:
#   REPO_DIR    - main application directory (default: /opt/your_app)
#   APP_ENV     - app env file (default: /etc/your_app/your_app.env)
#   APP_SERVICE - systemd unit (default: /etc/systemd/system/your_app.service)
#   APP_LOG     - app log file (default: /var/log/app.log)

REPO_DIR="${REPO_DIR:-/opt/your_app}"
APP_ENV="${APP_ENV:-/etc/your_app/your_app.env}"
APP_SERVICE="${APP_SERVICE:-/etc/systemd/system/your_app.service}"
APP_LOG="${APP_LOG:-/var/log/app.log}"

echo "==========================================" && \
echo "FILE PERMISSIONS SECURITY AUDIT - $(date)" && \
echo "Hostname: $(hostname)" && \
echo "==========================================" && \
echo "" && \
echo "=== 1. CRITICAL SYSTEM FILES ===" && \
echo "Passwd: $(stat -c '%a %U:%G' /etc/passwd 2>/dev/null || echo 'N/A')" && \
echo "Shadow: $(stat -c '%a %U:%G' /etc/shadow 2>/dev/null || echo 'N/A')" && \
echo "Sudoers: $(stat -c '%a %U:%G' /etc/sudoers 2>/dev/null || echo 'N/A')" && \
echo "SSH Config: $(stat -c '%a %U:%G' /etc/ssh/sshd_config 2>/dev/null || echo 'N/A')" && \
echo "" && \
echo "=== 2. APPLICATION FILES ===" && \
[ -f "$APP_ENV" ] && echo "app env: $(stat -c '%a %U:%G' "$APP_ENV" 2>/dev/null || echo 'MISSING')" || echo "app env: NOT FOUND" && \
[ -d "$REPO_DIR" ] && echo "App Dir: $(stat -c '%a %U:%G' "$REPO_DIR" 2>/dev/null || echo 'N/A')" || echo "App Dir: NOT FOUND" && \
[ -f "$APP_SERVICE" ] && echo "Service: $(stat -c '%a %U:%G' "$APP_SERVICE" 2>/dev/null || echo 'N/A')" || echo "Service: NOT FOUND" && \
echo "" && \
echo "=== 3. WORLD-WRITABLE FILES (RISK) ===" && \
echo "In /etc: $(find /etc -type f -perm -002 2>/dev/null | wc -l) files" && \
find /etc -type f -perm -002 2>/dev/null | head -10 && \
echo "In /opt: $(find /opt -type f -perm -002 2>/dev/null | wc -l) files" && \
find /opt -type f -perm -002 2>/dev/null | head -10 && \
echo "In /var/log: $(find /var/log -type f -perm -002 2>/dev/null | wc -l) files" && \
find /var/log -type f -perm -002 2>/dev/null | head -10 && \
echo "" && \
echo "=== 4. SUID/SGID FILES ===" && \
echo "SUID files: $(find /usr /bin /sbin /opt -type f -perm -4000 2>/dev/null | wc -l)" && \
find /usr /bin /sbin /opt -type f -perm -4000 2>/dev/null | head -10 && \
echo "SGID files: $(find /usr /bin /sbin /opt -type f -perm -2000 2>/dev/null | wc -l)" && \
find /usr /bin /sbin /opt -type f -perm -2000 2>/dev/null | head -10 && \
echo "" && \
echo "=== 5. SENSITIVE FILES PERMISSIONS ===" && \
find /opt /etc /home -type f \( -name "*.env" -o -name ".env*" -o -name "*secret*" -o -name "*key*" \) 2>/dev/null | grep -vE "(node_modules|\.git|\.venv|__pycache__)" | while read f; do [ -f "$f" ] && perm=$(stat -c "%a" "$f" 2>/dev/null) && [ "$perm" != "600" ] && [ "$perm" != "400" ] && echo "[RISK] $f: $perm"; done && \
echo "" && \
echo "=== 6. APPLICATION DIRECTORY DETAILS ===" && \
[ -d "$REPO_DIR" ] && (echo "Top-level permissions:" && ls -ld "$REPO_DIR" && echo "" && echo "Files with wrong permissions:" && find "$REPO_DIR" -type f \( -perm -002 -o -perm -020 \) 2>/dev/null | head -20) || echo "Application directory not found" && \
echo "" && \
echo "=== 7. SYSTEMD SERVICES ===" && \
find /etc/systemd/system -name "*.service" -type f 2>/dev/null | while read f; do echo "$(stat -c '%a %U:%G' "$f" 2>/dev/null) $f"; done | head -20 && \
echo "" && \
echo "=== 8. NGINX CONFIG ===" && \
[ -f /etc/nginx/nginx.conf ] && echo "nginx.conf: $(stat -c '%a %U:%G' /etc/nginx/nginx.conf 2>/dev/null)" || echo "nginx.conf: NOT FOUND" && \
[ -d /etc/nginx/sites-available ] && echo "Sites available: $(ls -1 /etc/nginx/sites-available/ 2>/dev/null | head -5)" || echo "Nginx sites not found" && \
echo "" && \
echo "=== 9. LOG FILES ===" && \
[ -f "$APP_LOG" ] && echo "app log: $(stat -c '%a %U:%G' "$APP_LOG" 2>/dev/null)" || echo "app log: NOT FOUND" && \
echo "Syslog: $(stat -c '%a %U:%G' /var/log/syslog 2>/dev/null || echo 'N/A')" && \
echo "" && \
echo "=== 10. SUMMARY ===" && \
echo "World-writable files in critical dirs: $(find /etc /opt /var/log -type f -perm -002 2>/dev/null | wc -l)" && \
echo "SUID files: $(find /usr /bin /sbin /opt -type f -perm -4000 2>/dev/null | wc -l)" && \
echo "SGID files: $(find /usr /bin /sbin /opt -type f -perm -2000 2>/dev/null | wc -l)" && \
echo "Files in /etc not owned by root: $(find /etc -type f ! -user root 2>/dev/null | wc -l)" && \
echo "" && \
echo "==========================================" && \
echo "AUDIT COMPLETE - $(date)" && \
echo "=========================================="

