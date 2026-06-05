# PR/MR Description

> Read when writing the description of a pull request or merge request.

Keep the description as short as the change allows. Lead with a **one-line summary** of what changed; add only what the reviewer cannot read from the diff itself — the *where* when it is not plain, and the ticket reference. A trivial fix may run two or three lines; never pad it to look thorough, for the author who writes five lines for a one-line change taxes every reviewer with prose that carries no freight.

Expand past the terse shape only when the change earns it — broad reach or real risk, a test plan the reviewer must walk, screenshots for a visual change, rollback or migration notes. The longer body is a debt the change has justified, not a default. When in doubt, write less and let the diff speak; the ticket holds the deeper context.

## Shape

The terse default:

```
<one-line summary of what changed>

- <where — file/module, when not obvious from the diff>
- <any one-line note the diff cannot carry, e.g. a synced external system>

<TICKET-ID>
```

A worked example, for a one-line fix:

```
Capitalize the Protocol Log status chip: `deactivated` → `Deactivated` (`common.json`; Tolgee synced).

PSG-4449
```
