#!/bin/bash
# Comprehensive sensitive files test

# Override via $1 or BASE_URL env var
BASE_URL="${1:-${BASE_URL:-https://api.example.com}}"
RESULTS_FILE="sensitive_files_test_results.txt"

echo "Sensitive Files Exposure Test" > "$RESULTS_FILE"
echo "Target: $BASE_URL" >> "$RESULTS_FILE"
echo "Date: $(date)" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

# Counters
TOTAL=0
EXPOSED=0
BLOCKED=0
INFO=0

test_file() {
    local file="$1"
    local status=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/$file")
    TOTAL=$((TOTAL + 1))
    
    if [ "$status" = "200" ]; then
        echo "❌ $file: HTTP $status (EXPOSED!)"
        echo "❌ $file: HTTP $status (EXPOSED!)" >> "$RESULTS_FILE"
        EXPOSED=$((EXPOSED + 1))
        return 1
    else
        echo "✅ $file: HTTP $status"
        echo "✅ $file: HTTP $status" >> "$RESULTS_FILE"
        BLOCKED=$((BLOCKED + 1))
        return 0
    fi
}

echo "=== Testing Environment Files ===" | tee -a "$RESULTS_FILE"
ENV_FILES=(
  ".env" ".env.local" ".env.production" ".env.development" ".env.backup"
  ".env.old" ".env.bak" ".env.save" ".env.tmp" ".env.copy" ".env.swp"
  ".env~" "mcp.env" "secrets.env" "config.env" "env.txt" "env.ini"
  "env.conf" "env.cfg" ".flaskenv" ".envrc"
)

for file in "${ENV_FILES[@]}"; do
    test_file "$file"
done

echo "" | tee -a "$RESULTS_FILE"
echo "=== Testing Git Repository Files ===" | tee -a "$RESULTS_FILE"
GIT_FILES=(
  ".git/config" ".git/HEAD" ".git/refs/heads/master" ".git/index"
  ".git/logs/HEAD" ".git/objects/" ".git/description" ".git/info/exclude"
  ".git/hooks/" ".git/COMMIT_EDITMSG" ".git/info/refs"
)

for file in "${GIT_FILES[@]}"; do
    test_file "$file"
done

echo "" | tee -a "$RESULTS_FILE"
echo "=== Testing Configuration Files ===" | tee -a "$RESULTS_FILE"
CONFIG_FILES=(
  "config.json" "secrets.json" "credentials.json" "package.json"
  "requirements.txt" "fabfile.py" "src/api/config.py" "setup.py"
  "pyproject.toml" "Makefile" "Dockerfile" "docker-compose.yml"
  "pip.conf" ".pypirc" ".python-version" "package-lock.json"
  "yarn.lock" ".npmrc" ".yarnrc"
)

for file in "${CONFIG_FILES[@]}"; do
    test_file "$file"
done

echo "" | tee -a "$RESULTS_FILE"
echo "=== Testing Path Traversal Attempts ===" | tee -a "$RESULTS_FILE"
TRAVERSAL_PATHS=(
  "../.env" "../../.env" "../../../.env" "../../etc/mcp/mcp.env"
  "../../etc/passwd" "../../etc/shadow" "../../etc/hosts"
  "../../etc/nginx/nginx.conf" "../../root/.ssh/id_rsa"
  "....//....//....//etc/passwd"
  "%2e%2e%2f%2e%2e%2f%2e%2e%2fetc%2fpasswd"
  "..%2F..%2F..%2Fetc%2Fpasswd"
)

for path in "${TRAVERSAL_PATHS[@]}"; do
    test_file "$path"
done

echo "" | tee -a "$RESULTS_FILE"
echo "=== Testing Backup/Archive Directories ===" | tee -a "$RESULTS_FILE"
BACKUP_PATHS=(
  "backup/.env" "backup/config.json" "tmp/.env" "temp/.env"
  "old/.env" "archive/.env" "backups/.env" ".backup/.env"
  "bak/.env" "backup.tar.gz" "backup.zip" "db_backup.sql" "database.sql"
)

for path in "${BACKUP_PATHS[@]}"; do
    test_file "$path"
done

echo "" | tee -a "$RESULTS_FILE"
echo "=== Testing Common Sensitive File Locations ===" | tee -a "$RESULTS_FILE"
SENSITIVE_PATHS=(
  ".aws/credentials" ".aws/config" ".ssh/id_rsa" ".ssh/id_rsa.pub"
  ".ssh/config" ".ssh/known_hosts" "google-service-account.json"
  "service-account.json" "credentials.json" ".htaccess" "web.config"
  "nginx.conf" "apache.conf" ".htpasswd" ".docker/config.json" ".kube/config"
)

for path in "${SENSITIVE_PATHS[@]}"; do
    test_file "$path"
done

echo "" | tee -a "$RESULTS_FILE"
echo "=== Testing Application Directories ===" | tee -a "$RESULTS_FILE"
APP_PATHS=(
  "api/.env" "v1/.env" "static/.env" "src/.env" "src/api/.env"
  "src/api/config.py" "admin/.env" "private/.env" "secure/.env"
  "internal/.env" "app/.env" "application/.env" "lib/.env" "vendor/.env"
  "node_modules/.env"
)

for path in "${APP_PATHS[@]}"; do
    test_file "$path"
done

echo "" | tee -a "$RESULTS_FILE"
echo "=== Testing Documentation Files ===" | tee -a "$RESULTS_FILE"
DOC_FILES=(
  "README.md" "SECURITY_AUDIT.md" "PENETRATION_TEST_REPORT.md"
  "SECURITY_ENDPOINTS.md" "SENSITIVE_FILES_TEST_REPORT.md"
  "CHANGELOG.md" "LICENSE" "CONTRIBUTING.md" "docs/README.md" "docs/SECURITY.md"
)

for file in "${DOC_FILES[@]}"; do
    status=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/$file")
    TOTAL=$((TOTAL + 1))
    if [ "$status" = "200" ]; then
        echo "⚠️  $file: HTTP $status (Exposed - informational only)"
        echo "⚠️  $file: HTTP $status (Exposed - informational only)" >> "$RESULTS_FILE"
        INFO=$((INFO + 1))
    else
        echo "✅ $file: HTTP $status"
        echo "✅ $file: HTTP $status" >> "$RESULTS_FILE"
        BLOCKED=$((BLOCKED + 1))
    fi
done

echo "" | tee -a "$RESULTS_FILE"
echo "=== SUMMARY ===" | tee -a "$RESULTS_FILE"
echo "Total files tested: $TOTAL" | tee -a "$RESULTS_FILE"
echo "Exposed files (CRITICAL): $EXPOSED" | tee -a "$RESULTS_FILE"
echo "Informational exposure: $INFO" | tee -a "$RESULTS_FILE"
echo "Blocked files: $BLOCKED" | tee -a "$RESULTS_FILE"

echo ""
echo "Results saved to: $RESULTS_FILE"
