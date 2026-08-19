#!/usr/bin/env bash
# Records the current timestamp as the last /cleanup-dev run.
# Consumed by preflight-check.sh.

set -euo pipefail

mkdir -p "$HOME/.skadi/preflight"
date +%s > "$HOME/.skadi/preflight/cleanup-dev-last-run"
