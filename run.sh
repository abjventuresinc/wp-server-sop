#!/bin/bash
set -e

cd /var/www/vhosts/localhost/html

########################################
# 1️⃣ Create New Admin & Delete Others
########################################
DOMAIN=$(wp option get siteurl --allow-root | sed 's#https\?://##' | sed 's#/.*##')
DOMAIN_NAME=$(echo $DOMAIN | cut -d'.' -f1)
PW="gar$(echo $DOMAIN_NAME | cut -c1 | tr '[:lower:]' '[:upper:]')$(echo $DOMAIN_NAME | rev | cut -c1 | tr '[:upper:]' '[:lower:]')3esrx9gc!"

NEW_ID=$(wp user create webadmin webadmin@$DOMAIN --role=administrator --user_pass="$PW" --allow-root --porcelain)
wp user delete $(wp user list --field=ID --allow-root | grep -v "^$NEW_ID$") --reassign=$NEW_ID --allow-root

########################################
# 2️⃣ Regenerate SALTs (force logout)
########################################
wp config shuffle-salts --allow-root

########################################
# 3️⃣ Fix File Permissions
########################################
find . -type f -exec chmod 644 {} \;
find . -type d -exec chmod 755 {} \;
chmod 600 wp-config.php

########################################
# 4️⃣ Block PHP Execution in Uploads
########################################
echo "" >> .htaccess
echo "# Block PHP execution in uploads (OpenLiteSpeed)" >> .htaccess
echo "RewriteEngine On" >> .htaccess
echo "RewriteRule ^wp-content/uploads/.*\.php$ - [F,L]" >> .htaccess

rm -rf wp-content/litespeed-cache/*

########################################
# 5️⃣ Malware Scan
########################################
echo "=== SCAN: PHP FILES IN UPLOADS ===" > scan-output.txt
find wp-content/uploads -type f -name "*.php" >> scan-output.txt

echo -e "\n=== SCAN: RECENTLY MODIFIED PHP FILES (7 DAYS) ===" >> scan-output.txt
find . -type f -name "*.php" -mtime -7 >> scan-output.txt

echo -e "\n=== SCAN: SUSPICIOUS FUNCTIONS ===" >> scan-output.txt
grep -RIn --color=never -E "base64_decode|eval\(|gzinflate|str_rot13|shell_exec|passthru|system\(" . >> scan-output.txt

echo -e "\n=== SCAN: 777 PERMISSION FILES ===" >> scan-output.txt
find . -type f -perm 0777 >> scan-output.txt

echo -e "\n=== SCAN COMPLETE ===" >> scan-output.txt

########################################
# 6️⃣ Backup wp-config.php
########################################
cp wp-config.php wp-config.php.backup.$(date +%Y%m%d-%H%M%S)

########################################
# 7️⃣ Reinstall MU Plugin
########################################
cd wp-content
cp -r mu-plugins mu-plugins.backup.$(date +%Y%m%d-%H%M%S)
rm -rf mu-plugins/*

wget -O mu-plugins/abj_datalayers.php https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/abj_datalayers.php

########################################
# 8️⃣ Install & Activate Wordfence
########################################
cd /var/www/vhosts/localhost/html
wp plugin install wordfence --activate --allow-root

########################################
# ✔ AIOM + AIOS3 (extra commands)
########################################
wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOM.zip --activate --allow-root
wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOS3.zip --activate --allow-root

echo "🎉 SOP Completed Successfully!"
