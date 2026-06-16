#!/usr/bin/env bash
# ==============================================================================
# Quota Refresh Script — Background fetcher (macOS/Linux)
# Discovers local Antigravity server, queries Connect-RPC, writes cache.
# Designed to run in the background (hidden) to prevent TUI input lag.
# ==============================================================================

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_FILE="${SCRIPT_DIR}/quota_cache.json"
LOCK_FILE="${SCRIPT_DIR}/quota_refresh.lock"
TIMEOUT_SECONDS=5

USER_STATUS_PATH="/exa.language_server_pb.LanguageServerService/GetUserStatus"
REQUEST_BODY='{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}'

# --- Prevent concurrent executions ---
if [ -f "$LOCK_FILE" ]; then
    # Clear stale lock files (> 30s)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        mtime=$(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)
    else
        mtime=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)
    fi
    now=$(date +%s)
    age=$((now - mtime))
    if [ "$age" -lt 30 ]; then
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
touch "$LOCK_FILE"

cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# Helper: write failure state, keeping last-known data as stale if possible
write_failure() {
    local err_msg="$1"
    if [ -f "$CACHE_FILE" ] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import sys, json
from datetime import datetime
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    if d.get("gemini") and d.get("claude_gpt"):
        d["stale"] = True
        d["stale_reason"] = sys.argv[2]
        d["error"] = None
        with open(sys.argv[1], "w", encoding="utf-8") as f:
            json.dump(d, f, indent=2)
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
' "$CACHE_FILE" "$err_msg" && return
    fi

    # Fallback: write error-only cache
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "{\"timestamp\": \"$now\", \"error\": \"$err_msg\"}" > "$CACHE_FILE"
}

# Helper: discover listening ports for a given PID
get_ports_for_pid() {
    local pid=$1
    local ports=""
    
    if command -v lsof >/dev/null 2>&1; then
        ports=$(lsof -a -iTCP -P -n -p "$pid" 2>/dev/null | grep -i "LISTEN" | grep -oE "[0-9]+$" | sort -u)
    fi
    if [ -z "$ports" ] && command -v ss >/dev/null 2>&1; then
        ports=$(ss -lntp 2>/dev/null | grep -E "pid=$pid,|,pid=$pid\b" | grep -oE ":[0-9]+" | cut -d: -f2 | sort -u)
    fi
    if [ -z "$ports" ] && command -v netstat >/dev/null 2>&1; then
        ports=$(netstat -lntp 2>/dev/null | grep -E "[ \t]$pid/" | grep -oE "127\.0\.0\.1:[0-9]+" | cut -d: -f2 | sort -u)
    fi
    echo "$ports"
}

# --- Step 1: Process and Token Discovery ---
# Match language_server, antigravity, or agy processes
pids=$(ps -ww -o pid,command -A 2>/dev/null | grep -E "language_server|antigravity|agy" | grep -v "grep" | awk '{print $1}')

