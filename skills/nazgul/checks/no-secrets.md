---
name: No committed secrets
scope: [diff, project]
---

Secrets must not live in source. A leaked API key burns the moment it's pushed; rotation is the only remedy. Catching them before merge — and sweeping the standing tree for ones that slipped through — is the cheapest defence.

Scan the given target — whether the supplied diff or the standing project tree — for committed secrets.

**Concrete tokens** (string-match by prefix or pattern):

- AWS access keys: `AKIA[0-9A-Z]{16}` or `ASIA[0-9A-Z]{16}`.
- AWS secret access keys: 40 chars of `[A-Za-z0-9/+=]` near `aws_secret_access_key` / `AWS_SECRET_ACCESS_KEY`.
- GitHub tokens: `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_` followed by 36+ chars.
- Slack tokens: `xox[baprs]-` followed by alphanumerics.
- Stripe keys: `sk_live_`, `sk_test_`, `rk_live_`, `rk_test_`.
- OpenAI / Anthropic keys: `sk-[A-Za-z0-9]{40,}`, `sk-ant-[A-Za-z0-9-]{90,}`.
- Google API keys: `AIza[0-9A-Za-z_-]{35}`.
- JWTs: three base64url segments dot-separated, the first decoding to `{"alg":...}`.
- Private keys: any line containing `-----BEGIN ` followed by `PRIVATE KEY-----` (RSA, EC, OPENSSH, PGP).

**Heuristic shapes**:

- Connection strings with embedded credentials: `<scheme>://<user>:<password>@<host>`, password non-empty.
- `.env`-style assignments where the key looks credential-bearing (`*_TOKEN`, `*_SECRET`, `*_KEY`, `*_PASSWORD`, `*_API_KEY`) and the value is non-empty and not a placeholder.

Pass when:

- No matching pattern appears in the target.
- A match appears only in clearly non-production places:
  - Documentation or comments labelled fake / example / sample / placeholder.
  - Test fixtures using obvious non-production values (`test_key_123`, `EXAMPLE_KEY`, `<your-token-here>`).
  - `.env.example` / `.env.template` / similar files where values are placeholders.

Fail when:

- Any plausible secret is introduced (diff scope) or sits in the project tree (project scope).

Do not flag:

- Public keys (`-----BEGIN PUBLIC KEY-----`, `ssh-rsa AAAA...` in `authorized_keys`-style files).
- Output of hashing — clearly stored hashes, not plaintext.
- Random-looking strings that are demonstrably not credentials (UUIDs, Git commit SHAs, content hashes).

On fail, name each finding as `file:line — <kind of secret>`. Do **not** echo the secret value back; quote only the first few characters of the prefix.
