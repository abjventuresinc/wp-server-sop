#!/bin/bash
set -o pipefail

DRY_RUN=false
LOG_FILE="sop-log-$(date +%Y%m%d-%H%M%S).txt"
WP_ROOT="/var/www/vhosts/localhost/html"

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

# Function: run command + log output (from WP_ROOT directory)
run_cmd() {
    log "------------------------------------------------------------"
    log "➡️ Command: $1"
    log "------------------------------------------------------------"

    if [ "$DRY_RUN" = true ]; then
        log "🟡 DRY RUN: Command NOT executed."
        return 0
    fi

    OUTPUT=$(cd "$WP_ROOT" && eval "$1" 2>&1)
    STATUS=$?

    echo "$OUTPUT" | tee -a "$LOG_FILE"

    if [ $STATUS -ne 0 ]; then
        log "❌ ERROR running: $1"
        return $STATUS
    else
        log "✅ SUCCESS"
        return 0
    fi
}

# Check prerequisites
check_prerequisites() {
    log "🔍 Checking prerequisites..."
    
    if ! command -v wp &> /dev/null; then
        log "❌ ERROR: wp-cli is not installed or not in PATH"
        exit 1
    fi
    
    if [ ! -d "$WP_ROOT" ]; then
        log "❌ ERROR: WordPress root directory does not exist: $WP_ROOT"
        exit 1
    fi
    
    if [ ! -f "$WP_ROOT/wp-config.php" ]; then
        log "❌ ERROR: wp-config.php not found in $WP_ROOT"
        exit 1
    fi

    if ! command -v wget &> /dev/null && [ "$DRY_RUN" = false ]; then
        log "⚠️ WARNING: wget is not installed. MU plugin download may fail."
    fi
    
    log "✅ Prerequisites check passed"
}

log "==============================================="
log "🚀 BEGIN WORDPRESS SOP SCRIPT"
log "Dry Run Mode: $DRY_RUN"
log "Log File: $LOG_FILE"
log "WordPress Root: $WP_ROOT"
log "==============================================="

# Check prerequisites
check_prerequisites

########################################
# 1️⃣ Change to WP root (in main shell)
########################################
if [ "$DRY_RUN" = false ]; then
    cd "$WP_ROOT" || {
        log "❌ ERROR: Cannot change to $WP_ROOT"
        exit 1
    }
    log "✅ Changed to WordPress root: $WP_ROOT"
else
    log "🟡 DRY RUN: Would change to $WP_ROOT"
fi

########################################
# 1.1 Compute DOMAIN / PW in main shell
########################################
if [ "$DRY_RUN" = false ]; then
    log "➡️ Computing DOMAIN, DOMAIN_NAME and PW"

    DOMAIN=$(cd "$WP_ROOT" && wp option get siteurl --allow-root 2>/dev/null | sed 's#https\?://##' | sed 's#/.*##')

    if [ -z "$DOMAIN" ]; then
        log "❌ ERROR: Could not retrieve site URL."
        exit 1
    fi

    DOMAIN_NAME=$(echo "$DOMAIN" | cut -d'.' -f1)
    PW="gar$(echo "$DOMAIN_NAME" | cut -c1 | tr '[:lower:]' '[:upper:]')$(echo "$DOMAIN_NAME" | rev | cut -c1 | tr '[:upper:]' '[:lower:]')3esrx9gc!"

    log "DOMAIN=$DOMAIN"
    log "DOMAIN_NAME=$DOMAIN_NAME"
else
    log "🟡 DRY RUN: Would compute DOMAIN, DOMAIN_NAME, PW"
    DOMAIN="example.com"
    DOMAIN_NAME="example"
    PW="[computed]"
fi

########################################
# 1.2 Create / reuse webadmin & delete others
########################################
run_cmd 'wp user get webadmin --field=ID --allow-root'

NEW_ID=""

