#!/usr/bin/env bash
# ==============================================================================
# Uninstaller Script for macOS and Linux — Antigravity CLI Quota Statusline
# ==============================================================================

set -e

# Configuration
INSTALL_DIR="${HOME}/.gemini/antigravity-cli"
SETTINGS_FILE="${INSTALL_DIR}/settings.json"
BACKUP_FILE="${SETTINGS_FILE}.bak"

echo "=== Uninstalling Antigravity CLI Quota Statusline ==="

# 1. Restore settings.json
if [ -f "$BACKUP_FILE" ]; then
    echo "Restoring settings.json from backup..."
    mv "$BACKUP_FILE" "$SETTINGS_FILE"
elif [ -f "$SETTINGS_FILE" ]; then
    echo "Removing statusLine entry from settings.json..."
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, os, sys
path = sys.argv[1]
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if "statusLine" in data:
            del data["statusLine"]
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        print(f"Warning: Could not parse JSON: {e}")
' "$SETTINGS_FILE"
    elif command -v node >/dev/null 2>&1; then
        node -e '
const fs = require("fs");
const path = process.argv[1];
if (fs.existsSync(path)) {
    try {
        let data = JSON.parse(fs.readFileSync(path, "utf8"));
        delete data.statusLine;
        fs.writeFileSync(path, JSON.stringify(data, null, 2), "utf8");
    } catch(e) {}
}
' "$SETTINGS_FILE"
    else
        echo "Could not parse JSON. Please manually remove the 'statusLine' entry from ${SETTINGS_FILE}."
    fi
fi

# 2. Delete Installed Files
echo "Cleaning up files from ${INSTALL_DIR}..."
rm -f "${INSTALL_DIR}/statusline.sh"
rm -f "${INSTALL_DIR}/quota_refresh.sh"
rm -f "${INSTALL_DIR}/quota_cache.json"
rm -f "${INSTALL_DIR}/quota_refresh.lock"

# Remove directory if empty
if [ -d "$INSTALL_DIR" ] && [ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    rmdir "$INSTALL_DIR"
fi

echo "=== Uninstallation Completed ==="
echo "Restart your Antigravity CLI session to apply."
