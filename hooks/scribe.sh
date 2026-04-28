#!/bin/bash
# scribe.sh — export a Minerva markdown section as one issue.
#
# Usage:
#   scribe.sh <file> <heading-slug> --project=<KEY> [--target=youtrack|disk] [--commit]
#
# Step 2 of the build is dry-run only: prints the rendered issue body and the
# would-be POST/disk write, performs no network or filesystem writes. The
# --commit flag is reserved for later steps and currently a no-op (still dry).
#
# Resolves the section heading by fuzzy slug match (case- and punctuation-
# tolerant, contiguous tokens) against `## Epic ...` headings only. On zero or
# multiple matches, lists candidates and exits non-zero.

set -euo pipefail
export LC_ALL=C.UTF-8

# ---------- arg parsing ----------

FILE=""
SLUG=""
PROJECT=""
TARGET="youtrack"
COMMIT=0
FORCE=0
WITH_SUBTASKS=0
SCREENSHOT_PATH=""

# Duplicate-detected exit code, surfaced so the skill can prompt the user and
# re-invoke with --force.
EXIT_DUPLICATE=75

usage() {
  echo "Usage: $0 <file> <heading-slug> --project=<KEY> [--target=youtrack|disk] [--commit] [--force] [--with-subtasks] [--screenshot-path=<png>]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project=*)         PROJECT="${1#*=}" ;;
    --target=*)          TARGET="${1#*=}" ;;
    --screenshot-path=*) SCREENSHOT_PATH="${1#*=}" ;;
    --commit)            COMMIT=1 ;;
    --force)             FORCE=1 ;;
    --with-subtasks)     WITH_SUBTASKS=1 ;;
    -h|--help)           usage; exit 0 ;;
    -*)                  echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *)                   if   [[ -z "$FILE" ]]; then FILE="$1"
                         elif [[ -z "$SLUG" ]]; then SLUG="$1"
                         else echo "unexpected positional arg: $1" >&2; usage; exit 2
                         fi ;;
  esac
  shift
done

[[ -z "$FILE"    ]] && { echo "missing <file>" >&2;          usage; exit 2; }
[[ -z "$SLUG"    ]] && { echo "missing <heading-slug>" >&2;  usage; exit 2; }
[[ -z "$PROJECT" ]] && { echo "missing --project=<KEY>" >&2; usage; exit 2; }
[[ ! -f "$FILE"  ]] && { echo "file not found: $FILE" >&2;   exit 2; }

case "$TARGET" in
  youtrack|disk) ;;
  *) echo "invalid --target: $TARGET (must be youtrack or disk)" >&2; exit 2 ;;
esac

# ---------- normalize: lowercase, strip punctuation, collapse whitespace ----------

normalize() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c '[:alnum:][:space:]' ' ' \
    | tr -s '[:space:]' ' ' \
    | sed -e 's/^ *//' -e 's/ *$//'
}

NORM_SLUG="$(normalize "$SLUG")"
[[ -z "$NORM_SLUG" ]] && { echo "slug is empty after normalization" >&2; exit 2; }

# ---------- collect Epic headings and fuzzy-match ----------

# headings: array of "linenum<TAB>raw heading text (without leading '## ')"
HEADINGS=()
while IFS= read -r line; do
  HEADINGS+=("$line")
done < <(awk '
  /^## / {
    text = substr($0, 4)
    if (tolower(text) ~ /^epic/) print NR "\t" text
  }
' "$FILE")

