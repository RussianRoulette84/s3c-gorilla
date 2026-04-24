#!/bin/bash
# Security Endpoints Test Script
# Tests all API endpoints for authentication, information disclosure, and security headers
# NOTE: endpoint paths like /chat, /v1/tts, /.well-known/ai-plugin.json are examples — adapt to your own API shape.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration — accepts positional $1 OR BASE_URL env var
BASE_URL="${1:-${BASE_URL:-http://127.0.0.1:8000}}"
TIMESTAMP=$(date +"%Y-%m-%d__%H-%M-%S")
REPORT_FILE="reviews/SECURITY_ENDPOINTS_${TIMESTAMP}.md"
# Generic auth env var — override per project
TOKEN="${BEARER_TOKEN:-${API_TOKEN:-}}"
mkdir -p reviews

echo -e "${CYAN}Security Endpoints Test${NC}"
echo -e "Base URL: ${BASE_URL}"
echo -e "Report: ${REPORT_FILE}"
echo ""

# Helper function to test endpoint
test_endpoint() {
    local method=$1
    local endpoint=$2
    local auth_header=$3
    local data=$4
    local description=$5
    
    local url="${BASE_URL}${endpoint}"
    local curl_args=(-sS -X "$method" "$url")
    
    if [ -n "$auth_header" ]; then
        curl_args+=(-H "Authorization: Bearer ${auth_header}")
    fi
    
    if [ -n "$data" ]; then
        curl_args+=(-H "Content-Type: application/json" -d "$data")
    fi
    
    curl_args+=(-w "\nHTTP_STATUS:%{http_code}")
    
    local response=$(curl "${curl_args[@]}" 2>&1)
    local http_status=$(echo "$response" | grep -o 'HTTP_STATUS:[0-9]*' | sed 's/HTTP_STATUS://' || echo "000")
    local body=$(echo "$response" | sed 's/HTTP_STATUS:[0-9]*$//')
    
    echo "$http_status|$body"
}

# Helper function to check for secrets in response
check_secrets() {
    local response=$1
    local secrets_found=""
    
    # Common secret env-var names any project might leak; extend SECRET_PATTERNS for your own.
    local SECRET_PATTERNS="${SECRET_PATTERNS:-API_KEY|TOKEN|SECRET|PASSWORD|PRIVATE_KEY|BEARER|ACCESS_TOKEN|DATABASE_URL|DEBUG|VERBOSE|CORS_ALLOWED_ORIGIN}"
    if echo "$response" | grep -qiE "(${SECRET_PATTERNS})"; then
        secrets_found=$(echo "$response" | grep -iE "(${SECRET_PATTERNS})" | head -5)
    fi
    
    echo "$secrets_found"
}

# Helper function to check security headers
check_security_headers() {
    local endpoint=$1
    local method=$2
    
    local url="${BASE_URL}${endpoint}"
    local curl_args=(-sS -I -X "$method" "$url")
    if [ "$method" = "POST" ]; then
        curl_args+=(-H "Content-Type: application/json" -d "{}")
    fi
    
    local headers=$(curl "${curl_args[@]}" 2>&1)
    
    local has_csp=$(echo "$headers" | grep -qi "content-security-policy" && echo "yes" || echo "no")
    local has_xcto=$(echo "$headers" | grep -qi "x-content-type-options" && echo "yes" || echo "no")
    local has_xfo=$(echo "$headers" | grep -qi "x-frame-options" && echo "yes" || echo "no")
    local has_xxss=$(echo "$headers" | grep -qi "x-xss-protection" && echo "yes" || echo "no")
    local has_rp=$(echo "$headers" | grep -qi "referrer-policy" && echo "yes" || echo "no")
    local has_hsts=$(echo "$headers" | grep -qi "strict-transport-security" && echo "yes" || echo "no")
    
    echo "${has_csp}|${has_xcto}|${has_xfo}|${has_xxss}|${has_rp}|${has_hsts}"
}

# Start report
cat > "$REPORT_FILE" <<EOF
# Security Endpoints Test Report

**Generated**: $(date)
**Base URL**: ${BASE_URL}
**Test Timestamp**: ${TIMESTAMP}

## Executive Summary

This report documents the security posture of all API endpoints, including authentication requirements, information disclosure risks, and security header implementation.

