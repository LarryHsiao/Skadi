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

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
