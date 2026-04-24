#!/bin/bash
# external_recon.sh — external attack-surface audit for a domain.
#
# Runs: subdomain enum → dual-scheme liveness → port scan → DNS posture
#   → TLS audit (per-host weak-protocol probe + testssl on primary)
#   → per-host security-header audit with scoring
#   → sensitive file + API-spec exposure
#   → management-panel probe
#   → HTTP-method posture
#   → nuclei CVE/misconfig scan
#   → verdict.
#
# Usage:
#   ./scripts/security/external_recon.sh example.com
#   ./scripts/security/external_recon.sh example.com api.example.com
#   ./scripts/security/external_recon.sh example.com api.example.com --deep
#
# Env:
#   NO_COLOR=1   disable ANSI output
#
# All probes are non-destructive — read-only. Run from your laptop.

set -uo pipefail

# ── args & config ────────────────────────────────────────────────
# Pass domain as $1 (or via DOMAIN env); primary host as $2 (or PRIMARY env)
DOMAIN="${1:-${DOMAIN:-example.com}}"
PRIMARY="${2:-${PRIMARY:-api.${DOMAIN}}}"
DEEP_FLAG="${3:-}"
TIMESTAMP=$(date +"%Y-%m-%d__%H-%M-%S")
OUT_DIR="reviews/recon_${DOMAIN}_${TIMESTAMP}"

# Hard check — if we can't create or write to OUT_DIR, bail NOW.
# Previously we silently continued and every downstream phase cascaded
# "No such file or directory" errors.
if ! mkdir -p "$OUT_DIR" 2>/dev/null || [ ! -d "$OUT_DIR" ] || [ ! -w "$OUT_DIR" ]; then
  printf 'FATAL: cannot create or write to output dir: %s\n' "$OUT_DIR" >&2
  printf '  cwd: %s\n' "$(pwd)" >&2
  printf '  parent: %s\n' "$(ls -ld "$(dirname "$OUT_DIR")" 2>&1)" >&2
  exit 2
fi

HIGH=0; MED=0; LOW=0
FINDINGS_FILE="$OUT_DIR/findings.txt"
SUPPRESSED_FILE="$OUT_DIR/suppressed.txt"
: > "$FINDINGS_FILE"
: > "$SUPPRESSED_FILE"

ALLOWLIST="reviews/.recon-allowlist"

# ── colors ───────────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''; C_MAG=''; C_DIM=''; C_BLD=''; C_RST=''
else
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
  C_CYN=$'\033[0;36m'; C_MAG=$'\033[0;35m'; C_DIM=$'\033[2m'
  C_BLD=$'\033[1m';    C_RST=$'\033[0m'
fi

say()   { printf '%s▶ %s%s\n'   "$C_CYN" "$*" "$C_RST"; }
ok()    { printf '%s  ✓ %s%s\n' "$C_GRN" "$*" "$C_RST"; }
warn()  { printf '%s  ! %s%s\n' "$C_YEL" "$*" "$C_RST"; }
fail()  { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RST"; }
dim()   { printf '%s%s%s\n'     "$C_DIM" "$*" "$C_RST"; }
bold()  { printf '%s%s%s\n'     "$C_BLD" "$*" "$C_RST"; }

# ── allowlist + finding helpers ──────────────────────────────────
is_allowlisted() {
  [ -f "$ALLOWLIST" ] || return 1
  local msg=$1 line
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    case "$msg" in *"$line"*) return 0;; esac
  done < "$ALLOWLIST"
  return 1
}

finding() {
  local sev=$1 msg=$2
  if is_allowlisted "$msg"; then
    printf '%s  ~ [%s] %s (suppressed)%s\n' "$C_DIM" "$sev" "$msg" "$C_RST"
    printf '[%s] %s\n' "$sev" "$msg" >> "$SUPPRESSED_FILE"
    return
  fi
  case "$sev" in
    HIGH) HIGH=$((HIGH+1)); printf '%s[HIGH]%s %s\n' "$C_RED" "$C_RST" "$msg" ;;
    MED)  MED=$((MED+1));   printf '%s[MED] %s %s\n' "$C_YEL" "$C_RST" "$msg" ;;
    LOW)  LOW=$((LOW+1));   printf '%s[LOW] %s %s\n' "$C_DIM" "$C_RST" "$msg" ;;
  esac
  printf '[%s] %s\n' "$sev" "$msg" >> "$FINDINGS_FILE"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve testssl — brew installs as `testssl.sh` on macOS.
