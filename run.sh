#!/bin/bash
set -o pipefail
shopt -s nocasematch

#####################################
# Global config
#####################################
DRY_RUN=false
SECURITY_ONLY=false
NO_PLUGINS=false

LOG_FILE="sop-log-$(date +%Y%m%d-%H%M%S).txt"
WP_ROOT="/var/www/vhosts/localhost/html"

START_TIME=$(date +%s)
FAILED=false
ROLLBACK_ACTIONS=()

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
    log ""
    log "${BOLD}============================================================${RESET}"
    log "${BOLD}🔷 $1${RESET}"
    log "${BOLD}============================================================${RESET}"
}

log_step_start() { log "${YELLOW}▶️ START: $1${RESET}"; }
log_step_end()   { log "${GREEN}✅ END: $1${RESET}"; }

#####################################
# Rollback handling
#####################################
register_rollback() {
    ROLLBACK_ACTIONS+=("$1")
}

run_rollback() {
    [[ ${#ROLLBACK_ACTIONS[@]} -eq 0 ]] && return
    log_section "ROLLBACK"
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
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --security-only) SECURITY_ONLY=true ;;
            --no-plugins) NO_PLUGINS=true ;;
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

    [[ "$DRY_RUN" == true ]] && {
        log "🟡 DRY RUN — skipped"
        log_step_end "Command (dry-run)"
        return 0
    }

    local start=$(date +%s)
    local output
    output=$(cd "$WP_ROOT" && eval "$cmd" 2>&1)
    local status=$?
    local end=$(date +%s)

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
    command -v wp &>/dev/null || exit 1
    [[ -d "$WP_ROOT" ]] || exit 1
    [[ -f "$WP_ROOT/wp-config.php" ]] || exit 1
    log "✅ OK"
}

#####################################
# Site identity
#####################################
compute_site_identity() {
    log_section "Site Identity"

    [[ "$DRY_RUN" == true ]] && {
        DOMAIN="example.com"
        DOMAIN_NAME="example"
        PW="[computed]"
        log "🟡 DRY RUN values"
        return
    }

    DOMAIN=$(cd "$WP_ROOT" && wp option get siteurl --allow-root | sed -E 's#https?://##;s#/.*##')
    DOMAIN_NAME=$(cut -d. -f1 <<< "$DOMAIN")
    PW="gar${DOMAIN_NAME^}${DOMAIN_NAME: -1}3esrx9gc!"

    log "DOMAIN=$DOMAIN"
}

#####################################
# Security rules
#####################################
block_php_uploads() {
    log_section "Block PHP in Uploads"
    [[ "$DRY_RUN" == true ]] && return

    local f="$WP_ROOT/.htaccess"
    grep -q "uploads.*\.php" "$f" 2>/dev/null && return

    cp "$f" "$f.bak"
    register_rollback "mv '$f.bak' '$f'"

    cat >> "$f" <<EOF
# Block PHP execution in uploads
RewriteEngine On
RewriteRule ^wp-content/uploads/.*\.php$ - [F,L]
EOF
}

block_debug_log() {
    log_section "Protect debug.log"
    [[ "$DRY_RUN" == true ]] && return

    local f="$WP_ROOT/wp-content/.htaccess"
    [[ -f "$f" ]] || touch "$f"

    grep -q "debug.log" "$f" && return

    cp "$f" "$f.bak"
    register_rollback "mv '$f.bak' '$f'"

    cat >> "$f" <<EOF
# Block debug.log
<Files "debug.log">
  Require all denied
</Files>
EOF
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

    check_prerequisites
    compute_site_identity

    cd "$WP_ROOT"

    log_section "Admin User"
    run_cmd "wp user get webadmin --allow-root || wp user create webadmin webadmin@$DOMAIN --role=administrator --user_pass='$PW' --allow-root"

    log_section "Security Hardening"
    run_cmd "wp config shuffle-salts --allow-root"
    run_cmd "chmod 600 wp-config.php"
    run_cmd "find . -type f -exec chmod 644 {} \;"
    run_cmd "find . -type d -exec chmod 755 {} \;"

    block_php_uploads
    block_debug_log

    [[ "$SECURITY_ONLY" == true ]] && return

    log_section "Malware Scan"
    run_cmd "find wp-content/uploads -name '*.php'"

    [[ "$NO_PLUGINS" == true ]] && return

    log_section "Plugins"
    run_cmd "wp plugin install wordfence --activate --allow-root"
    run_cmd "wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOM.zip --force --activate --allow-root"
    run_cmd "wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOS3.zip --force --activate --allow-root"
}

main "$@"

#####################################
# Summary
#####################################
END_TIME=$(date +%s)
log_section "SUMMARY"
log "Duration: $((END_TIME - START_TIME))s"
[[ "$FAILED" == false ]] && log "${GREEN}✅ SUCCESS${RESET}" || log "${RED}❌ FAILED${RESET}"
log "Log file: $LOG_FILE"