candidates=() # Each candidate is "port:token"
for pid in $pids; do
    cmdline=$(ps -ww -o command -p "$pid" 2>/dev/null | tail -n 1)
    
    # Extract token
    token=""
    if [[ "$cmdline" =~ --csrf_token[=\ ]+([^\ ]+) ]]; then
        token="${BASH_REMATCH[1]}"
        token=$(echo "$token" | tr -d '"'\')
    fi
    
    ports=$(get_ports_for_pid "$pid")
    for port in $ports; do
        candidates+=("${port}:${token}")
    done
done

# Proactive probe fallback: scan top 40 listening TCP ports (highest first) if process match is empty
if [ ${#candidates[@]} -eq 0 ]; then
    fallback_ports=""
    if command -v lsof >/dev/null 2>&1; then
        fallback_ports=$(lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | grep -oE "[0-9]+$" | sort -ru | head -n 40)
    elif command -v ss >/dev/null 2>&1; then
        fallback_ports=$(ss -lnt -H 2>/dev/null | awk '{print $4}' | cut -d: -f2 | sort -ru | head -n 40)
    fi
    for p in $fallback_ports; do
        candidates+=("${p}:")
    done
fi

if [ ${#candidates[@]} -eq 0 ]; then
    write_failure "No Antigravity language server process or listening port discovered"
    exit 1
fi

# --- Step 2: Query Connect-RPC Endpoint ---
response=""
last_err="No endpoint responded"

for cand in "${candidates[@]}"; do
    port="${cand%%:*}"
    token="${cand#*:}"
    
    # Try both HTTP and HTTPS
    for scheme in "http" "https"; do
        url="${scheme}://127.0.0.1:${port}${USER_STATUS_PATH}"
        
        # Build headers
        headers=(
            "-H" "Accept: application/json"
            "-H" "Content-Type: application/json"
            "-H" "Connect-Protocol-Version: 1"
        )
        if [ -n "$token" ]; then
            headers+=("-H" "X-Codeium-Csrf-Token: ${token}")
        fi
        
        # cURL call
        k_flag=""
        if [ "$scheme" = "https" ]; then
            k_flag="-k" # Insecure for self-signed certificates
        fi
        
        resp=$(curl -s $k_flag -X POST "${headers[@]}" -d "$REQUEST_BODY" --max-time "$TIMEOUT_SECONDS" "$url" 2>/dev/null)
        
        if [[ "$resp" == *"userStatus"* ]]; then
            response="$resp"
            break 2
        fi
        if [ -n "$resp" ]; then
            last_err="Invalid response format: $(echo "$resp" | head -c 100)"
        fi
    done
done

if [ -z "$response" ]; then
    write_failure "Could not connect to language server: ${last_err}"
    exit 1
fi

# --- Step 3: Parse response and update JSON Cache ---
if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys, json, re
from datetime import datetime, timezone

def format_refresh_time(val):
    if not val:
        return "N/A"
    try:
        # Match standard ISO 8601 components robustly (compatible with Python <3.7)
        m = re.match(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})", val)
        if not m:
            return str(val)
        year, month, day, hour, minute, second = map(int, m.groups())
        dt = datetime(year, month, day, hour, minute, second, tzinfo=timezone.utc)
        
        now = datetime.now(timezone.utc)
        diff = dt - now
        total_minutes = int(diff.total_seconds() / 60)
        
        if total_minutes <= 0:
            return "now"
        hours = total_minutes // 60
        mins = total_minutes % 60
        if hours > 0:
            return f"{hours}h {mins}m"
        return f"{mins}m"
    except Exception:
        return str(val)

try:
    data = json.loads(sys.argv[1])
    user_status = data.get("userStatus", {})
    email = user_status.get("email", "")
    plan_name = user_status.get("planStatus", {}).get("planInfo", {}).get("planName", "")
    configs = user_status.get("cascadeModelConfigData", {}).get("clientModelConfigs", [])
    
    buckets = {
        "gemini": {"pct": None, "reset": "N/A"},
        "claude_gpt": {"pct": None, "reset": "N/A"}
    }
    
    for m in configs:
        label = str(m.get("label", ""))
        key = None
        if re.search(r"gemini", label, re.IGNORECASE):
            key = "gemini"
        elif re.search(r"claude|gpt", label, re.IGNORECASE):
            key = "claude_gpt"
            
        if not key:
            continue
            
        quota_info = m.get("quotaInfo", {})
        frac = 0.0
        if quota_info and "remainingFraction" in quota_info:
            frac = float(quota_info["remainingFraction"])
        pct = round(max(0.0, min(1.0, frac)) * 100.0, 2)
        
        if buckets[key]["pct"] is None or pct < buckets[key]["pct"]:
            buckets[key]["pct"] = pct
            if quota_info and "resetTime" in quota_info:
                buckets[key]["reset"] = format_refresh_time(quota_info["resetTime"])
                
    for k in ["gemini", "claude_gpt"]:
        if buckets[k]["pct"] is None:
            buckets[k]["pct"] = 0.0
            
    output = {
        "timestamp": datetime.now().astimezone().isoformat(),
        "error": None,
        "stale": False,
        "account": email,
        "plan": plan_name,
        "gemini": {
            "remaining_pct": buckets["gemini"]["pct"],
            "refresh_in": buckets["gemini"]["reset"]
        },
        "claude_gpt": {
            "remaining_pct": buckets["claude_gpt"]["pct"],
            "refresh_in": buckets["claude_gpt"]["reset"]
        }
    }
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)
except Exception as e:
    print(f"Error parsing status: {e}")
    sys.exit(1)
' "$response" "$CACHE_FILE"
else
    # Simple fallback without python (rare, but handles it)
    # Extracts basic properties using grep/sed and writes a raw json cache
    gem_pct=$(echo "$response" | grep -o '"label": *"[^"]*gemini[^"]*".*?"remainingFraction": *[0-9.]*' | grep -o '"remainingFraction": *[0-9.]*' | awk '{print $2}' | sort -n | head -n 1)
    cla_pct=$(echo "$response" | grep -o '"label": *"[^"]*\(claude\|gpt\)[^"]*".*?"remainingFraction": *[0-9.]*' | grep -o '"remainingFraction": *[0-9.]*' | awk '{print $2}' | sort -n | head -n 1)
    
    # Scale from 0..1 to 0..100
    if [ -z "$gem_pct" ]; then gem_pct="100.0"; else gem_pct=$(echo "$gem_pct * 100" | awk '{print $1}'); fi
    if [ -z "$cla_pct" ]; then cla_pct="100.0"; else cla_pct=$(echo "$cla_pct * 100" | awk '{print $1}'); fi
    
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat <<EOF > "$CACHE_FILE"
{
  "timestamp": "$now",
  "error": null,
  "stale": false,
  "account": "unknown",
  "plan": "unknown",
  "gemini": {
    "remaining_pct": $gem_pct,
    "refresh_in": "N/A"
  },
  "claude_gpt": {
    "remaining_pct": $cla_pct,
    "refresh_in": "N/A"
  }
}
EOF
fi