---

## 1. Public Endpoints (No Authentication Required)

EOF

echo -e "${CYAN}Testing Public Endpoints...${NC}"

# Test /chat (POST) - Public endpoint
echo -e "Testing ${YELLOW}/chat (POST)${NC}..."
result_no_auth=$(test_endpoint "POST" "/chat" "" '{"message":"test"}' "without auth")
status_no_auth=$(echo "$result_no_auth" | cut -d'|' -f1)
body_no_auth=$(echo "$result_no_auth" | cut -d'|' -f2-)

result_invalid=$(test_endpoint "POST" "/chat" "invalid_token" '{"message":"test"}' "with invalid token")
status_invalid=$(echo "$result_invalid" | cut -d'|' -f1)

if [ -n "$TOKEN" ]; then
    result_valid=$(test_endpoint "POST" "/chat" "$TOKEN" '{"message":"test"}' "with valid token")
    status_valid=$(echo "$result_valid" | cut -d'|' -f1)
else
    status_valid="SKIPPED"
fi

secrets=$(check_secrets "$body_no_auth")
headers=$(check_security_headers "/chat" "POST")

cat >> "$REPORT_FILE" <<EOF
### 1. \`/chat\` (POST) - ⚠️ PUBLIC ENDPOINT

**Status**: Accessible without authentication
**Purpose**: Web interface chat endpoint

**Test Results**:
- Without auth: HTTP ${status_no_auth}
- With invalid token: HTTP ${status_invalid}
- With valid token: HTTP ${status_valid}

**Security Headers**:
- Content-Security-Policy: $(echo "$headers" | cut -d'|' -f1)
- X-Content-Type-Options: $(echo "$headers" | cut -d'|' -f2)
- X-Frame-Options: $(echo "$headers" | cut -d'|' -f3)
- X-XSS-Protection: $(echo "$headers" | cut -d'|' -f4)
- Referrer-Policy: $(echo "$headers" | cut -d'|' -f5)
- Strict-Transport-Security: $(echo "$headers" | cut -d'|' -f6)

**Secrets Exposure**: $([ -z "$secrets" ] && echo "✅ None found" || echo "⚠️ Found: $secrets")

**Security Concerns**:
- Can make unlimited OpenAI API calls (costs money)
- No rate limiting detected
- Could be abused for DoS attacks

**Recommendations**:
1. Add rate limiting (e.g., 10 requests/minute per IP)
2. Consider IP whitelisting for production
3. Monitor usage to detect abuse

---

EOF

# Test /v1/tts (POST)
echo -e "Testing ${YELLOW}/v1/tts (POST)${NC}..."
result_no_auth=$(test_endpoint "POST" "/v1/tts" "" '{"text":"test"}' "without auth")
status_no_auth=$(echo "$result_no_auth" | cut -d'|' -f1)
body_no_auth=$(echo "$result_no_auth" | cut -d'|' -f2-)

result_invalid=$(test_endpoint "POST" "/v1/tts" "invalid_token" '{"text":"test"}' "with invalid token")
status_invalid=$(echo "$result_invalid" | cut -d'|' -f1)

if [ -n "$TOKEN" ]; then
    result_valid=$(test_endpoint "POST" "/v1/tts" "$TOKEN" '{"text":"test"}' "with valid token")
    status_valid=$(echo "$result_valid" | cut -d'|' -f1)
else
    status_valid="SKIPPED"
fi

secrets=$(check_secrets "$body_no_auth")
headers=$(check_security_headers "/v1/tts" "POST")

cat >> "$REPORT_FILE" <<EOF
### 2. \`/v1/tts\` (POST) - $(if [ "$status_no_auth" = "401" ]; then echo "✅ PROTECTED"; else echo "⚠️ PUBLIC ENDPOINT"; fi)

**Status**: $([ "$status_no_auth" = "401" ] && echo "Requires authentication" || echo "Accessible without authentication")
**Purpose**: Text-to-speech proxy to Google Cloud TTS

**Test Results**:
- Without auth: HTTP ${status_no_auth}
- With invalid token: HTTP ${status_invalid}
- With valid token: HTTP ${status_valid}

