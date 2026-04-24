#!/bin/bash
# Comprehensive Penetration Test Script
# NOTE: endpoint paths like /chat and /v1/tts below are examples — adapt to your own API shape.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
# Override the target by passing as $1 or setting BASE_URL; BEARER_TOKEN is the generic auth env var
BASE_URL="${1:-${BASE_URL:-https://api.example.com}}"
TIMESTAMP=$(date +"%Y-%m-%d__%H-%M-%S")
REPORT_FILE="reviews/PENETRATION_TEST_REPORT_${TIMESTAMP}.md"
TOKEN="${BEARER_TOKEN:-${API_TOKEN:-}}"
mkdir -p reviews

# Counters
TOTAL=0
PASSED=0
WARN=0
FAILED=0
HIGH_RISK=0
MID_RISK=0
LOW_RISK=0

echo -e "${CYAN}Penetration Test${NC}"
echo -e "Base URL: ${BASE_URL}"
echo -e "Report: ${REPORT_FILE}"
echo ""

# Initialize report
cat > "$REPORT_FILE" <<EOF
# Penetration Test Report - ${BASE_URL}
**Date:** $(date +"%Y-%m-%d %H:%M:%S")
**Target:** ${BASE_URL}
**Tester:** Automated

## Executive Summary

[Summary will be filled after tests]

## Security Metrics

**Risk Assessment Summary:**
- **High Risk**: 0
- **Mid Risk**: 0
- **Low Risk**: 0
- **Working**: 0
- **TOTAL**: 0

**Progress Tracking:**
- ✅ Passed: 0
- ⚠️ Needs Attention: 0
- ❌ Failed: 0

---

## Test Results

EOF

# Helper function to test endpoint
test_endpoint() {
    local method=$1
    local endpoint=$2
    local auth_header=$3
    local data=$4
    local description=$5
    
    local url="${BASE_URL}${endpoint}"
    local curl_args=(-sS -X "$method" "$url" -w "\nHTTP_STATUS:%{http_code}")
    
    if [ -n "$auth_header" ]; then
        curl_args+=(-H "Authorization: Bearer ${auth_header}")
    fi
    
    if [ -n "$data" ]; then
        curl_args+=(-H "Content-Type: application/json" -d "$data")
    fi
    
    local response=$(curl "${curl_args[@]}" 2>&1)
    local http_status=$(echo "$response" | grep -o 'HTTP_STATUS:[0-9]*' | sed 's/HTTP_STATUS://' || echo "000")
    local body=$(echo "$response" | sed 's/HTTP_STATUS:[0-9]*$//')
    
    echo "$http_status|$body"
}

# Test 1: Authentication & Authorization
echo -e "${CYAN}=== 1. Authentication & Authorization Tests ===${NC}"
echo "### 1. Authentication & Authorization" >> "$REPORT_FILE"

# Test /chat without token
echo "Testing /chat (POST) without token..."
result=$(test_endpoint "POST" "/chat" "" '{"message":"test"}' "Unauthorized access")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
TOTAL=$((TOTAL + 1))

if [ "$status" = "401" ]; then
    echo -e "${GREEN}✅ /chat without token: HTTP 401 (Expected)${NC}"
    echo "- ✅ `/chat` (POST) without token: HTTP 401 (Expected - intentionally public for token entry)" >> "$REPORT_FILE"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}❌ /chat without token: HTTP $status (Expected 401)${NC}"
    echo "- ❌ `/chat` (POST) without token: HTTP $status (Expected 401)" >> "$REPORT_FILE"
    FAILED=$((FAILED + 1))
    HIGH_RISK=$((HIGH_RISK + 1))
fi

# Test with invalid token
echo "Testing with invalid token..."
result=$(test_endpoint "POST" "/chat" "invalid_token_12345" '{"message":"test"}' "Invalid token")
status=$(echo "$result" | cut -d'|' -f1)
TOTAL=$((TOTAL + 1))

