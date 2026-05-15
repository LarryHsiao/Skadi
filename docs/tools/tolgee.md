# Tolgee

## Source of truth

When a project is wired to Tolgee, **every i18n change starts in Tolgee** — adding a key, editing a value, renaming, deleting. The local resource files (`*.arb`, `*.json`, `messages.properties`, and the like) are downstream artifacts: pulled from Tolgee, never edited by hand. A direct edit to the local file is a phantom — the next pull overwrites it, and the translators on Tolgee never see the change.

The order is: edit in Tolgee → pull → commit the regenerated files. Code that *references* a key (using it in a widget, a template, a string lookup) is ordinary source and edits as such; only the **definition** of the key and its translated values lives upstream.

## All languages move together

When adding or updating a key in Tolgee, **every supported language must move with it** — translate (or at least seed) each locale in the same change. Leave a language out and the UI degrades silently for its users: the missing locale shows the key id, the English fallback, or an empty cell, depending on the consumer.

The rule yields only when the user says so explicitly — "skip Japanese, the translator handles it on Friday", "EN-only for now". When a locale is left behind by intent, name what is owed so it does not ship forgotten.

## Pushing values

When pushing a translation value to Tolgee, the value must keep its line separators as raw newlines. Do not escape them into `\n` (or `\r\n`) sequences in the payload.

Tolgee stores the value as it arrives. Escaped separators land in the stored string verbatim and surface to consumers as the literal two-character sequence `\n` rather than a true line break — corrupting the rendered text.

Before any push — CLI, API call, or import script — inspect multiline values. The on-the-wire JSON should carry a JSON-encoded newline (`"\n"` in the source, decoding to a real newline byte), not a doubly-escaped `"\\n"`. If the tooling double-escapes by default, disable that behavior or unescape before the push.

## Debugging line separators

When a translation surfaces a literal `\n` to consumers instead of a true line break, the cure is not to guess at the push tool — it is to **push, then pull the result** and read what Tolgee actually stored. The round-trip is the test.

**The push-then-pull ritual.**

1. **Push** the value through whatever path is suspect — CLI, import script, API call.
2. **Pull** the same key back from Tolgee's API:

   ```bash
   curl -s -H "X-API-Key: $TOLGEE_TOKEN" \
     "$TOLGEE_URL/v2/projects/$PROJECT_ID/translations?filterKeyName=$KEY" \
     | jq -r '.._embedded.keys[].translations[].text'
   ```

   `jq -r` decodes the JSON string. If the stored value is healthy, the output prints across multiple lines. If the literal characters `\` and `n` appear in the output, the stored value is double-escaped — the bug is upstream of Tolgee.

3. **Inspect the raw JSON** without `-r` to see the wire form. A correct value carries `"line one\nline two"` (one backslash, one `n` — a JSON-encoded newline). A broken value carries `"line one\\nline two"` (two backslashes — the backslash itself was escaped, so Tolgee stored a literal `\n`).

**Reading the wire form.**

| Wire JSON           | Stored bytes              | Renders as              | Verdict |
|---------------------|---------------------------|-------------------------|---------|
| `"a\nb"`            | `a` `\n` `b` (newline)    | two lines               | healthy |
| `"a\\nb"`           | `a` `\` `n` `b`           | the literal `a\nb`      | broken  |

**Common causes, in order of likelihood.**

- The push tool JSON-encoded a string that was already JSON-encoded — one pass too many.
- The source on disk (YAML, JSON, properties file) carried escape sequences that the loader did not unescape before handing the value to the push tool.
- Shell quoting preserved the backslash — `echo "a\nb"` emits four characters in most shells; `printf 'a\nb'` emits a real newline. Quoting choices matter when piping into the push.

**Fix at the source.** Repair the layer that introduced the extra escape — never paper over it at the consumer or by post-processing the stored value. After the fix, run the push-then-pull ritual again on the same key; the stored bytes are the only honest verdict.
