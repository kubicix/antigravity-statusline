<#
.SYNOPSIS
    Remote One-Liner Installer for agy-statusline
.DESCRIPTION
    Downloads the latest release from GitHub, extracts it to a temporary
    directory, runs install.ps1, then cleans up.
    Usage:  irm https://raw.githubusercontent.com/kubicix/agy-statusline/main/install-remote.ps1 | iex
.AUTHOR
    Kubilay Birer (kubicix) — MIT License
#>

$ErrorActionPreference = "Stop"

# ─── Configuration ───────────────────────────────────────────────────────────
$REPO_OWNER = "kubicix"
$REPO_NAME  = "agy-statusline"
$BRANCH     = "main"
$ZIP_URL    = "https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/$BRANCH.zip"

# ─── Banner ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ========================================================' -ForegroundColor Cyan
Write-Host '    agy-statusline — Remote Installer' -ForegroundColor Cyan
Write-Host '    Quota Usage Bars for Gemini, Claude and GPT' -ForegroundColor Cyan
Write-Host '  ========================================================' -ForegroundColor Cyan
Write-Host ''

# ─── Step 1: Create temp directory ───────────────────────────────────────────
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "agy-statusline-install-$(Get-Random)"
$zipFile = Join-Path ([System.IO.Path]::GetTempPath()) "agy-statusline-$(Get-Random).zip"

Write-Host '  [1/4] Downloading from GitHub...' -ForegroundColor White
Write-Host "        $ZIP_URL" -ForegroundColor Gray

try {
    # Download the ZIP archive
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ZIP_URL -OutFile $zipFile -UseBasicParsing

    if (-not (Test-Path $zipFile)) {
        throw "Download failed — ZIP file not found."
    }

    $zipSize = (Get-Item $zipFile).Length
    $zipKB = [math]::Round($zipSize / 1024, 1)
    Write-Host "        Downloaded: ${zipKB} KB" -ForegroundColor Gray

} catch {
    Write-Host "  [ERROR] Failed to download repository:" -ForegroundColor Red
    Write-Host "          $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Alternatives:' -ForegroundColor White
    Write-Host "    git clone https://github.com/$REPO_OWNER/$REPO_NAME.git" -ForegroundColor Gray
    Write-Host "    cd $REPO_NAME" -ForegroundColor Gray
    Write-Host '    powershell -ExecutionPolicy Bypass -File .\install.ps1' -ForegroundColor Gray
    Write-Host ''
    exit 1
}

# ─── Step 2: Extract ZIP ────────────────────────────────────────────────────
Write-Host '  [2/4] Extracting archive...' -ForegroundColor White

try {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force

    # GitHub ZIPs extract into a subfolder named "repo-branch"
    $extractedDir = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
    if ($null -eq $extractedDir) {
        throw "Extraction failed — no directory found inside the archive."
    }

    $installDir = $extractedDir.FullName
    Write-Host "        Extracted to: $installDir" -ForegroundColor Gray

} catch {
    Write-Host "  [ERROR] Failed to extract archive:" -ForegroundColor Red
    Write-Host "          $($_.Exception.Message)" -ForegroundColor Yellow
    # Cleanup on failure
    Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# ─── Step 3: Run install.ps1 ────────────────────────────────────────────────
Write-Host '  [3/4] Running installer...' -ForegroundColor White
Write-Host ''

$installScript = Join-Path $installDir "install.ps1"

if (-not (Test-Path $installScript)) {
    Write-Host "  [ERROR] install.ps1 not found in the downloaded archive." -ForegroundColor Red
    Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

try {
    & powershell.exe -ExecutionPolicy Bypass -File $installScript
} catch {
    Write-Host "  [ERROR] Installer failed:" -ForegroundColor Red
    Write-Host "          $($_.Exception.Message)" -ForegroundColor Yellow
    Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# ─── Step 4: Cleanup ────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  [4/4] Cleaning up temp files...' -ForegroundColor White
Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host '        Done.' -ForegroundColor Gray

# ─── Final Message ──────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ========================================================' -ForegroundColor Green
Write-Host '    Installation complete!' -ForegroundColor Green
Write-Host '  ========================================================' -ForegroundColor Green
Write-Host ''
Write-Host '  Start a new agy session to see your quota bars:' -ForegroundColor White
Write-Host '    agy' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Source: https://github.com/$REPO_OWNER/$REPO_NAME" -ForegroundColor Gray
Write-Host ''