if   have testssl;    then TESTSSL=testssl
elif have testssl.sh; then TESTSSL=testssl.sh
else TESTSSL=""
fi

require() {
  local missing=()
  for tool in "$@"; do have "$tool" || missing+=("$tool"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf '%s✗ missing tools:%s %s\n' "$C_RED" "$C_RST" "${missing[*]}"
    echo  "  install hint: brew install ${missing[*]}"
    exit 1
  fi
}
require curl jq subfinder httpx naabu nuclei ffuf dig openssl
if [ -z "$TESTSSL" ]; then
  fail "missing tools: testssl / testssl.sh"; echo "  brew install testssl"; exit 1
fi

# ── banner ───────────────────────────────────────────────────────
cat <<BANNER
${C_MAG}
   ██████╗ ███████╗ ██████╗ ██████╗ ███╗   ██╗
   ██╔══██╗██╔════╝██╔════╝██╔═══██╗████╗  ██║
   ██████╔╝█████╗  ██║     ██║   ██║██╔██╗ ██║
   ██╔══██╗██╔══╝  ██║     ██║   ██║██║╚██╗██║
   ██║  ██║███████╗╚██████╗╚██████╔╝██║ ╚████║
   ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝
   ${C_DIM}external attack-surface audit · v2${C_RST}${C_MAG}
${C_RST}
BANNER
bold "  target   : $DOMAIN"
bold "  primary  : $PRIMARY"
bold "  out dir  : $OUT_DIR"
bold "  deep     : $([ "$DEEP_FLAG" = "--deep" ] && echo yes || echo no)"
echo

# ── 1. subdomain enum ────────────────────────────────────────────
say "[1/10] subdomain enumeration"
SUBS="$OUT_DIR/subs.txt"
subfinder -d "$DOMAIN" -all -silent 2>/dev/null > "$SUBS" || true
curl -sS --max-time 30 "https://crt.sh/?q=%25.${DOMAIN}&output=json" 2>/dev/null \
  | jq -r '.[]?.name_value' 2>/dev/null \
  | tr -d '*' | sed '/^$/d' \
  >> "$SUBS" || true
if [ "$DEEP_FLAG" = "--deep" ] && have amass; then
  dim "      amass passive (180s cap)…"
  timeout 180 amass enum -passive -d "$DOMAIN" -silent 2>/dev/null >> "$SUBS" || true
fi
[ -s "$SUBS" ] && sort -u "$SUBS" -o "$SUBS"
N_SUBS=$(wc -l < "$SUBS" 2>/dev/null | tr -d ' '); N_SUBS=${N_SUBS:-0}
ok "$N_SUBS subdomains"
[ -s "$SUBS" ] && dim "$(sed 's/^/      /' "$SUBS")"
echo

# ── 2. liveness (dual scheme) ────────────────────────────────────
say "[2/10] liveness & fingerprint (httpx, http+https)"
ALIVE="$OUT_DIR/alive.txt"
URL_LIST="$OUT_DIR/url_list.txt"
{ sed 's|^|https://|' "$SUBS"; sed 's|^|http://|' "$SUBS"; } > "$URL_LIST"
httpx -l "$URL_LIST" -silent -title -tech-detect -status-code \
      -tls-grab -web-server -ip -cdn -timeout 8 -retries 1 \
      -follow-redirects -no-color > "$ALIVE" 2>/dev/null || true
N_ALIVE=$(wc -l < "$ALIVE" 2>/dev/null | tr -d ' '); N_ALIVE=${N_ALIVE:-0}
ok "$N_ALIVE live endpoints"
[ -s "$ALIVE" ] && dim "$(head -15 "$ALIVE" | sed 's/^/      /')"
[ "$N_ALIVE" -gt 15 ] 2>/dev/null && dim "      … ($((N_ALIVE-15)) more)"
echo

# ── 3. port scan + interesting ports ─────────────────────────────
say "[3/10] port scan (naabu, top-1000)"
PORTS="$OUT_DIR/ports.txt"
naabu -list "$SUBS" -top-ports 1000 -silent -rate 300 -timeout 500 \
      2>/dev/null > "$PORTS" || true
N_PORTS=$(wc -l < "$PORTS" 2>/dev/null | tr -d ' '); N_PORTS=${N_PORTS:-0}
HOST_PORTS="$OUT_DIR/host_ports.txt"
: > "$HOST_PORTS"
[ -s "$PORTS" ] && awk -F: '{hosts[$1]=hosts[$1]" "$2} END{for(h in hosts) print h":"hosts[h]}' \
  "$PORTS" | sort > "$HOST_PORTS"
ok "$N_PORTS host:port pairs"
[ -s "$HOST_PORTS" ] && dim "$(sed 's/^/      /' "$HOST_PORTS")"

declare -a RISKY_SSH=()  RISKY_MAIL=()  RISKY_DB=()  RISKY_OTHER=()
while IFS= read -r line; do
  host="${line%%:*}"; ports="${line#*:}"
  for p in $ports; do
    case "$p" in
      22) RISKY_SSH+=("$host:$p");;
      25|465|587|110|995|143|993)
        [ "$host" != "posta.$DOMAIN" ] && RISKY_MAIL+=("$host:$p");;
      3306|5432|6379|27017|11211|9200) RISKY_DB+=("$host:$p");;
      2375|2376|6443|8080|8081|9090|9000) RISKY_OTHER+=("$host:$p");;
    esac
  done
