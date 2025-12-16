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

LOG_FILE="sop-log-$(date +%Y%m%d-%H%M%S).txt"
WP_ROOT="/var/www/vhosts/localhost/html"
WP_USER="ubuntu"
WP_GROUP="ubuntu"

START_TIME=$(date +%s)
FAILED=false
SECTION_TIMES=()

#####################################
# Color support
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
    local end dur
    end=$(date +%s)
    dur=$((end - SECTION_START))
    SECTION_TIMES+=("$CURRENT_SECTION: ${dur}s")
    log "${GREEN}⏱️ Section completed in ${dur}s${RESET}"
}

#####################################
# Argument parsing
#####################################
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --security-only) SECURITY_ONLY=true ;;
        --no-plugins) NO_PLUGINS=true ;;
    esac
done

#####################################
# Command runner
#####################################
run_cmd() {
    log "${YELLOW}▶️ $1${RESET}"
    [[ "$DRY_RUN" == true ]] && return 0
    (cd "$WP_ROOT" && eval "$1") 2>&1 | tee -a "$LOG_FILE"
}

#####################################
# Prerequisites
#####################################
log_section "Prerequisites"
command -v wp >/dev/null || { log "❌ wp-cli missing"; exit 1; }
[[ -f "$WP_ROOT/wp-config.php" ]] || { log "❌ wp-config.php missing"; exit 1; }
end_section

#####################################
# Site Identity
#####################################
log_section "Site Identity"
if [[ "$DRY_RUN" == true ]]; then
    DOMAIN="example.com"
else
    DOMAIN=$(cd "$WP_ROOT" && wp option get siteurl --allow-root | sed -E 's#https?://##;s#/.*##')
fi
DOMAIN_NAME=$(cut -d. -f1 <<< "$DOMAIN")
ADMIN_PW="gar${DOMAIN_NAME^}${DOMAIN_NAME: -1}3esrx9gc!"
log "DOMAIN=$DOMAIN"
end_section

#####################################
# WordPress Permission Repair (CRITICAL)
#####################################
log_section "Repair WordPress Permissions"

mkdir -p wp-content/{uploads,upgrade,cache,wflogs,litespeed}

chown -R ${WP_USER}:${WP_GROUP} wp-content

# Lock WordPress core
find wp-admin wp-includes -type d -exec chmod 755 {} \;
find wp-admin wp-includes -type f -exec chmod 644 {} \;

# Lock root PHP files
find . -maxdepth 1 -type f -name "*.php" -exec chmod 644 {} \;

# Secure wp-config
chmod 600 wp-config.php

# Allow wp-content writes safely
find wp-content -type d -exec chmod 755 {} \;
find wp-content -type f -exec chmod 644 {} \;

end_section

#####################################
# Admin User
#####################################
log_section "Admin User"
if ! wp user get webadmin --allow-root >/dev/null 2>&1; then
    run_cmd "wp user create webadmin webadmin@$DOMAIN --role=administrator --user_pass='$ADMIN_PW' --allow-root"
else
    log "ℹ️ webadmin already exists"
fi
end_section

#####################################
# Security Hardening
#####################################
log_section "Security Hardening"
run_cmd "wp config shuffle-salts --allow-root"

# Block PHP in uploads
HTACCESS="$WP_ROOT/.htaccess"
grep -q "uploads.*\.php" "$HTACCESS" 2>/dev/null || cat >> "$HTACCESS" <<'EOF'
# Block PHP execution in uploads
RewriteEngine On
RewriteRule ^wp-content/uploads/.*\.php$ - [F,L]
EOF

# Protect debug.log
DEBUG_HT="$WP_ROOT/wp-content/.htaccess"
grep -q "debug.log" "$DEBUG_HT" 2>/dev/null || cat >> "$DEBUG_HT" <<'EOF'
# Block debug.log
<Files "debug.log">
  Require all denied
</Files>
EOF

end_section

[[ "$SECURITY_ONLY" == true ]] && goto_summary=true || goto_summary=false

#####################################
# Malware Scan
#####################################
if [[ "$goto_summary" == false ]]; then
    log_section "Malware Scan"
    run_cmd "find wp-content/uploads -name '*.php'"
    end_section
fi

#####################################
# Plugins
#####################################
if [[ "$goto_summary" == false && "$NO_PLUGINS" == false ]]; then
    log_section "Plugins"

    run_cmd "wp plugin install wordfence --activate --allow-root"
    run_cmd "wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOM.zip --force --activate --allow-root"
    run_cmd "wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOS3.zip --force --allow-root"

    if wp eval 'echo method_exists("Ai1wm_Cron","exists") ? "OK" : "NO";' --allow-root 2>/dev/null | grep -q OK; then
        run_cmd "wp plugin activate all-in-one-wp-migration-s3-extension --allow-root"
        log "✅ AIOS3 activated"
    else
        log "⚠️ AIOS3 installed but NOT activated (prevented fatal error)"
    fi

    end_section
fi

#####################################
# Summary
#####################################
END_TIME=$(date +%s)
log_section "SUMMARY"
log "Total duration: $((END_TIME - START_TIME))s"
for s in "${SECTION_TIMES[@]}"; do log " • $s"; done
[[ "$FAILED" == false ]] && log "${GREEN}✅ SUCCESS${RESET}" || log "${RED}❌ FAILED${RESET}"
log "Log file: $LOG_FILE"
