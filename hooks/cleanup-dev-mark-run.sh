#!/usr/bin/env bash
# Records the current timestamp as the last /cleanup-dev run.
# Consumed by preflight-check.sh.

set -euo pipefail

mkdir -p "$HOME/.claude"
date +%s > "$HOME/.claude/.cleanup-dev-last-run"