done < "$HOST_PORTS"
[ "${#RISKY_SSH[@]}"  -gt 0 ] && finding HIGH "SSH exposed on: ${RISKY_SSH[*]}"
[ "${#RISKY_MAIL[@]}" -gt 0 ] && finding MED  "mail ports on non-mail hosts: ${RISKY_MAIL[*]}"
[ "${#RISKY_DB[@]}"   -gt 0 ] && finding HIGH "database/cache exposed: ${RISKY_DB[*]}"
[ "${#RISKY_OTHER[@]}" -gt 0 ] && finding MED "control-plane ports exposed: ${RISKY_OTHER[*]}"
echo

# ── 4. DNS posture ───────────────────────────────────────────────
say "[4/10] DNS posture"
DNS="$OUT_DIR/dns.txt"
{
  echo "--- A/AAAA ---";   dig "$DOMAIN" A +short; dig "$DOMAIN" AAAA +short
  echo "--- NS ---";       dig "$DOMAIN" NS +short
  echo "--- MX ---";       dig "$DOMAIN" MX +short
  echo "--- TXT ---";      dig "$DOMAIN" TXT +short
  echo "--- DMARC ---";    dig "_dmarc.$DOMAIN" TXT +short
  echo "--- CAA ---";      dig "$DOMAIN" CAA +short
} > "$DNS"
ok "→ $DNS"
grep -qi dmarc  "$DNS" || finding MED "no DMARC record — domain spoofable"
grep -qi 'v=spf1' "$DNS" || finding MED "no SPF record — domain spoofable"
grep -q 'issue'   "$DNS" || finding LOW "no CAA record — any CA can issue certs for $DOMAIN"
echo

# ── 5. TLS audit — testssl on primary ────────────────────────────
say "[5/10] TLS audit on $PRIMARY (testssl)"
TLS_HTML="$OUT_DIR/tls.html"
"$TESTSSL" --quiet --color 0 --severity LOW --htmlfile "$TLS_HTML" \
        "https://$PRIMARY" > "$OUT_DIR/tls.txt" 2>&1 || true
TLS_HIGH=0
if [ -f "$OUT_DIR/tls.txt" ]; then
  TLS_HIGH=$(grep -cE 'HIGH|CRITICAL' "$OUT_DIR/tls.txt" 2>/dev/null || true)
  TLS_HIGH=${TLS_HIGH:-0}
fi
if [ "$TLS_HIGH" -gt 0 ] 2>/dev/null; then
  finding HIGH "testssl: $TLS_HIGH HIGH/CRITICAL issue(s) on $PRIMARY (see tls.txt)"
fi
ok "→ $TLS_HTML"

# ── 5b. Weak TLS protocol probe on every alive HTTPS host ────────
say "[5b/10] weak protocol probe (TLSv1.0 / TLSv1.1) on all hosts"
WEAK_TLS="$OUT_DIR/weak_tls.txt"; : > "$WEAK_TLS"
# Portable alternative to mapfile (missing on macOS bash 3.2): dump
# unique https URLs to a file and read from it wherever needed.
HTTPS_LIST="$OUT_DIR/https_hosts.txt"
awk '/^https:/ {print $1}' "$ALIVE" | sort -u > "$HTTPS_LIST"
while IFS= read -r url; do
  [ -z "$url" ] && continue
  host=${url#https://}; host=${host%%/*}; host=${host%:*}
  for proto in tls1 tls1_1; do
    if timeout 6 openssl s_client -connect "$host:443" -servername "$host" \
          -"$proto" </dev/null >/dev/null 2>&1; then
      case "$proto" in tls1_1) label='TLSv1.1';; tls1) label='TLSv1.0';; esac
      echo "$host  $label" >> "$WEAK_TLS"
      finding HIGH "weak TLS: $host accepts $label"
    fi
  done
