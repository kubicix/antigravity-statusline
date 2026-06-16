#!/usr/bin/env bash
# ==============================================================================
# Remote One-Liner Installer for agy-statusline (macOS/Linux)
# Downloads the latest release from GitHub, extracts it, runs install.sh.
# Usage: curl -sSL https://raw.githubusercontent.com/kubicix/agy-statusline/main/install-remote.sh | bash
# ==============================================================================

set -e

REPO_OWNER="kubicix"
REPO_NAME="agy-statusline"
BRANCH="main"
ZIP_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${BRANCH}.zip"

# Banner
echo ""
echo -e "\033[36m  ========================================================\033[0m"
echo -e "\033[36m    agy-statusline — Remote Installer (macOS/Linux)\033[0m"
echo -e "\033[36m    Quota Usage Bars for Gemini, Claude and GPT\033[0m"
echo -e "\033[36m  ========================================================\033[0m"
echo ""

# Create temp workspace
TEMP_DIR=$(mktemp -d -t agy-statusline-install-XXXXXX)
ZIP_FILE="${TEMP_DIR}/archive.zip"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Step 1: Download ZIP
echo -e "\033[37m  [1/4] Downloading from GitHub...\033[0m"
echo -e "\033[90m        ${ZIP_URL}\033[0m"

if command -v curl >/dev/null 2>&1; then
    curl -L -s -o "$ZIP_FILE" "$ZIP_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$ZIP_FILE" "$ZIP_URL"
else
    echo -e "\033[31m  [ERROR] Neither curl nor wget is installed.\033[0m"
    echo -e "\033[33m  Alternatives:\033[0m"
    echo -e "\033[90m    git clone https://github.com/${REPO_OWNER}/${REPO_NAME}.git\033[0m"
    echo -e "\033[90m    cd ${REPO_NAME}\033[0m"
    echo -e "\033[90m    ./install.sh\033[0m"
    exit 1
fi

if [ ! -f "$ZIP_FILE" ]; then
    echo -e "\033[31m  [ERROR] Download failed — ZIP file not found.\033[0m"
    exit 1
fi

# Step 2: Extract ZIP
echo -e "\033[37m  [2/4] Extracting archive...\033[0m"
if command -v unzip >/dev/null 2>&1; then
    unzip -q -d "$TEMP_DIR" "$ZIP_FILE"
else
    echo -e "\033[31m  [ERROR] unzip is required to extract the installer.\033[0m"
    exit 1
fi

# Find the extracted folder
EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "agy-statusline-*" | head -n 1)
if [ -z "$EXTRACTED_DIR" ]; then
    echo -e "\033[31m  [ERROR] Extraction folder not found.\033[0m"
    exit 1
fi

# Step 3: Run installer
echo -e "\033[37m  [3/4] Running installer...\033[0m"
echo ""

INSTALL_SCRIPT="${EXTRACTED_DIR}/install.sh"
if [ ! -f "$INSTALL_SCRIPT" ]; then
    echo -e "\033[31m  [ERROR] install.sh not found in extracted archive.\033[0m"
    exit 1
fi

chmod +x "$INSTALL_SCRIPT"
# Run with bash, passing down the target dir context
/bin/bash "$INSTALL_SCRIPT"

# Step 4: Cleanup
echo ""
echo -e "\033[37m  [4/4] Cleaning up temp files...\033[0m"
# Done by trap on exit

echo ""
echo -e "\033[32m  ========================================================\033[0m"
echo -e "\033[32m    Installation complete!\033[0m"
echo -e "\033[32m  ========================================================\033[0m"
echo ""
echo -e "\033[37m  Start a new agy session to see your quota bars:\033[0m"
echo -e "\033[36m    agy\033[0m"
echo ""
echo -e "\033[90m  Source: https://github.com/${REPO_OWNER}/${REPO_NAME}\033[0m"
echo ""