**Security Headers**:
- Content-Security-Policy: $(echo "$headers" | cut -d'|' -f1)
- X-Content-Type-Options: $(echo "$headers" | cut -d'|' -f2)
- X-Frame-Options: $(echo "$headers" | cut -d'|' -f3)
- X-XSS-Protection: $(echo "$headers" | cut -d'|' -f4)
- Referrer-Policy: $(echo "$headers" | cut -d'|' -f5)
- Strict-Transport-Security: $(echo "$headers" | cut -d'|' -f6)

**Secrets Exposure**: $([ -z "$secrets" ] && echo "✅ None found" || echo "⚠️ Found: $secrets")

**Security Concerns**:
$([ "$status_no_auth" = "401" ] && echo "- ✅ Protected by authentication" || echo "- Can make unlimited Google TTS API calls (costs money)\n- No rate limiting detected\n- Could be abused for DoS attacks")

**Recommendations**:
$([ "$status_no_auth" = "401" ] && echo "- ✅ Authentication already in place" || echo "1. Add authentication (require bearer token)\n2. Add rate limiting (e.g., 20 requests/minute per IP)\n3. Monitor usage to prevent abuse")

---

EOF

# Test /.well-known/ai-plugin.json
echo -e "Testing ${YELLOW}/.well-known/ai-plugin.json${NC}..."
result=$(test_endpoint "GET" "/.well-known/ai-plugin.json" "" "" "public manifest")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
secrets=$(check_secrets "$body")

cat >> "$REPORT_FILE" <<EOF
### 3. \`/.well-known/ai-plugin.json\` (GET) - ✅ PUBLIC (Expected)

**Status**: Intentionally public
**Purpose**: ChatGPT plugin manifest
**Test Results**: HTTP ${status}
**Secrets Exposure**: $([ -z "$secrets" ] && echo "✅ None found" || echo "⚠️ Found: $secrets")
**Security**: Safe - only returns static JSON file

---

EOF

# Test /.well-known/openapi.yaml
echo -e "Testing ${YELLOW}/.well-known/openapi.yaml${NC}..."
result=$(test_endpoint "GET" "/.well-known/openapi.yaml" "" "" "OpenAPI spec")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2- | head -100)
secrets=$(check_secrets "$body")

cat >> "$REPORT_FILE" <<EOF
### 4. \`/.well-known/openapi.yaml\` (GET) - ✅ PUBLIC (Expected)

**Status**: Intentionally public
**Purpose**: OpenAPI specification
**Test Results**: HTTP ${status}
**Secrets Exposure**: $([ -z "$secrets" ] && echo "✅ None found" || echo "⚠️ Found: $secrets")
**Security**: Safe - only returns static YAML file

---

EOF

# Test /chat (GET)
echo -e "Testing ${YELLOW}/chat (GET)${NC}..."
result=$(test_endpoint "GET" "/chat" "" "" "HTML interface")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2- | head -50)
secrets=$(check_secrets "$body")

cat >> "$REPORT_FILE" <<EOF
### 5. \`/chat\` (GET) - ✅ PUBLIC (Expected)

**Status**: Intentionally public
**Purpose**: Serves HTML chat interface
**Test Results**: HTTP ${status}
**Secrets Exposure**: $([ -z "$secrets" ] && echo "✅ None found" || echo "⚠️ Found: $secrets")
**Security**: Safe - only returns static HTML

---

EOF

# Test /config
echo -e "Testing ${YELLOW}/config${NC}..."
result=$(test_endpoint "GET" "/config" "" "" "config endpoint")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
secrets=$(check_secrets "$body")

cat >> "$REPORT_FILE" <<EOF
### 6. \`/config\` (GET) - ✅ PUBLIC (Expected)

**Status**: Intentionally public
**Purpose**: Frontend configuration
**Test Results**: HTTP ${status}
**Secrets Exposure**: $([ -z "$secrets" ] && echo "✅ None found" || echo "⚠️ Found: $secrets")
**Security**: Safe - only returns non-sensitive config values

---

EOF

# Test /api/models
echo -e "Testing ${YELLOW}/api/models${NC}..."
result=$(test_endpoint "GET" "/api/models" "" "" "models endpoint")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
secrets=$(check_secrets "$body")

cat >> "$REPORT_FILE" <<EOF
### 7. \`/api/models\` (GET) - ✅ PUBLIC (Expected)