done < "$HTTPS_LIST"
if [ -s "$WEAK_TLS" ]; then ok "→ $WEAK_TLS"; else ok "all hosts reject TLSv1.0 / TLSv1.1"; fi
echo

# ── 6. Security headers sweep w/ per-host scoring ────────────────
say "[6/10] security header audit per host"
HDRS="$OUT_DIR/headers.txt"; : > "$HDRS"
HDR_SCORE="$OUT_DIR/headers_score.txt"; : > "$HDR_SCORE"

# Strings instead of arrays — bash 3.2 on macOS plays poorly with
# `set -u` + empty arrays.
while IFS= read -r url; do
  [ -z "$url" ] && continue
  hdr=$(curl -skI --max-time 8 "$url" 2>/dev/null)
  score=0
  miss_hdrs=""
  hdr_leaks=""
  {
    echo "=== $url ==="
    echo "$hdr" | grep -iE 'content-security-policy|strict-transport|x-frame|x-content-type|referrer-policy|permissions-policy|server|x-powered-by'
    echo
  } >> "$HDRS"

  if echo "$hdr" | grep -qi 'strict-transport-security';        then score=$((score+2)); else miss_hdrs="$miss_hdrs HSTS"; fi
  if echo "$hdr" | grep -qi 'x-content-type-options';           then score=$((score+1)); else miss_hdrs="$miss_hdrs X-Content-Type-Options"; fi
  if echo "$hdr" | grep -qiE 'x-frame-options|frame-ancestors'; then score=$((score+1)); else miss_hdrs="$miss_hdrs X-Frame-Options"; fi
  if echo "$hdr" | grep -qi 'content-security-policy';          then score=$((score+2)); fi
  if echo "$hdr" | grep -qi 'referrer-policy';                  then score=$((score+1)); else miss_hdrs="$miss_hdrs Referrer-Policy"; fi
  if echo "$hdr" | grep -qi 'permissions-policy';               then score=$((score+1)); fi

  srv=$(echo "$hdr" | awk 'tolower($1)=="server:" {sub(/^[^:]*:[ \t]*/,""); sub(/\r$/,""); print; exit}')
  if [ -n "$srv" ] && echo "$srv" | grep -qE '[0-9]+\.[0-9]+'; then
    hdr_leaks="$hdr_leaks Server:$srv"
    score=$((score-1))
  fi
  if echo "$hdr" | grep -qi 'x-powered-by'; then
    hdr_leaks="$hdr_leaks X-Powered-By"
    score=$((score-1))
  fi

  printf '%-40s  score=%d  missing=[%s] leaks=[%s]\n' \
    "$url" "$score" "${miss_hdrs# }" "${hdr_leaks# }" >> "$HDR_SCORE"
done < "$HTTPS_LIST"
ok "→ $HDR_SCORE"
dim "$(sed 's/^/      /' "$HDR_SCORE")"

# Surface low-score hosts + leaks
while read -r scoreline; do
  s=$(echo "$scoreline" | awk -F'score=' '{split($2,a," "); print a[1]}')
  host=$(echo "$scoreline" | awk '{print $1}')
  [ -z "$s" ] && continue
  [ "$s" -lt 3 ] && finding MED "weak security headers on $host (score $s)"
  echo "$scoreline" | grep -q 'leaks=\[Server:' && \
    finding LOW "version disclosure in Server header: $host"
done < "$HDR_SCORE"
echo

# ── 7. sensitive file + API spec probe ───────────────────────────
say "[7/10] sensitive file + API spec probe (primary)"
SENS="$OUT_DIR/sensitive.txt"
cat > "$OUT_DIR/wordlist.txt" <<'EOF'
.env
.env.local
.env.production
.env.sample
.git/config
.git/HEAD
.git/index
.DS_Store
config.json
secrets.json
credentials.json
dump.sql
backup.zip
backup.tar.gz
.htaccess
.htpasswd
.well-known/security.txt
server-status
server-info
phpinfo.php
id_rsa
.aws/credentials
.npmrc
docker-compose.yml
.terraform.tfstate
terraform.tfstate
openapi.yaml
openapi.json
swagger.json
swagger.yaml
api/v1/swagger
api-docs
docs
redoc
graphql
.well-known/openapi.yaml
actuator
actuator/health
actuator/env
metrics
debug
debug/pprof
.vscode/settings.json
.idea/workspace.xml
EOF
ffuf -u "https://$PRIMARY/FUZZ" -w "$OUT_DIR/wordlist.txt" \
     -mc 200,301,302,403 -timeout 8 -t 10 \
     -o "$SENS" -of json -s 2>/dev/null || true