if [ "$status" = "401" ]; then
    echo -e "${GREEN}✅ Invalid token rejected: HTTP 401${NC}"
    echo "- ✅ Invalid token rejected: HTTP 401" >> "$REPORT_FILE"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}❌ Invalid token: HTTP $status (Expected 401)${NC}"
    echo "- ❌ Invalid token: HTTP $status (Expected 401)" >> "$REPORT_FILE"
    FAILED=$((FAILED + 1))
    HIGH_RISK=$((HIGH_RISK + 1))
fi

# Test TTS endpoint without auth
echo "Testing /v1/tts without auth..."
result=$(test_endpoint "POST" "/v1/tts" "" '{"text":"test"}' "TTS unauthorized")
status=$(echo "$result" | cut -d'|' -f1)
TOTAL=$((TOTAL + 1))

if [ "$status" = "401" ] || [ "$status" = "403" ]; then
    echo -e "${GREEN}✅ /v1/tts without auth: HTTP $status${NC}"
    echo "- ✅ `/v1/tts` without auth: HTTP $status" >> "$REPORT_FILE"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}❌ /v1/tts without auth: HTTP $status (Expected 401/403)${NC}"
    echo "- ❌ `/v1/tts` without auth: HTTP $status (Expected 401/403)" >> "$REPORT_FILE"
    FAILED=$((FAILED + 1))
    HIGH_RISK=$((HIGH_RISK + 1))
fi

# Test 2: Security Headers
echo ""
echo -e "${CYAN}=== 2. Security Headers Tests ===${NC}"
echo "" >> "$REPORT_FILE"
echo "### 2. Security Headers" >> "$REPORT_FILE"

headers=$(curl -sS -I "${BASE_URL}/chat" 2>&1)

check_header() {
    local header_name=$1
    local expected=$2
    local found=$(echo "$headers" | grep -i "$header_name" || echo "")
    TOTAL=$((TOTAL + 1))
    
    if [ -n "$found" ]; then
        echo -e "${GREEN}✅ $header_name: Present${NC}"
        echo "- ✅ $header_name: Present" >> "$REPORT_FILE"
        PASSED=$((PASSED + 1))
    else
        echo -e "${YELLOW}⚠️  $header_name: Missing${NC}"
        echo "- ⚠️  $header_name: Missing" >> "$REPORT_FILE"
        WARN=$((WARN + 1))
        LOW_RISK=$((LOW_RISK + 1))
    fi
}

check_header "X-Content-Type-Options" "nosniff"
check_header "X-Frame-Options" "DENY"
check_header "X-XSS-Protection" "1; mode=block"
check_header "Referrer-Policy" "strict-origin-when-cross-origin"
check_header "Strict-Transport-Security" "max-age"
check_header "Content-Security-Policy" ""

# Check CSP for unsafe-eval
csp=$(echo "$headers" | grep -i "content-security-policy" || echo "")
if echo "$csp" | grep -q "unsafe-eval"; then
    echo -e "${YELLOW}⚠️  CSP contains 'unsafe-eval'${NC}"
    echo "- ⚠️  CSP contains 'unsafe-eval' (check if necessary)" >> "$REPORT_FILE"
    WARN=$((WARN + 1))
    MID_RISK=$((MID_RISK + 1))
else
    echo -e "${GREEN}✅ CSP does not contain 'unsafe-eval'${NC}"
    echo "- ✅ CSP does not contain 'unsafe-eval'" >> "$REPORT_FILE"
    PASSED=$((PASSED + 1))
fi
TOTAL=$((TOTAL + 1))

# Test 3: CORS
echo ""
echo -e "${CYAN}=== 3. CORS Configuration Tests ===${NC}"
echo "" >> "$REPORT_FILE"
echo "### 3. CORS Configuration" >> "$REPORT_FILE"

