# Tolgee

## Pushing values

When pushing a translation value to Tolgee, the value must keep its line separators as raw newlines. Do not escape them into `\n` (or `\r\n`) sequences in the payload.

Tolgee stores the value as it arrives. Escaped separators land in the stored string verbatim and surface to consumers as the literal two-character sequence `\n` rather than a true line break — corrupting the rendered text.

Before any push — CLI, API call, or import script — inspect multiline values. The on-the-wire JSON should carry a JSON-encoded newline (`"\n"` in the source, decoding to a real newline byte), not a doubly-escaped `"\\n"`. If the tooling double-escapes by default, disable that behavior or unescape before the push.