if [ "$DRY_RUN" = false ]; then

    USER_EXISTS=$(cd "$WP_ROOT" && wp user get webadmin --field=ID --allow-root 2>/dev/null || echo "")

    if [ -z "$USER_EXISTS" ]; then
        log "🔧 Creating webadmin user..."
        CREATE_OUTPUT=$(cd "$WP_ROOT" && wp user create webadmin "webadmin@$DOMAIN" --role=administrator --user_pass="$PW" --allow-root 2>&1)
        CREATE_STATUS=$?

        echo "$CREATE_OUTPUT" | tee -a "$LOG_FILE"

        if [ $CREATE_STATUS -ne 0 ]; then
            log "❌ Failed to create webadmin. Continuing without user deletion."
        else
            # Extract numeric ID from "Success: Created user X." output
            NEW_ID=$(echo "$CREATE_OUTPUT" | grep -oE 'Created user [0-9]+' | grep -oE '[0-9]+' || echo "$CREATE_OUTPUT" | grep -oE '[0-9]+' | head -1)
            if [ -z "$NEW_ID" ]; then
                # Fallback: try to get ID by querying the user we just created
                NEW_ID=$(cd "$WP_ROOT" && wp user get webadmin --field=ID --allow-root 2>/dev/null || echo "")
            fi
            if [ -n "$NEW_ID" ]; then
                log "✅ Created webadmin with ID $NEW_ID"
            else
                log "⚠️ Created webadmin but could not extract ID. User deletion will be skipped."
            fi
        fi
    else
        log "ℹ️ webadmin already exists — ID: $USER_EXISTS"
        NEW_ID=$USER_EXISTS
    fi

    ########################################
    # DELETE ALL OTHER USERS SAFELY + CORRECTLY (FIXED)
    ########################################
    if [[ -n "$NEW_ID" ]]; then
        log "🧹 Deleting all other users and reassigning content to webadmin (#$NEW_ID)..."

        OTHER_IDS=$(cd "$WP_ROOT" && wp user list --field=ID --allow-root | grep -v "^$NEW_ID$" || true)

        if [ -n "$OTHER_IDS" ]; then
            for USER_ID in $OTHER_IDS; do
                run_cmd "wp user delete $USER_ID --reassign=$NEW_ID --allow-root"
            done
        else
            log "ℹ️ No other users to delete"
        fi
    else
        log "⚠️ NEW_ID empty. Skipping user deletion."
    fi

else
    log "🟡 DRY RUN: Would create webadmin and delete all other users."
fi

########################################
# 2️⃣ Regenerate SALTs
########################################
run_cmd 'wp config shuffle-salts --allow-root'

########################################
# 3️⃣ Fix File Permissions
########################################
run_cmd "find $WP_ROOT -type f -exec chmod 644 {} \;"
run_cmd "find $WP_ROOT -type d -exec chmod 755 {} \;"
run_cmd "chmod 600 $WP_ROOT/wp-config.php"

########################################
# 4️⃣ Block PHP Execution in Uploads
########################################
HTACCESS_FILE="$WP_ROOT/.htaccess"
HTACCESS_RULE="# Block PHP execution in uploads (OLS)"

if [ "$DRY_RUN" = false ]; then
    if [ -f "$HTACCESS_FILE" ] && grep -q "$HTACCESS_RULE" "$HTACCESS_FILE"; then
        log "ℹ️ PHP execution block already exists"
    else
        log "📝 Adding PHP execution block to .htaccess"
        {
            echo ""
            echo "$HTACCESS_RULE"
            echo "RewriteEngine On"
            echo "RewriteRule ^wp-content/uploads/.*\.php$ - [F,L]"
        } >> "$HTACCESS_FILE"
        log "✅ Added PHP execution block"
    fi
else
    log "🟡 DRY RUN: Would add .htaccess rules"
fi

run_cmd "rm -rf $WP_ROOT/wp-content/litespeed-cache/*"

########################################
# 5️⃣ Malware Scan
########################################
SCAN_FILE="$WP_ROOT/scan-output.txt"

run_cmd "echo '=== SCAN: PHP FILES IN UPLOADS ===' > $SCAN_FILE"
run_cmd "find $WP_ROOT/wp-content/uploads -type f -name '*.php' >> $SCAN_FILE 2>/dev/null || true"
run_cmd "echo -e '\n=== SCAN: MODIFIED IN LAST 7 DAYS ===' >> $SCAN_FILE"
run_cmd "find $WP_ROOT -type f -name '*.php' -mtime -7 >> $SCAN_FILE 2>/dev/null || true"
run_cmd "echo -e '\n=== SCAN: SUSPICIOUS FUNCTIONS ===' >> $SCAN_FILE"
run_cmd "grep -RIn -E 'base64_decode|eval\(|gzinflate|str_rot13|shell_exec|passthru|system\(' $WP_ROOT --exclude-dir=node_modules --exclude-dir=.git --exclude='scan-output.txt' 2>/dev/null | head -1000 >> $SCAN_FILE || true"
run_cmd "echo -e '\n=== SCAN: 777 PERMISSIONS ===' >> $SCAN_FILE"
run_cmd "find $WP_ROOT -type f -perm 0777 >> $SCAN_FILE 2>/dev/null || true"
log "✅ Malware scan saved to $SCAN_FILE"

