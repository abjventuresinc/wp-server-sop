#!/usr/bin/env bash
set -o pipefail
set -u
shopt -s nocasematch

#####################################
# Global config
#####################################
DRY_RUN=false
SECURITY_ONLY=false
NO_PLUGINS=false

FORCE_SINGLE_ADMIN=false   # DANGEROUS: deletes ALL users except webadmin
YES=false                  # required to run FORCE_SINGLE_ADMIN non-interactively

LOG_FILE="sop-log-$(date +%Y%m%d-%H%M%S).txt"
WP_ROOT="/var/www/vhosts/localhost/html"

START_TIME=$(date +%s)
FAILED=false
ROLLBACK_ACTIONS=()
SECTION_TIMES=()

#####################################
# Color support (terminal only)
#####################################
if [[ -t 1 ]]; then
  RED="\033[0;31m"
  GREEN="\033[0;32m"
  YELLOW="\033[0;33m"
  BLUE="\033[0;34m"
  BOLD="\033[1m"
  RESET="\033[0m"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

#####################################
# Logging helpers
#####################################
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

log() {
  printf "[%s] %b%s%b\n" "$(timestamp)" "$BLUE" "$*" "$RESET" | tee -a "$LOG_FILE"
}

log_section() {
  CURRENT_SECTION="$1"
  SECTION_START=$(date +%s)
  log ""
  log "${BOLD}============================================================${RESET}"
  log "${BOLD}🔷 $1${RESET}"
  log "${BOLD}============================================================${RESET}"
}

end_section() {
  local end; end=$(date +%s)
  local dur=$((end - SECTION_START))
  SECTION_TIMES+=("$CURRENT_SECTION: ${dur}s")
  log "${GREEN}⏱️ Section completed in ${dur}s${RESET}"
}

log_step_start() { log "${YELLOW}▶️ START: $1${RESET}"; }
log_step_end()   { log "${GREEN}✅ END: $1${RESET}"; }

#####################################
# Rollback handling
#####################################
register_rollback() { ROLLBACK_ACTIONS+=("$1"); }

run_rollback() {
  [[ ${#ROLLBACK_ACTIONS[@]} -eq 0 ]] && return
  log_section "ROLLBACK"
  local action
  for action in "${ROLLBACK_ACTIONS[@]}"; do
    log "↩️ $action"
    eval "$action" || true
  done
}

#####################################
# Trap unexpected exit
#####################################
on_exit() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    FAILED=true
    log "${RED}❌ Script exited unexpectedly (code $exit_code)${RESET}"
    run_rollback
  fi
}
trap on_exit EXIT

#####################################
# Argument parsing
#####################################
parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=true ;;
      --security-only) SECURITY_ONLY=true ;;
      --no-plugins) NO_PLUGINS=true ;;
      --force-single-admin) FORCE_SINGLE_ADMIN=true ;;
      --yes) YES=true ;;
    esac
  done
}

#####################################
# Command runner
#####################################
run_cmd() {
  local cmd="$1"
  log_step_start "Command"
  log "➡️ $cmd"

  if [[ "$DRY_RUN" == true ]]; then
    log "🟡 DRY RUN — skipped"
    log_step_end "Command (dry-run)"
    return 0
  fi

  local start end output status
  start=$(date +%s)
  output=$(cd "$WP_ROOT" && eval "$cmd" 2>&1)
  status=$?
  end=$(date +%s)

  printf "%s\n" "$output" | tee -a "$LOG_FILE"

  if [[ $status -ne 0 ]]; then
    log "${RED}❌ Failed after $((end-start))s${RESET}"
    FAILED=true
    exit $status
  fi

  log "⏱️ $((end-start))s"
  log_step_end "Command"
}

#####################################
# Prerequisites
#####################################
check_prerequisites() {
  log_section "Prerequisites"
  command -v wp &>/dev/null || { log "${RED}wp-cli not found${RESET}"; exit 1; }
  [[ -d "$WP_ROOT" ]] || { log "${RED}WP_ROOT not found: $WP_ROOT${RESET}"; exit 1; }
  [[ -f "$WP_ROOT/wp-config.php" ]] || { log "${RED}wp-config.php not found in $WP_ROOT${RESET}"; exit 1; }
  log "✅ OK"
  end_section
}

