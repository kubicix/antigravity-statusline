<#
.SYNOPSIS
    Uninstaller for Antigravity CLI Custom Statusline
.DESCRIPTION
    Restores the original settings.json from backup and removes installed scripts.
.AUTHOR
    Kubilay Birer (kubicix) — MIT License
#>

$ErrorActionPreference = "Stop"

# Paths
$TARGET_DIR = Join-Path $env:USERPROFILE ".gemini\antigravity-cli"
$SETTINGS_FILE = Join-Path $TARGET_DIR "settings.json"
$BACKUP_FILE = Join-Path $TARGET_DIR "settings.json.bak"

# Banner
Write-Host ''
Write-Host '  ========================================================' -ForegroundColor Cyan
Write-Host '    Antigravity CLI - Statusline Uninstaller' -ForegroundColor Cyan
Write-Host '  ========================================================' -ForegroundColor Cyan
Write-Host ''

# Step 1: Restore settings.json
if (Test-Path $BACKUP_FILE) {
    Write-Host '  [1/3] Restoring settings.json from backup...' -ForegroundColor White
    Copy-Item -Path $BACKUP_FILE -Destination $SETTINGS_FILE -Force
    Remove-Item $BACKUP_FILE -Force
    Write-Host '        Original settings restored' -ForegroundColor Gray
} else {
    Write-Host '  [1/3] No backup found - resetting statusLine config...' -ForegroundColor Yellow
    if (Test-Path $SETTINGS_FILE) {
        $settings = Get-Content -Path $SETTINGS_FILE -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties.Name -contains 'statusLine') {
            $settings.statusLine.type = ''
            $settings.statusLine.command = ''
            $settings.statusLine.enabled = $true
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($SETTINGS_FILE, ($settings | ConvertTo-Json -Depth 10), $utf8NoBom)
        Write-Host '        statusLine.type reset to empty' -ForegroundColor Gray
    }
}

# Step 2: Remove installed scripts
Write-Host '  [2/3] Removing installed scripts...' -ForegroundColor White
$filesToRemove = @('statusline.ps1', 'quota_refresh.ps1', 'quota_cache.json', 'quota_refresh.lock')
foreach ($file in $filesToRemove) {
    $filePath = Join-Path $TARGET_DIR $file
    if (Test-Path $filePath) {
        Remove-Item $filePath -Force
        Write-Host "        Removed: $file" -ForegroundColor Gray
    }
}

# Step 3: Verify
Write-Host '  [3/3] Verifying cleanup...' -ForegroundColor White
$remaining = $filesToRemove | Where-Object { Test-Path (Join-Path $TARGET_DIR $_) }
if ($remaining.Count -eq 0) {
    Write-Host '        All files cleaned up' -ForegroundColor Gray
} else {
    Write-Host "        Warning: Some files could not be removed: $($remaining -join ', ')" -ForegroundColor Yellow
}

# Done
Write-Host ''
Write-Host '  [OK] Uninstall complete!' -ForegroundColor Green
Write-Host '    Restart agy to apply changes.' -ForegroundColor Gray
Write-Host ''
