# Secrets

Secrets live in Vaultwarden. Scripts read them through a single helper — `~/.claude/hooks/secret.sh` — which tries Vaultwarden's `bw serve` REST API first and falls back to an env var. Never read a token directly from `$ENV_VAR` in a hook; always route through the helper.

## One item per service, not per env-var

A token is paired to its server URL; treat them as a unit. Bitwarden's data model already does this:

```
Item: youtrack
  URI:      https://larryhsiao.com:9081
  Username: (optional — service login if relevant)
  Password: <token>
```

Item names are lowercase service names (`youtrack`, `jira`, …). Re-use Bitwarden's native fields rather than inventing custom ones.

## Helper signature

`secret.sh <service> [field] [env_override]`

- `field` defaults to `password`; valid values are `password`, `uri`, `username`, `notes`.
- `env_override` overrides the auto-mapped env-var name. Auto mapping: `password → <SERVICE>_TOKEN`, `uri → <SERVICE>_URL`, `username → <SERVICE>_USERNAME`, `notes → <SERVICE>_NOTES`.

Examples: `secret.sh youtrack` (token), `secret.sh youtrack uri` (URL), `secret.sh jira password JIRA_API_TOKEN` (Jira's env var diverges from the auto map, so override it).

## Per-session ritual

Once per machine: `bw config server <vault-url>`, then `bw login` (interactive). Per terminal session where Claude Code will run:

```
export BW_SESSION=$(bw unlock --raw)
bw serve --port 8087 &
```

The serve process holds the unlocked vault and answers the helper's HTTP calls. If `bw serve` is not reachable, the helper silently falls back to env vars, so old flows still work.

## Authoring new skills

Any hook needing a secret calls `"$(dirname "$0")/secret.sh" <service> [field] [env_override]` and errors plainly if empty. Do not pass secrets through intermediate env vars unless the helper has already supplied them.
