#!/usr/bin/env bash
set -u

HOST="localhost"
HTTP_PORT=80
HTTPS_PORT=443
OUTPUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:-localhost}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:-80}"; shift 2 ;;
    --https-port) HTTPS_PORT="${2:-443}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) echo "Usage: $0 [--host NAME] [--http-port N] [--https-port N] [--output DIR]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-./linux-web-health-$STAMP}"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/web-health.txt"
JSON="$OUTPUT_DIR/web-summary.json"
ERRORS="$OUTPUT_DIR/command-errors.log"
: > "$REPORT"; : > "$ERRORS"

section() { local title="$1"; shift; { printf '\n===== %s =====\n' "$title"; "$@"; } >> "$REPORT" 2>> "$ERRORS" || true; }
have() { command -v "$1" >/dev/null 2>&1; }

section "Collection metadata" bash -c 'date -Is; hostname -f 2>/dev/null || hostname; id'
section "System capacity" bash -c 'uptime; free -h 2>/dev/null || true; df -hT / /var 2>/dev/null || df -hT'
section "Listening web ports" bash -c 'ss -ltnp 2>/dev/null | grep -E ":(80|443|8080|8443)[[:space:]]" || true'
section "Web processes" bash -c 'ps -eo pid,user,comm,%cpu,%mem,args --sort=-%cpu | grep -E "(nginx|apache2|httpd)" | grep -v grep || true'

SERVER="none"
SERVICE_STATE="unknown"
CONFIG_STATUS="not_available"
if have nginx; then
  SERVER="nginx"
  section "Nginx version" nginx -v
  section "Nginx configuration test" nginx -t
  section "Nginx full configuration" nginx -T
  section "Nginx service" systemctl status nginx --no-pager -l
  SERVICE_STATE="$(systemctl is-active nginx 2>/dev/null || echo unknown)"
  nginx -t >/dev/null 2>&1 && CONFIG_STATUS="passed" || CONFIG_STATUS="failed"
  section "Nginx recent errors" bash -c 'journalctl -u nginx --since "24 hours ago" --no-pager -n 300; tail -n 300 /var/log/nginx/error.log 2>/dev/null || true'
elif have apache2 || have httpd; then
  SERVER="apache"
  APACHE_BIN="$(command -v apache2ctl || command -v apachectl || command -v httpd)"
  SERVICE="apache2"; systemctl list-unit-files httpd.service >/dev/null 2>&1 && SERVICE="httpd"
  section "Apache version" "$APACHE_BIN" -v
  section "Apache configuration test" "$APACHE_BIN" configtest
  section "Apache virtual hosts" "$APACHE_BIN" -S
  section "Apache service" systemctl status "$SERVICE" --no-pager -l
  SERVICE_STATE="$(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown)"
  "$APACHE_BIN" configtest >/dev/null 2>&1 && CONFIG_STATUS="passed" || CONFIG_STATUS="failed"
  section "Apache recent errors" bash -c "journalctl -u '$SERVICE' --since '24 hours ago' --no-pager -n 300; tail -n 300 /var/log/apache2/error.log /var/log/httpd/error_log 2>/dev/null || true"
fi

HTTP_OK=false
HTTPS_OK=false
if have curl; then
  section "HTTP response" curl -sS -I --connect-timeout 5 --max-time 12 "http://$HOST:$HTTP_PORT/"
  curl -sS -I --connect-timeout 5 --max-time 12 "http://$HOST:$HTTP_PORT/" >/dev/null 2>&1 && HTTP_OK=true
  section "HTTPS response" curl -k -sS -I --connect-timeout 5 --max-time 12 "https://$HOST:$HTTPS_PORT/"
  curl -k -sS -I --connect-timeout 5 --max-time 12 "https://$HOST:$HTTPS_PORT/" >/dev/null 2>&1 && HTTPS_OK=true
fi

CERT_DAYS=-1
if have openssl; then
  section "TLS certificate" bash -c "echo | openssl s_client -servername '$HOST' -connect '$HOST:$HTTPS_PORT' 2>/dev/null | openssl x509 -noout -subject -issuer -serial -dates -fingerprint -sha256"
  END_DATE="$(echo | openssl s_client -servername "$HOST" -connect "$HOST:$HTTPS_PORT" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2-)"
  if [[ -n "$END_DATE" ]]; then
    CERT_DAYS="$(( ($(date -d "$END_DATE" +%s) - $(date +%s)) / 86400 ))"
  fi
fi

cat > "$JSON" <<EOF
{
  "collected_at": "$(date -Is)",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "detected_server": "$SERVER",
  "service_state": "$SERVICE_STATE",
  "configuration_test": "$CONFIG_STATUS",
  "target_host": "$HOST",
  "http_reachable": $HTTP_OK,
  "https_reachable": $HTTPS_OK,
  "certificate_days_remaining": $CERT_DAYS
}
EOF

printf '\nWeb server health collection completed. Output: %s\n' "$OUTPUT_DIR" | tee -a "$REPORT"
