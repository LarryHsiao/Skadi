# jq

Default to `jq` for reading or editing JSON files above a few KB — loading the whole file wastes context that a targeted query would not. This applies especially to generated specs and manifests (OpenAPI/Swagger, `package-lock.json`-style files) where only one endpoint or one entry matters to the task at hand.

## Reading

- `jq 'keys' file.json` — top-level structure
- `jq '.paths | keys' file.json` — list of a swagger file's endpoints
- `jq '.paths["/some/path"]' file.json` — one endpoint's full definition
- `jq '.definitions["SomeSchema"]' file.json` — a referenced schema by name (follow `$ref` pointers the same way)

## Editing

Patch through a temp file — jq cannot write in place:

```bash
jq '.paths["/x"].patch.summary = "New summary"' file.json > tmp && mv tmp file.json
```

For a multi-field change, extract the slice, edit it with a normal editor, then splice it back:

```bash
jq --argjson patch "$(cat slice.json)" '.paths["/x"] = $patch' file.json > tmp && mv tmp file.json
```

## If jq is missing

Check with `command -v jq` before falling back to a full-file read or edit. If it's absent, stop and prompt the user to install it rather than silently reading the whole file:

- macOS: `brew install jq`
- Windows: `winget install jqlang.jq` (or `scoop install jq`)
- Linux: distro package manager (`apt install jq`, `dnf install jq`, …)

Only fall back to reading the whole file if the user declines to install.
