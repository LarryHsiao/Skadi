#!/usr/bin/env bash
# Records the current timestamp as the last /daily run.
# Consumed by preflight-check.sh.

set -euo pipefail

mkdir -p "$HOME/.skadi/preflight"
date +%s > "$HOME/.skadi/preflight/daily-last-run"
