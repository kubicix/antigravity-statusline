#!/usr/bin/env bash
# ==============================================================================
# Installer Script for macOS and Linux — Antigravity CLI Quota Statusline
# ==============================================================================

set -e

# Configuration
INSTALL_DIR="${HOME}/.gemini/antigravity-cli"
SETTINGS_FILE="${INSTALL_DIR}/settings.json"
BACKUP_FILE="${SETTINGS_FILE}.bak"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_STATUSLINE="${SCRIPT_DIR}/statusline.sh"
SRC_REFRESH="${SCRIPT_DIR}/quota_refresh.sh"

echo "=== Installing Antigravity CLI Quota Statusline ==="

# 1. Verification
if [ ! -f "$SRC_STATUSLINE" ] || [ ! -f "$SRC_REFRESH" ]; then
    echo "Error: Source scripts not found in current directory (${SCRIPT_DIR})."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Warning: cURL is not installed. Background refresh might fail."
fi

# 2. Create Target Directory
mkdir -p "$INSTALL_DIR"

# 3. Backup Settings File
if [ -f "$SETTINGS_FILE" ]; then
    echo "Backing up existing settings.json to $(basename "$BACKUP_FILE")..."
    cp "$SETTINGS_FILE" "$BACKUP_FILE"
fi

# 4. Copy Scripts & Set Permissions
echo "Copying scripts to ${INSTALL_DIR}..."
cp "$SRC_STATUSLINE" "${INSTALL_DIR}/statusline.sh"
cp "$SRC_REFRESH" "${INSTALL_DIR}/quota_refresh.sh"
chmod +x "${INSTALL_DIR}/statusline.sh"
chmod +x "${INSTALL_DIR}/quota_refresh.sh"

# 5. Write Initial Cache
echo "Seeding initial quota cache..."
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat <<EOF > "${INSTALL_DIR}/quota_cache.json"
{
  "timestamp": "$now",
  "error": null,
  "stale": false,
  "account": "unknown",
  "plan": "unknown",
  "gemini": {
    "remaining_pct": 100.0,
    "refresh_in": "Full"
  },
  "claude_gpt": {
    "remaining_pct": 100.0,
    "refresh_in": "Full"
  }
}
EOF

# 6. Update settings.json
echo "Configuring settings.json..."
TARGET_CMD="/bin/bash ${INSTALL_DIR}/statusline.sh"

if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, os, sys
path = sys.argv[1]
cmd = sys.argv[2]
data = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        pass
data["statusLine"] = {
    "type": "command",
    "command": cmd,
    "enabled": True
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
' "$SETTINGS_FILE" "$TARGET_CMD"
elif command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const path = process.argv[1];
const cmd = process.argv[2];
let data = {};
if (fs.existsSync(path)) {
    try { data = JSON.parse(fs.readFileSync(path, "utf8")); } catch(e) {}
}
data.statusLine = { type: "command", command: cmd, enabled: true };
fs.writeFileSync(path, JSON.stringify(data, null, 2), "utf8");
' "$SETTINGS_FILE" "$TARGET_CMD"
else
    # Minimal sed fallback if no interpreters
    if [ ! -f "$SETTINGS_FILE" ] || [ ! -s "$SETTINGS_FILE" ]; then
        echo -e '{\n  "statusLine": {\n    "type": "command",\n    "command": "'"${TARGET_CMD}"'",\n    "enabled": true\n  }\n}' > "$SETTINGS_FILE"
    else
        echo "Warning: Python3 or Node.js not found. Cannot automatically parse JSON."
        echo "Please manually add the following block to ${SETTINGS_FILE}:"
        echo '  "statusLine": {'
        echo '    "type": "command",'
        echo '    "command": "'"${TARGET_CMD}"'",'
        echo '    "enabled": true'
        echo '  }'
    fi
fi

echo "=== Installation Completed ==="
echo "Restart your Antigravity CLI session by running: agy"
