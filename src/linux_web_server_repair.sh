#!/usr/bin/env bash
set -u

umask 077

DO_REPAIR=false
ROTATE_LOGS=false
SERVICE_ACTION=""
SERVER_CHOICE="auto"
VERIFY_URL=""
DRY_RUN=false
ASSUME_YES=false
OUTPUT_DIR=""
FAILURES=0
ACTIONS=0
SERVER=""
SERVICE_UNIT=""
CONF_DIR=""
LOGROTATE_FILE=""
TEST_CMD=()

usage() {
  cat <<'EOF'
Usage: linux_web_server_repair.sh [options]

Repair actions:
  --repair                    Back up configuration, validate it, enable the
                              detected web service, and reload it when active or
                              start it when stopped.
  --service-action ACTION     start, restart, reload, enable, or reset-failed.
  --rotate-logs               Run the installed server's logrotate policy.

Selection and verification:
  --server auto|nginx|apache  Select the web server. Default: auto.
  --verify-url URL            Require a successful HTTP response after repair.

Controls:
  --dry-run                   Show intended commands without changing the system.
  --yes                       Skip the confirmation prompt.
  --output DIR                Save logs, backups, and verification output in DIR.
  -h, --help                  Show this help.

Exit codes: 0 success, 2 usage, 3 missing requirement, 4 privilege failure,
10 cancelled, 20 repair or verification failure.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repair) DO_REPAIR=true; shift ;;
    --service-action)
      [ "$#" -ge 2 ] || { echo "--service-action requires a value." >&2; exit 2; }
      SERVICE_ACTION="$2"; shift 2 ;;
    --rotate-logs) ROTATE_LOGS=true; shift ;;
    --server)
      [ "$#" -ge 2 ] || { echo "--server requires a value." >&2; exit 2; }
      SERVER_CHOICE="$2"; shift 2 ;;
    --verify-url)
      [ "$#" -ge 2 ] || { echo "--verify-url requires a URL." >&2; exit 2; }
      VERIFY_URL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --output)
      [ "$#" -ge 2 ] || { echo "--output requires a directory." >&2; exit 2; }
      OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if ! $DO_REPAIR && ! $ROTATE_LOGS && [ -z "$SERVICE_ACTION" ]; then
  echo "Choose at least one repair action." >&2
  usage
  exit 2
fi
case "$SERVER_CHOICE" in auto|nginx|apache) : ;; *) echo "Unsupported server selection: $SERVER_CHOICE" >&2; exit 2 ;; esac
case "$SERVICE_ACTION" in ''|start|restart|reload|enable|reset-failed) : ;; *) echo "Unsupported service action: $SERVICE_ACTION" >&2; exit 2 ;; esac
if $DO_REPAIR && [ -n "$SERVICE_ACTION" ]; then
  echo "Use --repair or --service-action, not both." >&2
  exit 2
fi
case "$VERIFY_URL" in ''|http://*|https://*) : ;; *) echo "--verify-url must begin with http:// or https://" >&2; exit 2 ;; esac

command -v systemctl >/dev/null 2>&1 || { echo "systemd is required." >&2; exit 3; }

has_nginx() { command -v nginx >/dev/null 2>&1 && systemctl cat nginx.service >/dev/null 2>&1; }
has_apache() {
  { command -v apache2ctl >/dev/null 2>&1 || command -v apachectl >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1; } &&
  { systemctl cat apache2.service >/dev/null 2>&1 || systemctl cat httpd.service >/dev/null 2>&1; }
}
select_nginx() {
  SERVER=nginx
  SERVICE_UNIT=nginx.service
  CONF_DIR=/etc/nginx
  LOGROTATE_FILE=/etc/logrotate.d/nginx
  TEST_CMD=(nginx -t)
}
select_apache() {
  SERVER=apache
  if systemctl cat apache2.service >/dev/null 2>&1; then
    SERVICE_UNIT=apache2.service
    CONF_DIR=/etc/apache2
    LOGROTATE_FILE=/etc/logrotate.d/apache2
  else
    SERVICE_UNIT=httpd.service
    CONF_DIR=/etc/httpd
    LOGROTATE_FILE=/etc/logrotate.d/httpd
  fi
  if command -v apache2ctl >/dev/null 2>&1; then
    TEST_CMD=(apache2ctl configtest)
  elif command -v apachectl >/dev/null 2>&1; then
    TEST_CMD=(apachectl configtest)
  else
    TEST_CMD=(httpd -t)
  fi
}

