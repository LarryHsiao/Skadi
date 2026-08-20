#!/usr/bin/env bash

# Never take git's optional index.lock from this statusline's read-only git
# calls (branch, diff --cached, status --porcelain, rev-list). The statusline
# refreshes constantly, and `git status` otherwise grabs index.lock to refresh
# the index — racing foreground rebases/commits in the watched repo and
# leaving "Unable to create index.lock: File exists". Required locks (commit,
# rebase) are unaffected; only the optional read-side refresh is suppressed.
export GIT_OPTIONAL_LOCKS=0

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
git_dir=$(git -C "$cwd" rev-parse --git-dir 2>/dev/null)
git_common_dir=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)
git_toplevel=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
diff_stat=$(git -C "$cwd" diff --cached --shortstat 2>/dev/null)
lines_added=$(echo "$diff_stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')
lines_removed=$(echo "$diff_stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+')
lines_added=${lines_added:-0}
lines_removed=${lines_removed:-0}
changed_count=$(git -C "$cwd" status --porcelain 2>/dev/null | grep -cE '^\?\?|^.[MDRC]' )
unpushed_count=$(git -C "$cwd" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)

# ANSI color codes: colored background
BLUE=$'\033[44;97m'      # blue bg, white text
GREEN=$'\033[42;30m'     # green bg, black text
YELLOW=$'\033[43;30m'    # yellow bg, black text
RED=$'\033[41;97m'       # red bg, white text
RESET=$'\033[0m'

# Foreground-only colors for the quota gauge — a background highlight would
# drown the ▰▱ glyphs, so the bar wears its health on the text instead.
FG_GREEN=$'\033[32m'
FG_YELLOW=$'\033[33m'
FG_RED=$'\033[31m'

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

# gauge pct — renders a 10-cell ▰▱ bar filled to pct% (nearest cell)
GAUGE_WIDTH=10
gauge() {
    local pct="$1"
    local filled=$(( (pct * GAUGE_WIDTH + 50) / 100 ))
    [ "$filled" -lt 0 ] && filled=0
    [ "$filled" -gt "$GAUGE_WIDTH" ] && filled="$GAUGE_WIDTH"

    local i out=""
    for (( i = 0; i < GAUGE_WIDTH; i++ )); do
        if [ "$i" -lt "$filled" ]; then out+="▰"; else out+="▱"; fi
    done
    printf "%s" "$out"
}

# colorize label raw_pct [reset_ts] — prints "label ▰▰▱▱ XX%" gauge of remaining
# quota, foreground-colored by threshold, with optional reset ETA as the label
colorize() {
    local label="$1"
    local val="$2"
    local reset_ts="$3"

    if [ -z "$val" ]; then
        if [ -n "$label" ]; then printf "%s: N/A" "$label"; else printf "N/A"; fi
        return
    fi

    local used_num remaining
    used_num=$(printf "%.0f" "$val")
    remaining=$(( 100 - used_num ))

    local color
    if [ "$remaining" -ge 50 ]; then
        color="$FG_GREEN"
    elif [ "$remaining" -ge 30 ]; then
        color="$FG_YELLOW"
    else
        color="$FG_RED"
    fi

    local display_label="$label"
    if [ -n "$reset_ts" ]; then
        local eta
        eta=$(rough_eta "$reset_ts")
        [ -n "$eta" ] && display_label="$eta"
    fi

    local prefix=""
    [ -n "$display_label" ] && prefix="$display_label "
    printf "%s%s%s %s%%%s" "$color" "$prefix" "$(gauge "$remaining")" "$remaining" "$RESET"
}

# colorize_temp weather_str — replaces the temperature value with a colored version
colorize_temp() {
    local str="$1"
    local temp_match temp_num color

    temp_match=$(echo "$str" | grep -oE '[+-]?[0-9]+°C' | head -1)
    [ -z "$temp_match" ] && { echo "$str"; return; }

    temp_num=$(echo "$temp_match" | grep -oE '[+-]?[0-9]+')

    # Drop the leading + on positive temps; keep the - on negatives.
    local temp_display="${temp_match#+}"

    if [ "$temp_num" -ge 30 ]; then
        color="$RED"
    elif [ "$temp_num" -ge 28 ]; then
        color="$YELLOW"
    elif [ "$temp_num" -ge 20 ]; then
        color="$GREEN"
    else
        color="$BLUE"
    fi

    echo "${str/${temp_match}/ ${color}${temp_display}${RESET}}"
}

# Weather with 30-minute cache
WEATHER_CACHE="/tmp/.claude_weather_cache"
weather="Weather N/A"

# mtime of a file, or 0 when it cannot be read. GNU (Linux, Git Bash) spells the
# format -c, BSD (macOS) spells it -f, and neither accepts the other's flag. GNU
# goes first because BSD stat bears no -c at all and so cannot answer it by
# accident, whereas GNU's -f means "filesystem status" and could in principle
# print something numeric before failing.
file_mtime() {
    stat -c "%Y" "$1" 2>/dev/null || stat -f "%m" "$1" 2>/dev/null || echo 0
}

if [ -f "$WEATHER_CACHE" ]; then
    cache_age=$(( $(date +%s) - $(file_mtime "$WEATHER_CACHE") ))
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

context_str=$(colorize "" "$context_raw")
rate_5h_str=$(colorize "5h" "$rate_5h_raw" "$rate_5h_reset")
rate_7d_str=$(colorize "7d" "$rate_7d_raw" "$rate_7d_reset")

# Format lines changed and unstaged/untracked counts
lines_str="+${lines_added}/-${lines_removed}"
changed_str="📄 ${changed_count}"
unpushed_str="⬆ ${unpushed_count}"

# Grammar error count for today
GRAMMAR_LOG="$HOME/.skadi/grammar_log"
TODAY=$(date +%Y-%m-%d)
grammar_today=0
if [ -f "$GRAMMAR_LOG" ]; then
    # grep -c already prints 0 on no match (and exits 1) — a `|| echo 0` would
    # add a second 0, making grammar_today the two-line "0\n0" that wraps the
    # statusline. Take grep's own count; default only if the read yields nothing.
    grammar_today=$(grep -c "^${TODAY}$" "$GRAMMAR_LOG" 2>/dev/null)
    grammar_today=${grammar_today:-0}
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

# account_badge — prints "<glyph>\t<label>" naming the Claude login this session
# runs under. Each ~/.claude* config root keeps its own .claude.json, so the
# root the session was launched against is the one that holds the truth; a team
# or enterprise login shows its organization, a personal one shows "personal",
# and a login that cannot be read falls back to the profile's own name.
account_badge() {
    local config_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claude.json"
    local account_raw org_type org_name
    account_raw=$(jq -r '.oauthAccount | [.organizationType // "", .organizationName // ""] | @tsv' "$config_file" 2>/dev/null)
    IFS=$'\t' read -r org_type org_name <<< "$account_raw"

    local glyph label=""
    case "$org_type" in
        claude_team|claude_enterprise)
            glyph="🏢"
            label=$(echo "${org_name%% *}" | tr '[:upper:]' '[:lower:]')
            ;;
        claude_max|claude_pro|claude_free)
            glyph="🏠"
            label="personal"
            ;;
    esac

    if [ -z "$label" ]; then
        glyph="🔑"
        label="${SKADI_PROFILE:-unknown}"
    fi
    printf "%s\t%s" "$glyph" "$label"
}