if [[ ${#HEADINGS[@]} -eq 0 ]]; then
  echo "no '## Epic ...' headings found in $FILE" >&2
  exit 2
fi

MATCH_LINE=""
MATCH_TEXT=""
MATCH_COUNT=0
CANDIDATES=()
# Strip any HTML comment markers (e.g. `<!-- yt: JVC-5 -->`, `<!-- jira: ... -->`)
# from a heading's display text so they do not bleed into titles, slugs, or
# normalized strings used for fuzzy matching.
strip_markers() {
  printf '%s' "$1" | sed -E 's/<!--[^>]*-->//g' | sed -E 's/[[:space:]]+$//'
}

for h in "${HEADINGS[@]}"; do
  ln="${h%%	*}"
  txt="${h#*	}"
  txt_clean="$(strip_markers "$txt")"
  norm="$(normalize "$txt_clean")"
  CANDIDATES+=("$txt_clean")
  if [[ " $norm " == *" $NORM_SLUG "* ]]; then
    MATCH_LINE="$ln"
    MATCH_TEXT="$txt_clean"
    MATCH_COUNT=$((MATCH_COUNT + 1))
  fi
done

if [[ $MATCH_COUNT -eq 0 ]]; then
  echo "no epic heading matches slug '$SLUG'. candidates:" >&2
  for c in "${CANDIDATES[@]}"; do echo "  - $c" >&2; done
  exit 2
fi
if [[ $MATCH_COUNT -gt 1 ]]; then
  echo "slug '$SLUG' matches multiple epics; tighten it. candidates:" >&2
  for c in "${CANDIDATES[@]}"; do
    norm="$(normalize "$c")"
    if [[ " $norm " == *" $NORM_SLUG "* ]]; then echo "  - $c" >&2; fi
  done
  exit 2
fi

# ---------- slice the section: from MATCH_LINE up to next '## ' or EOF ----------

SECTION_BODY="$(awk -v start="$MATCH_LINE" '
  NR < start { next }
  NR == start { in_section = 1; next }      # skip the heading line itself
  in_section && /^## / { exit }              # next top-level heading ends the section
  in_section && /^---[[:space:]]*$/ { exit } # also stop on horizontal rule separator
  in_section { print }
' "$FILE")"

# Strip trailing blank lines from section body
SECTION_BODY="$(printf '%s' "$SECTION_BODY" | awk 'NF{p=1} p' | awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--){if(lines[i] ~ /[^[:space:]]/){last=i;break}} for(i=1;i<=last;i++) print lines[i]}')"

# ---------- locate the source Figma node id and file's source line ----------

SOURCE_LINE="$(grep -m1 -E '_Source: Figma frame' "$FILE" || true)"
FIGMA_NODE_ID=""
if [[ -n "$SOURCE_LINE" ]]; then
  FIGMA_NODE_ID="$(printf '%s' "$SOURCE_LINE" | grep -oE '`[0-9]+:[0-9]+`' | tr -d '`' || true)"
fi

# ---------- locate Open Questions block (file-level) ----------

OPEN_QUESTIONS="$(awk '
  /^## Open Questions[[:space:]]*$/ { in_oq = 1; next }
  in_oq && /^## / { exit }
  in_oq { print }
' "$FILE")"

# Strip leading and trailing blank lines from OQ
OPEN_QUESTIONS="$(printf '%s' "$OPEN_QUESTIONS" | awk 'NF{p=1} p' | awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--){if(lines[i] ~ /[^[:space:]]/){last=i;break}} for(i=1;i<=last;i++) print lines[i]}')"

# ---------- look for jira marker on or near the heading ----------

JIRA_KEY=""
# Search the heading line itself plus the next 20 lines for a marker.
JIRA_KEY="$(awk -v start="$MATCH_LINE" -v end="$((MATCH_LINE + 20))" '
  NR >= start && NR <= end { print }
' "$FILE" | grep -oE '<!--[[:space:]]*jira:[[:space:]]*[A-Z][A-Z0-9]*-[0-9]+' \
  | head -1 \
  | grep -oE '[A-Z][A-Z0-9]*-[0-9]+' || true)"

# ---------- look for section-level YouTrack marker (parent issue id) ----------
# Per Pick 4A, the marker rides on the heading line itself.
# Pattern: ## Epic 1 · ... <!-- yt: JVC-5 -->

SECTION_YT_ID="$(awk -v start="$MATCH_LINE" 'NR == start' "$FILE" \
  | grep -oE '<!--[[:space:]]*yt:[[:space:]]*[A-Z][A-Z0-9]*-[0-9]+' \
  | head -1 \
  | grep -oE '[A-Z][A-Z0-9]*-[0-9]+' || true)"

# ---------- parse the sub-task tree ----------
#
# Walks SECTION_BODY for lines under the "**Sub-tasks**" marker and groups
# them into top-level items. A top-level item is recognised by `- [ ] **TITLE**`
# at column 0 (optionally with trailing text and an inline `<!-- yt: ID -->`
# marker). Lines that follow at indent >= 2 (or blank) belong to the current
# top-level item; an unindented non-list line ends the block.
#
# Emits records to stdout in this shape, one per top-level item:
#
#   <TAB>RECORD<TAB>
#   TITLE<TAB><title text>
#   YT_ID<TAB><JVC-NN or empty>
#   FIRST<TAB><raw first line>
#   BODY_BEGIN
#   ... body lines verbatim ...
#   BODY_END
#
# A leading <TAB>RECORD<TAB> sentinel lets bash split records reliably even
# when bodies contain blank lines.

parse_subtasks() {
  printf '%s\n' "$SECTION_BODY" | awk '
    BEGIN { in_st = 0; have_item = 0 }

    # The "**Sub-tasks**" header opens the parsing window.
    /^\*\*Sub-tasks\*\*[[:space:]]*$/ { in_st = 1; next }
    !in_st { next }

    # Top-level item: matches "- [ ] **TITLE**" or "- [x] **TITLE**" at col 0.
    /^- \[[ xX]\] \*\*[^*]+\*\*/ {
      if (have_item) { print "BODY_END" }
      have_item = 1

      # Extract title text between the first pair of ** ... **.
      s = index($0, "**") + 2
      rest = substr($0, s)
      e = index(rest, "**")
      title = substr(rest, 1, e - 1)

      # Pull a YouTrack id marker on the same line, if any.
      yt = ""
      if (match($0, /<!--[[:space:]]*yt:[[:space:]]*[A-Z][A-Z0-9]*-[0-9]+/)) {
        seg = substr($0, RSTART, RLENGTH)
        if (match(seg, /[A-Z][A-Z0-9]*-[0-9]+/)) {
          yt = substr(seg, RSTART, RLENGTH)
        }
      }

      print "\tRECORD\t"
      print "TITLE\t" title
      print "YT_ID\t" yt
      print "FIRST\t" $0
      print "BODY_BEGIN"
      next
    }

    # Inside a top-level item: indented lines and blanks belong to its body.
    have_item == 1 {
      if ($0 == "" || $0 ~ /^[[:space:]]/) { print; next }
      # An unindented non-list line ends the sub-task block.
      print "BODY_END"
      have_item = 0
      in_st = 0
      exit
    }

    END { if (have_item) print "BODY_END" }
  '
}

# Render the markdown body for a single child (sub-issue), given the top-level
# title, the leaves block, and the parent issue URL (may be `<parent>` while
# dry-run, replaced by the real URL at commit time).
render_child_body() {
  local title="$1" leaves="$2" parent_url="$3"
  printf '## Source\n\n'
  printf -- '- Parent: %s\n' "$parent_url"
  printf -- '- File: `%s`\n' "$REL_FILE"
  printf -- '- Section: `%s` → **%s**\n' "$MATCH_TEXT" "$title"
  if [[ -n "$FIGMA_NODE_ID" ]]; then
    printf -- '- Figma frame: `%s`\n' "$FIGMA_NODE_ID"
  fi
  if [[ -n "$JIRA_KEY" ]]; then
    printf -- '- JIRA: %s\n' "$JIRA_KEY"
  fi
  printf '\n## Tasks\n\n'
  if [[ -n "$leaves" ]]; then
    # Strip the 2-space indent inherited from being nested under the
    # top-level item in the source markdown. Relative indentation between
    # leaves (e.g. a sub-leaf at 4 spaces) is preserved.
    printf '%s\n' "$leaves" | awk '{ sub(/^  /, ""); print }'
  else
    printf '_(no leaves yet — sharpen in the source markdown)_\n'
  fi
}

# Iterate parsed sub-task records and call a per-record callback in the parent
# shell. The callback receives three positional args:
#
#   $1  index (1-based)
#   $2  title
#   $3  yt_id (may be empty)
#
# The leaves block is exported via the variable $LEAVES_TMP just before each
# call, since multi-line content does not survive shell-arg quoting cleanly.
foreach_child() {
  local cb="$1"
  local idx=0 title="" ytid="" leaves="" in_b=0 line=""
  while IFS= read -r line; do
    case "$line" in
      $'\tRECORD\t')
        if [[ $idx -gt 0 ]]; then
          LEAVES_TMP="$leaves"
          "$cb" "$idx" "$title" "$ytid"
        fi
        idx=$((idx + 1))
        title=""; ytid=""; leaves=""; in_b=0
        ;;
      "TITLE	"*)      title="${line#TITLE	}" ;;
      "YT_ID	"*)      ytid="${line#YT_ID	}" ;;
      "FIRST	"*)      : ;;
      "BODY_BEGIN")    in_b=1 ;;
      "BODY_END")      in_b=0 ;;
      *)
        if [[ $in_b -eq 1 ]]; then
          if [[ -z "$leaves" ]]; then leaves="$line"
          else                        leaves="$leaves"$'\n'"$line"
          fi
        fi
        ;;
    esac
  done < <(parse_subtasks)
  if [[ $idx -gt 0 ]]; then
    LEAVES_TMP="$leaves"
    "$cb" "$idx" "$title" "$ytid"
  fi
}

