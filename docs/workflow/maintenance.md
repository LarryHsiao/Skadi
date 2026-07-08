# Maintenance — Keeping This Config Healthy

> Read before changing skadi's rules, and after any session that learned a
> lesson worth keeping. The audience is every future session, whatever its
> model tier.

## Edit covenant — who may change what

| Target | May a session change it? |
|---|---|
| Memory files (`memory/` in a project's auto-memory) | Freely — that is what memory is for. |
| `docs/workflow/*`, `docs/style/*`, `docs/tools/*` | Propose the edit and wait for the user's word (CLAUDE.md's *Change Approval*). Wording fixes and factual corrections are still proposals. |
| Skills (`skills/*/SKILL.md`) | Propose + word. Never edit the copies under `~/.claude*` — repo first, then `/install`. |
| `CLAUDE.md`, `settings.json`, `hooks/*` | Propose + word, and name the blast radius: these load into (or gate) every session on every machine. |
| Live copies under `~/.claude*/` | Never. They are overwritten on the next install sweep. The repo is the source of truth. |

## Lesson write-back

- A lesson learned mid-session lands first as a **memory entry** (`feedback`
  or `project` type, per the memory format in the system prompt) — cheap,
  immediate, no approval needed.
- A lesson **graduates** into a doc or CLAUDE.md when it has earned it: it
  corrected the same mistake twice, or it applies beyond the project where it
  was learned. Graduation is a proposal (edit covenant above). After
  graduation, shrink the memory to a pointer.
- A lesson goes to the file that owns its concern — a style rule to
  `docs/style/`, a delegation rule to `docs/workflow/delegation.md` — not as
  a one-off exception threaded into a skill's prose. The container is the
  point (`docs/style/universal.md`).

## Compaction thresholds

- **CLAUDE.md and the `@`-loaded style docs are the token budget.** When their
  combined weight grows past ~35K characters, propose extracting the coldest
  sections into referenced (non-`@`) docs. Mind the trap: only `@docs/...`
  references auto-load — moving content to a plain path silently removes it
  from every session's context. Move only what is genuinely read-on-demand.
- **A single doc past ~200 lines** gets a table of contents or a split —
  whichever keeps a cold read under one screen of scanning.
- **One in, one out (soft).** When adding a rule to an always-loaded file,
  look for a rule the new one obsoletes or a section that can defer to a hook
  or referenced doc. Accretion without pruning is how the budget dies.

## Authoring standard — writing for every future reader

- **Concrete and executable.** A rule states signals, an action, and where it
  applies. "Be careful with X" is not a rule; "before X, check Y; if Z, stop
  and ask" is.
- **Example-bearing.** Judgment-shaped rules carry one positive and one
  negative example (`judgment.md` is the pattern).
- **Sonnet-runnable.** If following the rule requires the judgment of a
  stronger model, the rule is not finished — decompose it until the steps are
  mechanical, or name plainly where judgment is required and what to do then
  (escalate, second opinion, ask — `judgment.md` §5).
- **Plain voice in machine-facing docs.** The Tolkien cadence belongs to chat;
  these files are read by models under token pressure.
- **When a hook enforces a behavior, prose defers to the hook.** State only
  what the hook does not carry, and name the hook (the Grammar Check section
  is the pattern).

## Known degradation modes — and their preventions

1. **Rule accretion.** Every incident adds a rule; the always-loaded weight
   bloats until sessions start skimming. *Prevention:* the compaction
   thresholds above, applied on sight, not on schedule.
2. **Dual codebooks drifting.** CLAUDE.md sections, these docs, and plugin
   skills (superpowers) each speak to the same gates and slowly diverge.
   *Prevention:* CLAUDE.md carries the precedence line; every rule lives in
   exactly one home, and other surfaces point to it.
3. **Prose and hooks drifting apart.** A section describes a behavior; the
   hook that enforces it changes; the section now lies. *Prevention:* the
   defer-to-hook rule above — the less the prose repeats the hook, the less
   there is to drift.
4. **Stale rosters and tool names.** Model names, flags, and skill names rot
   silently. *Prevention:* date-stamp roster-like content (see
   `delegation.md`) and verify before relying on any dated claim.
5. **Ritual compliance.** Gauges, acceptances, and reviews get rendered pro
   forma — present in form, empty in substance. *Prevention:* an acceptance
   line must be a checkable outcome with same-turn evidence; a review must
   name file:line or say PASS. Anything that cannot fail is not a check —
   delete it or sharpen it.