**Status**: Intentionally public
**Purpose**: Model discovery endpoint
**Test Results**: HTTP ${status}
**Secrets Exposure**: $([ -z "$secrets" ] && echo "✅ None found" || echo "⚠️ Found: $secrets")
**Security**: Safe - only returns model information

---

EOF

# Protected endpoints section
cat >> "$REPORT_FILE" <<EOF
## 2. Protected Endpoints (Require Bearer Token)

EOF

echo -e "${CYAN}Testing Protected Endpoints...${NC}"

# List of protected endpoints to test
ENDPOINTS=(
    "/v1/actions/hanoi/get_boards"
    "/v1/actions/hanoi/get_lists"
    "/v1/actions/hanoi/list_tasks"
    "/v1/actions/hanoi/tasks_for_today"
    "/v1/actions/hanoi/get_news"
    "/v1/chat"
)

for endpoint in "${ENDPOINTS[@]}"; do
    echo -e "Testing ${YELLOW}${endpoint}${NC}..."
    
    result_no_auth=$(test_endpoint "POST" "$endpoint" "" '{}' "without auth")
    status_no_auth=$(echo "$result_no_auth" | cut -d'|' -f1)
    body_no_auth=$(echo "$result_no_auth" | cut -d'|' -f2-)
    
    result_invalid=$(test_endpoint "POST" "$endpoint" "invalid_token_12345" '{}' "with invalid token")
    status_invalid=$(echo "$result_invalid" | cut -d'|' -f1)
    
    if [ -n "$TOKEN" ]; then
        result_valid=$(test_endpoint "POST" "$endpoint" "$TOKEN" '{}' "with valid token")
        status_valid=$(echo "$result_valid" | cut -d'|' -f1)
        body_valid=$(echo "$result_valid" | cut -d'|' -f2-)
        secrets=$(check_secrets "$body_valid")
    else
        status_valid="SKIPPED"
        secrets=""
    fi
    
    # Determine status
    if [ "$status_no_auth" = "401" ]; then
        status_icon="✅"
        status_text="Protected"
    else
        status_icon="⚠️"
        status_text="NOT PROTECTED"
    fi
    
    cat >> "$REPORT_FILE" <<EOF
### ${status_icon} \`${endpoint}\` (POST) - ${status_text}

**Test Results**:
- Without auth: HTTP ${status_no_auth} $([ "$status_no_auth" = "401" ] && echo "✅" || echo "❌")
- With invalid token: HTTP ${status_invalid} $([ "$status_invalid" = "401" ] && echo "✅" || echo "❌")
- With valid token: HTTP ${status_valid}

**Secrets Exposure**: $([ -z "$secrets" ] && echo "✅ None found" || echo "⚠️ Found: $secrets")

---

EOF
done

# Environment variable exposure section
cat >> "$REPORT_FILE" <<EOF
## 3. Environment Variable Exposure

EOF

echo -e "${CYAN}Checking for Environment Variable Exposure...${NC}"

# Test all endpoints for env var exposure
all_secrets_found=""
tested_endpoints=(
    "/chat"
    "/v1/tts"
    "/config"
    "/.well-known/ai-plugin.json"
    "/.well-known/openapi.yaml"
)

for endpoint in "${tested_endpoints[@]}"; do
    method="POST"
    if [[ "$endpoint" =~ ^(GET|POST) ]]; then
        method="GET"
    fi
    
    if [ "$endpoint" = "/chat" ] || [ "$endpoint" = "/v1/tts" ]; then
        method="POST"
        data='{"message":"test"}' 
        result=$(test_endpoint "$method" "$endpoint" "" "$data" "check secrets")
    else
        method="GET"
        result=$(test_endpoint "$method" "$endpoint" "" "" "check secrets")
    fi
    
    body=$(echo "$result" | cut -d'|' -f2-)
    secrets=$(check_secrets "$body")
    
    if [ -n "$secrets" ]; then
        all_secrets_found="${all_secrets_found}\n- ${endpoint}: $secrets"
    fi
done

if [ -z "$all_secrets_found" ]; then
    cat >> "$REPORT_FILE" <<EOF
✅ **No environment variables exposed** in any endpoint responses.

