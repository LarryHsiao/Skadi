# Vör — Teams Watchman (Design)

- **Date:** 2026-07-06
- **Status:** Approved design, pending implementation plan
- **Skill slug:** `vor` (lives at `~/.claude-personal/skills/vor/`)
- **Named for:** Vör, the Norse goddess from whom nothing is concealed — watchfulness itself.

## Purpose

Read the Microsoft Teams conversations the user already belongs to, and help them
stay on top of the traffic: summarize what is new, flag what is addressed to them or
needs a reply, and *suggest* a response they could send.

**Vör reads and advises. It never posts.** The user keeps a hand on every send.

## Scope

**In scope (v1):**

- Read new messages from Teams channels and chats the user is a member of.
- Organize the new traffic: cluster by thread, flag @-mentions and direct questions,
  drop routine noise.
- Suggest a draft reply, in-session, for the user to copy manually.
- Notify the user when threads want attention.

**Out of scope (v1):**

- Posting anything back to Teams (no `announce`, no write scopes).
- Reading conversations the user is not a member of.
- LINE (see Extension Points — deferred as an experiment).
- Discord / Slack (documented extension points, not built).

## Architecture

Follows the source-as-concrete shape from `docs/style/oo.md`: a mechanism-blind seam,
one concrete per platform, cross-cutting concerns as decorators.

> The interface notation below is **conceptual**, borrowed from `oo.md` to name the
> boundaries. Vör is a Claude Code skill (a `SKILL.md` plus a poll script), not a Dart
> app — the concrete implementation language (PowerShell / bash / a small helper) is a
> decision for the implementation plan, not this design. The seam/concrete *boundaries*
> hold regardless of language.

### `MessageSource` seam

Answers one question: *what is new since the last look?* Returns a list of normalized
messages plus an opaque cursor. Knows nothing about Teams, Graph, or any platform.

```
abstract interface class MessageSource {
  Future<MessageBatch> since(Cursor cursor);
}
```

### Normalized message

The shape every concrete must produce, so the Organizer and Suggester never learn
which platform a message came from:

```
{
  id:        String,      // platform message id
  sender:    String,      // display name
  text:      String,      // plain-text body (HTML stripped)
  thread:    String,      // channel/chat + reply-chain identity
  timestamp: String,      // ISO-8601 UTC
  mentionsMe: bool,       // true if the user was @-mentioned
}
```

### `TeamsSource` concrete (the only source built in v1)

- Uses Microsoft Graph **`delta`** query over the user's channels and chats
  (`/me/chats/getAllMessages` / per-channel `messages/delta`).
- Persists the returned **`deltaLink`** as the cursor, so each run fetches only what
  is new. Cursor stored on disk under the skill's state dir.
- Reads its Graph bearer token via the `~/.claude/hooks/secret.sh` helper — never
  from a raw env var.
- Strips HTML from message bodies to produce `text`.

### Organizer (AI step)

Takes the normalized batch and produces a structured brief: threads clustered,
`mentionsMe` and direct-question threads surfaced first, routine noise collapsed.

### Suggester (AI step)

For each thread that wants a reply, drafts a suggested response in this session for
the user to eyeball and copy. Emits text only — no send path exists.

### Surface

- An organized brief rendered to chat.
- Optional `PushNotification` ("3 threads need a reply") for when the user is away
  from the terminal.

## Authentication & Permissions

- **Scopes (read only):** `Chat.Read` / `ChannelMessage.Read.All` (delegated).
- **Tenant:** the user's work tenant. Consent is admin-gated and *not yet granted*.
- **Token:** stored in Vaultwarden, read at runtime via `secret.sh`.

### Runtime gate (stated plainly)

The skill is fully writable today, but **stays dormant until a Graph token with the
read scopes exists**. Until then it authors clean and fails at the first API call with
a `401`/`403`. This is a known, accepted condition — not a bug.

## Testing Strategy

The live Graph call cannot be exercised until consent lands, so:

- **Fixture-JSON tests** cover the parseable seams: cursor (`deltaLink`) handling,
  message normalization (HTML strip, `mentionsMe` detection), and thread clustering.
- The **one live Graph call** is the manual check the user runs the day consent is
  granted. This is named explicitly so the untested edge is honest, per the
  "new code lands with a test" rule and the Fail Loud rule.

## Extension Points (not built in v1)

The `MessageSource` seam is mechanism-blind, so each of these is *one new concrete*
against a proven seam — no rework of Organizer, Suggester, or surface:

- **`LineDesktopSource`** — read the user's personal LINE chats by screen-vision
  (screenshot the LINE desktop window, scroll, OCR / vision-read). Lower ban risk than
  a rogue client (reads only the user's own legitimate screen), but the flakiest source
  by far: brittle to UI changes, DPI/theme, no true cursor, must run with LINE visible.
  Deferred as a clearly-labeled experiment. LINE has **no** sanctioned API for personal
  chats, so screen-vision is the only honest route.
- **`DiscordSource`** — bot token + gateway/REST. Simpler auth than Teams.
- **`SlackSource`** — Web API `conversations.history`.

## Skill Shape

```
~/.claude-personal/skills/vor/
  SKILL.md            # trigger, verb, orchestration
  <poll script>       # TeamsSource: Graph delta + cursor persistence
  fixtures/           # sample Graph JSON for tests
  <tests>
```

Propagated to live config via the `/install` skill, never by copying by hand.

## Acceptance (what "done" looks like for the skill, once built)

- Given fixture Graph JSON, the normalizer produces the documented message shape and
  correctly sets `mentionsMe`.
- Given two successive fixture batches, the cursor logic returns only the second
  batch's new messages on the second call.
- The Organizer brief surfaces `mentionsMe` / direct-question threads above noise.
- The Suggester emits a draft per flagged thread and no send call exists anywhere in
  the code path.
- Live Graph read is verified manually once tenant consent is granted.

## Open Questions

- Which channels/chats to watch — all the user belongs to, or a configured subset?
  (Default assumption: all; a filter list is a cheap later addition.)
- Notification threshold — always notify, or only above N flagged threads?
