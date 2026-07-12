# Task Sizing — Worked Example

> A reference for the Task Sizing part of the `## Free-Form Gate` rule in `CLAUDE.md`. The rule names the gauge and the cleavage discipline; this file shows one cleavage end-to-end.

"Add a session-summary hook" rings **medium** — a new script, a settings wire-up, a README line, an end-to-end check. It cleaves so:

1. Write the shell script under `hooks/` in isolation; run it by hand to confirm shape.
2. Add a single `permissions.allow` entry in `settings.json` for the new script path.
3. Wire the hook into `settings.json` under its event, one event only.
4. Update the `README.md` Hooks entry so the inventory stays honest.

Each step narrow of reach, each leaves the tree working, each trivial to walk back.
