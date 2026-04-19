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
    "People keep asking if I'm back. Yeah, I'm thinking I'm back. — John Wick"
    "He killed my dog. — John Wick"
    "I'm not that guy anymore. — John Wick"
    "Whoever comes, I'll send them back. — John Wick"
    "He once killed three men in a bar with a pencil. A f***ing pencil. — Viggo Tarasov"
    "John is a man of focus, commitment, and sheer will. — Viggo Tarasov"
    "Be seeing you, Jonathan. — Winston"
    "You've been asking about John Wick. He's the one you send to kill the Boogeyman. — Viggo Tarasov"
    "It's not what you did, son, that angers me so. It's who you did it to. — Viggo Tarasov"
    "He's not the Boogeyman. He's the one you send to kill the f***ing Boogeyman. — Viggo Tarasov"
    "Baba Yaga. — Viggo Tarasov"
    "Just tell them, whoever comes, I'll kill them all. — John Wick"
    "We're professionals. Our reputations are everything. — Marcus"
    "Do I look like I'm f***ing around? — John Wick"
    "Everything's got a price. — Winston"
    "Results. That's what I need. — Santino D'Antonio"
    "Consequences. — Winston"
)
wick_quote="${wick_quotes[$RANDOM % ${#wick_quotes[@]}]}"

# Proverbs
proverbs=(
    "Break a leg."
)

# The Accountant quotes
accountant_quotes=(
    "I'm a work in progress. — Christian Wolff"
    "Somebody always gets hurt. — Christian Wolff's father"
    "Math is the only thing that isn't subject to opinion. — Christian Wolff"
    "Being different is not a bad thing. It means you see the world in your own way. — Justine"
    "Sometimes, in order to keep the people in our lives safe, we do things that we regret. — Christian Wolff"
    "You're not done. When I'm done, I'll tell you. — Christian Wolff's father"
    "I uncook books. — Christian Wolff"
    "You must make friends wherever you go. — Christian Wolff"
    "Patience. Things get better. — Christian Wolff"
)

# The Mentalist quotes (超感應神探)
mentalist_quotes=(
    "Red John is a shallow, sick, narcissistic sociopath. — Patrick Jane"
    "Tea is the solution to all problems. — Patrick Jane"
    "I'm not psychic. I just pay attention. — Patrick Jane"
    "I don't have friends. I have associates... and Teresa Lisbon. — Patrick Jane"
    "Red John wants me to suffer. So I intend to be very, very happy. — Patrick Jane"
    "There is no such thing as psychic phenomenon. There are only tricks. — Patrick Jane"
    "I solve crimes. I help put bad guys in jail. It's my way of making amends. — Patrick Jane"
    "Everybody has a tell. — Patrick Jane"
    "I'm a consultant. I consult. — Patrick Jane"
    "I'm very good at reading people. It's a gift and a curse. — Patrick Jane"
    "Always bet on human nature. — Patrick Jane"
    "People are predictable. That's not an insult. It's comforting. — Patrick Jane"
    "The best con is the one where the mark never knows they've been had. — Patrick Jane"
    "A good magician never reveals his secrets. Lucky for you, I'm not a magician. — Patrick Jane"
    "I've been called a lot of things. Modest isn't one of them. — Patrick Jane"
    "There's a fine line between confidence and arrogance. I walk it perfectly. — Patrick Jane"
    "You'd be amazed what you can get people to do if you just ask nicely. — Patrick Jane"
    "Be the chess player, not the chess piece. — Patrick Jane"
    "The details. The details tell you everything. — Patrick Jane"
    "I notice things. That's all. — Patrick Jane"
    "The trick to lying is believing your own lie. — Patrick Jane"
    "Patterns. Everything is patterns. — Patrick Jane"
    "Happiness is an inside job. — Patrick Jane"
    "Lying is like any other skill. The more you practice, the better you get. — Patrick Jane"
    "The greatest trick is making people think they figured it out themselves. — Patrick Jane"
    "I have a very low boredom threshold. — Patrick Jane"
    "You can't con an honest man. Well, you can, but it's not as much fun. — Patrick Jane"
    "Every lie contains a seed of truth. Find the seed. — Patrick Jane"
    "Instinct is just experience dressed up as intuition. — Patrick Jane"
    "Anger is just fear with nowhere to go. — Patrick Jane"
    "People don't change. They just reveal themselves more clearly. — Patrick Jane"
    "Patience is just cruelty with better manners. — Patrick Jane"
    "The best lies are the ones closest to the truth. — Patrick Jane"
    "Everybody lies. The trick is knowing when it matters. — Patrick Jane"
    "Guilt is a funny thing. It never quite goes away. — Patrick Jane"
    "Revenge is a dish best served piping hot. Contrary to popular opinion. — Patrick Jane"
    "You should never argue with a woman who's carrying a gun. — Patrick Jane"
    "Never underestimate the power of a broken heart. — Patrick Jane"
    "Trust is a leap of faith. Most people are too afraid to jump. — Patrick Jane"
    "The problem with secrets is they have a way of coming out. — Patrick Jane"
    "People only see what they're prepared to see. — Patrick Jane"
    "You'd be surprised what you can learn from people when you actually listen to them. — Patrick Jane"
    "A guilty man always returns to the scene of the crime. — Patrick Jane"
    "Sometimes the best way to get information is to give some. — Patrick Jane"
    "Don't ever tell a man he has no sense of humor. It's the one thing every man thinks he has. — Patrick Jane"
    "The truth is always the truth, whether you believe it or not. — Patrick Jane"
    "Memory is a strange thing. It doesn't work like I thought it did. — Patrick Jane"
    "Faith is a beautiful thing, but it can be used against you. — Patrick Jane"
    "A man with nothing to lose is a very dangerous man. — Patrick Jane"
    "I was a fake psychic. Now I just have to be real. — Patrick Jane"
    "Everything is significant if you look closely enough. — Patrick Jane"
    "You can tell everything about a person by what they laugh at. — Patrick Jane"
    "The most dangerous person in any room is the one who has nothing to lose. — Patrick Jane"
    "Observation without judgment. That's the key. — Patrick Jane"
    "The mind is a muscle. Most people never exercise it. — Patrick Jane"
    "Charm is just honesty with better packaging. — Patrick Jane"
    "A good question is worth more than a good answer. — Patrick Jane"
    "A smile is the most powerful weapon in any arsenal. — Patrick Jane"
    "You can't fake kindness. It's the one thing people always recognize. — Patrick Jane"
    "Every story has a beginning, a middle, and an end. Not always in that order. — Patrick Jane"
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