#####################################
# Identity + ownership detection
#####################################
detect_users() {
  # owner of WP files
  WP_OWNER="$(stat -c '%U' "$WP_ROOT/wp-config.php" 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")"
  WP_GROUP="$(stat -c '%G' "$WP_ROOT/wp-config.php" 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")"

  # web server user (OpenLiteSpeed -> nobody)
  if ps aux | grep -E 'openlitespeed|lshttpd' | grep -qv grep; then
    WEB_USER="nobody"
    WEB_GROUP="nogroup"
  elif ps aux | grep -E 'nginx' | grep -qv grep; then
    WEB_USER="www-data"
    WEB_GROUP="www-data"
  elif ps aux | grep -E 'apache2|httpd' | grep -qv grep; then
    WEB_USER="www-data"
    WEB_GROUP="www-data"
  else
    WEB_USER="nobody"
    WEB_GROUP="nogroup"
  fi

  # php worker user (your box shows lsphp as ubuntu)
  PHP_USER="$(ps aux | awk '/lsphp/ && $1 !~ /root/ {print $1; exit}' || true)"
  [[ -z "${PHP_USER:-}" ]] && PHP_USER="$WP_OWNER"

  log "Detected WP_OWNER=$WP_OWNER, WP_GROUP=$WP_GROUP"
  log "Detected WEB_USER=$WEB_USER, WEB_GROUP=$WEB_GROUP"
  log "Detected PHP_USER=$PHP_USER"
}

#####################################
# Site identity
#####################################
compute_site_identity() {
  log_section "Site Identity"

  if [[ "$DRY_RUN" == true ]]; then
    DOMAIN="example.com"
    DOMAIN_NAME="example"
    PW="[computed]"
    log "🟡 DRY RUN values"
    end_section
    return
  fi

  DOMAIN=$(cd "$WP_ROOT" && wp option get siteurl --allow-root | sed -E 's#https?://##;s#/.*##' | tr -d '\r')
  DOMAIN_NAME=$(cut -d. -f1 <<< "$DOMAIN")
  PW="gar${DOMAIN_NAME^}${DOMAIN_NAME: -1}3esrx9gc!"

  log "DOMAIN=$DOMAIN"
  end_section
}

#####################################
# Backups for small file edits
#####################################
safe_backup() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local bak="${f}.bak.$(date +%s)"
  cp "$f" "$bak"
  register_rollback "mv '$bak' '$f'"
}

#####################################
# Permissions that keep plugins working (OLS-friendly)
#####################################
ensure_writable_wp_content() {
  log_section "Permissions: wp-content writable"

  [[ "$DRY_RUN" == true ]] && { log "🟡 DRY RUN"; end_section; return; }

  # Create common writable dirs used by WP/LS/Wordfence/updates
  local dirs=(
    "$WP_ROOT/wp-content/uploads"
    "$WP_ROOT/wp-content/upgrade"
    "$WP_ROOT/wp-content/cache"
    "$WP_ROOT/wp-content/wflogs"
    "$WP_ROOT/wp-content/litespeed"
  )

  for d in "${dirs[@]}"; do
    mkdir -p "$d"
  done

  # Make sure web/PHP can write: set group to WEB_GROUP and enable setgid
  # (keeps new files group-owned by WEB_GROUP)
  chown -R "$WP_OWNER:$WEB_GROUP" "$WP_ROOT/wp-content" || true
  chmod 755 "$WP_ROOT/wp-content" || true
  chmod g+s "$WP_ROOT/wp-content" || true

  # Directories writable for group
  find "$WP_ROOT/wp-content" -type d -exec chmod 775 {} \; 2>/dev/null || true

  # Files: readable for group (WP/plugins will create what they need)
  find "$WP_ROOT/wp-content" -type f -exec chmod 664 {} \; 2>/dev/null || true

  # Make especially important dirs writable
  chmod 775 "$WP_ROOT/wp-content/uploads" "$WP_ROOT/wp-content/upgrade" "$WP_ROOT/wp-content/wflogs" 2>/dev/null || true

  # Wordfence expects wflogs writable
  touch "$WP_ROOT/wp-content/wflogs/.write_test" 2>/dev/null || true
  rm -f "$WP_ROOT/wp-content/wflogs/.write_test" 2>/dev/null || true

  log "✅ wp-content permissions set (group-writable) to avoid Wordfence/WP update/import issues"
  end_section
}