########################################
# 6️⃣ Backup wp-config.php
########################################
run_cmd "cp $WP_ROOT/wp-config.php $WP_ROOT/wp-config.php.backup.\$(date +%Y%m%d-%H%M%S)"

########################################
# 7️⃣ MU Plugin Setup (mkdir FIXED)
########################################
MU_PLUGINS_DIR="$WP_ROOT/wp-content/mu-plugins"
MU_PLUGIN_FILE="$MU_PLUGINS_DIR/abj_datalayers.php"

if [ "$DRY_RUN" = false ]; then
    mkdir -p "$MU_PLUGINS_DIR"
    log "📁 MU Plugins directory ensured"

    BACKUP_DIR="${MU_PLUGINS_DIR}.backup.$(date +%Y%m%d-%H%M%S)"

    if [ -d "$MU_PLUGINS_DIR" ] && [ "$(ls -A "$MU_PLUGINS_DIR" 2>/dev/null)" ]; then
        cp -r "$MU_PLUGINS_DIR" "$BACKUP_DIR"
        log "📦 Backed up MU plugins to $BACKUP_DIR"
    else
        log "ℹ️ No existing mu-plugins to back up"
    fi

    rm -rf "$MU_PLUGINS_DIR"/* 2>/dev/null || true
    
    log "⬇️ Downloading abj_datalayers.php..."
    if wget -O "$MU_PLUGIN_FILE" "https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/abj_datalayers.php" 2>&1 | tee -a "$LOG_FILE"; then
        log "✅ Successfully downloaded abj_datalayers.php"
    else
        log "❌ Failed to download abj_datalayers.php"
    fi
else
    log "🟡 DRY RUN: Would install MU plugin"
fi


########################################
# 8️⃣ Install + ACTIVATE Wordfence
########################################
if [ "$DRY_RUN" = false ]; then
    if cd "$WP_ROOT" && wp plugin is-installed wordfence --allow-root 2>/dev/null; then
        log "ℹ️ Wordfence already installed, activating..."
        run_cmd 'wp plugin activate wordfence --allow-root'
    else
        run_cmd 'wp plugin install wordfence --allow-root'
        run_cmd 'wp plugin activate wordfence --allow-root'
    fi
else
    run_cmd 'wp plugin install wordfence --allow-root'
    run_cmd 'wp plugin activate wordfence --allow-root'
fi

########################################
# 9️⃣ Install + Activate AIOM + AIOS3
########################################
if [ "$DRY_RUN" = false ]; then
    # Check and install/activate AIOM
    if cd "$WP_ROOT" && wp plugin is-installed all-in-one-wp-migration --allow-root 2>/dev/null; then
        log "ℹ️ AIOM already installed, activating..."
        run_cmd 'wp plugin activate all-in-one-wp-migration --allow-root'
    else
        run_cmd 'wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOM.zip --force --allow-root'
        run_cmd 'wp plugin activate all-in-one-wp-migration --allow-root'
    fi
    
    # Check and install/activate AIOS3
    if cd "$WP_ROOT" && wp plugin is-installed all-in-one-wp-migration-s3-extension --allow-root 2>/dev/null; then
        log "ℹ️ AIOS3 already installed, activating..."
        run_cmd 'wp plugin activate all-in-one-wp-migration-s3-extension --allow-root'
    else
        run_cmd 'wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOS3.zip --force --allow-root'
        run_cmd 'wp plugin activate all-in-one-wp-migration-s3-extension --allow-root'
    fi
else
    run_cmd 'wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOM.zip --allow-root'
    run_cmd 'wp plugin activate aiom --allow-root'
    run_cmd 'wp plugin install https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/AIOS3.zip --allow-root'
    run_cmd 'wp plugin activate aios3 --allow-root'
fi

log "==============================================="
log "🏁 SCRIPT FINISHED — Full log saved to $LOG_FILE"
log "Dry Run Mode: $DRY_RUN"
log "==============================================="
