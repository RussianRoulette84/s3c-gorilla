#!/bin/bash
# Fix file permissions based on security audit results and deployment issues
# Run with: sudo bash scripts/security/srv/fix_permissions.sh
# 
# This script fixes:
# - Critical system file ownership issues
# - SSH config permissions
# - Application-specific writable directories
# - Google Cloud authentication directories
# - Log directories
# - Generated content directories
#
# SKIPPED (as requested):
# - application env file ownership
# - main application directory ownership ($REPO_DIR stays root:${APP_GROUP} 750)
# - /etc/nginx/sites-available ownership

set -euo pipefail

echo "=========================================="
echo "FIXING FILE PERMISSIONS"
echo "Date: $(date)"
echo "=========================================="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Override these via env for your project
REPO_DIR="${REPO_DIR:-/opt/your_app}"
APP_USER="${APP_USER:-appuser}"
APP_GROUP="${APP_GROUP:-appuser}"
# Back-compat aliases used throughout the script
MCP_USER="$APP_USER"
MCP_GROUP="$APP_GROUP"

# 1. CRITICAL: Fix /etc/passwd ownership
echo -e "${YELLOW}[1/10]${NC} Fixing /etc/passwd ownership..."
if [ -f /etc/passwd ]; then
    current_owner=$(stat -c "%U:%G" /etc/passwd 2>/dev/null || echo "unknown")
    echo "  Current: $current_owner"
    chown root:root /etc/passwd
    new_owner=$(stat -c "%U:%G" /etc/passwd 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}Fixed:${NC} $new_owner"
else
    echo -e "  ${RED}ERROR:${NC} /etc/passwd not found!"
    exit 1
fi
echo ""

# 2. CRITICAL: Fix /etc/group ownership
echo -e "${YELLOW}[2/10]${NC} Fixing /etc/group ownership..."
if [ -f /etc/group ]; then
    current_owner=$(stat -c "%U:%G" /etc/group 2>/dev/null || echo "unknown")
    echo "  Current: $current_owner"
    chown root:root /etc/group
    new_owner=$(stat -c "%U:%G" /etc/group 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}Fixed:${NC} $new_owner"
else
    echo -e "  ${RED}ERROR:${NC} /etc/group not found!"
    exit 1
fi
echo ""

# 3. Fix SSH config permissions
echo -e "${YELLOW}[3/10]${NC} Fixing /etc/ssh/sshd_config permissions..."
if [ -f /etc/ssh/sshd_config ]; then
    current_perm=$(stat -c "%a" /etc/ssh/sshd_config 2>/dev/null || echo "unknown")
    echo "  Current: $current_perm"
    chmod 600 /etc/ssh/sshd_config
    new_perm=$(stat -c "%a" /etc/ssh/sshd_config 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}Fixed:${NC} $new_perm"
else
    echo -e "  ${YELLOW}WARNING:${NC} /etc/ssh/sshd_config not found (SSH may not be installed)"
fi
echo ""

# 4. Fix /etc/sudoers.d permissions
echo -e "${YELLOW}[4/10]${NC} Fixing /etc/sudoers.d permissions..."
if [ -d /etc/sudoers.d ]; then
    current_perm=$(stat -c "%a" /etc/sudoers.d 2>/dev/null || echo "unknown")
    echo "  Current: $current_perm"
    chmod 755 /etc/sudoers.d
    new_perm=$(stat -c "%a" /etc/sudoers.d 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}Fixed:${NC} $new_perm"
else
    echo -e "  ${RED}ERROR:${NC} /etc/sudoers.d not found!"
    exit 1
fi
echo ""

# 5. Fix /var/log permissions
echo -e "${YELLOW}[5/10]${NC} Fixing /var/log permissions..."
if [ -d /var/log ]; then
    current_perm=$(stat -c "%a" /var/log 2>/dev/null || echo "unknown")
    echo "  Current: $current_perm"
    chmod 755 /var/log
    new_perm=$(stat -c "%a" /var/log 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}Fixed:${NC} $new_perm"
    
    # Create and fix app log file if it exists (override via $APP_LOG_FILE)
    APP_LOG_FILE="${APP_LOG_FILE:-/var/log/app.log}"
    if [ -f "$APP_LOG_FILE" ]; then
        chown ${MCP_USER}:${MCP_GROUP} "$APP_LOG_FILE"
        chmod 644 "$APP_LOG_FILE"
        echo -e "  ${GREEN}Fixed:${NC} $APP_LOG_FILE ownership"
    fi
else
    echo -e "  ${RED}ERROR:${NC} /var/log not found!"
    exit 1
fi
echo ""

# 6. Fix application log directory
echo -e "${YELLOW}[6/10]${NC} Fixing application log directory..."
LOG_DIR="${REPO_DIR}/logs"
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    echo "  Created: $LOG_DIR"
fi
chown ${MCP_USER}:${MCP_GROUP} "$LOG_DIR"
chmod 755 "$LOG_DIR"
current_owner=$(stat -c "%U:%G" "$LOG_DIR" 2>/dev/null || echo "unknown")
echo -e "  ${GREEN}Fixed:${NC} $LOG_DIR -> $current_owner"
echo ""

