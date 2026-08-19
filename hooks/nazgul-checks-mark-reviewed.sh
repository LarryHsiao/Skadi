#!/usr/bin/env bash
# Stamp the nazgul-checks review state file with the current epoch.
# Called by /nazgul reviewed; consumed by hooks/preflight-check.sh.

set -euo pipefail

state="$HOME/.skadi/preflight/nazgul-checks-last-review"
mkdir -p "$HOME/.skadi/preflight"
date +%s > "$state"
echo "Marked nazgûl checks reviewed at $(date '+%Y-%m-%d %H:%M:%S')."
