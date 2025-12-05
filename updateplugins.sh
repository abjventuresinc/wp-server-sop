#!/bin/bash

# --- CONFIG ---
PLUGIN_URL="https://raw.githubusercontent.com/abjventuresinc/custom-datalayer-mu-plugin/main/elementor-pro.zip"
ZIP_FILE="/tmp/elementor-pro.zip"

echo "Checking Elementor installation status..."

# Capture plugin list
PLUGIN_STATUS=$(wp plugin list --allow-root 2>/dev/null)

if [[ $? -ne 0 ]]; then
    echo "❌ Error: wp-cli not found or not accessible."
    exit 1
fi

# Check Elementor free
if echo "$PLUGIN_STATUS" | grep -q "^elementor\s"; then
    echo "✅ Elementor (free) is installed."
else
    echo "❌ Elementor (free) is NOT installed."
fi

# Check Elementor Pro
if echo "$PLUGIN_STATUS" | grep -q "^elementor-pro\s"; then
    echo "🔍 Elementor Pro detected — we will reinstall to ensure correct version."
else
    echo "⚠️ Elementor Pro not found — we will install it."
fi

echo "⬇️ Downloading Elementor Pro from GitHub..."
curl -L -s -o "$ZIP_FILE" "$PLUGIN_URL"

if [[ ! -f "$ZIP_FILE" ]]; then
    echo "❌ Failed to download Elementor Pro zip file."
    exit 1
fi

echo "📦 Installing Elementor Pro..."
wp plugin install "$ZIP_FILE" --force --activate --allow-root

if [[ $? -eq 0 ]]; then
    echo "✅ Elementor Pro installed and activated successfully."
else
    echo "❌ Failed to install Elementor Pro."
    exit 1
fi

echo "All done."