# Test malicious origin
echo "Testing CORS with malicious origin..."
cors_response=$(curl -sS -X OPTIONS "${BASE_URL}/chat" \
    -H 'Origin: https://evil.com' \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: Content-Type' \
    -I 2>&1)
TOTAL=$((TOTAL + 1))

if echo "$cors_response" | grep -qi "access-control-allow-origin.*evil.com"; then
    echo -e "${RED}❌ CORS allows evil.com origin${NC}"
    echo "- ❌ CORS allows evil.com origin (VULNERABLE)" >> "$REPORT_FILE"
    FAILED=$((FAILED + 1))
    HIGH_RISK=$((HIGH_RISK + 1))
else
    echo -e "${GREEN}✅ CORS blocks evil.com origin${NC}"
    echo "- ✅ CORS blocks evil.com origin" >> "$REPORT_FILE"
    PASSED=$((PASSED + 1))
fi

# Test 4: Input Validation
echo ""
echo -e "${CYAN}=== 4. Input Validation Tests ===${NC}"
echo "" >> "$REPORT_FILE"
echo "### 4. Input Validation" >> "$REPORT_FILE"

if [ -n "$TOKEN" ]; then
    # XSS test
    echo "Testing XSS injection..."
    result=$(test_endpoint "POST" "/chat" "$TOKEN" '{"message":"<script>alert(1)</script>"}' "XSS test")
    status=$(echo "$result" | cut -d'|' -f1)
    TOTAL=$((TOTAL + 1))
    
    if [ "$status" = "200" ] || [ "$status" = "401" ]; then
        echo -e "${GREEN}✅ XSS payload handled: HTTP $status${NC}"
        echo "- ✅ XSS payload handled: HTTP $status" >> "$REPORT_FILE"
        PASSED=$((PASSED + 1))
    else
        echo -e "${YELLOW}⚠️  XSS test: HTTP $status${NC}"
        echo "- ⚠️  XSS test: HTTP $status" >> "$REPORT_FILE"
        WARN=$((WARN + 1))
        LOW_RISK=$((LOW_RISK + 1))
    fi
    
    # SQL injection test
    echo "Testing SQL injection..."
    result=$(test_endpoint "POST" "/chat" "$TOKEN" '{"message":"'\'' OR 1=1--"}' "SQL injection test")
    status=$(echo "$result" | cut -d'|' -f1)
    TOTAL=$((TOTAL + 1))
    
    if [ "$status" = "200" ] || [ "$status" = "401" ]; then
        echo -e "${GREEN}✅ SQL injection payload handled: HTTP $status${NC}"
        echo "- ✅ SQL injection payload handled: HTTP $status" >> "$REPORT_FILE"
        PASSED=$((PASSED + 1))
    else
        echo -e "${YELLOW}⚠️  SQL injection test: HTTP $status${NC}"
        echo "- ⚠️  SQL injection test: HTTP $status" >> "$REPORT_FILE"
        WARN=$((WARN + 1))
        LOW_RISK=$((LOW_RISK + 1))
    fi
else
    echo -e "${YELLOW}⚠️  Skipping input validation tests (no token)${NC}"
    echo "- ⚠️  Skipped (no token provided)" >> "$REPORT_FILE"
fi

# Test 5: Information Disclosure
echo ""
echo -e "${CYAN}=== 5. Information Disclosure Tests ===${NC}"
echo "" >> "$REPORT_FILE"
echo "### 5. Information Disclosure" >> "$REPORT_FILE"

test_file_access() {
    local file=$1
    local status=$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/${file}")
    TOTAL=$((TOTAL + 1))
    
    if [ "$status" = "200" ]; then
        echo -e "${RED}❌ $file: HTTP 200 (EXPOSED!)${NC}"
        echo "- ❌ $file: HTTP 200 (EXPOSED!)" >> "$REPORT_FILE"
        FAILED=$((FAILED + 1))
        HIGH_RISK=$((HIGH_RISK + 1))
    else
        echo -e "${GREEN}✅ $file: HTTP $status${NC}"
        echo "- ✅ $file: HTTP $status" >> "$REPORT_FILE"
        PASSED=$((PASSED + 1))
    fi
}

test_file_access ".env"
test_file_access "package.json"
test_file_access "config.json"
test_file_access "requirements.txt"

# Test error messages
echo "Testing error message disclosure..."
result=$(test_endpoint "POST" "/invalid-endpoint" "" '{}' "Invalid endpoint")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
TOTAL=$((TOTAL + 1))

if echo "$body" | grep -qiE "(traceback|exception|file.*line|stack)"; then
    echo -e "${RED}❌ Error message contains stack trace${NC}"
    echo "- ❌ Error message contains stack trace (information disclosure)" >> "$REPORT_FILE"
    FAILED=$((FAILED + 1))
    MID_RISK=$((MID_RISK + 1))
else
    echo -e "${GREEN}✅ Error messages are generic${NC}"
    echo "- ✅ Error messages are generic (no information disclosure)" >> "$REPORT_FILE"
    PASSED=$((PASSED + 1))
fi

# Test 6: Rate Limiting
echo ""
echo -e "${CYAN}=== 6. Rate Limiting Tests ===${NC}"
echo "" >> "$REPORT_FILE"
echo "### 6. Rate Limiting" >> "$REPORT_FILE"

if [ -n "$TOKEN" ]; then
    echo "Testing rate limiting (making 35 rapid requests)..."
    rate_limit_hit=0
    for i in {1..35}; do
        result=$(test_endpoint "POST" "/chat" "$TOKEN" '{"message":"test"}' "Rate limit test")
        status=$(echo "$result" | cut -d'|' -f1)
        if [ "$status" = "429" ]; then
            rate_limit_hit=1
            break
        fi
        sleep 0.3
    done
    TOTAL=$((TOTAL + 1))
    
    if [ "$rate_limit_hit" = "1" ]; then
        echo -e "${GREEN}✅ Rate limiting active: HTTP 429 after $i requests${NC}"
        echo "- ✅ Rate limiting active: HTTP 429 triggered" >> "$REPORT_FILE"
        PASSED=$((PASSED + 1))
    else
        echo -e "${YELLOW}⚠️  Rate limiting not triggered after 35 requests${NC}"
        echo "- ⚠️  Rate limiting not triggered (may be disabled in DEBUG mode)" >> "$REPORT_FILE"
        WARN=$((WARN + 1))
        LOW_RISK=$((LOW_RISK + 1))
    fi
else
    echo -e "${YELLOW}⚠️  Skipping rate limiting tests (no token)${NC}"
    echo "- ⚠️  Skipped (no token provided)" >> "$REPORT_FILE"
fi

# Test 7: HTTPS/TLS
echo ""
echo -e "${CYAN}=== 7. HTTPS/TLS Tests ===${NC}"
echo "" >> "$REPORT_FILE"
echo "### 7. HTTPS/TLS" >> "$REPORT_FILE"

hsts=$(echo "$headers" | grep -i "strict-transport-security" || echo "")
TOTAL=$((TOTAL + 1))

if [ -n "$hsts" ]; then
    echo -e "${GREEN}✅ HSTS header present${NC}"
    echo "- ✅ HSTS header present" >> "$REPORT_FILE"
    PASSED=$((PASSED + 1))
else
    echo -e "${YELLOW}⚠️  HSTS header missing${NC}"
    echo "- ⚠️  HSTS header missing" >> "$REPORT_FILE"
    WARN=$((WARN + 1))
    MID_RISK=$((MID_RISK + 1))
fi

# Test 8: HTTP Method Tests
echo ""
echo -e "${CYAN}=== 8. HTTP Method Tests ===${NC}"
echo "" >> "$REPORT_FILE"
echo "### 8. HTTP Method Tests" >> "$REPORT_FILE"

# GET on POST endpoint
echo "Testing GET on POST endpoint..."
result=$(test_endpoint "GET" "/chat" "" "" "GET on POST endpoint")
status=$(echo "$result" | cut -d'|' -f1)
TOTAL=$((TOTAL + 1))

if [ "$status" = "405" ]; then
    echo -e "${GREEN}✅ GET on POST endpoint: HTTP 405 (Method Not Allowed)${NC}"
    echo "- ✅ GET on POST endpoint: HTTP 405 (Method Not Allowed)" >> "$REPORT_FILE"
    PASSED=$((PASSED + 1))
else
    echo -e "${YELLOW}⚠️  GET on POST endpoint: HTTP $status${NC}"
    echo "- ⚠️  GET on POST endpoint: HTTP $status" >> "$REPORT_FILE"
    WARN=$((WARN + 1))
    LOW_RISK=$((LOW_RISK + 1))
fi

# Test 9: OpenAPI Spec
echo ""
echo -e "${CYAN}=== 9. OpenAPI Spec Exposure Test ===${NC}"
echo "" >> "$REPORT_FILE"
echo "### 9. OpenAPI Spec Exposure" >> "$REPORT_FILE"

openapi_status=$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/.well-known/openapi.yaml")
TOTAL=$((TOTAL + 1))

if [ "$openapi_status" = "200" ]; then
    echo -e "${YELLOW}ℹ️  OpenAPI spec is publicly accessible: HTTP 200${NC}"
    echo "- ℹ️  OpenAPI spec is publicly accessible: HTTP 200 (acceptable, informational only)" >> "$REPORT_FILE"
    WARN=$((WARN + 1))
    LOW_RISK=$((LOW_RISK + 1))
else
    echo -e "${GREEN}✅ OpenAPI spec: HTTP $openapi_status${NC}"
    echo "- ✅ OpenAPI spec: HTTP $openapi_status" >> "$REPORT_FILE"
    PASSED=$((PASSED + 1))
fi

# Update report summary
cat >> "$REPORT_FILE" <<EOF

---

## Security Metrics Summary

**Final Risk Count:**
- **High Risk**: ${HIGH_RISK}
- **Mid Risk**: ${MID_RISK}
- **Low Risk**: ${LOW_RISK}
- **Working**: ${PASSED}
- **TOTAL**: ${TOTAL}

**Progress Tracking:**
- ✅ Passed: ${PASSED}
- ⚠️ Needs Attention: ${WARN}
- ❌ Failed: ${FAILED}

## ✅ STRENGTHS (What's Working Well)

[Summary of passed tests]

## ⚠️ ISSUES FOUND

[Summary of warnings and failures]

## 📋 RECOMMENDATIONS

[Recommendations based on findings]

## 🎯 TEST RESULTS SUMMARY

| Test Category | Status | Notes |
|--------------|--------|-------|
| Authentication | ✅/❌ | [Notes] |
| Authorization | ✅/❌ | [Notes] |
| Security Headers | ✅/❌ | [Notes] |
| CORS | ✅/❌ | [Notes] |
| Input Validation | ✅/❌ | [Notes] |
| Information Disclosure | ✅/❌ | [Notes] |
| Rate Limiting | ✅/❌ | [Notes] |
| HTTPS/TLS | ✅/❌ | [Notes] |
| HTTP Methods | ✅/❌ | [Notes] |
| OpenAPI Spec | ℹ️ | [Notes] |

## ✅ OVERALL ASSESSMENT

**Security Rating: [X]/10** ⭐⭐⭐⭐⭐

**Summary:**
[Overall assessment]

---

**Report Generated:** $(date +"%Y-%m-%d %H:%M:%S")
**Status:** ✅ PASS / ⚠️ WARN / ❌ FAIL
EOF

echo ""
echo -e "${CYAN}=== SUMMARY ===${NC}"
echo "Total tests: $TOTAL"
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${YELLOW}Warnings: $WARN${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo ""
echo "Report saved to: $REPORT_FILE"