# Line 1: project name + worktree name (if any) + branch
project_name=$(basename "$cwd")
worktree_name=""
if [ -n "$git_common_dir" ] && [ "$git_dir" != "$git_common_dir" ]; then
    project_name=$(basename "$(dirname "$git_common_dir")")
    worktree_name=$(basename "$git_toplevel")
fi
project_label=$(ellipsize_end "$project_name" 25)
branch_label=$(ellipsize_end "${git_branch:-N/A}" 35)
worktree_segment=""
[ -n "$worktree_name" ] && worktree_segment="🌳 $(ellipsize_end "$worktree_name" 25)  "
printf "📁 %s  %s🌿 %s\n" "$project_label" "$worktree_segment" "$branch_label"

# Line 2: branch info
printf "✏️ %s  %s  %s  %s\n" "$lines_str" "$changed_str" "$unpushed_str" "$grammar_str"

# Line 3: model + login badge + context gauge
IFS=$'\t' read -r account_emoji account_short <<< "$(account_badge)"
account_short=$(ellipsize_end "$account_short" 12)
printf "%s %s  %s %s  📊 %s\n" "$model_emoji" "$model_short" "$account_emoji" "$account_short" "$context_str"

# Line 4: quota gauges (5h + 7d) — split off so the three bars don't overrun one line
printf "⚡ %s  📅 %s\n" "$rate_5h_str" "$rate_7d_str"

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

