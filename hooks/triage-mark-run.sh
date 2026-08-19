#!/usr/bin/env bash
# Records the current timestamp as the last /triage run.
# Consumed by preflight-check.sh.

set -euo pipefail

mkdir -p "$HOME/.skadi/preflight"
date +%s > "$HOME/.skadi/preflight/triage-last-run"
