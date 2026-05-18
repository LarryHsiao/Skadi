#!/usr/bin/env bash
# Records the current timestamp as the last /daily run.
# Consumed by preflight-check.sh.

set -euo pipefail

mkdir -p "$HOME/.claude"
date +%s > "$HOME/.claude/.daily-last-run"
