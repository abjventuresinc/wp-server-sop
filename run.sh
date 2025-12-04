#!/bin/bash
set -o pipefail

DRY_RUN=false
LOG_FILE="sop-log-$(date +%Y%m%d-%H%M%S).txt"

# Detect --dry-run flag
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        DRY_RUN=true
        echo "🔍 DRY RUN MODE ENABLED — No commands will be executed."
    fi
done

log() {
    echo "$@" | tee -a "$LOG_FILE"
}

# Function: run command + log output
run_cmd() {
    log "------------------------------------------------------------"
    log "➡️ Command: $1"
    log "------------------------------------------------------------"

    if [ "$DRY_RUN" = true ]; then
        log "🟡 DRY RUN: Command NOT executed."
        return
    fi

    OUTPUT=$(eval "$1" 2>&1)
    STATUS=$?

    echo "$OUTPUT" | tee -a "$LOG_FILE"

    if [ $STATUS -ne 0 ]; then
        log "❌ ERROR running: $1"
    else
        log "✅ SUCCESS"
    fi
}

log "==============================================="
log "🚀 BEGIN WORDPRESS SOP SCRIPT"
log "Dry Run Mode: $DRY_RUN"
log "Log File: $LOG_FILE"
log "==============================================="

########################################
# 1️⃣ Change to WP root
########################################
run_cmd 'cd /var/www/vhosts/localhost/html'

########################################
# 1.1 Compute DOMAIN / PW in main shell
########################################
if [ "$DRY_RUN" = false ]; then
    log "➡️ Computing DOMAIN, DOMAIN_NAME and PW"

    DOMAIN=$(wp option get siteurl --allow-root | sed 's#https\?://##' | sed 's#/.*##')
    DOMAIN_NAME=$(echo "$DOMAIN" | cut -d'.' -f1)
    PW="gar$(echo "$DOMAIN_NAME" | cut -c1 | tr '[:lower:]' '[:upper:]')$(echo "$DOMAIN_NAME" | rev | cut -c1 | tr '[:upper:]' '[:lower:]')3esrx9gc!"

    log "DOMAIN=$DOMAIN"
    log "DOMAIN_NAME=$DOMAIN_NAME"
else
    log "🟡 DRY RUN: Would compute DOMAIN, DOMAIN_NAME, PW"
fi

########################################
# 1.2 Create / reuse webadmin & delete others
########################################
# just for logging
run_cmd 'wp user get webadmin --field=ID --allow-root'

NEW_ID=""

if [ "$DRY_RUN" = false ]; then
    USER_EXISTS=$(wp user get webadmin --field=ID --allow-root 2>/dev/null || echo "")

    if [ -z "$USER_EXISTS" ]; then
        log "🔧 Creating webadmin user..."
        CREATE_OUTPUT=$(wp user create webadmin "webadmin@$DOMAIN" --role=administrator --user_pass="$PW" --allow-root 2>&1)
        CREATE_STATUS=$?

        echo "$CREATE_OUTPUT" | tee -a "$LOG_FILE"

        if [ $CREATE_STATUS -ne 0 ]; then
            log "❌ Failed to create webadmin. Continuing script without user deletion."
        else
            NEW_ID=$(echo "$CREATE_OUTPUT" | tail -n1)
            log "✅ Created webadmin with ID $NEW_ID"
        fi
    else
        log "ℹ️ webadmin already exists — ID: $USER_EXISTS"
        NEW_ID=$USER_EXISTS
    fi

    if [ -n "$NEW_ID" ]; then
        log "🧹 Deleting all other users and reassigning content to webadmin (#$NEW_ID)..."
        DELETE_CMD="wp user delete \$(wp user list --field=ID --allow-root | grep -v \"^$NEW_ID$\") --reassign=$NEW_ID --allow-root"
        run_cmd "$DELETE_CMD"
    else
        log "⚠️ NEW_ID is empty. Skipping user deletion step."
    fi
else
    log "🟡 DRY RUN: Would create webadmin (if missing) and delete other users."
fi

########################################
# 2️⃣ Regenerate SALTs
########################################
run_cmd 'wp config shuffle-salts --allow-root'

########################################
# 3️⃣ Fix File Permissions
########################################
run_cmd 'find . -type f -exec chmod 644 {} \;'
run_cmd 'find . -type d -exec chmod 755 {} \;'
run_cmd 'chmod 600 wp-config.php'

########################################
# 4️⃣ Block PHP Execution in Uploads
########################################
run_cmd 'echo "" >> .htaccess'
run_cmd 'echo "# Block PHP execution in uploads (OLS)" >> .htaccess'
run_cmd 'echo "RewriteEngine On" >> .htaccess'
run_cmd 'echo "RewriteRule ^wp-content/uploads/.*\.php$ - [F,L]" >> .htaccess'
run_cmd 'rm -rf wp-content/litespeed-cache/*'

########################################
# 5️⃣ Malware Scan (Improved)
########################################
run_cmd 'echo "=== SCAN: PHP FILES IN UPLOADS ===" > scan-output.txt'
run_cmd 'find wp-content/uploads -type f -name "*.php" >> scan-output.txt'
run_cmd 'echo -e "\n=== SCAN: RECENTLY MODIFIED PHP FILES ===" >> scan-output.txt'
run_cmd 'find . -type f -name "*.php" -mtime -7 >> scan-output.txt'
run_cmd 'echo -e "\n=== SCAN: SUSPICIOUS FUNCTIONS ===" >> scan-output.txt'
run_cmd 'grep -RIn --color=never -E "base64_decode|eval\(|gzinflate|str_rot13|shell_exec|passthru|system\(" . | grep -v "scan-output.txt" >> scan-output.txt'
run_cmd 'echo -e "\n=== SCAN: 777 PERMISSION FILES ===" >> scan-output.txt'
run_cmd 'find . -type f -perm 0777 >> scan-output.txt'
run_cmd 'echo -e "\n=== SCAN COMPLETE ===" >> scan-output.txt'

########################################
# 6️⃣ Backup wp-config.php
########################################
run_cmd 'cp wp-config.php wp-config.php.backup.$(date +%Y%m%d-%H%M%S)'

########################################
# 7️⃣ Reinstall MU Plugin
########################################
run_cmd 'cd wp-content'
run_cmd 'cp -r mu-plugins mu-plugins.backup.$(date +%Y%m%d-%H%M%S)'
run_cmd 'rm -rf mu-plugins/*'
run_cmd 'wget -O mu-plugins/abj_datalayers.php https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/abj_datalayers.php'

########################################
# 8️⃣ Install + ACTIVATE Wordfence
########################################
run_cmd 'cd /var/www/vhosts/localhost/html'
run_cmd 'wp plugin install wordfence --allow-root'
run_cmd 'wp plugin activate wordfence --allow-root'

########################################
# 9️⃣ Install + Activate AIOM + AIOS3
########################################
run_cmd 'wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOM.zip --allow-root'
run_cmd 'wp plugin activate aiom --allow-root'

run_cmd 'wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOS3.zip --allow-root'
run_cmd 'wp plugin activate aios3 --allow-root'

log "==============================================="
log "🏁 SCRIPT FINISHED — Full log saved to $LOG_FILE"
log "Dry Run Mode: $DRY_RUN"
log "==============================================="
