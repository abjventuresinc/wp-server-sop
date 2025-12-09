#!/bin/bash

# =============================================================
#  ABJ Ventures - Plugin Auto Update Script
#  Checks if plugin exists → downloads ZIP → reinstalls → activates
#  Provides detailed logging with timestamps.
# =============================================================

log() {
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] $1"
}

log "===== STARTING WORDPRESS PLUGIN UPDATE SOP ====="

# ----------------------------------------
# DEFINE PLUGINS
# Format: "slug|download_url"
# ----------------------------------------
PLUGINS=(
    "elementor-pro|https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/elementor-pro.zip"
    "woocommerce-product-feeds|https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/woocommerce-product-feeds.zip"
    "woocommerce-zapier|https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/woocommerce-zapier.zip"
)

# ----------------------------------------
# Check wp-cli availability
# ----------------------------------------
log "Checking wp-cli availability..."
wp plugin list --allow-root >/dev/null 2>&1

if [[ $? -ne 0 ]]; then
    log "❌ ERROR: wp-cli not found or not accessible."
    exit 1
fi

log "wp-cli detected. Proceeding..."

# ----------------------------------------
# PROCESS EACH PLUGIN
# ----------------------------------------
for ENTRY in "${PLUGINS[@]}"; do
    SLUG="${ENTRY%%|*}"
    URL="${ENTRY##*|}"
    ZIP_FILE="/tmp/${SLUG}.zip"

    log "----------------------------------------"
    log "Processing plugin: $SLUG"
    log "Download URL: $URL"

    # Check if plugin exists
    if wp plugin list --allow-root | grep -q "^${SLUG}\s"; then
        log "🔍 Plugin '$SLUG' found — will reinstall to ensure correct version."
    else
        log "⚠️ Plugin '$SLUG' NOT found — will install it."
    fi

    # Download ZIP
    log "⬇️ Downloading plugin package..."
    curl -L -s -o "$ZIP_FILE" "$URL"

    if [[ ! -f "$ZIP_FILE" ]]; then
        log "❌ ERROR: Failed to download ZIP file for $SLUG. Skipping..."
        continue
    fi

    log "📦 Download complete. File saved as: $ZIP_FILE"
    log "File size: $(stat -c%s "$ZIP_FILE") bytes"

    # Install / Reinstall plugin
    log "Installing plugin '$SLUG' via wp-cli..."
    wp plugin install "$ZIP_FILE" --force --activate --allow-root

    if [[ $? -eq 0 ]]; then
        log "✅ Plugin '$SLUG' installed/updated and activated successfully."
    else
        log "❌ ERROR: Failed to install or activate plugin '$SLUG'."
        continue
    fi
done

log "===== ALL PLUGINS PROCESSED SUCCESSFULLY ====="
