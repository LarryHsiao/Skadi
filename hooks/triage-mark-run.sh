#!/usr/bin/env bash
# Records the current timestamp as the last /triage run.
# Consumed by preflight-check.sh.

set -euo pipefail

mkdir -p "$HOME/.claude"
date +%s > "$HOME/.claude/.triage-last-run"
