---
name: vor
description: Use when the user runs /vor. Reads new Microsoft Teams messages from the conversations they belong to — via the Microsoft 365 claude.ai connector by preference, falling back to a read-only Graph delta poller once tenant consent lands — organizes the traffic — clustering threads, surfacing @-mentions and direct questions, collapsing noise — and suggests draft replies in-session. It never posts to Teams.
---

# Vör — Teams Watchman

Vör watches the Teams conversations you belong to and helps you keep pace: it
reads what is new, organizes it, and suggests how you might reply. **It reads and
advises. It never posts.** You keep a hand on every send.

## Verb

`/vor` — fetch, organize, suggest.

## Steps

1. **Fetch.** Two routes, connector preferred.

   **Primary — Microsoft 365 claude.ai connector.** Locate
   `mcp__claude_ai_Microsoft_365__chat_message_search` (a deferred tool; load its
   schema with ToolSearch first —
   `select:mcp__claude_ai_Microsoft_365__chat_message_search`, or search
   `chat message search` if the exact name differs). If present, search with
   query `*` and `afterDateTime` set to 24 hours ago, then normalize each result
   field-by-field: `id`←`id`, `sender`←`from.displayName`, `text`←`summary`
   (HTML tags stripped), `thread`←`chatId`, `timestamp`←`createdDateTime`,
   `mentionsMe`←best-effort — call `get_me` once and match the returned identity
   against `text` (the connector carries no mention metadata, so this is a
   heuristic, not authoritative).

   Two named limits of this route: it misses **channels** (only chats) once
   `afterDateTime` is set, and with no delta cursor, dedup is by time window
   only — running `/vor` more than once inside the 24h window can resurface the
   same messages.

   **Fallback — Graph delta poller**, used when the connector tool is absent
   from the session:

   ```bash
   ~/.claude/hooks/vor-teams-poll.sh
   ```

   Handle the exit code before anything else:
   - `2` — dormant. Tell the user plainly what is missing (no `sources.txt`, or no
     `vor-graph-token`) and stop. This is expected until tenant consent lands.
   - `3` — a tool (`jq`/`curl`) is missing. Name it and ask the user to install it.
   - `4` — Graph denied or errored. Relay that consent for
     `Chat.Read`/`ChannelMessage.Read.All` is not yet granted, and stop.
   - `0` — proceed. The stdout is a JSON array of normalized messages
     (`{id, sender, text, thread, timestamp, mentionsMe}`); an empty array means
     nothing new.

   The poller's `mentionsMe` is authoritative (real Graph mention metadata) and
   it covers channels the connector route misses — prefer its judgment over the
   connector's heuristic when both have run.

2. **Organize.** Read the messages and group them by `thread`. Surface, in this
   order: threads where `mentionsMe` is true, then threads that ask a direct
   question, then the rest collapsed into a one-line "routine" tally. Drop pure
   noise (joins, reactions, automated notices).

3. **Suggest.** For each surfaced thread that wants a reply, draft a short
   suggested response in-session for the user to read and copy. **Do not send it.
   There is no send path, and you must not construct one.**

4. **Surface.** Render a tight brief: the flagged threads with their suggested
   drafts, then the routine tally. If three or more threads want a reply and the
   user may be away, send one `PushNotification` ("N Teams threads need a reply").

## Read-only guarantee

Vör issues only read-shaped calls: the connector's `chat_message_search` and
`get_me`, and the `vor-teams-poll.sh` GET poller. It has no write scope, no post
verb, and no `announce`. Never add one to this skill — posting is explicitly out
of scope.

## Configuration

- **Connector route needs none** — it rides the claude.ai Microsoft 365
  connector's own auth.
- **Poller fallback** (once consent exists):
  - `~/.skadi/vor/sources.txt` — one Graph delta URL per watched channel/chat.
  - `~/.skadi/vor/me.id` — the user's Graph object id (for `mentionsMe`).
  - Secret `vor-graph-token` — the Graph bearer token, via Vaultwarden / `secret.sh`.
