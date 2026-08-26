# Maintenance — Keeping This Config Healthy

> Read before changing skadi's rules, and after any session that learned a
> lesson worth keeping. The audience is every future session, whatever its
> model tier.

## Edit covenant — who may change what

| Target | May a session change it? |
|---|---|
| Memory files (`memory/` in a project's auto-memory) | Freely — that is what memory is for. |
| `docs/workflow/*`, `docs/style/*`, `docs/tools/*` | Propose the edit and wait for the user's word (CLAUDE.md's *Free-Form Gate*). Wording fixes and factual corrections are still proposals. |
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

The always-loaded set is CLAUDE.md plus the `@`-loaded style docs. Mind the
trap on any extraction: only `@docs/...` references auto-load — moving content
to a plain path silently removes it from every session's context. Move only
what is genuinely read-on-demand.

- **Prune on evidence, not on a character count.** The risk guarded against is
  degradation mode 1 — rules accreting until sessions skim them. That is an
  *attention* cost, not a token one, and `/este` measures it directly. Prune
  when its structural rows (`verify.test`, `verify.lint`) fall across several
  consecutive runs while the always-loaded weight rose. Absent that signal, a
  file that grew is not by itself a problem.
  - Measured 2026-08-26 over 22 pulse runs since 2026-07-09: weight went
    29,008 → 43,196 while overall adherence rose 52% → 73% (r = +0.70). Read
    that as *the predicted harm did not appear*, *not* as *growth helps* — the
    rubric's own denominator was mended three times in that window, and its
    criterion says plainly that such mending lifts a rate with no change in
    conduct. Re-run this correlation before leaning on it; it is a dated claim.
- **~45,000 characters is a smell test, not a limit.** Past it, read the file
  and ask which rules have stopped earning their weight. The previous ~35,000
  was not derived from anything: it was the size on the day it was written
  (2026-07-08, actual 35,532) — a status quo dressed as a budget. Do not treat
  this number better than its predecessor deserved. If it is ever hit,
  re-measure rather than obey.
- **A single doc past ~200 lines** gets a table of contents or a split —
  whichever keeps a cold read under one screen of scanning.
- **One in, one out (soft).** When adding a rule to an always-loaded file,
  look for a rule the new one obsoletes or a section that can defer to a hook
  or referenced doc. Keep this for the discipline, not the arithmetic: it
  forces a measurement, and measuring is what catches an estimate that was
  wrong — a pruning pass on 2026-08-26 predicted 1,600 characters saved and
  delivered 371, because it sized the section rather than the duplicated part
  inside it. Size what will actually be deleted.
- **In a skadi-rooted session the always-loaded set is charged twice** — once
  as global instructions from the installed root, once as project instructions
  from the repo, byte-identical. Any weight measured here is doubled in
  exactly the sessions that edit these rules. The remedy is not obvious (the
  repo copy is the install source), so this is recorded rather than solved.

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

## Why the reminder hooks are shaped as they are

`gate-reminder.sh` and `compliance-review-reminder.sh` both re-inject their
gate's trigger into *every* user prompt. Their specifications live in
CLAUDE.md; this is the reasoning behind their shape, kept here so the
always-loaded file carries the rule and not its defence.

- **Why every turn, not only closing ones.** A hook can detect *about to
  mutate* from a tool call, but not *about to claim done* from prose. There is
  no reliable signal for the second, so the always-inject pattern is the one
  that has held. It pays context on every turn to avoid missing the turn that
  matters.
- **Why the review reminder names the agent dispatch.** `pulse-rubric.json`'s
  `rule.compliance-review` credits a segment only when an `Agent` call stands
  behind the verdict line. A reminder nudging toward the literal marker alone
  would teach it to be typed unearned — corrupting the very measure it exists
  to protect. A reminder must never make the metric easier to satisfy than the
  behaviour it stands for.
- **Cost, when trimming.** These two hooks are charged per prompt, not per
  task. A clause covering a rare branch does not belong in them; put it in the
  CLAUDE.md section instead, which is charged once per session.
