#!/bin/bash
set -e

DRY_RUN=false
LOG_FILE="sop-log-$(date +%Y%m%d-%H%M%S).txt"

# Detect --dry-run flag
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        DRY_RUN=true
        echo "🔍 DRY RUN MODE ENABLED — No commands will be executed."
    fi
done

# Function: run command + log output
run_cmd() {
    echo "------------------------------------------------------------" | tee -a "$LOG_FILE"
    echo "➡️ Command: $1" | tee -a "$LOG_FILE"
    echo "------------------------------------------------------------" | tee -a "$LOG_FILE"

    if [ "$DRY_RUN" = true ]; then
        echo "🟡 DRY RUN: Command NOT executed." | tee -a "$LOG_FILE"
        return
    fi

    # Execute command AND capture output
    OUTPUT=$(eval "$1" 2>&1)
    STATUS=$?

    echo "$OUTPUT" | tee -a "$LOG_FILE"

    if [ $STATUS -ne 0 ]; then
        echo "❌ ERROR running: $1" | tee -a "$LOG_FILE"
        echo "Output:" | tee -a "$LOG_FILE"
        echo "$OUTPUT" | tee -a "$LOG_FILE"
    else
        echo "✅ SUCCESS" | tee -a "$LOG_FILE"
    fi
}

echo "===============================================" | tee -a "$LOG_FILE"
echo "🚀 BEGIN WORDPRESS SOP SCRIPT" | tee -a "$LOG_FILE"
echo "Dry Run Mode: $DRY_RUN" | tee -a "$LOG_FILE"
echo "Log File: $LOG_FILE" | tee -a "$LOG_FILE"
echo "===============================================" | tee -a "$LOG_FILE"

########################################
# 1️⃣ Create New Admin & Delete Others
########################################
run_cmd 'cd /var/www/vhosts/localhost/html'
run_cmd 'DOMAIN=$(wp option get siteurl --allow-root | sed "s#https\?://##" | sed "s#/.*##")'
run_cmd 'DOMAIN_NAME=$(echo $DOMAIN | cut -d"." -f1)'
run_cmd 'PW="gar$(echo $DOMAIN_NAME | cut -c1 | tr "[:lower:]" "[:upper:]")$(echo $DOMAIN_NAME | rev | cut -c1 | tr "[:upper:]" "[:lower:]")3esrx9gc!"'
run_cmd 'NEW_ID=$(wp user create webadmin webadmin@$DOMAIN --role=administrator --user_pass="$PW" --allow-root --porcelain)'
run_cmd 'wp user delete $(wp user list --field=ID --allow-root | grep -v "^$NEW_ID$") --reassign=$NEW_ID --allow-root'

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
# 8️⃣ Install + ACTIVATE Wordfence (Improved)
########################################
run_cmd 'cd /var/www/vhosts/localhost/html'
run_cmd 'wp plugin install wordfence --allow-root'

# Explicit activation with logging
run_cmd 'wp plugin activate wordfence --allow-root'

########################################
# ✔ Install + Activate AIOM + AIOS3 (Improved)
########################################
run_cmd 'wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOM.zip --allow-root'
run_cmd 'wp plugin activate aiom --allow-root'

run_cmd 'wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOS3.zip --allow-root'
run_cmd 'wp plugin activate aios3 --allow-root'

echo "===============================================" | tee -a "$LOG_FILE"
echo "🏁 SCRIPT FINISHED — Full log saved to $LOG_FILE" | tee -a "$LOG_FILE"
echo "Dry Run Mode: $DRY_RUN" | tee -a "$LOG_FILE"
echo "===============================================" | tee -a "$LOG_FILE"
