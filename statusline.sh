#!/usr/bin/env bash

# Read JSON from stdin
input=$(cat)

# Extract raw numeric values from JSON using jq
context_raw=$(echo "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
rate_5h_raw=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
rate_5h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
rate_7d_raw=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
rate_7d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)
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

# rough_eta timestamp — prints rough time until reset (e.g. "~2h", "~30m", "~3d")
# Accepts Unix epoch (integer) or ISO-8601 string
rough_eta() {
    local reset_ts="$1"
    [ -z "$reset_ts" ] && return

    local now reset_epoch diff_sec
    now=$(date +%s)
    if [[ "$reset_ts" =~ ^[0-9]+$ ]]; then
        reset_epoch="$reset_ts"
    else
        reset_epoch=$(date -d "$reset_ts" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${reset_ts%%.*}" +%s 2>/dev/null)
    fi
    [ -z "$reset_epoch" ] && return

    diff_sec=$(( reset_epoch - now ))
    [ "$diff_sec" -le 0 ] && { printf "now"; return; }

    if [ "$diff_sec" -lt 3600 ]; then
        printf "%dm" $(( diff_sec / 60 ))
    elif [ "$diff_sec" -lt 86400 ]; then
        printf "%dh" $(( diff_sec / 3600 ))
    else
        printf "%dd" $(( diff_sec / 86400 ))
    fi
}

# colorize label raw_pct [reset_ts] — prints "label: XX%" with background color + optional reset ETA
colorize() {
    local label="$1"
    local val="$2"
    local reset_ts="$3"

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

    local display_label="$label"
    if [ -n "$reset_ts" ]; then
        local eta
        eta=$(rough_eta "$reset_ts")
        [ -n "$eta" ] && display_label="$eta"
    fi

    printf "%s%s: %s%%%s" "$color" "$display_label" "$remaining" "$RESET"
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

    echo "${str/${temp_match}/ ${color}${temp_match}${RESET}}"
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


# Strip location prefix from wttr.in format=2 output (e.g. "City: ⛅ ..." → "⛅ ...")
weather="${weather#*: }"
# Collapse multiple spaces into one
weather=$(echo "$weather" | tr -s ' ')

# colorize_wind weather_str — colors wind speed by threshold (km/h)
colorize_wind() {
    local str="$1"
    local wind_match wind_num color

    wind_match=$(echo "$str" | grep -oE '[0-9]+km/h' | head -1)
    [ -z "$wind_match" ] && { echo "$str"; return; }

    wind_num=$(echo "$wind_match" | grep -oE '[0-9]+')

    if [ "$wind_num" -le 20 ]; then
        color="$GREEN"
    elif [ "$wind_num" -le 40 ]; then
        color="$YELLOW"
    else
        color="$RED"
    fi

    echo "${str/${wind_match}/${color}${wind_match}${RESET}}"
}

# Apply temperature and wind color after resolving weather (not cached, to keep cache clean)
weather=$(colorize_temp "$weather")
weather=$(colorize_wind "$weather")

context_str=$(colorize "Context" "$context_raw")
rate_5h_str=$(colorize "5h" "$rate_5h_raw" "$rate_5h_reset")
rate_7d_str=$(colorize "7d" "$rate_7d_raw" "$rate_7d_reset")

# Format lines changed and unstaged/untracked counts
lines_str="+${lines_added}/-${lines_removed}"
changed_str="📄 ${changed_count}"
unpushed_str="⬆ ${unpushed_count}"

# Grammar error count for today
GRAMMAR_LOG="$HOME/.claude/.grammar_log"
TODAY=$(date +%Y-%m-%d)
grammar_today=0
if [ -f "$GRAMMAR_LOG" ]; then
    grammar_today=$(grep -c "^${TODAY}$" "$GRAMMAR_LOG" 2>/dev/null || echo 0)
fi
grammar_str="✍️ ${grammar_today}"

# Model short name + emoji
model_lower=$(echo "$model_name" | tr '[:upper:]' '[:lower:]')
case "$model_lower" in
    *opus*)   model_emoji="🎵"; model_short="Opus" ;;
    *sonnet*) model_emoji="📝"; model_short="Sonnet" ;;
    *haiku*)  model_emoji="🍃"; model_short="Haiku" ;;
    *)        model_emoji="🤖"; model_short="${model_name:-N/A}" ;;
esac

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