# ---------- render the issue body ----------

REL_FILE="$FILE"

render_body() {
  local image_ref="$1"   # the markdown image line; empty if no source frame
  printf '## Source\n\n'
  printf -- '- File: `%s`\n' "$REL_FILE"
  printf -- '- Section: `%s`\n' "$MATCH_TEXT"
  if [[ -n "$FIGMA_NODE_ID" ]]; then
    printf -- '- Figma frame: `%s`\n' "$FIGMA_NODE_ID"
  fi
  if [[ -n "$JIRA_KEY" ]]; then
    printf -- '- JIRA: %s\n' "$JIRA_KEY"
  fi
  printf '\n'
  if [[ -n "$image_ref" ]]; then
    printf '%s\n\n' "$image_ref"
  fi
  printf '%s\n' "$SECTION_BODY"
  if [[ -n "$OPEN_QUESTIONS" ]]; then
    printf '\n## Open Questions\n\n%s\n' "$OPEN_QUESTIONS"
  fi
}

# Decide the image reference to embed in the body.
# - youtrack target uses `attachment://...` so YouTrack rewrites it to the uploaded
#   attachment after upload.
# - disk target uses `./screenshot.png` and only includes the line if a screenshot
#   was actually supplied (or, in dry-run, if a Figma node id exists).
IMAGE_REF=""
HAS_SCREENSHOT=0
if [[ -n "$SCREENSHOT_PATH" ]]; then
  if [[ ! -f "$SCREENSHOT_PATH" ]]; then
    echo "screenshot path does not exist: $SCREENSHOT_PATH" >&2
    exit 2
  fi
  HAS_SCREENSHOT=1
fi

case "$TARGET" in
  youtrack)
    if [[ -n "$FIGMA_NODE_ID" || $HAS_SCREENSHOT -eq 1 ]]; then
      IMAGE_REF='![Component](attachment://screenshot.png)'
    fi ;;
  disk)
    # On commit, only embed the image line if we actually have a screenshot file.
    # In dry-run, embed the placeholder so the user sees the intended shape.
    if [[ $COMMIT -eq 1 ]]; then
      [[ $HAS_SCREENSHOT -eq 1 ]] && IMAGE_REF='![Component](./screenshot.png)'
    else
      [[ -n "$FIGMA_NODE_ID" || $HAS_SCREENSHOT -eq 1 ]] && IMAGE_REF='![Component](./screenshot.png)'
    fi ;;
