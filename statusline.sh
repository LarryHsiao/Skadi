#!/usr/bin/env bash

# Read JSON from stdin
input=$(cat)

# Extract raw numeric values from JSON using jq
context_raw=$(echo "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
rate_5h_raw=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
rate_7d_raw=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
model_name=$(echo "$input" | jq -r '.model.display_name // empty' 2>/dev/null)
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0' 2>/dev/null)
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0' 2>/dev/null)
git_branch=$(git -C "$(echo "$input" | jq -r '.cwd // "."' 2>/dev/null)" rev-parse --abbrev-ref HEAD 2>/dev/null)

# ANSI color codes: colored background
BLUE=$'\033[44;97m'      # blue bg, white text
GREEN=$'\033[42;30m'     # green bg, black text
YELLOW=$'\033[43;30m'    # yellow bg, black text
RED=$'\033[41;97m'       # red bg, white text
RESET=$'\033[0m'

# colorize label raw_pct — prints "label: XX%" with background color
colorize() {
    local label="$1"
    local val="$2"

    if [ -z "$val" ]; then
        printf "%s: N/A" "$label"
        return
    fi

    local pct_num
    pct_num=$(printf "%.0f" "$val")

    local color
    if [ "$pct_num" -ge 85 ]; then
        color="$RED"
    elif [ "$pct_num" -ge 45 ]; then
        color="$YELLOW"
    else
        color="$GREEN"
    fi

    printf "%s%s: %s%%%s" "$color" "$label" "$pct_num" "$RESET"
}

# colorize_temp weather_str — replaces the temperature value with a colored version
colorize_temp() {
    local str="$1"
    local temp_match temp_num color

    temp_match=$(echo "$str" | grep -oE '[+-]?[0-9]+°C' | head -1)
    [ -z "$temp_match" ] && { echo "$str"; return; }

    temp_num=$(echo "$temp_match" | grep -oE '[+-]?[0-9]+')

    if [ "$temp_num" -ge 30 ]; then
        color="$RED"
    elif [ "$temp_num" -ge 28 ]; then
        color="$YELLOW"
    elif [ "$temp_num" -ge 20 ]; then
        color="$GREEN"
    else
        color="$BLUE"
    fi

    echo "${str/${temp_match}/${color}${temp_match}${RESET}}"
}

# Weather with 30-minute cache
WEATHER_CACHE="/tmp/.claude_weather_cache"
weather="Weather N/A"

if [ -f "$WEATHER_CACHE" ]; then
    cache_age=$(( $(date +%s) - $(stat -f "%m" "$WEATHER_CACHE" 2>/dev/null || echo 0) ))
    if [ "$cache_age" -lt 1800 ]; then
        weather=$(cat "$WEATHER_CACHE")
    fi
fi

if [ "$weather" = "Weather N/A" ]; then
    fetched=$(curl -s --max-time 3 "wttr.in?format=3" 2>/dev/null)
    if [ -n "$fetched" ]; then
        # Title-case the location name (part before the first ': ')
        weather=$(echo "$fetched" | awk -F': ' '{
            n=split($1,w," "); loc=""
            for(i=1;i<=n;i++) loc=loc (i>1?" ":"") toupper(substr(w[i],1,1)) substr(w[i],2)
            print "📍 " loc " " $2
        }')
        echo "$weather" > "$WEATHER_CACHE"
    elif [ -f "$WEATHER_CACHE" ]; then
        weather=$(cat "$WEATHER_CACHE")
    fi
fi

# Apply temperature color after resolving weather (not cached, to keep cache clean)
weather=$(colorize_temp "$weather")

context_str=$(colorize "Context" "$context_raw")
rate_5h_str=$(colorize "5h" "$rate_5h_raw")
rate_7d_str=$(colorize "7d" "$rate_7d_raw")

# Format lines changed
lines_str="+${lines_added}/-${lines_removed}"

# Model short name + emoji
model_lower=$(echo "$model_name" | tr '[:upper:]' '[:lower:]')
case "$model_lower" in
    *opus*)   model_emoji="🎵"; model_short="Opus" ;;
    *sonnet*) model_emoji="📝"; model_short="Sonnet" ;;
    *haiku*)  model_emoji="🍃"; model_short="Haiku" ;;
    *)        model_emoji="🤖"; model_short="${model_name:-N/A}" ;;
esac

printf "🌿%s  ✏️%s\n" \
    "${git_branch:-N/A}" "$lines_str"
printf "%s%s  📊%s  ⚡%s  📅%s\n" \
    "$model_emoji" "$model_short" "$context_str" "$rate_5h_str" "$rate_7d_str"
printf "%s\n" "$weather"
