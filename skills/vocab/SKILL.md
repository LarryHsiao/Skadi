---
name: vocab
description: Use when the user runs /vocab <word>, /vocab review [n], or /vocab list. Stores English / Traditional Chinese flashcards under ~/.skadi/vocab/, surfaces them with spaced repetition, and tracks review state.
---

# Vocabulary Skill

A personal vocabulary deck. Each lookup writes a card; the review verb walks the cards that fall due, scoring each by self-recall.

## Storage

- One card per file at `~/.skadi/vocab/<slug>.md`.
- `<slug>` = the word lowercased; whitespace becomes `_` (so `in lieu of` → `in_lieu_of`).
- SRS state lives in YAML-ish frontmatter; the meaning lives in the body.

Card shape:

```markdown
---
word: serendipity
ease: 2.5
interval: 1
hits: 0
last_reviewed: 2026-04-27
created: 2026-04-27
---

**EN:** the occurrence of events by chance in a happy or beneficial way.

**ZH-TW:** 機緣巧合；意外的好運。

**Example:** They met by serendipity at a quiet bookstore.
```

`interval` is in days. `ease` is the multiplier used when bumping the interval. `hits` counts how many times the user has scored the card `good` — at `10` the card has graduated and is removed from the deck. `last_reviewed` and `created` are `YYYY-MM-DD` and come from `date +%Y-%m-%d` — never guess.

## Argument parsing

`/vocab [verb-or-word] [...rest]`

- No arg or `help` → print the three verbs and stop.
- `review [n]` → walk up to `n` due cards (default `5`).
- `list` → show every card with its due state.
- Anything else → treat the whole argument as a word (or short phrase) to look up.

## Verb: lookup (default)

`/vocab <word>`

### 1. Slugify and check for an existing card

```bash
slug=$(printf '%s' "<word>" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
test -f "$HOME/.skadi/vocab/$slug.md"
```

If the card exists, read it with the Read tool, render it to the user, and append "(already in deck — review state preserved)". Stop here.

### 2. Resolve the meaning

Provide:

- **EN definition** — concise, the most common sense first; if highly polysemous, list 2–3 senses as bullets.
- **ZH-TW translation** — Traditional Chinese (繁體中文) only, never Simplified.
- **Example** — one short sentence using the word in plain context.

### 3. Write the card

Use the Write tool to create `~/.skadi/vocab/<slug>.md` with the shape shown above. Set `last_reviewed` and `created` to today (`date +%Y-%m-%d`), `ease` to `2.5`, `interval` to `1`, `hits` to `0`.

### 4. Render

Show the card body to the user, prefaced by a single line: "Stored — first review tomorrow."

## Verb: review

`/vocab review [n]`  (default `n = 5`)

### 1. Fetch the deck state

Run the cards hook:

```bash
~/.claude/hooks/vocab-cards.sh
```

Output is TSV: `word \t ease \t interval \t last_reviewed \t due_in_days`.

Filter rows where `due_in_days <= 0`, sort ascending by `due_in_days` (most overdue first), and take the first `n`.

If the deck is empty: tell the user "Deck is empty — seed it with `/vocab <word>`." and stop.
If nothing is due: tell the user "Nothing due today — next card surfaces in M day(s)." where `M` is the smallest positive `due_in_days`. Stop.

### 2. Walk each due card, one at a time

For each card in turn:

a. Read the card file (`~/.skadi/vocab/<word>.md`) so the body and current state are in hand.

b. Show **only the word** to the user and ask them to recall the meaning out loud or in chat. Wait for their reply.

c. Reveal the card body (EN + ZH-TW + example).

d. Ask via `AskUserQuestion` for the self-score:
   - `forgot` — couldn't recall it
   - `hard`   — struggled but got there
   - `good`   — recalled it cleanly
   - `easy`   — instant recall

e. Compute the new state:

| Score    | New `ease`                | New `interval` (days)                   |
|----------|---------------------------|-----------------------------------------|
| `forgot` | `max(1.3, ease - 0.20)`   | `1`                                     |
| `hard`   | `max(1.3, ease - 0.15)`   | `max(1, round(interval * 1.2))`         |
| `good`   | `ease` (unchanged)        | `round(interval * ease)`                |
| `easy`   | `ease + 0.15`             | `round(interval * ease * 1.3)`          |

Round intervals to whole days. Clamp `ease` at a floor of `1.3`. Keep `ease` to one decimal place.

f. If the score is `good`, increment `hits` by `1`. Other scores leave `hits` unchanged. (Reading: a card "answered" is one recalled cleanly; struggle, instant flash, and outright miss are not answers.)

g. **Retire-or-update.** If `hits` has just reached `10`, the card has graduated — delete it instead of writing the new state:

```bash
rm "$HOME/.skadi/vocab/<word>.md"
```

Otherwise update the card with the Edit tool — the four frontmatter lines `ease:`, `interval:`, `hits:`, `last_reviewed:`. Set `last_reviewed` to today.

h. Move on to the next card.

### 3. Summary

After the walk, print a single line:

```
Reviewed N · forgot=A · hard=B · good=C · easy=D · retired=R · next due in M day(s)
```

`R` is the count of cards that graduated this session (hit `hits == 10`). `M` is the smallest new interval just set among the cards that survived; if every reviewed card retired, omit the "next due" tail.

## Verb: list

`/vocab list`

Run `~/.claude/hooks/vocab-cards.sh` and render every row as a table sorted by `due_in_days` ascending:

```
WORD          DUE       INT  EASE  LAST
ephemeral     overdue   3    2.3   2026-04-22  (-2)
serendipity   today     1    2.5   2026-04-27
liminal       in 3d     7    2.65  2026-04-24
```

`DUE` column:
- `due_in_days < 0` → `overdue` plus `(<due_in_days>)` at the end of the row
- `due_in_days == 0` → `today`
- `due_in_days > 0` → `in Nd`

If the deck is empty, say so and suggest `/vocab <word>` to seed it.

## Rules

- Always Traditional Chinese (繁體) for ZH-TW. Never Simplified.
- One word (or short phrase) per file. Lowercase slug, underscores for spaces.
- `date +%Y-%m-%d` is the source of truth for today — never the date in memory or the model's guess.
- Round intervals to whole days; clamp ease at `1.3`.
- The review verb walks one card at a time. Do not batch-reveal.
- Never overwrite an existing card on lookup — preserve its SRS state.
- The vocab directory is created lazily by the hook; do not pre-create it from the skill.
- A card retires (file deleted) the moment `hits` reaches `10`. Only `good` scores count toward `hits`; `forgot`, `hard`, and `easy` leave it untouched. Cards lacking a `hits:` line are read as `hits: 0`.
