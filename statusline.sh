#!/usr/bin/env bash

# Read JSON from stdin
input=$(cat)

# Extract raw numeric values from JSON using jq
context_raw=$(echo "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
rate_5h_raw=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
rate_7d_raw=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)

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

    printf "%s %s: %s%% %s" "$color" "$label" "$pct_num" "$RESET"
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

# Current time
current_time=$(date +"%H:%M")

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

# Focus timer
POMODORO_STATE="$HOME/.claude/.pomodoro_state"
POMODORO_NOTIFIED="$HOME/.claude/.pomodoro_notified"
focus_str="⏱ /focus"

if [ -f "$POMODORO_STATE" ]; then
    # shellcheck disable=SC1090
    source "$POMODORO_STATE"
    now=$(date +%s)
    remaining=$(( DURATION - (now - START_TIME) ))

    if [ "$remaining" -le 0 ]; then
        focus_str="${RED} ⏱ -- ${RESET}"
        if [ ! -f "$POMODORO_NOTIFIED" ]; then
            touch "$POMODORO_NOTIFIED"
            if [ "$TYPE" = "work" ]; then
                osascript -e 'display notification "Focus session complete. Time for a break." with title "⏱ Focus Timer"' 2>/dev/null &
            else
                osascript -e 'display notification "Break over. Ready to focus?" with title "⏱ Focus Timer"' 2>/dev/null &
            fi
        fi
    else
        mins=$(( remaining / 60 ))
        if [ "$TYPE" = "work" ]; then
            focus_str="${BLUE} ⏱ ${mins}m ${RESET}"
        else
            focus_str="${GREEN} ⏸ ${mins}m ${RESET}"
        fi
    fi
fi

printf "🕐 %s  %s  %s  📊 %s  ⚡ %s  📅 %s\n" \
    "$current_time" "$weather" "$focus_str" "$context_str" "$rate_5h_str" "$rate_7d_str"