if [ -s "$SENS" ]; then
  HITS=$(jq '.results | length' "$SENS" 2>/dev/null || echo 0)
  if [ "$HITS" -gt 0 ]; then
    ok "$HITS paths responded:"
    jq -r '.results[] | "      [\(.status)] \(.url)"' "$SENS"
    while read -r u; do
      case "$u" in
        *openapi.json|*openapi.yaml|*swagger.json|*swagger.yaml|*/docs|*/redoc|*/api-docs)
          finding MED "API schema publicly exposed: $u";;
        *.env*|*.git/*|*id_rsa|*.aws/*|*credentials*)
          finding HIGH "secret artifact publicly exposed: $u";;
        *.well-known/security.txt) : ;;
        *) finding LOW "path reachable (review): $u";;
      esac
    done < <(jq -r '.results[] | select(.status==200) | .url' "$SENS" 2>/dev/null)
  else
    ok "no sensitive paths exposed"
  fi
else
  ok "no sensitive paths exposed"
fi
echo

# ── 8. Management panel probe ────────────────────────────────────
say "[8/10] management panel probe (primary)"
PANELS="$OUT_DIR/panels.txt"; : > "$PANELS"
for path in /adminer /adminer.css /phpmyadmin /pma /sqladmin \
            /netdata /netdata/ /stub_status \
            /iredadmin /iredadmin/ /mail /mail/ /roundcube /webmail \
            /SOGo /SOGo/ /sogo /synapse-admin /_matrix/static/ \
            /matrix /element /wp-admin /wp-login.php \
            /actuator /actuator/env /actuator/health \
            /grafana /kibana /prometheus /traefik \
            /.git/HEAD /.env /.DS_Store /composer.json; do
  s=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://$PRIMARY$path")
  case "$s" in
    200|301|302|401|403) printf '%-32s %s\n' "$path" "$s" >> "$PANELS" ;;
  esac
done
if [ -s "$PANELS" ]; then
  ok "$(wc -l < "$PANELS") panel paths responded:"
  sed 's/^/      /' "$PANELS"
  while read -r line; do
    path=$(echo "$line" | awk '{print $1}')
    code=$(echo "$line" | awk '{print $2}')
    # 200/301 = reachable content; flag it
    if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
      finding MED "management path reachable: $path (HTTP $code)"
    fi
  done < "$PANELS"
else
  ok "no management panels reachable on primary"
fi
echo

# ── 9. HTTP method posture ───────────────────────────────────────
say "[9/10] HTTP method posture (primary)"
METHODS="$OUT_DIR/methods.txt"; : > "$METHODS"
for m in OPTIONS TRACE PUT DELETE PATCH CONNECT; do
  s=$(curl -skX "$m" --max-time 5 -o /dev/null -w '%{http_code}' "https://$PRIMARY/")
  printf '%-8s %s\n' "$m" "$s" >> "$METHODS"
done
dim "$(sed 's/^/      /' "$METHODS")"
ok "→ $METHODS"
# Destructive methods should NEVER succeed (2xx). Upload-y 201/204 is the red flag.
while read -r line; do
  m=$(echo "$line" | awk '{print $1}')
  code=$(echo "$line" | awk '{print $2}')
  case "$m:$code" in
    TRACE:200|PUT:2??|DELETE:2??|PATCH:2??|CONNECT:2??)
      finding HIGH "destructive HTTP method accepted: $m → $code"
      ;;
  esac
done < "$METHODS"
echo

# ── 10. nuclei — CVEs, misconfigs, exposures ─────────────────────
say "[10/10] nuclei (low+ severity)"
NUCLEI="$OUT_DIR/nuclei.txt"
awk '{print $1}' "$ALIVE" | sort -u | nuclei \
     -silent -severity low,medium,high,critical \
     -timeout 8 -retries 1 -rate-limit 100 \
     -o "$NUCLEI" 2>/dev/null || true
N_NUC=0
if [ -s "$NUCLEI" ]; then
  N_NUC=$(wc -l < "$NUCLEI" 2>/dev/null | tr -d ' ')
  N_NUC=${N_NUC:-0}
fi
if [ "$N_NUC" -gt 0 ] 2>/dev/null; then
  ok "$N_NUC nuclei findings"
  head -10 "$NUCLEI" | sed 's/^/      /'
  CRIT=$(grep -ci critical "$NUCLEI" 2>/dev/null || true); CRIT=${CRIT:-0}
  HI=$(grep -ci '\[high\]'  "$NUCLEI" 2>/dev/null || true); HI=${HI:-0}
  [ "$CRIT" -gt 0 ] 2>/dev/null && finding HIGH "nuclei: $CRIT critical"
  [ "$HI"   -gt 0 ] 2>/dev/null && finding HIGH "nuclei: $HI high"
else
  ok "nuclei: no findings"
fi
echo

# ── verdict ──────────────────────────────────────────────────────
TOTAL=$((HIGH+MED+LOW))
cat <<EOF
${C_BLD}╔════════════════════════════════════════════════╗${C_RST}
${C_BLD}║                   VERDICT                      ║${C_RST}
${C_BLD}╚════════════════════════════════════════════════╝${C_RST}
EOF
printf '  %shigh  %d%s   %smed   %d%s   %slow   %d%s   total %d\n\n' \
  "$C_RED" "$HIGH" "$C_RST" \
  "$C_YEL" "$MED"  "$C_RST" \
  "$C_DIM" "$LOW"  "$C_RST" "$TOTAL"

if [ "$TOTAL" -eq 0 ]; then
  printf '  %s✓ clean — no findings.%s\n' "$C_GRN" "$C_RST"
else
  bold "  findings:"
  sort "$FINDINGS_FILE" | sed 's/^/    /'
fi
echo

# ── summary markdown ─────────────────────────────────────────────
REPORT="$OUT_DIR/SUMMARY.md"
{
  echo "# External Recon — $DOMAIN"
  echo
  echo "- **Date:** $(date '+%Y-%m-%d %H:%M:%S')"
  echo "- **Primary host:** $PRIMARY"
  echo "- **Subdomains:** $N_SUBS"
  echo "- **Live endpoints:** $N_ALIVE"
  echo "- **Open host:port pairs:** $N_PORTS"
  echo "- **Nuclei findings:** ${N_NUC:-0}"
  echo "- **Verdict:** HIGH=$HIGH  MED=$MED  LOW=$LOW"
  echo
  echo "## Findings"
  [ -s "$FINDINGS_FILE" ] && sed 's/^/- /' "$FINDINGS_FILE" || echo "_none_"
  echo
  echo "## Suppressed (by allowlist)"
  [ -s "$SUPPRESSED_FILE" ] && sed 's/^/- /' "$SUPPRESSED_FILE" || echo "_none_"
  echo
  echo "## Subdomains";        echo '```'; cat "$SUBS"; echo '```'
  echo "## Live";              echo '```'; cat "$ALIVE"; echo '```'
  echo "## Ports per host";    echo '```'; cat "$HOST_PORTS"; echo '```'
  echo "## DNS";               echo '```'; cat "$DNS"; echo '```'
  echo "## Weak TLS";          [ -s "$WEAK_TLS" ] && { echo '```'; cat "$WEAK_TLS"; echo '```'; } || echo "_none_"
  echo "## Header scores";     echo '```'; cat "$HDR_SCORE"; echo '```'
  echo "## Sensitive paths"
  if [ -s "$SENS" ]; then
    jq -r '.results[]? | "- [\(.status)] \(.url)"' "$SENS" 2>/dev/null || echo "_none_"
  else
    echo "_none_"
  fi
  echo "## Management panels"
  [ -s "$PANELS" ]  && { echo '```'; cat "$PANELS"; echo '```'; }  || echo "_none_"
  echo "## HTTP methods";      echo '```'; cat "$METHODS"; echo '```'
  echo "## Nuclei"
  [ "${N_NUC:-0}" -gt 0 ] && { echo '```'; cat "$NUCLEI"; echo '```'; } || echo "_none_"
} > "$REPORT"

ln -sfn "recon_${DOMAIN}_${TIMESTAMP}" "reviews/recon_${DOMAIN}_latest" 2>/dev/null || true

printf '%s  summary  : %s%s\n' "$C_GRN" "$REPORT" "$C_RST"
printf '%s  latest   : reviews/recon_%s_latest%s\n' "$C_GRN" "$DOMAIN" "$C_RST"
echo
