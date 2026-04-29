#!/usr/bin/env bash
# Stamp the nazgul-checks review state file with the current epoch.
# Called by /nazgul reviewed; consumed by hooks/preflight-check.sh.

set -euo pipefail

state="$HOME/.claude/.nazgul-checks-last-review"
date +%s > "$state"
echo "Marked nazgûl checks reviewed at $(date '+%Y-%m-%d %H:%M:%S')."