# Proverbs
proverbs=(
    "Break a leg."
    "A bird in the hand is worth two in the bush."
    "Actions speak louder than words."
    "The early bird catches the worm."
    "Don't count your chickens before they hatch."
    "When in Rome, do as the Romans do."
    "The pen is mightier than the sword."
    "Rome wasn't built in a day."
    "A journey of a thousand miles begins with a single step."
    "Don't put all your eggs in one basket."
    "Practice makes perfect."
    "Honesty is the best policy."
    "Where there's a will, there's a way."
    "Necessity is the mother of invention."
    "Fortune favours the bold."
    "Look before you leap."
    "A stitch in time saves nine."
    "Better late than never."
    "Every cloud has a silver lining."
    "Don't judge a book by its cover."
    "The grass is always greener on the other side."
    "Two wrongs don't make a right."
    "When the going gets tough, the tough get going."
    "Slow and steady wins the race."
    "All that glitters is not gold."
    "Out of sight, out of mind."
    "Curiosity killed the cat."
    "Birds of a feather flock together."
    "Absence makes the heart grow fonder."
    "A penny saved is a penny earned."
    "Don't bite the hand that feeds you."
    "If it ain't broke, don't fix it."
    "Measure twice, cut once."
    "The squeaky wheel gets the grease."
    "You can't have your cake and eat it too."
    "Easy come, easy go."
    "Many hands make light work."
    "Too many cooks spoil the broth."
    "Strike while the iron is hot."
    "A chain is only as strong as its weakest link."
    "Don't cross the bridge until you come to it."
    "The apple doesn't fall far from the tree."
    "People who live in glass houses shouldn't throw stones."
    "A rolling stone gathers no moss."
    "Good things come to those who wait."
    "Hope for the best, prepare for the worst."
    "Cut your coat according to your cloth."
    "Still waters run deep."
    "The proof of the pudding is in the eating."
    "A watched pot never boils."
    "What goes around comes around."
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

# The Lord of the Rings quotes
lotr_quotes=(
    "All we have to decide is what to do with the time that is given us. — Gandalf"
    "Even the smallest person can change the course of the future. — Galadriel"
    "Not all those who wander are lost. — Bilbo Baggins"
    "You shall not pass! — Gandalf"
    "I am no man. — Éowyn"
    "My precious. — Gollum"
    "One does not simply walk into Mordor. — Boromir"
    "Fly, you fools! — Gandalf"
    "I can't carry it for you, but I can carry you. — Samwise Gamgee"
    "There's some good in this world, Mr. Frodo — and it's worth fighting for. — Samwise Gamgee"
    "A wizard is never late, Frodo Baggins. Nor is he early. He arrives precisely when he means to. — Gandalf"
    "The board is set, the pieces are moving. — Gandalf"
    "Death is just another path, one that we all must take. — Gandalf"
    "I would have followed you, my brother, my captain, my king. — Boromir"
    "Po-ta-toes! Boil 'em, mash 'em, stick 'em in a stew. — Samwise Gamgee"
    "I'm going on an adventure! — Bilbo Baggins"
    "It's a dangerous business, Frodo, going out your door. — Bilbo Baggins"
    "The Ring has awoken. It's heard its master's call. — Gandalf"
    "Courage is found in unlikely places. — Gildor (via Gandalf)"
    "And my axe! — Gimli"
    "One Ring to rule them all, One Ring to find them, One Ring to bring them all, and in the darkness bind them. — The Ring inscription"
    "Speak, friend, and enter. — The Doors of Durin"
    "I am Gandalf the White. And I come back to you now at the turn of the tide. — Gandalf"
    "Nobody tosses a dwarf. — Gimli"
    "I would rather share one lifetime with you than face all the ages of this world alone. — Arwen"
    "For Frodo. — Aragorn"
    "My friends, you bow to no one. — Aragorn"
    "A day may come when the courage of men fails, but it is not this day. — Aragorn"
    "Certainty of death. Small chance of success. What are we waiting for? — Gimli"
    "So it begins. — Théoden"
    "Ride now, ride now, ride! Ride to ruin and the world's ending! — Théoden"
    "Forth Eorlingas! — Théoden"
    "The Ring-bearer is setting out on the Quest of Mount Doom. — Elrond"
    "Nine companions. So be it. You shall be the Fellowship of the Ring. — Elrond"
    "We wants it, we needs it. Must have the precious. — Gollum"
    "Sneaky little hobbitses. Wicked, tricksy, false. — Gollum"
    "What about second breakfast? — Pippin"
    "I don't think he knows about second breakfast, Pip. — Merry"
    "I'm glad you're with me, Samwise Gamgee. Here at the end of all things. — Frodo"
    "Well, I'm back. — Samwise Gamgee"
    "I am a servant of the Secret Fire, wielder of the flame of Anor. — Gandalf"
    "Fool of a Took! — Gandalf"
    "Keep it secret. Keep it safe. — Gandalf"
    "Don't be hasty. — Treebeard"
    "A red sun rises. Blood has been spilled this night. — Legolas"
    "They're taking the hobbits to Isengard! — Legolas"
    "I made a promise, Mr. Frodo. A promise. 'Don't you leave him, Samwise Gamgee.' And I don't mean to. — Samwise Gamgee"
    "I will not say: do not weep, for not all tears are an evil. — Gandalf"
    "Strangers from distant lands, friends of old. You have been summoned here to answer the threat of Mordor. — Elrond"
    "Middle-earth stands upon the brink of destruction. None can escape it. You will unite, or you will fall. — Elrond"
    "Bring forth the Ring, Frodo. — Elrond"
    "The Ring cannot be destroyed by any craft that we here possess. It must be cast back into the fiery chasm from whence it came. — Elrond"
    "It is hardly possible to separate you, even when he is summoned to a secret council and you are not. — Elrond"
    "It is a gift. A gift to the foes of Mordor. Why not use this Ring? — Boromir"
    "Gondor has no king. Gondor needs no king. — Boromir"
    "You carry the fate of us all, little one. If this is indeed the will of the Council, then Gondor will see it done. — Boromir"
    "You cannot wield it. None of us can. The One Ring answers to Sauron alone. — Aragorn"
    "Havo dad, Legolas. (Sit down, Legolas.) — Aragorn"
    "If by my life or death I can protect you, I will. You have my sword. — Aragorn"
    "This is no mere Ranger. He is Aragorn, son of Arathorn. You owe him your allegiance. — Legolas"
    "Have you heard nothing Lord Elrond has said? The Ring must be destroyed! — Legolas"
    "And you have my bow. — Legolas"
    "I will be dead before I see the Ring in the hands of an Elf! — Gimli"
    "I will take it. I will take the Ring to Mordor. Though — I do not know the way. — Frodo"
    "I will help you bear this burden, Frodo Baggins, as long as it is yours to bear. — Gandalf"
    "Hey! Mr. Frodo's not going anywhere without me! — Samwise Gamgee"
    "Anyway, you need people of intelligence on this sort of mission... quest... thing. — Merry"
    "You'd have to send us home tied up in a sack to stop us! — Pippin"
    "Great! Where are we going? — Pippin"
)

# Band of Brothers quotes
band_of_brothers_quotes=(
    "Hang tough. — Richard Winters"
    "We salute the rank, not the man. — Richard Winters"
    "We're paratroopers, Lieutenant. We're supposed to be surrounded. — Richard Winters"
    "You don't want to be a good officer, Nix. You don't want the responsibility. — Richard Winters"
    "I cherish the memories of a question my grandson asked me: 'Grandpa, were you a hero in the war?' Grandpa said, 'No, but I served in a company of heroes.' — Richard Winters (quoting Mike Ranney)"
    "The only hope you have is to accept the fact that you're already dead. — Ronald Speirs"
    "War brings out the worst in some and the best in others. — Ronald Speirs"
    "You think you can lead this platoon? — Richard Winters / — Yes, sir. — Ronald Speirs"
    "Three days in Eindhoven and everybody's a lover. — Lewis Nixon"
    "We're not lost, Private. We're in Normandy. — Richard Winters"
    "I'm not a coward, Captain. I'm just not that brave. — Albert Blithe"
    "Just hold my hand, then I won't be scared. — Albert Blithe"
    "You listen up! You're not the only man here with problems! — Carwood Lipton"
    "Currahee. — 506th PIR motto"
    "We stand alone together. — 506th PIR"
    "Men, it's been a long war, it's been a tough war. You've fought bravely, proudly for your country. You're a special group. You've found in one another a bond that exists only in combat, among brothers. — Richard Winters"
    "I found my peace in a foxhole. — Eugene Roe (paraphrased)"
    "Flash. — Thunder. — challenge and countersign, Normandy"
    "That's why I don't pray. I put my faith in something stronger. — Lewis Nixon (paraphrased)"
    "Who's the CO here? — I am. — Speirs. Good to have you with us. — Ronald Speirs to Easy"
    "They call me 'Wild Bill.' I like that. — William 'Wild Bill' Guarnere"
    "Gonna, gonna, gonna. You never do. — Joseph Toye"
    "I swear to God, Bull. You wanna know what your problem is? You care too much. — George Luz (paraphrased)"
    "Sir, there's a rumor we're going to be sent home. — Carwood Lipton"
    "We're all replacements, Private, one way or another. — Ronald Speirs"
)

# Person of Interest quotes
person_of_interest_quotes=(
    "You are being watched. — Harold Finch"
    "The government has a secret system: a machine that spies on you every hour of every day. — Harold Finch"
    "I know, because I built it. — Harold Finch"
    "I find it best to assume the worst. — John Reese"
    "Everyone is relevant to someone. — Root"
    "Can you hear me? — Root"
    "If you can hear this, you're alone. The only thing left of us is the sound of my voice. — The Machine"
    "Mr. Reese. — Harold Finch"
    "I have a job for you, Mr. Reese. — Harold Finch"
    "I'm a concerned third party. — John Reese"
    "We were never here. — John Reese"
    "There are no good or bad coders. There's just code. — Root (paraphrased)"
    "Everyone dies alone. But if you meant something to someone, then maybe you never really die. — John Reese (paraphrased)"
    "She's my friend, and she's going to save us all. — Root (paraphrased)"
    "You taught me to see everyone. — The Machine (paraphrased)"
    "We all have a part to play. — The Machine (paraphrased)"
    "Goodbye, Harold. Thank you for creating me. — The Machine (paraphrased)"
    "People are going to die, and I can stop it. — Harold Finch (paraphrased)"
)

# Build pool of available categories
pool=("wick" "mentalist")
[ ${#proverbs[@]} -gt 0 ] && pool+=("proverb")
[ ${#accountant_quotes[@]} -gt 0 ] && pool+=("accountant")
[ ${#suits_quotes[@]} -gt 0 ] && pool+=("suits")
[ ${#lotr_quotes[@]} -gt 0 ] && pool+=("lotr")
[ ${#band_of_brothers_quotes[@]} -gt 0 ] && pool+=("band")
[ ${#person_of_interest_quotes[@]} -gt 0 ] && pool+=("poi")
chosen="${pool[$RANDOM % ${#pool[@]}]}"

case "$chosen" in
    wick)       display_quote="🔫 \"${wick_quotes[$RANDOM % ${#wick_quotes[@]}]}\"";;
    proverb)    display_quote="📜 \"${proverbs[$RANDOM % ${#proverbs[@]}]}\"";;
    accountant) display_quote="🧮 \"${accountant_quotes[$RANDOM % ${#accountant_quotes[@]}]}\"";;
    mentalist)  display_quote="🔮 \"${mentalist_quotes[$RANDOM % ${#mentalist_quotes[@]}]}\"";;
    suits)      display_quote="👔 \"${suits_quotes[$RANDOM % ${#suits_quotes[@]}]}\"";;
    lotr)       display_quote="💍 \"${lotr_quotes[$RANDOM % ${#lotr_quotes[@]}]}\"";;
    band)       display_quote="🎖️ \"${band_of_brothers_quotes[$RANDOM % ${#band_of_brothers_quotes[@]}]}\"";;
    poi)        display_quote="👁️ \"${person_of_interest_quotes[$RANDOM % ${#person_of_interest_quotes[@]}]}\"";;
esac

# Line 4: divider
printf "%s\n" "──────────────────────────────────────────────────"

# Sunrise/sunset + moon phase from wttr.in, refreshed once per day (they shift only daily)
SUN_CACHE="/tmp/.claude_sun_cache"
sun_raw=""
today=$(date +%Y-%m-%d)
if [ -f "$SUN_CACHE" ] && [ "$(head -1 "$SUN_CACHE" 2>/dev/null)" = "$today" ]; then
    sun_raw=$(tail -1 "$SUN_CACHE")
fi
# A cache from the old single-clock format lacks the sunrise field — refetch when so
if [ "$(echo "$sun_raw" | grep -oE '[0-9]{2}:[0-9]{2}' | wc -l | tr -d ' ')" -lt 2 ]; then
    sun_raw=""
fi
if [ -z "$sun_raw" ]; then
    fetched=$(curl -s --max-time 3 "wttr.in/?format=%S+%s+%m" 2>/dev/null)
    if [ "$(echo "$fetched" | grep -oE '[0-9]{2}:[0-9]{2}' | wc -l | tr -d ' ')" -ge 2 ]; then
        sun_raw="$fetched"
        printf "%s\n%s\n" "$today" "$sun_raw" > "$SUN_CACHE"
    elif [ -f "$SUN_CACHE" ]; then
        sun_raw=$(tail -1 "$SUN_CACHE")
    fi
fi

# sun_raw is "HH:MM:SS HH:MM:SS 🌔" — sunrise, sunset, moon glyph
sunrise_time=$(echo "$sun_raw" | awk '{print $1}' | cut -d: -f1-2)
sunset_time=$(echo "$sun_raw" | awk '{print $2}' | cut -d: -f1-2)
moon_glyph=$(echo "$sun_raw" | awk '{print $NF}')

# After sunset+3h show the coming sunrise; after sunrise+3h show the coming sunset.
# The glyph follows the time shown: 🌅 sunrise, 🌇 sunset.
SUN_SHIFT_MIN=180
sun_label="$sunset_time"
sun_glyph="🌇"
if [ -n "$sunrise_time" ] && [ -n "$sunset_time" ]; then
    now_min=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
    sunrise_min=$(( 10#${sunrise_time%:*} * 60 + 10#${sunrise_time#*:} ))
    sunset_min=$(( 10#${sunset_time%:*} * 60 + 10#${sunset_time#*:} ))
    rise_switch=$(( (sunrise_min + SUN_SHIFT_MIN) % 1440 ))   # sunrise+3h: back to sunset
    set_switch=$(( (sunset_min + SUN_SHIFT_MIN) % 1440 ))     # sunset+3h: ahead to sunrise
    # Show sunrise while now lies in the cyclic arc [set_switch, rise_switch)
    in_rise_arc=0
    if [ "$set_switch" -le "$rise_switch" ]; then
        if [ "$now_min" -ge "$set_switch" ] && [ "$now_min" -lt "$rise_switch" ]; then
            in_rise_arc=1
        fi
    elif [ "$now_min" -ge "$set_switch" ] || [ "$now_min" -lt "$rise_switch" ]; then
        in_rise_arc=1
    fi
    if [ "$in_rise_arc" = "1" ]; then
        sun_label="$sunrise_time"
        sun_glyph="🌅"
    fi
fi

# Line 5: weather + sun time & moon
if [ -n "$sun_label" ]; then
    printf "%s  %s %s  %s\n" "$weather" "$sun_glyph" "$sun_label" "$moon_glyph"
else
    printf "%s\n" "$weather"
fi

# Line 6: quote (wrap at 64 columns; continuation lines hang under the opening ")
# Lead with '|' — Claude Code's statusline trims leading whitespace, so anchor with a visible char.
quote_indent='|   '
printf "%s\n" "$display_quote" | fold -s -w 60 | awk -v ind="$quote_indent" 'NR==1 {print; next} {print ind $0}'
