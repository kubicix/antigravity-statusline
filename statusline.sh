#!/usr/bin/env bash
# ==============================================================================
# Antigravity CLI Custom Statusline — Quota, Branch & Context Bars (macOS/Linux)
# Renders compact ANSI progress bars for model quota usage, plus a git branch
# indicator and a context-window usage bar. Called by agy CLI on every state
# change (JSON piped to stdin).
#
# All data comes straight from that stdin payload — agy already reports
# per-model quota in the "quota" field, so this script does no background
# polling of the local language server (no port scanning / CSRF tokens /
# HTTP probing).
# ==============================================================================

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

# Helper: Color by remaining percentage (green = healthy, red = low)
get_quota_color() {
    local pct_int=${1%.*}
    if [ -z "$pct_int" ]; then pct_int=0; fi
    if [ "$pct_int" -ge 70 ]; then echo "$GREEN"
    elif [ "$pct_int" -ge 30 ]; then echo "$YELLOW"
    else echo "$RED"
    fi
}

# Helper: Render a single progress bar
format_progress_bar() {
    local label="$1" pct="$2" refresh_info="$3" icon="${4:-◆}"
    local color pct_int filled_count empty_count filled_str empty_str pct_str padded_label

    color=$(get_quota_color "$pct")
    pct_int=${pct%.*}
    if [ -z "$pct_int" ]; then pct_int=0; fi

    filled_count=$(( (pct_int * BAR_WIDTH) / 100 ))
    if [ $filled_count -lt 0 ]; then filled_count=0; fi
    if [ $filled_count -gt $BAR_WIDTH ]; then filled_count=$BAR_WIDTH; fi
    empty_count=$(( BAR_WIDTH - filled_count ))

    filled_str=""
    if [ $filled_count -gt 0 ]; then filled_str=$(printf '█%.0s' $(seq 1 "$filled_count")); fi
    empty_str=""
    if [ $empty_count -gt 0 ]; then empty_str=$(printf '░%.0s' $(seq 1 "$empty_count")); fi

    pct_str=$(printf "%5.1f%%" "$pct")
    padded_label=$(printf "%-16s" "$label")

    echo "${DIM}${color}${icon}${RESET} ${WHITE}${padded_label}${RESET} ${GRAY}[${RESET}${color}${filled_str}${GRAY}${empty_str}${RESET}${GRAY}]${RESET} ${BOLD}${color}${pct_str}${RESET}  ${DIM}${CYAN}${refresh_info}${RESET}"
}

# --- Read stdin (agy pipes JSON session state) ---
payload=$(cat)

if [ -z "$payload" ] || ! command -v python3 >/dev/null 2>&1; then
    echo "${DIM}${GRAY}○ No quota data in payload yet (run /usage to check manually)${RESET}"
    exit 0
fi

# --- Parse payload: branch, quota buckets (grouped Gemini / Claude+GPT), context window ---
# Prints pipe-delimited lines this script then renders as bars:
#   BRANCH|<name>|<dirty 0/1>          (only if vcs.branch present)
#   QUOTA|Gemini|<pct>|<reset_info>
#   QUOTA|Claude/GPT|<pct>|<reset_info>
#   CONTEXT|<remaining_pct>|<used_pct>  (only if context_window present)
parsed=$(python3 -c '
import sys, json, re

def format_reset_in(seconds):
    try:
        seconds = int(seconds)
    except (TypeError, ValueError):
        return "N/A"
    if seconds <= 0:
        return "now"
    hours, mins = divmod(seconds // 60, 60)
    return f"{hours}h {mins}m" if hours > 0 else f"{mins}m"

try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

quota = data.get("quota") or {}
if not quota:
    sys.exit(0)

vcs = data.get("vcs") or {}
branch = vcs.get("branch")
if branch:
    dirty = 1 if vcs.get("dirty") else 0
    print(f"BRANCH|{branch}|{dirty}")

buckets = {"gemini": None, "claude_gpt": None}
for key, entry in quota.items():
    if re.search(r"gemini", key, re.IGNORECASE):
        group = "gemini"
    elif re.search(r"claude|gpt", key, re.IGNORECASE):
        group = "claude_gpt"
    else:
        continue
    frac = float(entry.get("remaining_fraction") or 0.0)
    pct = round(max(0.0, min(1.0, frac)) * 100.0, 2)
    reset = format_reset_in(entry.get("reset_in_seconds"))
    cur = buckets[group]
    if cur is None or pct < cur[0]:
        buckets[group] = (pct, reset)

for group, label in (("gemini", "Gemini"), ("claude_gpt", "Claude/GPT")):
    pct, reset = buckets[group] if buckets[group] else (0.0, "N/A")
    info = "Full" if pct >= 99.9 else f"Resets in {reset}"
    print(f"QUOTA|{label}|{pct}|{info}")

cw = data.get("context_window") or {}
if cw.get("remaining_percentage") is not None:
    remaining = float(cw["remaining_percentage"])
    used = round(100.0 - remaining, 1)
    print(f"CONTEXT|{remaining}|{used}% used")
' "$payload" 2>/dev/null)

if [ -z "$parsed" ]; then
    echo "${DIM}${GRAY}○ No quota data in payload yet (run /usage to check manually)${RESET}"
    exit 0
fi

# Strip stray CRs (e.g. a python interpreter on PATH that emits CRLF) so field
# comparisons below don't silently fail.
parsed="${parsed//$'\r'/}"

while IFS='|' read -r kind a b c; do
    case "$kind" in
        BRANCH)
            dirty_mark=""
            if [ "$b" = "1" ]; then dirty_mark=" ${YELLOW}*${RESET}"; fi
            echo "${DIM}${GRAY}on${RESET} ${CYAN}${a}${RESET}${dirty_mark}"
            ;;
        QUOTA)
            format_progress_bar "$a" "$b" "$c"
            ;;
        CONTEXT)
            format_progress_bar "Context" "$a" "$b" "■"
            ;;
    esac
done <<< "$parsed"
