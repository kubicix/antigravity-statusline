<#
.SYNOPSIS
    Antigravity CLI Custom Statusline — Quota, Branch & Context Bars
.DESCRIPTION
    Renders compact ANSI progress bars for model quota usage, plus a
    git branch indicator and a context-window usage bar.
    Called by agy CLI on every state change (JSON piped to stdin).
    All data comes straight from that stdin payload — agy already reports
    per-model quota in the "quota" field, so no background polling of the
    local language server (port scanning / CSRF tokens / HTTP probing) is
    needed or done here.
.AUTHOR
    Kubilay Birer (kubicix) — MIT License
#>

# ─── Force UTF-8 output (fixes garbled Unicode in IDE terminals) ─────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ─── Configuration ───────────────────────────────────────────────────────────
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

# ─── Read stdin (agy pipes JSON session state) ──────────────────────────────
try {
    $stdinData = [System.Console]::In.ReadToEnd()
} catch {
    $stdinData = ""
}

$payload = $null
if ($stdinData -and $stdinData.Trim() -ne "") {
    try { $payload = $stdinData | ConvertFrom-Json } catch { $payload = $null }
}

# ─── Helper: Color by remaining percentage (green = healthy, red = low) ─────
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

    $filledChar = [char]0x2588  # █
    $emptyChar  = [char]0x2591  # ░

    $filledStr = ([string]$filledChar) * $filledCount
    $emptyStr  = ([string]$emptyChar) * $emptyCount

    $pctStr = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0,6:F1}%", $Pct)
    $paddedLabel = $Label.PadRight(16)

    return "${DIM}${color}${Icon}${RESET} ${WHITE}${paddedLabel}${RESET} ${GRAY}[${RESET}${color}${filledStr}${GRAY}${emptyStr}${RESET}${GRAY}]${RESET} ${BOLD}${color}${pctStr}${RESET}  ${DIM}${CYAN}${RefreshInfo}${RESET}"
}

# ─── Helper: Format seconds-until-reset as "Xh Ym" / "Ym" / "now" ───────────
function Format-ResetIn {
    param([Nullable[int]]$Seconds)
    if ($null -eq $Seconds -or $Seconds -le 0) { return "now" }
    $hours = [math]::Floor($Seconds / 3600)
    $mins  = [math]::Floor(($Seconds % 3600) / 60)
    if ($hours -gt 0) { return "${hours}h ${mins}m" }
    return "${mins}m"
}

# ─── Helper: Group the "quota" payload into Gemini / Claude+GPT buckets ─────
# agy reports one bucket per model/window (e.g. "gemini-weekly"). Match by
# family in the key name and keep the most-constrained (lowest remaining)
# bucket per family — this mirrors the grouping the official /usage panel
# shows.
function Get-QuotaBuckets {
    param($Quota)

    $buckets = @{
        gemini     = @{ pct = $null; reset = "N/A" }
        claude_gpt = @{ pct = $null; reset = "N/A" }
    }
    if ($null -eq $Quota) { return $buckets }

    foreach ($prop in $Quota.PSObject.Properties) {
        $key = $prop.Name
        $group = $null
        if     ($key -match "(?i)gemini")     { $group = "gemini" }
        elseif ($key -match "(?i)claude|gpt") { $group = "claude_gpt" }
        if ($null -eq $group) { continue }

        $entry = $prop.Value
        $frac = 0.0
        if ($null -ne $entry.remaining_fraction) { $frac = [double]$entry.remaining_fraction }
        $pct = [math]::Round([math]::Max(0.0, [math]::Min(1.0, $frac)) * 100.0, 2)

        if ($null -eq $buckets[$group].pct -or $pct -lt $buckets[$group].pct) {
            $buckets[$group].pct = $pct
            $buckets[$group].reset = Format-ResetIn -Seconds ($entry.reset_in_seconds -as [int])
        }
    }

    foreach ($g in @("gemini", "claude_gpt")) {
        if ($null -eq $buckets[$g].pct) { $buckets[$g].pct = 0.0 }
    }
    return $buckets
}

# ─── Main: render from the stdin payload ────────────────────────────────────
$lines = @()

if ($null -eq $payload -or $null -eq $payload.quota) {
    $loadingIcon = [char]0x25CB  # ○
    $lines += "${DIM}${GRAY}${loadingIcon} No quota data in payload yet (run /usage to check manually)${RESET}"
} else {
    # Branch line
    if ($payload.vcs -and $payload.vcs.branch) {
        $dirtyMark = if ($payload.vcs.dirty) { " ${YELLOW}*${RESET}" } else { "" }
        $lines += "${DIM}${GRAY}on${RESET} ${CYAN}$($payload.vcs.branch)${RESET}${dirtyMark}"
    }

    # Quota bars
    $buckets = Get-QuotaBuckets -Quota $payload.quota
    $rows = @(
        @{ label = "Gemini";     data = $buckets["gemini"] },
        @{ label = "Claude/GPT"; data = $buckets["claude_gpt"] }
    )
    foreach ($row in $rows) {
        $pct = [double]$row.data.pct
        $info = if ($pct -ge 99.9) { "Full" } else { "Resets in $($row.data.reset)" }
        $lines += Format-ProgressBar -Label $row.label -Pct $pct -RefreshInfo $info
    }

    # Context window usage bar
    if ($payload.context_window -and $null -ne $payload.context_window.remaining_percentage) {
        $remainingPct = [double]$payload.context_window.remaining_percentage
        $usedPct = [math]::Round(100.0 - $remainingPct, 1)
        $lines += Format-ProgressBar -Label "Context" -Pct $remainingPct -RefreshInfo "${usedPct}% used" -Icon ([char]0x25A0)
    }
}

# Join and output — agy reads stdout
$output = $lines -join "`n"
[System.Console]::Out.Write($output)