# Line 1: project name + branch
project_name=$(basename "$cwd")
project_label=$(ellipsize_end "$project_name" 15)
branch_label=$(ellipsize_end "${git_branch:-N/A}" 25)
printf "📁 %s  🌿 %s\n" "$project_label" "$branch_label"

# Line 2: branch info
printf "✏️ %s  %s  %s  %s\n" "$lines_str" "$changed_str" "$unpushed_str" "$grammar_str"

# Line 3: model + context + rate limits
printf "%s %s  📊 %s  ⚡ %s  📅 %s\n" \
    "$model_emoji" "$model_short" "$context_str" "$rate_5h_str" "$rate_7d_str"

# John Wick quotes
wick_quotes=(
    "People keep asking if I'm back. Yeah, I'm thinking I'm back."
    "He killed my dog."
    "I'm not that guy anymore."
    "Whoever comes, I'll send them back."
    "He once killed three men in a bar with a pencil. A f***ing pencil."
    "John is a man of focus, commitment, and sheer will."
    "Be seeing you, Jonathan."
    "You've been asking about John Wick. He's the one you send to kill the Boogeyman."
    "It's not what you did, son, that angers me so. It's who you did it to."
    "He's not the Boogeyman. He's the one you send to kill the f***ing Boogeyman."
    "Baba Yaga."
    "Just tell them, whoever comes, I'll kill them all."
    "We're professionals. Our reputations are everything."
    "Do I look like I'm f***ing around?"
    "Everything's got a price."
    "Results. That's what I need."
    "Consequences."
)
wick_quote="${wick_quotes[$RANDOM % ${#wick_quotes[@]}]}"

# Proverbs
proverbs=(
    "Break a leg."
)

# The Accountant quotes
accountant_quotes=(
    "I'm a work in progress."
    "Somebody always gets hurt."
    "Math is the only thing that isn't subject to opinion."
    "Being different is not a bad thing. It means you see the world in your own way."
    "Sometimes, in order to keep the people in our lives safe, we do things that we regret."
    "You're not done. When I'm done, I'll tell you."
    "I uncook books."
    "You must make friends wherever you go."
    "Patience. Things get better."
)

# The Mentalist quotes (超感應神探)
mentalist_quotes=(
    "Red John is a shallow, sick, narcissistic sociopath."
    "Tea is the solution to all problems."
    "I'm not psychic. I just pay attention."
    "I don't have friends. I have associates... and Teresa Lisbon."
    "Red John wants me to suffer. So I intend to be very, very happy."
    "There is no such thing as psychic phenomenon. There are only tricks."
    "I solve crimes. I help put bad guys in jail. It's my way of making amends."
    "Everybody has a tell."
    "I'm a consultant. I consult."
    "I'm very good at reading people. It's a gift and a curse."
    "Always bet on human nature."
    "People are predictable. That's not an insult. It's comforting."
    "The best con is the one where the mark never knows they've been had."
    "A good magician never reveals his secrets. Lucky for you, I'm not a magician."
    "I've been called a lot of things. Modest isn't one of them."
    "There's a fine line between confidence and arrogance. I walk it perfectly."
    "You'd be amazed what you can get people to do if you just ask nicely."
    "Be the chess player, not the chess piece."
    "The details. The details tell you everything."
    "I notice things. That's all."
    "The trick to lying is believing your own lie."
    "Patterns. Everything is patterns."
    "Happiness is an inside job."
    "Lying is like any other skill. The more you practice, the better you get."
    "The greatest trick is making people think they figured it out themselves."
    "I have a very low boredom threshold."
    "You can't con an honest man. Well, you can, but it's not as much fun."
    "Every lie contains a seed of truth. Find the seed."
    "Instinct is just experience dressed up as intuition."
    "Anger is just fear with nowhere to go."
    "People don't change. They just reveal themselves more clearly."
    "Patience is just cruelty with better manners."
    "The best lies are the ones closest to the truth."
    "Everybody lies. The trick is knowing when it matters."
    "Guilt is a funny thing. It never quite goes away."
    "Revenge is a dish best served piping hot. Contrary to popular opinion."
    "You should never argue with a woman who's carrying a gun."
    "Never underestimate the power of a broken heart."
    "Trust is a leap of faith. Most people are too afraid to jump."
    "The problem with secrets is they have a way of coming out."
    "People only see what they're prepared to see."
    "You'd be surprised what you can learn from people when you actually listen to them."
    "A guilty man always returns to the scene of the crime."
    "Sometimes the best way to get information is to give some."
    "Don't ever tell a man he has no sense of humor. It's the one thing every man thinks he has."
    "The truth is always the truth, whether you believe it or not."
    "Memory is a strange thing. It doesn't work like I thought it did."
    "Faith is a beautiful thing, but it can be used against you."
    "A man with nothing to lose is a very dangerous man."
    "I was a fake psychic. Now I just have to be real."
    "Everything is significant if you look closely enough."
    "You can tell everything about a person by what they laugh at."
    "The most dangerous person in any room is the one who has nothing to lose."
    "Observation without judgment. That's the key."
    "The mind is a muscle. Most people never exercise it."
    "Charm is just honesty with better packaging."
    "A good question is worth more than a good answer."
    "A smile is the most powerful weapon in any arsenal."
    "You can't fake kindness. It's the one thing people always recognize."
    "Every story has a beginning, a middle, and an end. Not always in that order."
)

