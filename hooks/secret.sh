#!/bin/bash
# Usage: secret.sh <service> [field] [env_override]
#
# Resolves a credential field for <service> from Vaultwarden via `bw serve`,
# falling back to an env var if the vault is unreachable or empty.
#
# A single Bitwarden item per service carries the URI, username, and password
# as a unit (item name = lowercase service, e.g. "youtrack", "jira").
#
# Args:
#   service       Bitwarden item name. Required.
#   field         password|uri|username|notes. Default: password.
#   env_override  Env var name to fall back to. Default: auto-mapped.
#                 Pass "-" to skip env fallback entirely (vault-only).
#
# Auto env-var = <SERVICE_UPPER>_<SUFFIX>, where:
#   password -> TOKEN
#   uri      -> URL
#   username -> USERNAME
#   notes    -> NOTES
#
# Prints the resolved value to stdout. Exits 1 with stderr on miss.

set -euo pipefail

SERVICE="${1:-}"
FIELD="${2:-password}"
ENV_OVERRIDE="${3:-}"

if [[ -z "$SERVICE" ]]; then
  echo "secret.sh: service name required" >&2
  exit 1
fi

case "$FIELD" in
  password|uri|username|notes) ;;
  *)
    echo "secret.sh: unknown field '$FIELD' (password|uri|username|notes)" >&2
    exit 1
    ;;
esac

SERVE_URL="${BW_SERVE_URL:-http://localhost:8087}"

if curl -sS --max-time 1 "$SERVE_URL/status" >/dev/null 2>&1; then
  items_resp=$(curl -sS --max-time 5 "$SERVE_URL/list/object/items" 2>/dev/null || true)
  if [[ -n "$items_resp" ]]; then
    case "$FIELD" in
      password) jq_field='.login.password // empty' ;;
      username) jq_field='.login.username // empty' ;;
      uri)      jq_field='.login.uris[0].uri // empty' ;;
      notes)    jq_field='.notes // empty' ;;
    esac
    value=$(printf '%s' "$items_resp" \
      | jq -r --arg name "$SERVICE" \
          "select(.success == true) | .data.data[] | select(.name == \$name) | $jq_field" \
          2>/dev/null \
      | head -n1 || true)
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      exit 0
    fi
  fi
fi

if [[ "$ENV_OVERRIDE" != "-" ]]; then
  if [[ -z "$ENV_OVERRIDE" ]]; then
    service_upper=$(printf '%s' "$SERVICE" | tr '[:lower:]' '[:upper:]')
    case "$FIELD" in
      password) suffix=TOKEN ;;
      uri)      suffix=URL ;;
      username) suffix=USERNAME ;;
      notes)    suffix=NOTES ;;
    esac
    ENV_OVERRIDE="${service_upper}_${suffix}"
  fi
  env_value="${!ENV_OVERRIDE:-}"
  if [[ -n "$env_value" ]]; then
    printf '%s' "$env_value"
    exit 0
  fi
fi

if [[ "$ENV_OVERRIDE" == "-" ]]; then
  echo "secret.sh: '$SERVICE.$FIELD' not in Vaultwarden (bw serve at $SERVE_URL); env fallback disabled" >&2
else
  echo "secret.sh: '$SERVICE.$FIELD' not in Vaultwarden (bw serve at $SERVE_URL) or env \$$ENV_OVERRIDE" >&2
fi

if curl -sS --max-time 1 "$SERVE_URL/status" >/dev/null 2>&1; then
  items=$(curl -sS --max-time 5 "$SERVE_URL/list/object/items" 2>/dev/null \
    | jq -r 'select(.success == true) | .data.data[].name' 2>/dev/null \
    | sort -u || true)
  if [[ -n "$items" ]]; then
    echo "secret.sh: items in vault:" >&2
    while IFS= read -r name; do
      [[ -n "$name" ]] && echo "  - $name" >&2
    done <<<"$items"
  fi
fi
exit 1
