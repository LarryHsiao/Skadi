#!/bin/bash
# Offline tests for skills-cheatsheet-render.py. Builds a throwaway skills/
# folder with SKILL.md fixtures and checks the rendered HTML. Run:
#   bash skills-cheatsheet-render.test.sh
set -uo pipefail

RENDER="$(cd "$(dirname "$0")" && pwd)/skills-cheatsheet-render.py"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

contains() {
  if grep -qF "$2" "$3"; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — [$2] not found in $3"; fail=$((fail + 1)); fi
}

# ── fixtures ──
skills="$ROOT/skills"
mkdir -p "$skills/zed-skill" "$skills/amon-din-like"

cat >"$skills/zed-skill/SKILL.md" <<'EOF'
---
name: zed-skill
description: Zed does the last thing alphabetically.
user_invocable: true
---

# Zed
EOF

# A SKILL.md whose prose carries a decoy "name:"/"description:" example block,
# mirroring amon-din — only the leading frontmatter must be parsed.
cat >"$skills/amon-din-like/SKILL.md" <<'EOF'
---
name: amon-din-like
description: Watches CI runs & reports <status>.
user_invocable: true
---

# Amon-din-like

Example config:

```yaml
name: CI Routing
description: This project's CI binding for /amon-din
```
EOF

dest="$ROOT/out/skills-cheatsheet.html"
python3 "$RENDER" "$skills" "$dest" >/dev/null

# ── 1 · both real skills present, sorted, decoy ignored ──
contains "real skill zed-skill listed" '/zed-skill' "$dest"
contains "real skill amon-din-like listed" '/amon-din-like' "$dest"
contains "real description rendered" 'Watches CI runs' "$dest"
decoy_count=$(grep -c '/CI Routing' "$dest" || true)
check "decoy frontmatter not parsed as a skill" "0" "$decoy_count"

# ── 2 · sorted alphabetically: amon-din-like before zed-skill ──
pos_amon=$(grep -n '/amon-din-like' "$dest" | head -1 | cut -d: -f1)
pos_zed=$(grep -n '/zed-skill' "$dest" | head -1 | cut -d: -f1)
check "amon-din-like sorts before zed-skill" "1" "$([[ "$pos_amon" -lt "$pos_zed" ]] && echo 1 || echo 0)"

# ── 3 · escaping — a description with & < > renders safely ──
mkdir -p "$skills/escape-me"
cat >"$skills/escape-me/SKILL.md" <<'EOF'
---
name: escape-me
description: Reads A & B, checks x<y, then y>x.
---
EOF
python3 "$RENDER" "$skills" "$dest" >/dev/null
contains "ampersand escaped" 'A &amp; B' "$dest"
contains "angle brackets escaped" 'x&lt;y' "$dest"

# ── 4 · charset line first, favicon present ──
first_line=$(head -1 "$dest")
check "meta charset is the first line" '<meta charset="utf-8">' "$first_line"
contains "favicon present" 'rel="icon"' "$dest"

# ── 5 · a folder with no SKILL.md renders an empty (not broken) page ──
empty_skills="$ROOT/empty-skills"
mkdir -p "$empty_skills"
empty_dest="$ROOT/out/empty.html"
python3 "$RENDER" "$empty_skills" "$empty_dest" >/dev/null
contains "zero-skill count rendered" '0 skills' "$empty_dest"

# ── 6 · grouping — a mapped skill lands under its purpose heading ──
mkdir -p "$skills/council"
cat >"$skills/council/SKILL.md" <<'EOF'
---
name: council
description: Convenes a planning council on a tracker ticket.
user_invocable: true
---

# Council
EOF
python3 "$RENDER" "$skills" "$dest" >/dev/null
contains "mapped skill's group heading rendered" 'Plan &amp; Council' "$dest"
contains "unmapped skill falls into Other" 'Other' "$dest"
pos_group_hd=$(grep -n 'Plan &amp; Council' "$dest" | head -1 | cut -d: -f1)
pos_council_card=$(grep -n '/council<' "$dest" | head -1 | cut -d: -f1)
check "council card sits after its group heading" "1" "$([[ "$pos_council_card" -gt "$pos_group_hd" ]] && echo 1 || echo 0)"

# ── 7 · responsive grid — 3 columns wide, narrowing at smaller widths ──
contains "grid uses a 3-column layout" 'repeat(3, minmax(0, 1fr))' "$dest"
contains "grid narrows to 2 columns on a medium viewport" 'repeat(2, minmax(0, 1fr))' "$dest"

# ── 8 · a long description is shortened on the card, full text kept for hover + search ──
mkdir -p "$skills/long-desc"
cat >"$skills/long-desc/SKILL.md" <<'EOF'
---
name: long-desc
description: Use when the user runs this at length, because the real frontmatter descriptions in this repo tend to run well past a hundred characters and would otherwise wrap a card into a tall, uneven block.
user_invocable: true
---

# Long desc
EOF
python3 "$RENDER" "$skills" "$dest" >/dev/null
visible_ds=$(python3 -c "
import re
text = open('$dest').read()
m = re.search(r'/long-desc</div><div class=\"ds\"[^>]*>([^<]*)</div>', text)
print(m.group(1) if m else '')
")
check "long description's visible text is capped" "1" "$(echo "$visible_ds" | grep -c '…' || true)"
check "the visible card text does not carry the full sentence" "0" "$(echo "$visible_ds" | grep -c 'uneven block\.' || true)"
contains "full description kept as a hover tooltip" 'title="Use when the user runs this at length' "$dest"
contains "full description still searchable in data-hay" 'uneven block' "$dest"

# ── 9 · a purpose: field is preferred on the card; description stays the tooltip + search text ──
mkdir -p "$skills/has-purpose"
cat >"$skills/has-purpose/SKILL.md" <<'EOF'
---
name: has-purpose
description: Use when the user runs /has-purpose <ticket-id> [--flag] — argument-heavy trigger text for Claude's own routing, not for a human reader.
purpose: Does the one clean thing a human would want to read.
user_invocable: true
---

# Has purpose
EOF
python3 "$RENDER" "$skills" "$dest" >/dev/null
visible_purpose_ds=$(python3 -c "
import re
text = open('$dest').read()
m = re.search(r'/has-purpose</div><div class=\"ds\"[^>]*>([^<]*)</div>', text)
print(m.group(1) if m else '')
")
check "purpose text shown on the card, not the raw description" "Does the one clean thing a human would want to read." "$visible_purpose_ds"
contains "full description still kept as the hover tooltip" 'title="Use when the user runs /has-purpose' "$dest"
contains "full description still searchable in data-hay" 'argument-heavy trigger text' "$dest"
contains "purpose text also searchable in data-hay" 'the one clean thing' "$dest"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
