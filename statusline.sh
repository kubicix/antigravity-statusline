#!/usr/bin/env bash
# ==============================================================================
# Antigravity CLI Custom Statusline — Quota Usage Bars (macOS/Linux)
# Renders compact ANSI progress bars showing model quota usage.
# Called by agy CLI on every state change.
# ==============================================================================

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_FILE="${SCRIPT_DIR}/quota_cache.json"
REFRESH_SCRIPT="${SCRIPT_DIR}/quota_refresh.sh"
CACHE_MAX_AGE_SECONDS=60
BAR_WIDTH=16

# ANSI Escape Codes
ESC=$'\e'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
RED="${ESC}[31m"
CYAN="${ESC}[36m"
GRAY="${ESC}[90m"
WHITE="${ESC}[37m"

# Helper: Color by remaining percentage
get_quota_color() {
    local pct=$1
    # Strip decimals for integer comparison
    local pct_int=${pct%.*}
    if [ -z "$pct_int" ]; then pct_int=0; fi

    if [ "$pct_int" -ge 70 ]; then
        echo "$GREEN"
    elif [ "$pct_int" -ge 30 ]; then
        echo "$YELLOW"
    else
        echo "$RED"
    fi
}

# Helper: Render a single progress bar
format_progress_bar() {
    local label="$1"
    local pct="$2"
    local refresh_info="$3"
    local icon="◆"

    local color
    color=$(get_quota_color "$pct")

    # Strip decimals for arithmetic
    local pct_int=${pct%.*}
    if [ -z "$pct_int" ]; then pct_int=0; fi

    local filled_count=$(( (pct_int * BAR_WIDTH) / 100 ))
    if [ $filled_count -lt 0 ]; then filled_count=0; fi
    if [ $filled_count -gt $BAR_WIDTH ]; then filled_count=$BAR_WIDTH; fi
    local empty_count=$(( BAR_WIDTH - filled_count ))

    local filled_str=""
    if [ $filled_count -gt 0 ]; then
        filled_str=$(printf '█%.0s' $(seq 1 "$filled_count"))
    fi

    local empty_str=""
    if [ $empty_count -gt 0 ]; then
        empty_str=$(printf '░%.0s' $(seq 1 "$empty_count"))
    fi

    # Format percentage with consistent width (invariant culture dot decimal)
    local pct_str
    pct_str=$(printf "%5.1f%%" "$pct")

    # Pad label to consistent width
    local padded_label
    padded_label=$(printf "%-16s" "$label")

    echo "${DIM}${color}${icon}${RESET} ${WHITE}${padded_label}${RESET} ${GRAY}[${RESET}${color}${filled_str}${GRAY}${empty_str}${RESET}${GRAY}]${RESET} ${BOLD}${color}${pct_str}${RESET}  ${DIM}${CYAN}${refresh_info}${RESET}"
}

# Helper: Trigger background refresh if cache is stale
start_quota_refresh_if_needed() {
    local needs_refresh=false

    if [ ! -f "$CACHE_FILE" ]; then
        needs_refresh=true
    else
        local mtime
        if [[ "$OSTYPE" == "darwin"* ]]; then
            mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
        else
            mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
        fi
        
        local now
        now=$(date +%s)
        local cache_age=$((now - mtime))

        if [ "$cache_age" -gt "$CACHE_MAX_AGE_SECONDS" ]; then
            needs_refresh=true
        fi
    fi

    if [ "$needs_refresh" = true ] && [ -f "$REFRESH_SCRIPT" ]; then
        # Launch refresh in background — redirect stdin, stdout, stderr so it doesn't block the TUI
        bash "$REFRESH_SCRIPT" >/dev/null 2>&1 &
    fi
}

# --- Main: Read cache and render ---
start_quota_refresh_if_needed

# Read cached quota data
if [ -f "$CACHE_FILE" ]; then
    # Parse cache fields using python3 if available (robust) or fallback to grep/sed
    if command -v python3 >/dev/null 2>&1; then
        parsed_data=$(python3 -c '
import sys, json
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    if d.get("error"):
        print("ERROR")
    else:
        stale = " (stale)" if d.get("stale") else ""
        print(f"OK|{d[\"gemini\"][\"remaining_pct\"]}|{d[\"gemini\"][\"refresh_in\"]}|{d[\"claude_gpt\"][\"remaining_pct\"]}|{d[\"claude_gpt\"][\"refresh_in\"]}|{stale}")
except Exception:
    print("ERROR")
' "$CACHE_FILE" 2>/dev/null)
    else
        # Fallback to grep/sed if no Python
        # (Checks for any error block, parses raw fields)
        if grep -q '"error": *[^n]' "$CACHE_FILE"; then
            parsed_data="ERROR"
        else
            gem_pct=$(grep -o '"gemini": *{[^}]*}' "$CACHE_FILE" | grep -o '"remaining_pct": *[0-9.]*' | awk '{print $2}')
            gem_ref=$(grep -o '"gemini": *{[^}]*}' "$CACHE_FILE" | grep -o '"refresh_in": *"[^"]*"' | cut -d'"' -f4)
            cla_pct=$(grep -o '"claude_gpt": *{[^}]*}' "$CACHE_FILE" | grep -o '"remaining_pct": *[0-9.]*' | awk '{print $2}')
            cla_ref=$(grep -o '"claude_gpt": *{[^}]*}' "$CACHE_FILE" | grep -o '"refresh_in": *"[^"]*"' | cut -d'"' -f4)
            stale_flag=$(grep -o '"stale": *[a-z]*' "$CACHE_FILE" | awk '{print $2}')
            stale_str=""
            if [ "$stale_flag" = "true" ]; then stale_str=" (stale)"; fi
            
            if [ -n "$gem_pct" ] && [ -n "$cla_pct" ]; then
                parsed_data="OK|${gem_pct}|${gem_ref}|${cla_pct}|${cla_ref}|${stale_str}"
            else
                parsed_data="ERROR"
            fi
        fi
    fi
else
    parsed_data="ERROR"
fi

if [[ "$parsed_data" == "OK|"* ]]; then
    IFS='|' read -r -a fields <<< "$parsed_data"
    gem_pct="${fields[1]}"
    gem_ref="${fields[2]}"
    cla_pct="${fields[3]}"
    cla_ref="${fields[4]}"
    stale_str="${fields[5]}"

    # Process refresh times
    if [ "$gem_ref" = "Full" ] || [ -z "$gem_ref" ]; then gem_info="Full"; else gem_info="Resets in ${gem_ref}"; fi
    if [ "$cla_ref" = "Full" ] || [ -z "$cla_ref" ]; then cla_info="Full"; else cla_info="Resets in ${cla_ref}"; fi

    format_progress_bar "Gemini" "$gem_pct" "$gem_info" | sed "s/$/${stale_str}/"
    format_progress_bar "Claude/GPT" "$cla_pct" "$cla_info" | sed "s/$/${stale_str}/"
else
    # No data or error — show loading state
    echo "${DIM}${GRAY}○ Quota data loading... (run /usage to check manually)${RESET}"
fi