esac

BODY="$(render_body "$IMAGE_REF")"

# ---------- compute output slug from heading ----------

OUTPUT_SLUG="$(normalize "$MATCH_TEXT" | tr ' ' '-')"

# ---------- emit dry-run output ----------

# ---------- dispatch ----------

print_header() {
  cat <<EOF
================================================================================
$1
--------------------------------------------------------------------------------
file:    $FILE
section: $MATCH_TEXT
project: $PROJECT
target:  $TARGET
figma:   ${FIGMA_NODE_ID:-<none>}
jira:    ${JIRA_KEY:-<none>}
yt_id:   ${SECTION_YT_ID:-<none>}
slug:    $OUTPUT_SLUG
EOF
  if [[ -n "$SCREENSHOT_PATH" ]]; then
    echo "screenshot: $SCREENSHOT_PATH"
  fi
  echo "================================================================================"
}

if [[ $COMMIT -eq 0 ]]; then
  # ---- dry-run path ----
  print_header "DRY RUN — no network, no disk writes"
  echo
  echo "--- ISSUE TITLE ---"
  echo "$MATCH_TEXT"
  echo
  echo "--- ISSUE BODY ---"
  echo "$BODY"
  echo "--------------------------------------------------------------------------------"
  echo "--- SUB-TASK TREE (parsed for sub-issue creation) ---"
  parse_subtasks | awk '
    /^\tRECORD\t/   { idx++; print ""; print "[item " idx "]"; next }
    /^TITLE\t/      { sub(/^TITLE\t/, "  title:    "); print; next }
    /^YT_ID\t/      { sub(/^YT_ID\t/, "  yt_id:    "); print; next }
    /^FIRST\t/      { sub(/^FIRST\t/, "  raw line: "); print; next }
    /^BODY_BEGIN/   { print "  body:";    in_b = 1; next }
    /^BODY_END/     { in_b = 0; next }
    in_b            { print "    " $0 }
  '
  echo "--------------------------------------------------------------------------------"
  echo "--- CHILD ISSUE BODIES (one per top-level sub-task) ---"
  dry_run_child() {
    local idx="$1" title="$2" ytid="$3"
    echo
    echo "[child $idx] title: $title  yt_id: ${ytid:-<none>}"
    echo "----- body -----"
    render_child_body "$title" "$LEAVES_TMP" "<parent issue url, filled at commit>"
    echo "----------------"
  }
  foreach_child dry_run_child
  echo "--------------------------------------------------------------------------------"
  case "$TARGET" in
    youtrack)
      cat <<EOF
WOULD POST:
  POST  \${YOUTRACK_URL}/api/issues
  HEADERS:
    Authorization: Bearer \${YOUTRACK_TOKEN}
    Content-Type: application/json
  BODY (JSON):
    {
      "project": { "shortName": "$PROJECT" },
      "summary": <title above>,
      "description": <body above, with attachment:// rewritten after upload>
    }
  THEN:
    POST  \${YOUTRACK_URL}/api/issues/<id>/attachments
      multipart  file=screenshot.png
EOF
      ;;
    disk)
      FILE_STEM_DRY="$(basename "$FILE" .md)"
      cat <<EOF
WOULD WRITE:
  \$HOME/Documents/scribe/$FILE_STEM_DRY/$OUTPUT_SLUG/ticket.md       (the body above)
  \$HOME/Documents/scribe/$FILE_STEM_DRY/$OUTPUT_SLUG/screenshot.png  (copied from --screenshot-path or skipped if absent)
EOF
      ;;
  esac
  echo
  echo '(dry-run complete — no side effects performed)'
  exit 0
fi

# ---- commit path ----