#####################################
# Security rules (non-breaking)
#####################################
block_php_uploads() {
  log_section "Block PHP in Uploads"
  [[ "$DRY_RUN" == true ]] && { log "🟡 DRY RUN"; end_section; return; }

  local f="$WP_ROOT/.htaccess"
  [[ -f "$f" ]] || { log "ℹ️ No .htaccess found at root (OK on some OLS configs)"; end_section; return; }

  grep -q "Block PHP execution in uploads" "$f" 2>/dev/null && { log "ℹ️ Already present"; end_section; return; }

  safe_backup "$f"

  cat >> "$f" <<'EOF'

# Block PHP execution in uploads
RewriteEngine On
RewriteRule ^wp-content/uploads/.*\.php$ - [F,L]
EOF

  end_section
}

block_debug_log() {
  log_section "Protect debug.log"
  [[ "$DRY_RUN" == true ]] && { log "🟡 DRY RUN"; end_section; return; }

  local f="$WP_ROOT/wp-content/.htaccess"
  [[ -f "$f" ]] || touch "$f"

  grep -q "Block debug.log" "$f" && { log "ℹ️ Already protected"; end_section; return; }

  safe_backup "$f"

  cat >> "$f" <<'EOF'

# Block debug.log
<Files "debug.log">
  Require all denied
</Files>
EOF

  end_section
}

#####################################
# Admin user management
#####################################
ensure_webadmin() {
  log_section "Admin User"

  if [[ "$DRY_RUN" == true ]]; then
    log "🟡 DRY RUN"
    end_section
    return
  fi

  if ! wp user get webadmin --allow-root &>/dev/null; then
    run_cmd "wp user create webadmin webadmin@$DOMAIN --role=administrator --user_pass='$PW' --allow-root"
  else
    log "ℹ️ webadmin already exists"
    # Ensure role is admin (just in case)
    run_cmd "wp user set-role webadmin administrator --allow-root"
  fi

  end_section
}

confirm_force_single_admin() {
  [[ "$FORCE_SINGLE_ADMIN" == true ]] || return 0
  [[ "$YES" == true ]] && return 0

  echo ""
  echo "⚠️  DANGER: --force-single-admin will DELETE ALL USERS except 'webadmin'."
  echo "Type EXACTLY: DELETE-ALL-USERS"
  read -r reply
  if [[ "$reply" != "DELETE-ALL-USERS" ]]; then
    log "${RED}Aborted: confirmation not provided${RESET}"
    exit 1
  fi
}

enforce_single_admin() {
  [[ "$FORCE_SINGLE_ADMIN" == true ]] || return 0
  log_section "Enforce Single Admin (DESTRUCTIVE)"

  confirm_force_single_admin

  # Ensure webadmin exists first
  wp user get webadmin --allow-root &>/dev/null || {
    log "${RED}webadmin does not exist; refusing to delete users${RESET}"
    exit 1
  }

  local webadmin_id
  webadmin_id="$(wp user get webadmin --field=ID --allow-root | tr -d '\r')"

  # Delete all users except webadmin, reassign content to webadmin
  local ids id login
  ids="$(wp user list --field=ID --allow-root | tr -d '\r' || true)"

  while read -r id; do
    [[ -z "$id" ]] && continue
    login="$(wp user get "$id" --field=user_login --allow-root 2>/dev/null | tr -d '\r' || true)"
    if [[ "$login" != "webadmin" ]]; then
      run_cmd "wp user delete $id --reassign=$webadmin_id --yes --allow-root"
    fi
  done <<< "$ids"

  # Final sanity log
  run_cmd "wp user list --allow-root"

  log "✅ Only 'webadmin' should remain"
  end_section
}