# Suits quotes
suits_quotes=(
    "When you're backed against the wall, break the goddamn thing down. — Harvey Specter"
    "I don't have dreams, I have goals. — Harvey Specter"
    "Sometimes good guys gotta do bad things to make the bad guys pay. — Harvey Specter"
    "Winners don't make excuses when the other side plays the game. — Harvey Specter"
    "Loyalty is a two-way street. If I'm asking for it from you, you're getting it back from me. — Harvey Specter"
    "That's the difference between you and me. You wanna lose small, I wanna win big. — Harvey Specter"
    "Work until you no longer have to introduce yourself. — Harvey Specter"
    "You always have a choice. — Harvey Specter"
    "I don't play the odds, I play the man. — Harvey Specter"
    "First impressions last. You start behind the eight ball, you'll never get in front. — Harvey Specter"
    "I don't get lucky. I make my own luck. — Harvey Specter"
    "Anyone can do my job, but no one can be me. — Harvey Specter"
    "Sorry, I can't hear you over the sound of how awesome I am. — Harvey Specter"
    "I'm against having emotions, not against using them. — Harvey Specter"
    "I'm Harvey Specter. I close. — Harvey Specter"
    "Don't raise your voice. Improve your argument. — Harvey Specter"
    "Never destroy anyone in public when you can accomplish the same result in private. — Harvey Specter"
    "What are your choices when someone puts a gun to your head? You take the gun, or you pull out a bigger one. — Harvey Specter"
    "The only time success comes before work is in the dictionary. — Harvey Specter"
    "You wanna be a winner? Then win. — Harvey Specter"
    "Let me tell you something. You wanna work here? Act like it. — Harvey Specter"
    "I refuse to answer that on the grounds that I don't want to. — Harvey Specter"
    "Life is this. I like this. — Harvey Specter"
    "I don't have time for matters of principle. — Harvey Specter"
    "Ever love somebody so much you can barely breathe when you're with them? — Mike Ross"
    "Some people quit because they see the obstacles. Others create history because they don't. — Mike Ross"
    "Loyalty doesn't require you to lose your soul. — Jessica Pearson"
    "I don't respond to threats. I make them. — Jessica Pearson"
    "You just got Litt up. — Louis Litt"
    "Goddammit, Harvey! — Louis Litt"
    "I'm Donna. I know everything. — Donna Paulsen"
)

# Build pool of available categories
pool=("wick" "mentalist")
[ ${#proverbs[@]} -gt 0 ] && pool+=("proverb")
[ ${#accountant_quotes[@]} -gt 0 ] && pool+=("accountant")
[ ${#suits_quotes[@]} -gt 0 ] && pool+=("suits")
chosen="${pool[$RANDOM % ${#pool[@]}]}"

case "$chosen" in
    wick)       display_quote="🔫 \"${wick_quotes[$RANDOM % ${#wick_quotes[@]}]}\"";;
    proverb)    display_quote="📜 \"${proverbs[$RANDOM % ${#proverbs[@]}]}\"";;
    accountant) display_quote="🧮 \"${accountant_quotes[$RANDOM % ${#accountant_quotes[@]}]}\"";;
    mentalist)  display_quote="🔮 \"${mentalist_quotes[$RANDOM % ${#mentalist_quotes[@]}]}\"";;
    suits)      display_quote="👔 \"${suits_quotes[$RANDOM % ${#suits_quotes[@]}]}\"";;
esac

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

# Line 6: quote
printf "%s\n" "$display_quote"