case "$TARGET" in
  disk)
    FILE_STEM="$(basename "$FILE" .md)"
    OUTDIR="$HOME/Documents/scribe/$FILE_STEM/$OUTPUT_SLUG"
    mkdir -p "$OUTDIR"
    printf '%s\n' "$BODY" > "$OUTDIR/ticket.md"
    if [[ $HAS_SCREENSHOT -eq 1 ]]; then
      cp "$SCREENSHOT_PATH" "$OUTDIR/screenshot.png"
    fi
    print_header "COMMITTED — disk write"
    echo
    echo "wrote: $OUTDIR/ticket.md"
    if [[ $HAS_SCREENSHOT -eq 1 ]]; then
      echo "wrote: $OUTDIR/screenshot.png"
    else
      echo "(no screenshot supplied; image embed skipped)"
    fi
    ;;
  youtrack)
    HOOK_DIR="$(dirname "$0")"
    YT_TOKEN="$("$HOOK_DIR/secret.sh" youtrack 2>/dev/null || true)"
    YT_BASE="$("$HOOK_DIR/secret.sh" youtrack uri 2>/dev/null || true)"
    if [[ -z "$YT_TOKEN" ]]; then
      echo "YOUTRACK_TOKEN not found (Vaultwarden item 'youtrack' password, env \$YOUTRACK_TOKEN)" >&2
      exit 1
    fi
    if [[ -z "$YT_BASE" ]]; then
      echo "YOUTRACK_URL not found (Vaultwarden item 'youtrack' uri, env \$YOUTRACK_URL)" >&2
      exit 1
    fi
    YT_BASE="${YT_BASE%/}"

    # ---- branch: update existing issue, or create new one ----
    if [[ -n "$SECTION_YT_ID" ]]; then
      # ---- update path: section marker names the parent issue ----
      ISSUE_ID="$SECTION_YT_ID"
      ISSUE_URL="$YT_BASE/issue/$ISSUE_ID"

      # PATCH summary + description; summary is included so heading edits
      # propagate. The description still carries the attachment://screenshot.png
      # placeholder if applicable; it will be re-patched after upload (same
      # convergence point as the create path).
      UPDATE_FILE="$(mktemp)"
      UPDATE_HTTP=$(jq -n --arg s "$MATCH_TEXT" --arg d "$BODY" \
          '{summary: $s, description: $d}' \
        | curl -sS -X POST \
          -H "Authorization: Bearer $YT_TOKEN" \
          -H "Accept: application/json" \
          -H "Content-Type: application/json" \
          --data-binary @- \
          -o "$UPDATE_FILE" -w "%{http_code}" \
          "$YT_BASE/api/issues/$ISSUE_ID" || echo "000")
      if [[ "$UPDATE_HTTP" != 2* ]]; then
        echo "parent update failed (http=$UPDATE_HTTP):" >&2
        cat "$UPDATE_FILE" >&2
        rm -f "$UPDATE_FILE"
        exit 1
      fi
      rm -f "$UPDATE_FILE"
      echo "patched parent: $ISSUE_URL"
    else
      # ---- create path ----
      # Pre-flight duplicate check (unless --force)
      if [[ $FORCE -eq 0 ]]; then
        DUP_FILE="$(mktemp)"
        DUP_HTTP=$(curl -sS -G \
          -H "Authorization: Bearer $YT_TOKEN" \
          -H "Accept: application/json" \
          --data-urlencode "fields=idReadable,summary" \
          --data-urlencode "query=project: $PROJECT summary: \"$MATCH_TEXT\"" \
          -o "$DUP_FILE" -w "%{http_code}" \
          "$YT_BASE/api/issues" || echo "000")
        if [[ "$DUP_HTTP" != 2* ]]; then
          echo "duplicate-check failed (http=$DUP_HTTP):" >&2
          cat "$DUP_FILE" >&2
          rm -f "$DUP_FILE"
          exit 1
        fi
        DUP_ID="$(jq -r --arg s "$MATCH_TEXT" '
          (. // []) | map(select(.summary == $s)) | .[0].idReadable // empty
        ' < "$DUP_FILE")"
        rm -f "$DUP_FILE"
        if [[ -n "$DUP_ID" ]]; then
          print_header "DUPLICATE — issue with this title already exists"
          echo
          echo "existing: $YT_BASE/issue/$DUP_ID"
          echo "(re-run with --force to create a duplicate anyway, or add"
          echo " <!-- yt: $DUP_ID --> to the section heading to update it)"
          exit $EXIT_DUPLICATE
        fi
      fi

      # Create the issue.
      CREATE_FILE="$(mktemp)"
      CREATE_HTTP=$(jq -n --arg p "$PROJECT" --arg s "$MATCH_TEXT" --arg d "$BODY" \
          '{project: {shortName: $p}, summary: $s, description: $d}' \
        | curl -sS -X POST \
          -H "Authorization: Bearer $YT_TOKEN" \
          -H "Accept: application/json" \
          -H "Content-Type: application/json" \
          --data-binary @- \
          -o "$CREATE_FILE" -w "%{http_code}" \
          "$YT_BASE/api/issues?fields=idReadable" || echo "000")
      if [[ "$CREATE_HTTP" != 2* ]]; then
        echo "issue create failed (http=$CREATE_HTTP):" >&2
        cat "$CREATE_FILE" >&2
        rm -f "$CREATE_FILE"
        exit 1
      fi
      ISSUE_ID="$(jq -r '.idReadable // empty' < "$CREATE_FILE")"
      rm -f "$CREATE_FILE"
      if [[ -z "$ISSUE_ID" ]]; then
        echo "issue create returned 2xx but no idReadable" >&2
        exit 1
      fi
      ISSUE_URL="$YT_BASE/issue/$ISSUE_ID"
    fi

    # ---- upload screenshot, then patch description with the attachment URL ----
    if [[ $HAS_SCREENSHOT -eq 1 ]]; then
      ATT_FILE="$(mktemp)"
      ATT_HTTP=$(curl -sS -X POST \
        -H "Authorization: Bearer $YT_TOKEN" \
        -H "Accept: application/json" \
        -F "file=@$SCREENSHOT_PATH;type=image/png" \
        -o "$ATT_FILE" -w "%{http_code}" \
        "$YT_BASE/api/issues/$ISSUE_ID/attachments?fields=id,name,url" || echo "000")
      if [[ "$ATT_HTTP" != 2* ]]; then
        echo "attachment upload failed (http=$ATT_HTTP):" >&2
        cat "$ATT_FILE" >&2
        rm -f "$ATT_FILE"
        # The issue is already created; surface the URL so the user can salvage it.
        echo "issue created without attachment: $ISSUE_URL" >&2
        exit 1
      fi
      ATT_URL="$(jq -r '(. // []) | .[-1].url // empty' < "$ATT_FILE")"
      rm -f "$ATT_FILE"
      if [[ -n "$ATT_URL" ]]; then
        FULL_URL="$YT_BASE$ATT_URL"
        # Replace the placeholder in the description with the resolved attachment URL.
        NEW_BODY="$(printf '%s' "$BODY" | sed "s|attachment://screenshot.png|$FULL_URL|g")"
        PATCH_FILE="$(mktemp)"
        PATCH_HTTP=$(jq -n --arg d "$NEW_BODY" '{description: $d}' \
          | curl -sS -X POST \
            -H "Authorization: Bearer $YT_TOKEN" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            --data-binary @- \
            -o "$PATCH_FILE" -w "%{http_code}" \
            "$YT_BASE/api/issues/$ISSUE_ID" || echo "000")
        if [[ "$PATCH_HTTP" != 2* ]]; then
          echo "description patch failed (http=$PATCH_HTTP):" >&2
          cat "$PATCH_FILE" >&2
          rm -f "$PATCH_FILE"
          echo "issue created with attachment but description not patched: $ISSUE_URL" >&2
          exit 1
        fi
        rm -f "$PATCH_FILE"
      fi
    fi

    # ---- create or update children as sub-issues, if requested ----
    # Final per-child state; populated whether the child was newly created or
    # an existing one was patched. Used by the link step and the parent rewrite.
    CHILDREN_IDS=()
    CHILDREN_TITLES=()
    NEWLY_CREATED_CHILDREN_IDS=()  # subset that were just created (for writeback)
    NEWLY_CREATED_CHILDREN_INDEX=() # parallel — index into _CHILD_TITLES
    if [[ $WITH_SUBTASKS -eq 1 ]]; then
      # Collect parsed top-level items into bash arrays. We call render_child_body
      # eagerly so the parent's URL is baked in before any network call.
      _CHILD_TITLES=()
      _CHILD_BODIES=()
      _CHILD_YTIDS=()
      collect_child() {
        local idx="$1" title="$2" ytid="$3"
        _CHILD_TITLES+=("$title")
        _CHILD_BODIES+=("$(render_child_body "$title" "$LEAVES_TMP" "$ISSUE_URL")")
        _CHILD_YTIDS+=("$ytid")
      }
      foreach_child collect_child

      if [[ ${#_CHILD_TITLES[@]} -eq 0 ]]; then
        echo "no top-level sub-tasks parsed from section — skipping --with-subtasks" >&2
      else
        echo
        echo "processing ${#_CHILD_TITLES[@]} sub-issue(s) under $ISSUE_ID..."
      fi

      for i in "${!_CHILD_TITLES[@]}"; do
        c_title="${_CHILD_TITLES[$i]}"
        c_body="${_CHILD_BODIES[$i]}"
        c_ytid="${_CHILD_YTIDS[$i]}"

        if [[ -n "$c_ytid" ]]; then
          # ---- update existing child ----
          CUPD_FILE="$(mktemp)"
          CUPD_HTTP=$(jq -n --arg s "$c_title" --arg d "$c_body" \
              '{summary: $s, description: $d}' \
            | curl -sS -X POST \
              -H "Authorization: Bearer $YT_TOKEN" \
              -H "Accept: application/json" \
              -H "Content-Type: application/json" \
              --data-binary @- \
              -o "$CUPD_FILE" -w "%{http_code}" \
              "$YT_BASE/api/issues/$c_ytid" || echo "000")
          if [[ "$CUPD_HTTP" != 2* ]]; then
            echo "child update failed for '$c_title' ($c_ytid, http=$CUPD_HTTP):" >&2
            cat "$CUPD_FILE" >&2
            rm -f "$CUPD_FILE"
            echo "parent issue: $ISSUE_URL" >&2
            exit 1
          fi
          rm -f "$CUPD_FILE"
          CHILDREN_IDS+=("$c_ytid")
          CHILDREN_TITLES+=("$c_title")
          echo "  updated: $YT_BASE/issue/$c_ytid  ($c_title)"
        else
          # ---- create new child ----
          CCRT_FILE="$(mktemp)"
          CCRT_HTTP=$(jq -n --arg p "$PROJECT" --arg s "$c_title" --arg d "$c_body" \
              '{project: {shortName: $p}, summary: $s, description: $d}' \
            | curl -sS -X POST \
              -H "Authorization: Bearer $YT_TOKEN" \
              -H "Accept: application/json" \
              -H "Content-Type: application/json" \
              --data-binary @- \
              -o "$CCRT_FILE" -w "%{http_code}" \
              "$YT_BASE/api/issues?fields=idReadable" || echo "000")
          if [[ "$CCRT_HTTP" != 2* ]]; then
            echo "child create failed for '$c_title' (http=$CCRT_HTTP):" >&2
            cat "$CCRT_FILE" >&2
            rm -f "$CCRT_FILE"
            if [[ ${#CHILDREN_IDS[@]} -gt 0 ]]; then
              echo "children processed so far: ${CHILDREN_IDS[*]}" >&2
            fi
            echo "parent issue: $ISSUE_URL" >&2
            exit 1
          fi
          CHILD_ID="$(jq -r '.idReadable // empty' < "$CCRT_FILE")"
          rm -f "$CCRT_FILE"
          if [[ -z "$CHILD_ID" ]]; then
            echo "child create returned 2xx but no idReadable for '$c_title'" >&2
            exit 1
          fi
          CHILDREN_IDS+=("$CHILD_ID")
          CHILDREN_TITLES+=("$c_title")
          NEWLY_CREATED_CHILDREN_IDS+=("$CHILD_ID")
          NEWLY_CREATED_CHILDREN_INDEX+=("$i")
          echo "  created: $YT_BASE/issue/$CHILD_ID  ($c_title)"
        fi
      done
    fi

    # ---- link newly-created children as Subtasks of the parent ----
    # Existing (updated) children are already linked from a prior run; calling
    # the link command again is harmless but noisy, so we skip them.
    LINKED_COUNT=0
    if [[ ${#NEWLY_CREATED_CHILDREN_IDS[@]} -gt 0 ]]; then
      echo
      echo "linking ${#NEWLY_CREATED_CHILDREN_IDS[@]} new child(ren) as Subtasks of $ISSUE_ID..."
      for child_id in "${NEWLY_CREATED_CHILDREN_IDS[@]}"; do
        LINK_FILE="$(mktemp)"
        # YouTrack /api/commands accepts the natural-language form
        # "subtask of <parent>" applied to the child issue, which sets the
        # INWARD Subtask link cleanly across YT versions.
        LINK_HTTP=$(jq -n --arg pid "$ISSUE_ID" --arg cid "$child_id" \
            '{query: ("subtask of " + $pid), issues: [{idReadable: $cid}]}' \
          | curl -sS -X POST \
            -H "Authorization: Bearer $YT_TOKEN" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            --data-binary @- \
            -o "$LINK_FILE" -w "%{http_code}" \
            "$YT_BASE/api/commands" || echo "000")
        if [[ "$LINK_HTTP" != 2* ]]; then
          echo "subtask link failed for $child_id (http=$LINK_HTTP):" >&2
          cat "$LINK_FILE" >&2
          rm -f "$LINK_FILE"
          echo "linked so far: $LINKED_COUNT/${#NEWLY_CREATED_CHILDREN_IDS[@]}" >&2
          echo "(parent $ISSUE_URL and the unlinked children remain in YouTrack — link by hand or rerun)" >&2
          exit 1
        fi
        rm -f "$LINK_FILE"
        LINKED_COUNT=$((LINKED_COUNT + 1))
        echo "  linked: $child_id → subtask of $ISSUE_ID"
      done
    fi

    # ---- rewrite parent body to replace the original checklist with child links ----
    # Use ALL CHILDREN_IDS (created + updated) so the parent's sub-tasks block
    # reflects the full list, not just children processed this run.
    if [[ ${#CHILDREN_IDS[@]} -gt 0 ]]; then
      # Build the replacement block: "**Sub-tasks**" header + one line per child.
      CHILDREN_BLOCK="**Sub-tasks**"
      for i in "${!CHILDREN_IDS[@]}"; do
        CHILDREN_BLOCK+=$'\n'"- [ ] ${CHILDREN_IDS[$i]} — ${CHILDREN_TITLES[$i]}"
      done

      # Splice CHILDREN_BLOCK into the body, replacing the original
      # **Sub-tasks** block (everything from the marker until the next `## `
      # heading or EOF). NEW_BODY is the post-attachment-patch body; if no
      # screenshot was uploaded NEW_BODY was never set, so fall back to BODY.
      # Pass the multi-line block via env (BSD awk does not accept embedded
      # newlines in -v values).
      SOURCE_BODY="${NEW_BODY:-$BODY}"
      export CHILDREN_BLOCK
      FINAL_BODY="$(printf '%s\n' "$SOURCE_BODY" | awk '
        BEGIN { block = ENVIRON["CHILDREN_BLOCK"]; in_st = 0 }
        /^\*\*Sub-tasks\*\*[[:space:]]*$/ {
          print block
          in_st = 1
          next
        }
        in_st {
          if ($0 ~ /^## /) { in_st = 0; print ""; print; next }
          next
        }
        { print }
      ')"
      unset CHILDREN_BLOCK

      REWRITE_FILE="$(mktemp)"
      REWRITE_HTTP=$(jq -n --arg d "$FINAL_BODY" '{description: $d}' \
        | curl -sS -X POST \
          -H "Authorization: Bearer $YT_TOKEN" \
          -H "Accept: application/json" \
          -H "Content-Type: application/json" \
          --data-binary @- \
          -o "$REWRITE_FILE" -w "%{http_code}" \
          "$YT_BASE/api/issues/$ISSUE_ID" || echo "000")
      if [[ "$REWRITE_HTTP" != 2* ]]; then
        echo "parent body rewrite failed (http=$REWRITE_HTTP):" >&2
        cat "$REWRITE_FILE" >&2
        rm -f "$REWRITE_FILE"
        echo "(parent and children remain in YouTrack; only the parent description still shows the original checklist instead of child links)" >&2
        exit 1
      fi
      rm -f "$REWRITE_FILE"
      echo
      echo "parent body rewritten: sub-tasks block now lists ${#CHILDREN_IDS[@]} child link(s)"
    fi

    # ---- writeback yt markers into the source markdown (Pick 6A) ----
    # Adds `<!-- yt: <ID> -->` to:
    #   - the section heading line, if SECTION_YT_ID was empty (i.e. parent
    #     was just created this run);
    #   - each newly-created child's sub-task line, matched by bold title.
    # Idempotent: skips lines that already have a yt marker.
    NEED_WRITEBACK=0
    SECTION_MARKER_TO_WRITE=""
    if [[ -z "$SECTION_YT_ID" && -n "$ISSUE_ID" ]]; then
      SECTION_MARKER_TO_WRITE="$ISSUE_ID"
      NEED_WRITEBACK=1
    fi
    if [[ ${#NEWLY_CREATED_CHILDREN_IDS[@]} -gt 0 ]]; then
      NEED_WRITEBACK=1
    fi

    if [[ $NEED_WRITEBACK -eq 1 ]]; then
      # Build a TSV mapping of "title<TAB>id" for each newly-created child.
      WB_MAPPING=""
      for i in "${!NEWLY_CREATED_CHILDREN_IDS[@]}"; do
        idx="${NEWLY_CREATED_CHILDREN_INDEX[$i]}"
        wb_title="${_CHILD_TITLES[$idx]}"
        wb_id="${NEWLY_CREATED_CHILDREN_IDS[$i]}"
        WB_MAPPING+="$wb_title"$'\t'"$wb_id"$'\n'
      done

      WB_TMP="$(mktemp)"
      export _WB_MAPPING="$WB_MAPPING"
      export _WB_SECTION_LINE="$MATCH_LINE"
      export _WB_SECTION_MARKER="$SECTION_MARKER_TO_WRITE"

      awk '
        BEGIN {
          # Parse mapping into title2id[]
          mapping = ENVIRON["_WB_MAPPING"]
          n = split(mapping, lines, "\n")
          for (i = 1; i <= n; i++) {
            if (lines[i] == "") continue
            idx = index(lines[i], "\t")
            t = substr(lines[i], 1, idx - 1)
            v = substr(lines[i], idx + 1)
            title2id[t] = v
          }
          section_line = ENVIRON["_WB_SECTION_LINE"] + 0
          section_marker = ENVIRON["_WB_SECTION_MARKER"]
          in_section = 0
        }
        {
          line = $0

          # Section heading: maybe append the parent marker.
          if (NR == section_line) {
            if (section_marker != "" && line !~ /<!--[[:space:]]*yt:/) {
              line = line " <!-- yt: " section_marker " -->"
            }
            in_section = 1
            print line
            next
          }

          # End of section: next "## " or "---" closes it.
          if (in_section && NR > section_line && (line ~ /^## / || line ~ /^---[[:space:]]*$/)) {
            in_section = 0
          }

          # Inside section: top-level "- [ ] **TITLE**" line — match by title.
          if (in_section && line ~ /^- \[[ xX]\] \*\*[^*]+\*\*/) {
            s = index(line, "**") + 2
            rest = substr(line, s)
            e = index(rest, "**")
            t = substr(rest, 1, e - 1)
            if (t in title2id && line !~ /<!--[[:space:]]*yt:/) {
              line = line " <!-- yt: " title2id[t] " -->"
            }
          }

          print line
        }
      ' "$FILE" > "$WB_TMP"

      unset _WB_MAPPING _WB_SECTION_LINE _WB_SECTION_MARKER

      # Atomically replace the source file.
      if ! mv "$WB_TMP" "$FILE"; then
        echo "writeback failed: could not replace $FILE" >&2
        rm -f "$WB_TMP"
        exit 1
      fi
      echo
      echo "wrote markers back into $FILE"
      [[ -n "$SECTION_MARKER_TO_WRITE" ]] && echo "  + section: <!-- yt: $SECTION_MARKER_TO_WRITE -->"
      for i in "${!NEWLY_CREATED_CHILDREN_IDS[@]}"; do
        idx="${NEWLY_CREATED_CHILDREN_INDEX[$i]}"
        echo "  + ${_CHILD_TITLES[$idx]}: <!-- yt: ${NEWLY_CREATED_CHILDREN_IDS[$i]} -->"
      done
    fi

    if [[ -n "$SECTION_YT_ID" ]]; then
      print_header "COMMITTED — youtrack issue updated"
    else
      print_header "COMMITTED — youtrack issue created"
    fi
    echo
    echo "issue: $ISSUE_URL"
    if [[ ${#CHILDREN_IDS[@]} -gt 0 ]]; then
      echo "children: ${#CHILDREN_IDS[@]} processed (${#NEWLY_CREATED_CHILDREN_IDS[@]} new, $((${#CHILDREN_IDS[@]} - ${#NEWLY_CREATED_CHILDREN_IDS[@]})) updated)"
      for i in "${!CHILDREN_IDS[@]}"; do
        echo "  - ${CHILDREN_IDS[$i]}  ${CHILDREN_TITLES[$i]}"
      done
    fi
    ;;
esac
