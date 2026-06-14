<#
.SYNOPSIS
    Installer for Antigravity CLI Custom Statusline
.DESCRIPTION
    Copies statusline scripts to the antigravity-cli config directory
    and updates settings.json to enable the custom statusline.
.AUTHOR
    Kubilay Birer (kubicix) — MIT License
#>

$ErrorActionPreference = "Stop"

# Paths
$SOURCE_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$TARGET_DIR = Join-Path $env:USERPROFILE ".gemini\antigravity-cli"
$SETTINGS_FILE = Join-Path $TARGET_DIR "settings.json"
$BACKUP_FILE = Join-Path $TARGET_DIR "settings.json.bak"

# Banner
Write-Host ''
Write-Host '  ========================================================' -ForegroundColor Cyan
Write-Host '    Antigravity CLI - Custom Statusline Installer' -ForegroundColor Cyan
Write-Host '    Quota Usage Bars for Gemini, Claude and GPT' -ForegroundColor Cyan
Write-Host '  ========================================================' -ForegroundColor Cyan
Write-Host ''

# Verify target directory exists
if (-not (Test-Path $TARGET_DIR)) {
    Write-Host '  [ERROR] Antigravity CLI config directory not found:' -ForegroundColor Red
    Write-Host "          $TARGET_DIR" -ForegroundColor Yellow
    Write-Host '          Is agy installed? Run agy --version to check.' -ForegroundColor Gray
    exit 1
}

# Verify source files exist
$requiredFiles = @('statusline.ps1', 'quota_refresh.ps1')
foreach ($file in $requiredFiles) {
    $srcPath = Join-Path $SOURCE_DIR $file
    if (-not (Test-Path $srcPath)) {
        Write-Host "  [ERROR] Missing source file: $file" -ForegroundColor Red
        exit 1
    }
}

# Step 1: Backup settings.json
if (Test-Path $SETTINGS_FILE) {
    Write-Host '  [1/4] Backing up settings.json...' -ForegroundColor White
    Copy-Item -Path $SETTINGS_FILE -Destination $BACKUP_FILE -Force
    Write-Host '        Backup saved to: settings.json.bak' -ForegroundColor Gray
} else {
    Write-Host '  [1/4] No existing settings.json - will create new one' -ForegroundColor Yellow
}

# Step 2: Copy scripts
Write-Host '  [2/4] Copying scripts to antigravity-cli directory...' -ForegroundColor White
foreach ($file in $requiredFiles) {
    $srcPath = Join-Path $SOURCE_DIR $file
    $dstPath = Join-Path $TARGET_DIR $file
    Copy-Item -Path $srcPath -Destination $dstPath -Force
    Write-Host "        Copied: $file" -ForegroundColor Gray
}

# Step 3: Update settings.json
Write-Host '  [3/4] Updating settings.json...' -ForegroundColor White

# Build the command path with forward slashes (agy is Go binary, prefers forward slashes)
$scriptPath = (Join-Path $TARGET_DIR 'statusline.ps1').Replace('\', '/')
$command = 'powershell.exe -ExecutionPolicy Bypass -File ' + $scriptPath

if (Test-Path $SETTINGS_FILE) {
    # Read and update existing settings
    $settings = Get-Content -Path $SETTINGS_FILE -Raw | ConvertFrom-Json

    # Update or create statusLine section
    if ($settings.PSObject.Properties.Name -contains 'statusLine') {
        $settings.statusLine.type = 'command'
        $settings.statusLine.command = $command
        $settings.statusLine.enabled = $true
    } else {
        $settings | Add-Member -NotePropertyName 'statusLine' -NotePropertyValue @{
            type = 'command'
            command = $command
            enabled = $true
        } -Force
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($SETTINGS_FILE, ($settings | ConvertTo-Json -Depth 10), $utf8NoBom)
} else {
    # Create minimal settings file
    $newSettings = @{
        statusLine = @{
            type = 'command'
            command = $command
            enabled = $true
        }
    } | ConvertTo-Json -Depth 10

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($SETTINGS_FILE, $newSettings, $utf8NoBom)
}

Write-Host '        statusLine.type = "command"' -ForegroundColor Gray
Write-Host '        statusLine.enabled = true' -ForegroundColor Gray

# Step 4: Create initial empty cache
Write-Host '  [4/4] Creating initial quota cache...' -ForegroundColor White

# Error set so the statusline shows a loading line until the first real refresh.
$initialCache = @{
    timestamp = (Get-Date -Format 'o')
    error = 'Initializing - waiting for first quota refresh'
} | ConvertTo-Json -Depth 5

$cacheFile = Join-Path $TARGET_DIR 'quota_cache.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($cacheFile, $initialCache, $utf8NoBom)
Write-Host '        Cache initialized' -ForegroundColor Gray

# Done
Write-Host ''
Write-Host '  [OK] Installation complete!' -ForegroundColor Green
Write-Host ''
Write-Host '  Next steps:' -ForegroundColor White
Write-Host '    1. Open a new agy session:  agy' -ForegroundColor Gray
Write-Host '    2. The quota bars will appear below the input box' -ForegroundColor Gray
Write-Host '    3. Data refreshes automatically every 60 seconds' -ForegroundColor Gray
Write-Host ''
Write-Host '  To uninstall, run:  .\uninstall.ps1' -ForegroundColor Yellow
Write-Host ''
