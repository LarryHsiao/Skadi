#!/usr/bin/env bash
# Vör TeamsSource normalizer (pure). Graph chatMessage delta JSON on stdin,
# --me <userId> flags self-mentions. Normalized message array on stdout.
# READ-ONLY concern: shape only, no I/O beyond stdin/stdout.
set -euo pipefail

ME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --me) ME="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

jq --arg me "$ME" '
  [ .value[]?
    | select(.messageType == "message")
    | select(.from.user != null)
    | {
        id: .id,
        sender: (.from.user.displayName // "unknown"),
        thread: ((.channelIdentity.channelId // .chatId // "unknown")
                 + ":" + (.replyToId // .id)),
        timestamp: (.createdDateTime // ""),
        mentionsMe: ([ .mentions[]?.mentioned.user.id ] | index($me) != null),
        text: ( (.body.content // "")
                | gsub("<[^>]*>"; "")
                | gsub("&nbsp;"; " ")
                | gsub("&amp;"; "&")
                | gsub("&lt;"; "<")
                | gsub("&gt;"; ">")
                | gsub("^\\s+"; "")
                | gsub("\\s+$"; "") )
      }
  ]
'
