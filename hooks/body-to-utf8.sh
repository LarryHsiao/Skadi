#!/usr/bin/env bash
# Normalize a comment/description body file to UTF-8, in place.
# Usage: body-to-utf8.sh <file> [label]   (label names the body in the error; default "comment")
#   exit 0  file is UTF-8 (already, or converted from CP1252)
#   exit 1  file is neither; prints the JSON error the posting hooks emit
#
# Decoded in Python rather than with iconv: Apple's iconv reads a file in
# 1024-byte chunks and rejects valid UTF-8 whose multibyte character straddles
# a chunk edge, after which a CP1252 fallback would re-encode it as mojibake.

set -u

python -I - "$1" "${2:-comment}" <<'PY'
import sys

path, label = sys.argv[1], sys.argv[2]
raw = open(path, "rb").read()
try:
    raw.decode("utf-8")
    sys.exit(0)
except UnicodeDecodeError:
    pass
try:
    text = raw.decode("cp1252")
except UnicodeDecodeError:
    print('{"error":"%s body is neither valid UTF-8 nor CP1252"}' % label)
    sys.exit(1)
open(path, "wb").write(text.encode("utf-8"))
PY
