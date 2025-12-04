#!/bin/bash
set -e

DRY_RUN=false

# Detect --dry-run flag
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        DRY_RUN=true
        echo "🔍 DRY RUN MODE ENABLED — No commands will be executed."
    fi
done

# Function to run or print commands
run_cmd() {
    echo "------------------------------------------------------------"
    echo "➡️ Command:"
    echo "$1"
    echo "------------------------------------------------------------"

    if [ "$DRY_RUN" = false ]; then
        eval "$1"
    else
        echo "🟡 DRY RUN: Command NOT executed."
    fi
}

echo "==============================================="
echo "🚀 BEGIN WORDPRESS SOP SCRIPT"
echo "Dry Run Mode: $DRY_RUN"
echo "==============================================="

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
# 5️⃣ Malware Scan
########################################
run_cmd 'echo "=== SCAN: PHP FILES IN UPLOADS ===" > scan-output.txt'
run_cmd 'find wp-content/uploads -type f -name "*.php" >> scan-output.txt'
run_cmd 'echo -e "\n=== SCAN: RECENTLY MODIFIED PHP FILES ===" >> scan-output.txt'
run_cmd 'find . -type f -name "*.php" -mtime -7 >> scan-output.txt'
run_cmd 'echo -e "\n=== SCAN: SUSPICIOUS FUNCTIONS ===" >> scan-output.txt'
run_cmd 'grep -RIn --color=never -E "base64_decode|eval\(|gzinflate|str_rot13|shell_exec|passthru|system\(" . >> scan-output.txt'
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
# 8️⃣ Install Wordfence
########################################
run_cmd 'cd /var/www/vhosts/localhost/html'
run_cmd 'wp plugin install wordfence --activate --allow-root'

########################################
# ✔ AIOM + AIOS3 (Optional)
########################################
run_cmd 'wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOM.zip --activate --allow-root'
run_cmd 'wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOS3.zip --activate --allow-root'

echo "==============================================="
echo "🏁 SCRIPT FINISHED"
echo "Dry Run Mode: $DRY_RUN"
echo "==============================================="
