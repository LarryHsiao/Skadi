#!/usr/bin/env bash

# Read JSON from stdin
input=$(cat)

# Extract raw numeric values from JSON using jq
context_raw=$(echo "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
rate_5h_raw=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
rate_7d_raw=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
model_name=$(echo "$input" | jq -r '.model.display_name // empty' 2>/dev/null)
cwd=$(echo "$input" | jq -r '.cwd // "."' 2>/dev/null)
git_branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
diff_stat=$(git -C "$cwd" diff --cached --shortstat 2>/dev/null)
lines_added=$(echo "$diff_stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')
lines_removed=$(echo "$diff_stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+')
lines_added=${lines_added:-0}
lines_removed=${lines_removed:-0}
changed_count=$(git -C "$cwd" status --porcelain 2>/dev/null | grep -cE '^\?\?|^.[MDRC]' )
unpushed_count=$(git -C "$cwd" rev-list --count @{upstream}..HEAD 2>/dev/null || echo 0)

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

    local used_num remaining
    used_num=$(printf "%.0f" "$val")
    remaining=$(( 100 - used_num ))

    local color
    if [ "$remaining" -ge 75 ]; then
        color="$GREEN"
    elif [ "$remaining" -ge 30 ]; then
        color="$YELLOW"
    else
        color="$RED"
    fi

    printf "%s%s: %s%%%s" "$color" "$label" "$remaining" "$RESET"
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
    fetched=$(curl -s --max-time 3 "wttr.in?format=2" 2>/dev/null)
    if [ -n "$fetched" ] && ! echo "$fetched" | grep -qi "not available\|unknown location"; then
        weather="$fetched"
        echo "$weather" > "$WEATHER_CACHE"
    elif [ -f "$WEATHER_CACHE" ]; then
        weather=$(cat "$WEATHER_CACHE")
    fi
fi

# Truncate weather location name to 15 chars
weather_loc=$(echo "$weather" | sed 's/: .*//')
weather_rest=$(echo "$weather" | sed 's/^[^:]*: //')
if [ -n "$weather_rest" ]; then
    weather="$(ellipsize_end "$weather_loc" 15): $weather_rest"
fi

# Apply temperature color after resolving weather (not cached, to keep cache clean)
weather=$(colorize_temp "$weather")

context_str=$(colorize "Context" "$context_raw")
rate_5h_str=$(colorize "5h" "$rate_5h_raw")
rate_7d_str=$(colorize "7d" "$rate_7d_raw")

# Format lines changed and unstaged/untracked counts
lines_str="+${lines_added}/-${lines_removed}"
changed_str="📄 ${changed_count}"
unpushed_str="⬆ ${unpushed_count}"

# Model short name + emoji
model_lower=$(echo "$model_name" | tr '[:upper:]' '[:lower:]')
case "$model_lower" in
    *opus*)   model_emoji="🎵"; model_short="Opus" ;;
    *sonnet*) model_emoji="📝"; model_short="Sonnet" ;;
    *haiku*)  model_emoji="🍃"; model_short="Haiku" ;;
    *)        model_emoji="🤖"; model_short="${model_name:-N/A}" ;;
esac

# Line 1: project name
project_name=$(basename "$cwd")
printf "📁 %s\n" "$project_name"

# Ellipsize end of a string if longer than max_len
ellipsize_end() {
    local str="$1"
    local max_len="${2:-25}"
    local len=${#str}
    if [ "$len" -le "$max_len" ]; then
        echo "$str"
        return
    fi
    echo "${str:0:$(( max_len - 3 ))}..."
}

branch_label=$(ellipsize_end "${git_branch:-N/A}" 15)

# Line 2: branch info
printf "🌿 %s  ✏️ %s  %s  %s\n" "$branch_label" "$lines_str" "$changed_str" "$unpushed_str"

# Line 3: model + context + rate limits
printf "%s %s  📊 %s  ⚡ %s  📅 %s\n" \
    "$model_emoji" "$model_short" "$context_str" "$rate_5h_str" "$rate_7d_str"

# John Wick quotes (first movie)
wick_quotes=(
    "People keep asking if I'm back. Yeah, I'm thinking I'm back."
    "He killed my dog."
    "I'm not that guy anymore."
    "Whoever comes, I'll send them back."
    "You stabbed the Devil in the back and forced him back into the life he had just left."
    "He once killed three men in a bar with a pencil. A f***ing pencil."
    "John is a man of focus, commitment, and sheer will."
    "Be seeing you, Jonathan."
    "That's a lot of money for a hound dog."
    "You've been asking about John Wick. He's the one you send to kill the Boogeyman."
    "With a gun, he's the best. Without, he's still the best."
    "It's not what you did, son, that angers me so. It's who you did it to."
    "He's not the Boogeyman. He's the one you send to kill the f***ing Boogeyman."
    "Baba Yaga."
    "Oh, and I'd like to make a dinner reservation for twelve."
    "Just tell them, whoever comes, I'll kill them all."
    "We're professionals. Our reputations are everything."
    "You're not welcome here anymore."
    "I saw a different John Wick tonight."
    "Do I look like I'm f***ing around?"
    "Everything's got a price."
    "You can't just waltz in and kill someone. There are rules."
    "Results. That's what I need."
    "Consequences."
)
wick_quote="${wick_quotes[$RANDOM % ${#wick_quotes[@]}]}"

# Line 4: divider
printf "%s\n" "──────────────────────────────────────────────────"

# Line 5: weather + disk free
disk_free_num=$(df / | awk 'NR==2 {printf "%.2f", $4/1024/1024}')
disk_free_int=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
if [ "$disk_free_int" -ge 50 ]; then
    disk_color="$GREEN"
elif [ "$disk_free_int" -ge 20 ]; then
    disk_color="$YELLOW"
else
    disk_color="$RED"
fi
disk_str="💾 ${disk_color}${disk_free_num}GB${RESET}"

# CPU load (cross-platform)
os_type=$(uname -s 2>/dev/null)
case "$os_type" in
    Darwin*)
        cpu_load=$(top -l 1 -n 0 | awk '/CPU usage/{gsub(/%,?/,""); idle=$(NF-1); printf "%.0f", 100-idle}')
        ;;
    Linux*)
        cpu_load=$(top -bn1 | awk '/^%Cpu/{for(i=1;i<=NF;i++) if($i~/^[0-9]/ && $(i+1)~/id/) {printf "%.0f", 100-$i; break}}')
        ;;
    MINGW*|MSYS*|CYGWIN*)
        cpu_load=$(powershell.exe -NoProfile -Command "(Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average" 2>/dev/null | tr -d '[:space:]')
        ;;
esac
cpu_load=${cpu_load:-0}
if [ "$cpu_load" -le 40 ]; then
    cpu_color="$GREEN"
elif [ "$cpu_load" -le 70 ]; then
    cpu_color="$YELLOW"
else
    cpu_color="$RED"
fi
cpu_str="📈 ${cpu_color}Load: ${cpu_load}%${RESET}"

printf "%s  %s  %s\n" "$weather" "$cpu_str" "$disk_str"

# Line 6: John Wick quote
printf "🔫  \"%s\"\n" "$wick_quote"
