#!/bin/bash

# Navigate to WordPress root if needed
# cd /var/www/vhosts/localhost/html

echo "Checking Elementor installation status..."

# Run plugin list with --allow-root and capture output
PLUGIN_STATUS=$(wp plugin list --allow-root 2>/dev/null)

if [[ $? -ne 0 ]]; then
    echo "Error: Could not run wp-cli. Make sure wp-cli is installed and accessible."
    exit 1
fi

# Check Elementor
if echo "$PLUGIN_STATUS" | grep -q "^elementor\s"; then
    echo "✅ Elementor is installed."
else
    echo "❌ Elementor is NOT installed."
fi

# Check Elementor Pro
if echo "$PLUGIN_STATUS" | grep -q "^elementor-pro\s"; then
    echo "✅ Elementor Pro is installed."
else
    echo "❌ Elementor Pro is NOT installed."
fi

echo "Done."