#####################################
# Plugin helpers
#####################################
aios3_is_compatible() {
  [[ "$DRY_RUN" == true ]] && return 0
  local result
  result=$(cd "$WP_ROOT" && wp eval 'echo method_exists("Ai1wm_Cron","exists") ? "OK" : "NO";' --allow-root 2>/dev/null || true)
  [[ "$result" == "OK" ]]
}

ensure_aiom_storage_writable() {
  log_section "All-in-One WP Migration Storage Permissions"
  [[ "$DRY_RUN" == true ]] && { log "🟡 DRY RUN"; end_section; return; }

  local base="$WP_ROOT/wp-content/plugins/all-in-one-wp-migration"
  local storage="$base/storage"
  mkdir -p "$storage"

  # Keep plugin code readable, but storage writable
  chown -R "$WP_OWNER:$WEB_GROUP" "$base" 2>/dev/null || true
  chmod 755 "$base" 2>/dev/null || true
  find "$base" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "$base" -type f -exec chmod 644 {} \; 2>/dev/null || true

  chown -R "$WP_OWNER:$WEB_GROUP" "$storage" 2>/dev/null || true
  chmod 775 "$storage" 2>/dev/null || true
  chmod g+s "$storage" 2>/dev/null || true

  log "✅ AIOM storage should be writable: $storage"
  end_section
}

#####################################
# MAIN
#####################################
main() {
  parse_args "$@"

  log_section "BEGIN SOP"
  log "Dry run: $DRY_RUN"
  log "Security only: $SECURITY_ONLY"
  log "No plugins: $NO_PLUGINS"
  log "Force single admin: $FORCE_SINGLE_ADMIN"
  log "Yes (non-interactive destructive ops): $YES"
  end_section

  check_prerequisites
  detect_users
  compute_site_identity

  cd "$WP_ROOT" || exit 1

  # Minimal hardening that won't break plugin writes
  log_section "Security Hardening (safe)"
  run_cmd "wp config shuffle-salts --allow-root"
  run_cmd "chmod 600 wp-config.php"
  end_section

  # IMPORTANT: keep wp-content writable for OLS/WP
  ensure_writable_wp_content

  block_php_uploads
  block_debug_log

  ensure_webadmin
  enforce_single_admin

  if [[ "$SECURITY_ONLY" == true ]]; then
    log "⚠️ Security-only mode: skipping remaining steps"
    return 0
  fi

  log_section "Malware Scan"
  run_cmd "find wp-content/uploads -name '*.php'"
  end_section

  if [[ "$NO_PLUGINS" == true ]]; then
    log "⚠️ No-plugins mode: skipping plugin installation"
    return 0
  fi

  log_section "Plugins"
  run_cmd "wp plugin install wordfence --activate --allow-root"
  # Wordfence WAF storage path
  ensure_writable_wp_content

  run_cmd "wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOM.zip --force --activate --allow-root"
  ensure_aiom_storage_writable

  run_cmd "wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOS3.zip --force --allow-root"
  if aios3_is_compatible; then
    run_cmd "wp plugin activate all-in-one-wp-migration-s3-extension --allow-root"
    log "✅ AIOS3 activated (compatible)"
  else
    log "⚠️ AIOS3 installed but NOT activated (incompatible) — prevented fatal error"
  fi
  end_section
}

main "$@"

#####################################
# Summary
#####################################
END_TIME=$(date +%s)
log_section "SUMMARY"
log "Total duration: $((END_TIME - START_TIME))s"
log "Sections:"
for s in "${SECTION_TIMES[@]}"; do
  log " • $s"
done
[[ "$FAILED" == false ]] && log "${GREEN}✅ SUCCESS${RESET}" || log "${RED}❌ FAILED${RESET}"
log "Log file: $LOG_FILE"