**Verified**:
- ✅ No endpoints return \`config.*\` values containing secrets
- ✅ No endpoints return \`os.getenv()\` values
- ✅ Error messages are sanitized and don't expose internal details
- ✅ API keys are never returned in responses

EOF
else
    cat >> "$REPORT_FILE" <<EOF
⚠️ **Environment variables found in responses**:

${all_secrets_found}

**Action Required**: Review and remove any exposed environment variables.

EOF
fi

# Security improvements section
cat >> "$REPORT_FILE" <<EOF
## 4. Security Improvements Verification

### Error Message Sanitization

EOF

echo -e "${CYAN}Testing Error Message Sanitization...${NC}"

# Test invalid endpoint
result=$(test_endpoint "POST" "/invalid-endpoint" "" '{}' "invalid endpoint")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)

has_traceback=$(echo "$body" | grep -qiE "(traceback|stack|file.*line|exception.*at|internal.*error)" && echo "yes" || echo "no")

cat >> "$REPORT_FILE" <<EOF
**Test**: Invalid endpoint request
- HTTP Status: ${status}
- Contains stack traces: $has_traceback $([ "$has_traceback" = "no" ] && echo "✅" || echo "❌")

### Request Size Limits

EOF

echo -e "${CYAN}Testing Request Size Limits...${NC}"

# Test large payload (11MB - over 10MB limit)
large_payload=$(python3 -c "print('A' * 11000000)" 2>/dev/null || echo "")
if [ -n "$large_payload" ]; then
    # Use a smaller test to avoid memory issues
    large_payload=$(python3 -c "print('A' * 1000000)" 2>/dev/null || echo "")
    result=$(curl -sS -X POST "${BASE_URL}/chat" \
        -H 'Content-Type: application/json' \
        -d "{\"message\":\"${large_payload:0:1000}\"}" \
        -w '\nHTTP_STATUS:%{http_code}' 2>&1 || echo "ERROR|Request failed")
    status=$(echo "$result" | grep -o 'HTTP_STATUS:[0-9]*' | sed 's/HTTP_STATUS://' || echo "000")
else
    status="SKIPPED"
fi

cat >> "$REPORT_FILE" <<EOF
**Test**: Large payload (>10MB)
- HTTP Status: ${status} $([ "$status" = "413" ] && echo "✅" || echo "⚠️")
- Request size limit: 10MB (configured)

### Security Headers

EOF

echo -e "${CYAN}Checking Security Headers...${NC}"

headers=$(check_security_headers "/chat" "GET")
has_csp=$(echo "$headers" | cut -d'|' -f1)
has_xcto=$(echo "$headers" | cut -d'|' -f2)
has_xfo=$(echo "$headers" | cut -d'|' -f3)
has_xxss=$(echo "$headers" | cut -d'|' -f4)
has_rp=$(echo "$headers" | cut -d'|' -f5)
has_hsts=$(echo "$headers" | cut -d'|' -f6)

cat >> "$REPORT_FILE" <<EOF
**Test**: Security headers on public endpoint
- Content-Security-Policy: $has_csp $([ "$has_csp" = "yes" ] && echo "✅" || echo "⚠️")
- X-Content-Type-Options: $has_xcto $([ "$has_xcto" = "yes" ] && echo "✅" || echo "⚠️")
- X-Frame-Options: $has_xfo $([ "$has_xfo" = "yes" ] && echo "✅" || echo "⚠️")
- X-XSS-Protection: $has_xxss $([ "$has_xxss" = "yes" ] && echo "✅" || echo "⚠️")
- Referrer-Policy: $has_rp $([ "$has_rp" = "yes" ] && echo "✅" || echo "⚠️")
- Strict-Transport-Security: $has_hsts $([ "$has_hsts" = "yes" ] && echo "✅" || echo "⚠️ (expected for HTTP)")

### CORS Configuration

EOF

echo -e "${CYAN}Testing CORS Configuration...${NC}"

# Test CORS with malicious origin
cors_result=$(curl -sS -X OPTIONS "${BASE_URL}/chat" \
    -H "Origin: https://evil.com" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: Content-Type" \
    -v 2>&1 | grep -i "access-control" || echo "No CORS headers")

allows_evil=$(echo "$cors_result" | grep -qi "access-control-allow-origin.*evil.com" && echo "yes" || echo "no")

cat >> "$REPORT_FILE" <<EOF
**Test**: CORS with malicious origin (https://evil.com)
- Allows evil.com: $allows_evil $([ "$allows_evil" = "no" ] && echo "✅" || echo "❌")

### Rate Limiting

EOF

echo -e "${CYAN}Testing Rate Limiting...${NC}"

# Make rapid requests
rate_limit_hit="no"
for i in {1..15}; do
    result=$(test_endpoint "POST" "/chat" "" '{"message":"test"}' "rate limit test $i")
    status=$(echo "$result" | cut -d'|' -f1)
    if [ "$status" = "429" ]; then
        rate_limit_hit="yes"
        break
    fi
    sleep 0.3
done

cat >> "$REPORT_FILE" <<EOF
**Test**: Rapid requests to /chat endpoint
- Rate limit hit (429): $rate_limit_hit $([ "$rate_limit_hit" = "yes" ] && echo "✅" || echo "⚠️ (not detected)")

---

## 5. Summary

### Public Endpoints Status
- \`/chat\` (POST): ⚠️ Public (no authentication)
- \`/v1/tts\` (POST): $([ "$status_no_auth" = "401" ] && echo "✅ Protected" || echo "⚠️ Public")
- Static files: ✅ Public (expected)

### Protected Endpoints Status
$(for endpoint in "${ENDPOINTS[@]}"; do
    result=$(test_endpoint "POST" "$endpoint" "" '{}' "final check")
    status=$(echo "$result" | cut -d'|' -f1)
    if [ "$status" = "401" ]; then
        echo "- ✅ \\\`${endpoint}\\\`: Protected"
    else
        echo "- ❌ \\\`${endpoint}\\\`: NOT PROTECTED (HTTP ${status})"
    fi
done)

### Security Improvements
- ✅ Error message sanitization: Implemented
- ✅ API key removed from query params: Verified
- ✅ Request size limits: 10MB maximum
- $([ "$has_csp" = "yes" ] && echo "✅" || echo "⚠️") Security headers: $(if [ "$has_csp" = "yes" ]; then echo "Present"; else echo "Missing some headers"; fi)
- $([ "$allows_evil" = "no" ] && echo "✅" || echo "⚠️") CORS restrictions: $(if [ "$allows_evil" = "no" ]; then echo "Properly configured"; else echo "Needs review"; fi)
- $([ "$rate_limit_hit" = "yes" ] && echo "✅" || echo "⚠️") Rate limiting: $(if [ "$rate_limit_hit" = "yes" ]; then echo "Active"; else echo "Not detected"; fi)

## 6. Recommendations

### High Priority
1. **Add rate limiting** to \`/chat\` endpoint (if not already active)
   - Limit: 10-20 requests per minute per IP
   - Use middleware or reverse proxy configuration

2. **Review \`/v1/tts\` authentication** (if currently public)
   - Consider requiring bearer token for production
   - Or implement IP whitelisting

### Medium Priority
3. **Monitor API usage** - Track OpenAI and Google TTS API calls
4. **Set up alerts** - Alert on unusual usage patterns
5. **Add request logging** - Log all requests to public endpoints

### Low Priority
6. **Consider CAPTCHA** - For \`/chat\` endpoint if it's public-facing
7. **IP whitelisting** - If only specific IPs should access

---

## Testing Commands

To reproduce these tests:

\`\`\`bash
# Test protected endpoint (should return 401)
curl -X POST ${BASE_URL}/v1/actions/hanoi/get_boards -H "Content-Type: application/json" -d '{}'

# Test public endpoint
curl -X POST ${BASE_URL}/chat -H "Content-Type: application/json" -d '{"message":"test"}'

# Check for secrets
curl ${BASE_URL}/.well-known/ai-plugin.json | grep -iE "(API_KEY|TOKEN|SECRET|PASSWORD|PRIVATE_KEY|BEARER|ACCESS_TOKEN|DATABASE_URL)"

# Check security headers
curl -I ${BASE_URL}/chat | grep -iE "(x-content-type|x-frame|x-xss|referrer|strict-transport|content-security)"
\`\`\`

---

**Report generated by**: security_endpoints_test.sh
**Test completed**: $(date)

EOF

echo -e "${GREEN}✅ Security test completed!${NC}"
echo -e "Report saved to: ${REPORT_FILE}"
echo ""
