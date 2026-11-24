#!/bin/bash
# halbarad-jira.sh — Jira delta + per-source cursor for /halbarad. Read-only.
# Thin wrapper: resolves credentials (vault -> ~/.skadi/jira/config.md -> env,
# the same order jira-daily.sh uses) and the cursor path, then hands over to
# halbarad_jira.py, which holds the logic and the usage text.
#
# Platforms: macOS and Windows (Git Bash); Python 3 standard library only.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SECRET="$HERE/secret.sh"

if [[ -z "${HALBARAD_CURSOR_FILE:-}" ]]; then
  HALBARAD_CURSOR_FILE="$(bash "$HERE/skadi-state.sh" profile-path "${SKADI_PROFILE:-default}" halbarad_cursor.md)"
  export HALBARAD_CURSOR_FILE
fi

if [[ -z "${HALBARAD_JIRA_FIXTURE_DIR:-}" && "${1:-}" != "cursor" && "${1:-}" != "last" ]]; then
  config="$HOME/.skadi/jira/config.md"
  from_config() { [[ -f "$config" ]] && awk -F'`' -v k="$1" '$0 ~ k {v=$3; sub(/^: */,"",v); print v; exit}' "$config"; }
  url="$("$SECRET" jira uri - 2>/dev/null || true)"
  email="$("$SECRET" jira username - 2>/dev/null || true)"
  export HALBARAD_JIRA_URL="${url:-$(from_config JIRA_BASE_URL || true)}"
  export HALBARAD_JIRA_EMAIL="${email:-$(from_config JIRA_EMAIL || true)}"
  token="$("$SECRET" jira password JIRA_API_TOKEN 2>/dev/null || true)"
  export HALBARAD_JIRA_TOKEN="$token"
  if [[ -z "$HALBARAD_JIRA_URL" || -z "$HALBARAD_JIRA_EMAIL" || -z "$HALBARAD_JIRA_TOKEN" ]]; then
    echo '{"source":"jira","status":"error","reason":"not configured — Jira url, email or token missing"}'
    exit 2
  fi
fi

exec python3 "$HERE/halbarad_jira.py" "$@"
