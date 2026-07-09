---
name: estë
description: Use when the user runs /estë. Computes the adherence pulse — a marker-based, per-item scorecard (with confidence tiers) of how faithfully the skadi config's rules and skills are followed across all config roots — appends the run to history, renders a Henneth dashboard, and prints its URL. Read-only over transcripts; never writes to a tracker or repo. Runs on demand; wrap in /loop or cron for a standing cadence.
user_invocable: true
---

# Estë — The Adherence Pulse

Estë, the Vala of healing and rest, measures the health of the work: how
faithfully the config's rules and skills are kept. One run scans every config
root's transcripts, scores each rubric item, and lays a dashboard in the Henneth
window.

## Run

    python3 ~/.claude/hooks/pulse-scan.py

This walks `~/.claude`, `~/.claude-personal`, `~/.claude-work` under
`projects/**/*.jsonl` (read-only), appends a line to `~/.skadi/pulse/history.jsonl`,
writes the board channel `~/.skadi/board/pulse.json`, and renders
`~/.claude/previews/henneth/adherence-pulse.html`. It prints the headline overall.

Then ensure the Henneth window is up (boot it with `/henneth` if not) and surface
the dashboard URL inline — the page follows the folder, so the pulse appears on its
own once rendered.

## Notes

- **Read-only.** The pulse reads transcripts; it never writes to a tracker or repo.
- **Markers only.** The first cut scores machine-checkable signals — per-skill
  completion and grammar rate. Two rule items (commit-footer, PR assignee) are
  defined but marked `pending` until their git/forge probes are built.
- **Subagent verdicts under-report.** A skill that posts its verdict through a
  subagent — `/council`'s `[COUNSEL]`, `/celebrimbor`'s `[GWAITH]` — writes that
  marker in the tracker, not the main-thread transcript the pulse reads, so those
  rows read low. A known first-cut limitation, not a failure of the skill.
- **Honest tiers.** Each item carries a confidence tier, and the headline shows a
  figure per tier; a single cross-tier average is shown too, but always labelled as
  such and never standing alone.
- **Standing cadence.** The skill arms nothing. For a recurring pulse, wrap it:
  `/loop 6h /estë`, or a cron.
- **Tests ride beside the hook** — `pulse-scan.test.sh` runs offline via injected
  fixture roots (`PULSE_ROOTS`).
