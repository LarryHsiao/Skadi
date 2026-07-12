# Forge & Tracker Authorship — Per-Surface Details

> Read when opening a PR/MR or a tracker ticket. CLAUDE.md's *Forge & Tracker
> Authorship* section states the rule (assign to the author at creation time);
> this file carries the per-surface how and the reasoning.

## PR/MR Authorship

When opening a pull request or merge request — through a skill, a hook, or a free-form `gh` / `glab` call — assign it to the user (the author) by default. An unassigned PR/MR drifts: no one bears the next step, and reviewers cannot tell who drives it to merge. Pass `--assignee @me` to `gh pr create` and `glab mr create` unless the user names another assignee, or explicitly says to leave it bare.

## Issue Tracker Authorship

When opening a ticket in any issue tracker — Jira, YouTrack, Linear, GitHub Issues, GitLab Issues, and the like — through a hook, the tracker's CLI, or a REST/GraphQL call, assign it to the user (the author) by default. The shape of the harm is the same as an unassigned PR/MR: the queue cannot tell who drives the work, the ticket drifts unattended, and a notification stream grows around an artifact no one owns.

Pass the tracker's assignee field at creation time, not as a follow-up edit — the moment of creation is when the next step is clearest. Exceptions: when the user names another assignee, when the user explicitly says to leave it bare, or when the ticket is meant for a triage queue whose policy is "unassigned by default" (name that case at the call site and let the queue's owner pick it up).

The per-tracker how:

- **Jira** — set `fields.assignee.accountId` to the author's Atlassian account ID. The authenticated user's account ID is returned by `GET /rest/api/3/myself`; cache it once per machine in memory rather than re-fetching every call.
- **YouTrack** — set `assignee.login` (or the equivalent issue-field update) to the author's YouTrack login.
- **Linear** — set `assigneeId` to the author's Linear user ID (`viewer.id` from the GraphQL endpoint).
- **GitHub / GitLab Issues** — pass `--assignee @me` to `gh issue create` / `glab issue create`, mirroring the PR/MR convention.