# 7. Fix generated images directory (writable by mcp user)
echo -e "${YELLOW}[7/10]${NC} Fixing generated images directory..."
GENERATED_DIR="${REPO_DIR}/src/web/img/generated"
if [ ! -d "$GENERATED_DIR" ]; then
    mkdir -p "$GENERATED_DIR"
    echo "  Created: $GENERATED_DIR"
fi
chown -R ${MCP_USER}:${MCP_GROUP} "$GENERATED_DIR"
chmod -R 755 "$GENERATED_DIR"
current_owner=$(stat -c "%U:%G" "$GENERATED_DIR" 2>/dev/null || echo "unknown")
echo -e "  ${GREEN}Fixed:${NC} $GENERATED_DIR -> $current_owner"
echo ""

# 8. Fix generated video directory (if it exists)
echo -e "${YELLOW}[8/10]${NC} Fixing generated video directory..."
VIDEO_DIR="${REPO_DIR}/src/web/video/generated"
if [ ! -d "$VIDEO_DIR" ]; then
    mkdir -p "$VIDEO_DIR"
    echo "  Created: $VIDEO_DIR"
fi
chown -R ${MCP_USER}:${MCP_GROUP} "$VIDEO_DIR"
chmod -R 755 "$VIDEO_DIR"
current_owner=$(stat -c "%U:%G" "$VIDEO_DIR" 2>/dev/null || echo "unknown")
echo -e "  ${GREEN}Fixed:${NC} $VIDEO_DIR -> $current_owner"
echo ""

# 9. Fix .venv ownership + strip world rx (expected 750, not 755)
#    pip install as mcp user creates files with default umask (022 → 755/644)
#    which leaks installed package names to any user on the box. We want:
#      dirs + executables : 750 (rwxr-x---)
#      regular files      : 640 (rw-r-----)
#    `chmod -R go-w,o-rwx` preserves the execute bit on bin/* scripts while
#    stripping all world access and group write. Equivalent to 755→750,
#    644→640, 775→750, 666→640.
echo -e "${YELLOW}[9/10]${NC} Fixing .venv ownership + permissions..."
VENV_DIR="${REPO_DIR}/.venv"
if [ -d "$VENV_DIR" ]; then
    chown -R ${MCP_USER}:${MCP_GROUP} "$VENV_DIR"
    chmod -R go-w,o-rwx "$VENV_DIR"
    current_owner=$(stat -c "%U:%G" "$VENV_DIR" 2>/dev/null || echo "unknown")
    current_perm=$(stat -c "%a" "$VENV_DIR" 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}Fixed:${NC} $VENV_DIR -> $current_owner ($current_perm)"
else
    echo -e "  ${YELLOW}WARNING:${NC} $VENV_DIR not found (venv may not be created yet)"
fi

# Fix package egg-info directories (created during pip install -e .)
if [ -d "${REPO_DIR}/src" ]; then
    find "${REPO_DIR}/src" -name "*.egg-info" -type d -exec chown -R ${MCP_USER}:${MCP_GROUP} {} \; 2>/dev/null || true
    find "${REPO_DIR}/src" -name "*.egg-info" -type d -exec chmod -R 755 {} \; 2>/dev/null || true
    echo -e "  ${GREEN}Fixed:${NC} package egg-info directories"
fi
echo ""

# 10. Fix Google Cloud credentials directory
echo -e "${YELLOW}[10/10]${NC} Fixing Google Cloud credentials directory..."
GCLOUD_CONFIG_DIR="/home/${MCP_USER}/.config/gcloud"
if [ ! -d "$GCLOUD_CONFIG_DIR" ]; then
    mkdir -p "$GCLOUD_CONFIG_DIR"
    echo "  Created: $GCLOUD_CONFIG_DIR"
fi
chown -R ${MCP_USER}:${MCP_GROUP} "$GCLOUD_CONFIG_DIR"
chmod -R 700 "$GCLOUD_CONFIG_DIR"
current_owner=$(stat -c "%U:%G" "$GCLOUD_CONFIG_DIR" 2>/dev/null || echo "unknown")
echo -e "  ${GREEN}Fixed:${NC} $GCLOUD_CONFIG_DIR -> $current_owner"

# Also ensure mcp user home directory exists and is owned correctly
MCP_HOME="/home/${MCP_USER}"
if [ ! -d "$MCP_HOME" ]; then
    mkdir -p "$MCP_HOME"
    echo "  Created: $MCP_HOME"
fi
chown ${MCP_USER}:${MCP_GROUP} "$MCP_HOME"
chmod 755 "$MCP_HOME"
echo ""

echo "=========================================="
echo -e "${GREEN}ALL FIXES COMPLETE${NC}"
echo "=========================================="
echo ""
echo "Fixed directories:"
echo "  - Application logs: ${REPO_DIR}/logs"
echo "  - Generated images: ${REPO_DIR}/src/web/img/generated"
echo "  - Generated videos: ${REPO_DIR}/src/web/video/generated"
echo "  - Virtual environment: ${REPO_DIR}/.venv"
echo "  - Google Cloud config: /home/${MCP_USER}/.config/gcloud"
echo ""
echo "Recommendation: Re-run the security audit to verify:"
echo "  sudo bash scripts/security/srv/security_audit_permissions.sh"
echo ""
