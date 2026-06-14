<#
.SYNOPSIS
    Quota Refresh Script — Background fetcher for Antigravity language server quota data
.DESCRIPTION
    Discovers the local Antigravity language_server process, extracts its --csrf_token,
    finds its listening ports, queries the Connect-RPC GetUserStatus endpoint, parses
    per-model quota into two groups (Gemini, Claude/GPT) and writes quota_cache.json.
    Designed to run hidden in the background so it never blocks the TUI.
.AUTHOR
    Kubilay Birer (kubicix) — MIT License
#>

# ─── Configuration ───────────────────────────────────────────────────────────
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$CACHE_FILE = Join-Path $SCRIPT_DIR "quota_cache.json"
$LOCK_FILE  = Join-Path $SCRIPT_DIR "quota_refresh.lock"
$TIMEOUT_SECONDS = 5

# Connect-RPC endpoint exposed by the local Antigravity language server.
$USER_STATUS_PATH = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
$REQUEST_BODY = '{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}'

# ─── Prevent concurrent executions ──────────────────────────────────────────
if (Test-Path $LOCK_FILE) {
    $lockAge = (Get-Date) - (Get-Item $LOCK_FILE).LastWriteTime
    if ($lockAge.TotalSeconds -lt 30) { exit 0 }
    Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
}
Set-Content -Path $LOCK_FILE -Value (Get-Date -Format "o") -ErrorAction SilentlyContinue

# Accept the language server's self-signed cert (for the https attempt).
try {
    Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class AgyTrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
'@ -ErrorAction SilentlyContinue
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object AgyTrustAll
} catch {}

function Write-Cache {
    param([string]$Json)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($CACHE_FILE, $Json, $utf8NoBom)
}

try {
    # ─── Step 1: Discover language server processes (pid + csrf token + ports) ──
    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "language_server|antigravity" -or $_.CommandLine -match "--csrf_token"
    }

    # Each candidate pairs a token with the ports of the SAME process.
    $candidates = @()
    foreach ($proc in $processes) {
        $token = ""
        if ($proc.CommandLine -and $proc.CommandLine -match "--csrf_token(?:=|\s+)([^\s`"']+)") {
            $token = $Matches[1]
        }

        $ports = @()
        try {
            $conns = Get-NetTCPConnection -State Listen -OwningProcess $proc.ProcessId -ErrorAction SilentlyContinue
            foreach ($c in $conns) { if ($c.LocalAddress -match "127\.0\.0\.1|::1|0\.0\.0\.0") { $ports += [int]$c.LocalPort } }
        } catch {
            try {
                $lines = netstat -ano | Select-String -Pattern "LISTENING\s+$($proc.ProcessId)\s*$"
                foreach ($l in $lines) { if ($l -match "127\.0\.0\.1:(\d+)") { $ports += [int]$Matches[1] } }
            } catch {}
        }

        foreach ($port in ($ports | Select-Object -Unique)) {
            $candidates += [pscustomobject]@{ Port = $port; Token = $token }
        }
    }

    if ($candidates.Count -eq 0) {
        Write-Cache (@{
            timestamp = (Get-Date -Format "o")
            error = "No Antigravity language server process/port found"
        } | ConvertTo-Json -Depth 5)
        exit 1
    }

    # ─── Step 2: Query GetUserStatus (http first, https fallback) ─────────────
    $response = $null
    $lastError = "No candidate responded"

    foreach ($cand in $candidates) {
        foreach ($scheme in @("http", "https")) {
            $headers = @{
                "Accept" = "application/json"
                "Content-Type" = "application/json"
                "Connect-Protocol-Version" = "1"
            }
            if ($cand.Token -ne "") { $headers["X-Codeium-Csrf-Token"] = $cand.Token }

            $url = "${scheme}://127.0.0.1:$($cand.Port)$USER_STATUS_PATH"
            try {
                $response = Invoke-RestMethod -Uri $url -Method POST -Headers $headers `
                    -Body $REQUEST_BODY -TimeoutSec $TIMEOUT_SECONDS -ErrorAction Stop
                if ($null -ne $response -and $null -ne $response.userStatus) { break }
                $response = $null
            } catch {
                $lastError = $_.Exception.Message
            }
        }
        if ($null -ne $response) { break }
    }

    if ($null -eq $response) {
        Write-Cache (@{
            timestamp = (Get-Date -Format "o")
            error = "Could not query language server: $lastError"
        } | ConvertTo-Json -Depth 5)
        exit 1
    }

    # ─── Step 3: Parse per-model quota into two groups ───────────────────────
    # The API returns one effective remainingFraction (0..1) + resetTime per model.
    # proto3 JSON omits a fraction of 0.0, so an absent fraction means 0% remaining.
    function Format-RefreshTime {
        param([object]$Value)
        if ($null -eq $Value -or "$Value" -eq "") { return "N/A" }
        try {
            $target = [DateTimeOffset]::Parse($Value.ToString())
            $diff = $target - [DateTimeOffset]::Now
            if ($diff.TotalMinutes -le 0) { return "now" }
            $hours = [math]::Floor($diff.TotalHours)
            $mins = $diff.Minutes
            if ($hours -gt 0) { return "${hours}h ${mins}m" }
            return "${mins}m"
        } catch { return "$Value" }
    }

    # Two quota groups, matching the official /usage panel:
    #   GEMINI            -> Gemini Flash + Gemini Pro (shared limit)
    #   CLAUDE AND GPT    -> Claude Opus/Sonnet + GPT-OSS (shared limit)
    # Each holds the most-constrained (lowest remaining) model, plus its reset.
    $buckets = @{
        gemini     = @{ pct = $null; reset = "N/A" }
        claude_gpt = @{ pct = $null; reset = "N/A" }
    }

    $models = $response.userStatus.cascadeModelConfigData.clientModelConfigs
    foreach ($m in $models) {
        $label = "$($m.label)"
        $key = $null
        if     ($label -match "(?i)gemini")      { $key = "gemini" }
        elseif ($label -match "(?i)claude|gpt")  { $key = "claude_gpt" }
        if ($null -eq $key) { continue }

        # Absent remainingFraction (proto3 default) = 0.0 remaining.
        $frac = 0.0
        if ($m.quotaInfo -and $null -ne $m.quotaInfo.remainingFraction) {
            $frac = [double]$m.quotaInfo.remainingFraction
        }
        $pct = [math]::Round([math]::Max(0.0, [math]::Min(1.0, $frac)) * 100.0, 2)

        if ($null -eq $buckets[$key].pct -or $pct -lt $buckets[$key].pct) {
            $buckets[$key].pct = $pct
            if ($m.quotaInfo) { $buckets[$key].reset = Format-RefreshTime -Value $m.quotaInfo.resetTime }
        }
    }

    foreach ($k in @("gemini", "claude_gpt")) {
        if ($null -eq $buckets[$k].pct) { $buckets[$k].pct = 0.0 }
    }

    # ─── Step 4: Write cache ─────────────────────────────────────────────────
    Write-Cache (@{
        timestamp = (Get-Date -Format "o")
        error = $null
        account = "$($response.userStatus.email)"
        plan = "$($response.userStatus.planStatus.planInfo.planName)"
        gemini     = @{ remaining_pct = $buckets["gemini"].pct;     refresh_in = $buckets["gemini"].reset }
        claude_gpt = @{ remaining_pct = $buckets["claude_gpt"].pct; refresh_in = $buckets["claude_gpt"].reset }
    } | ConvertTo-Json -Depth 5)

} finally {
    Remove-Item $LOCK_FILE -Force -ErrorAction SilentlyContinue
}
