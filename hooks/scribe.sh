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
SCREENSHOT_PATH=""

# Duplicate-detected exit code, surfaced so the skill can prompt the user and
# re-invoke with --force.
EXIT_DUPLICATE=75

usage() {
  echo "Usage: $0 <file> <heading-slug> --project=<KEY> [--target=youtrack|disk] [--commit] [--screenshot-path=<png>]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project=*)         PROJECT="${1#*=}" ;;
    --target=*)          TARGET="${1#*=}" ;;
    --screenshot-path=*) SCREENSHOT_PATH="${1#*=}" ;;
    --commit)            COMMIT=1 ;;
    --force)             FORCE=1 ;;
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
for h in "${HEADINGS[@]}"; do
  ln="${h%%	*}"
  txt="${h#*	}"
  norm="$(normalize "$txt")"
  CANDIDATES+=("$txt")
  if [[ " $norm " == *" $NORM_SLUG "* ]]; then
    MATCH_LINE="$ln"
    MATCH_TEXT="$txt"
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

    # ---- pre-flight duplicate check (unless --force) ----
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
        echo "(re-run with --force to create a duplicate anyway)"
        exit $EXIT_DUPLICATE
      fi
    fi

    # ---- create the issue ----
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

    print_header "COMMITTED — youtrack issue created"
    echo
    echo "issue: $ISSUE_URL"
    ;;
esac
