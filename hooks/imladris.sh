#!/usr/bin/env bash
# imladris.sh — the hand behind /imladris: gather repos into the current empty folder.
#
# Resolves the profile's repo_groups.md (profile-level, so any folder finds it)
# and the protected-repos list, then runs imladris.py in the caller's directory.
# Test seams: IMLADRIS_GROUPS and IMLADRIS_PROTECTED override the two paths.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${SKADI_PROFILE:-default}"
GROUPS_FILE="${IMLADRIS_GROUPS:-$("$HERE/skadi-state.sh" profile-path "$PROFILE" repo_groups.md)}"
PROTECTED_FILE="${IMLADRIS_PROTECTED:-$HOME/.skadi/protected_repos.md}"

exec python3 -I "$HERE/imladris.py" --groups "$GROUPS_FILE" --protected "$PROTECTED_FILE" "$@"
