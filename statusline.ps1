<#
.SYNOPSIS
    Antigravity CLI Custom Statusline — Quota Usage Bars
.DESCRIPTION
    Renders compact ANSI progress bars showing model quota usage.
    Called by agy CLI on every state change (JSON piped to stdin).
    Reads cached quota data from quota_cache.json.
.AUTHOR
    Kubilay Birer (kubicix) — MIT License
#>

# ─── Force UTF-8 output (fixes garbled Unicode in IDE terminals) ─────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ─── Configuration ───────────────────────────────────────────────────────────
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$CACHE_FILE = Join-Path $SCRIPT_DIR "quota_cache.json"
$REFRESH_SCRIPT = Join-Path $SCRIPT_DIR "quota_refresh.ps1"
$CACHE_MAX_AGE_SECONDS = 60
$BAR_WIDTH = 16

# ─── ANSI Escape Codes ──────────────────────────────────────────────────────
$ESC = [char]27
$RESET   = "${ESC}[0m"
$BOLD    = "${ESC}[1m"
$DIM     = "${ESC}[2m"
$GREEN   = "${ESC}[32m"
$YELLOW  = "${ESC}[33m"
$RED     = "${ESC}[31m"
$CYAN    = "${ESC}[36m"
$GRAY    = "${ESC}[90m"
$WHITE   = "${ESC}[37m"
$BG_GRAY = "${ESC}[48;5;236m"

# ─── Read stdin (agy pipes JSON session state) ──────────────────────────────
try {
    $stdinData = [System.Console]::In.ReadToEnd()
} catch {
    $stdinData = ""
}

# ─── Helper: Color by remaining percentage ──────────────────────────────────
function Get-QuotaColor {
    param([double]$Pct)
    if ($Pct -ge 70) { return $GREEN }   # 70-100 green
    if ($Pct -ge 30) { return $YELLOW }  # 30-70  yellow
    return $RED                          # 0-30   red
}

# ─── Helper: Render a single progress bar ────────────────────────────────────
function Format-ProgressBar {
    param(
        [string]$Label,
        [double]$Pct,
        [string]$RefreshInfo,
        [string]$Icon = [char]0x25C6  # ◆
    )
    
    $color = Get-QuotaColor -Pct $Pct
    $filledCount = [math]::Floor(($Pct / 100.0) * $BAR_WIDTH)
    $emptyCount  = $BAR_WIDTH - $filledCount
    
    # Build bar characters
    $filledChar = [char]0x2588  # █
    $emptyChar  = [char]0x2591  # ░
    
    $filledStr = ([string]$filledChar) * $filledCount
    $emptyStr  = ([string]$emptyChar) * $emptyCount
    
    # Format percentage with consistent width (invariant culture -> dot decimal)
    $pctStr = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0,6:F1}%", $Pct)
    
    # Pad label to consistent width
    $paddedLabel = $Label.PadRight(16)
    
    # Compose the line
    $line = "${DIM}${color}${Icon}${RESET} ${WHITE}${paddedLabel}${RESET} ${GRAY}[${RESET}${color}${filledStr}${GRAY}${emptyStr}${RESET}${GRAY}]${RESET} ${BOLD}${color}${pctStr}${RESET}  ${DIM}${CYAN}${RefreshInfo}${RESET}"
    
    return $line
}

# ─── Helper: Trigger background refresh if cache is stale ────────────────────
function Start-QuotaRefreshIfNeeded {
    $needsRefresh = $false
    
    if (-not (Test-Path $CACHE_FILE)) {
        $needsRefresh = $true
    } else {
        $cacheAge = (Get-Date) - (Get-Item $CACHE_FILE).LastWriteTime
        if ($cacheAge.TotalSeconds -gt $CACHE_MAX_AGE_SECONDS) {
            $needsRefresh = $true
        }
    }
    
    if ($needsRefresh -and (Test-Path $REFRESH_SCRIPT)) {
        # Launch refresh in background — don't block the TUI
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $REFRESH_SCRIPT `
            -WindowStyle Hidden -PassThru | Out-Null
    }
}

# ─── Main: Read cache and render ────────────────────────────────────────────

# Trigger refresh if needed
Start-QuotaRefreshIfNeeded

# Read cached quota data
$quotaData = $null
if (Test-Path $CACHE_FILE) {
    try {
        $raw = Get-Content -Path $CACHE_FILE -Raw -ErrorAction Stop
        $quotaData = $raw | ConvertFrom-Json
    } catch {
        $quotaData = $null
    }
}

# ─── Render Output ──────────────────────────────────────────────────────────

$separator = "${GRAY}$([string]([char]0x2500) * 52)${RESET}"
$lines = @()

if ($null -eq $quotaData -or $null -ne $quotaData.error) {
    # No data yet or error — show loading state
    $loadingIcon = [char]0x25CB  # ○
    $lines += "${DIM}${GRAY}${loadingIcon} Quota data loading... (run /usage to check manually)${RESET}"
} else {
    # The local GetUserStatus API exposes one effective remaining % + reset per
    # model (it does NOT split weekly vs 5-hour like the /usage TUI does). The two
    # bars match the official /usage groups: Gemini, and Claude/GPT.
    $rows = @(
        @{ label = "Gemini";     data = $quotaData.gemini },
        @{ label = "Claude/GPT"; data = $quotaData.claude_gpt }
    )
    # Last-good data kept after a failed refresh is flagged stale; show a marker
    # instead of blanking the bars to a loading state.
    $staleSuffix = if ($quotaData.stale) { " ${DIM}${GRAY}(stale)${RESET}" } else { "" }
    foreach ($row in $rows) {
        $pct = [double]($row.data.remaining_pct)
        $refresh = [string]($row.data.refresh_in)
        $info = if ($pct -ge 99.9) { "Full" } else { "Resets in $refresh" }
        $lines += (Format-ProgressBar -Label $row.label -Pct $pct -RefreshInfo $info) + $staleSuffix
    }
}

# Join and output — agy reads stdout
$output = $lines -join "`n"
[System.Console]::Out.Write($output)