case "$SERVER_CHOICE" in
  nginx) has_nginx || { echo "Nginx service and command were not found." >&2; exit 3; }; select_nginx ;;
  apache) has_apache || { echo "Apache service and command were not found." >&2; exit 3; }; select_apache ;;
  auto)
    if has_nginx && systemctl is-active --quiet nginx.service; then
      select_nginx
    elif has_apache && { systemctl is-active --quiet apache2.service || systemctl is-active --quiet httpd.service; }; then
      select_apache
    elif has_nginx; then
      select_nginx
    elif has_apache; then
      select_apache
    else
      echo "No supported Nginx or Apache installation was found." >&2
      exit 3
    fi
    ;;
esac

[ -d "$CONF_DIR" ] || { echo "Configuration directory not found: $CONF_DIR" >&2; exit 3; }
if $ROTATE_LOGS; then command -v logrotate >/dev/null 2>&1 || { echo "logrotate is required for --rotate-logs." >&2; exit 3; }; fi
if [ -n "$VERIFY_URL" ]; then command -v curl >/dev/null 2>&1 || { echo "curl is required for --verify-url." >&2; exit 3; }; fi
if ! $DRY_RUN && [ "$(id -u)" -ne 0 ]; then
  echo "Run this repair as root, for example: sudo $0 ..." >&2
  exit 4
fi

STAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${OUTPUT_DIR:-./web-server-repair-$STAMP}"
BACKUP_DIR="$OUTPUT_DIR/backup"
mkdir -p "$OUTPUT_DIR" "$BACKUP_DIR"
LOG="$OUTPUT_DIR/repair.log"
BEFORE="$OUTPUT_DIR/before.txt"
AFTER="$OUTPUT_DIR/after.txt"
: > "$LOG"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
confirm() {
  $ASSUME_YES && return 0
  read -r -p "$1 [y/N]: " answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
run_action() {
  local description="$1"; shift
  ACTIONS=$((ACTIONS + 1))
  log "$description"
  if $DRY_RUN; then
    printf 'DRY-RUN:' >> "$LOG"
    printf ' %q' "$@" >> "$LOG"
    printf '\n' >> "$LOG"
    return 0
  fi
  if "$@" >> "$LOG" 2>&1; then
    log "SUCCESS: $description"
    return 0
  fi
  FAILURES=$((FAILURES + 1))
  log "WARNING: $description failed"
  return 1
}
config_valid() { "${TEST_CMD[@]}" >> "$LOG" 2>&1; }
collect_state() {
  local destination="$1"
  {
    echo "Collected: $(date -Is)"
    echo "Detected server: $SERVER"
    echo "Service unit: $SERVICE_UNIT"
    echo "Configuration directory: $CONF_DIR"
    echo
    systemctl status "$SERVICE_UNIT" --no-pager -l 2>&1 || true
    echo
    "${TEST_CMD[@]}" 2>&1 || true
    echo
    command -v ss >/dev/null 2>&1 && ss -lntp 2>/dev/null | grep -E '(:80|:443|nginx|apache|httpd)' || true
    echo
    df -h / /var /var/log 2>/dev/null || true
    echo
    journalctl -u "$SERVICE_UNIT" -n 100 --no-pager 2>&1 || true
    if [ -n "$VERIFY_URL" ]; then
      echo
      curl -kfsSIL --max-time 10 "$VERIFY_URL" 2>&1 || true
    fi
  } > "$destination"
}
backup_config() {
  if $DRY_RUN; then
    log "DRY-RUN: back up $CONF_DIR to $BACKUP_DIR/${SERVER}-config.tgz"
    return 0
  fi
  tar -C / -czf "$BACKUP_DIR/${SERVER}-config.tgz" "${CONF_DIR#/}" >> "$LOG" 2>&1 || {
    FAILURES=$((FAILURES + 1))
    log "WARNING: unable to back up $CONF_DIR; service changes were skipped."
    return 1
  }
  log "SUCCESS: backed up $CONF_DIR"
}

collect_state "$BEFORE"
confirm "Apply the selected $SERVER web-server repair actions?" || {
  log "Repair cancelled."
  exit 10
}

if $DO_REPAIR || [ -n "$SERVICE_ACTION" ]; then
  backup_config || { collect_state "$AFTER"; exit 20; }
fi

CONFIG_VALID=true
if $DO_REPAIR || [ -n "$SERVICE_ACTION" ]; then
  if $DRY_RUN; then
    log "DRY-RUN: ${TEST_CMD[*]}"
  elif config_valid; then
    log "SUCCESS: $SERVER configuration validation passed."
  else
    CONFIG_VALID=false
    FAILURES=$((FAILURES + 1))
    log "WARNING: $SERVER configuration validation failed. Service changes were skipped."
  fi
fi

if $ROTATE_LOGS; then
  if [ -f "$LOGROTATE_FILE" ]; then
    run_action "Running $SERVER log rotation policy" logrotate "$LOGROTATE_FILE" || true
  else
    FAILURES=$((FAILURES + 1))
    log "WARNING: logrotate policy not found: $LOGROTATE_FILE"
  fi
fi

if $CONFIG_VALID; then
  if $DO_REPAIR; then
    run_action "Enabling $SERVICE_UNIT" systemctl enable "$SERVICE_UNIT" || true
    if systemctl is-active --quiet "$SERVICE_UNIT"; then
      run_action "Reloading $SERVICE_UNIT" systemctl reload "$SERVICE_UNIT" || true
    else
      run_action "Starting $SERVICE_UNIT" systemctl start "$SERVICE_UNIT" || true
    fi
  fi
  case "$SERVICE_ACTION" in
    start) run_action "Starting $SERVICE_UNIT" systemctl start "$SERVICE_UNIT" || true ;;
    restart) run_action "Restarting $SERVICE_UNIT" systemctl restart "$SERVICE_UNIT" || true ;;
    reload) run_action "Reloading $SERVICE_UNIT" systemctl reload "$SERVICE_UNIT" || true ;;
    enable) run_action "Enabling and starting $SERVICE_UNIT" systemctl enable --now "$SERVICE_UNIT" || true ;;
    reset-failed) run_action "Clearing failed state for $SERVICE_UNIT" systemctl reset-failed "$SERVICE_UNIT" || true ;;
  esac
fi

$DRY_RUN || sleep 2
collect_state "$AFTER"
if ! $DRY_RUN && { $DO_REPAIR || [ "$SERVICE_ACTION" = start ] || [ "$SERVICE_ACTION" = restart ] || [ "$SERVICE_ACTION" = enable ]; }; then
  systemctl is-active --quiet "$SERVICE_UNIT" || {
    FAILURES=$((FAILURES + 1))
    log "WARNING: $SERVICE_UNIT is not active after repair."
  }
fi
if ! $DRY_RUN && ! config_valid; then
  FAILURES=$((FAILURES + 1))
  log "WARNING: post-repair $SERVER configuration validation failed."
fi
if [ -n "$VERIFY_URL" ] && ! $DRY_RUN; then
  if curl -kfsSIL --max-time 10 "$VERIFY_URL" >> "$LOG" 2>&1; then
    log "SUCCESS: $VERIFY_URL responded successfully."
  else
    FAILURES=$((FAILURES + 1))
    log "WARNING: $VERIFY_URL did not respond successfully."
  fi
fi

if [ "$FAILURES" -gt 0 ]; then
  log "Repair finished with $FAILURES failure(s)."
  exit 20
fi
log "Repair completed successfully. Actions performed: $ACTIONS"
exit 0
