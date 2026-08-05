#!/usr/bin/env python3
"""bq_common — the bq-CLI scaffolding every BigQuery-backed hook shares.

Lifted once three hooks (appgrowth.py, beleg-crashes.py, board-stability.py)
had each pasted the same QueryFailure/exe() pair — the third copy is the line
docs/style/universal.md draws for lifting a duplicate shape. Each hook's own
bq-invocation function (bq(), bq_rows(), bq_count()) stays where it is; their
exact flags differ enough per hook that only this shared scaffolding, not the
invocation itself, was truly the same shape three times over.
"""

import shutil


class QueryFailure(RuntimeError):
    """A bq invocation that never ran the query — distinct from one returning no rows.

    Without this distinction an expired token, a missing IAM grant, and a
    genuinely empty dataset all read the same way, and the real cause never
    reaches the user.
    """


def exe(name):
    """Resolve a CLI name to its full path — finds .cmd shims on Windows via PATHEXT."""
    return shutil.which(name) or name
