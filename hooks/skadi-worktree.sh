#!/usr/bin/env bash
# skadi-worktree.sh — Acquire and release an isolated source-code workspace
# so a skill can read or write the repo without disturbing the human's main
# checkout. Workspaces live under $TMPDIR (or /tmp), are auto-removed by the
# release verb on success, and stay intact when the skill aborts so the human
# can inspect what was left.
#
# Verbs
# -----
#
#   acquire <repo-path> [branch-or-ref]
#       Try `git worktree add` first (fast — shares the object store with the
#       source repo). On any worktree failure (most commonly: the branch is
#       already checked out elsewhere) fall back to `git clone <repo>` into the
#       same path. In clone mode, origin is re-pointed at the source repo's
#       origin so `git push` reaches the real remote.
#
#       If a branch/ref is supplied, the workspace is checked out on it. If
#       absent, the worktree is created with a detached HEAD at the source
#       repo's HEAD (clone fallback simply leaves the clone's default branch).
#
#       Prints the absolute workspace path on stdout. Exits non-zero with a
#       one-line message on stderr if acquire cannot succeed.
#
#   release <workspace-path>
#       Tear down the workspace. Worktree mode: `git worktree remove --force`
#       (falling back to `rm -rf` if git refuses). Clone mode: `rm -rf`. A
#       missing path is a silent success.
#
# Detection. A workspace's `.git` is a file (worktree) or a directory (clone);
# release branches on that to choose the right teardown.

set -e

die() {
  echo "skadi-worktree: $1" >&2
  exit 1
}

verb="${1:-}"
shift || true

case "$verb" in
  acquire)
    src="${1:-}"
    branch="${2:-}"
    [ -n "$src" ] || die "acquire: missing repo path"
    [ -d "$src" ] || die "acquire: not a directory: $src"

    repo=$(cd "$src" && git rev-parse --show-toplevel 2>/dev/null) \
      || die "acquire: not a git repo: $src"

    tmp_root="${TMPDIR:-/tmp}"
    tmp_root="${tmp_root%/}"
    path="${tmp_root}/skadi-$(date +%s)-$$-${RANDOM}"

    # Worktree first.
    if [ -n "$branch" ]; then
      if git -C "$repo" worktree add --quiet "$path" "$branch" 2>/dev/null; then
        echo "$path"
        exit 0
      fi
    else
      if git -C "$repo" worktree add --quiet --detach "$path" HEAD 2>/dev/null; then
        echo "$path"
        exit 0
      fi
    fi

    # Clone fallback.
    git clone --quiet "$repo" "$path" \
      || die "acquire: worktree refused and clone failed for $repo"

    origin_url=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
    if [ -n "$origin_url" ]; then
      git -C "$path" remote set-url origin "$origin_url"
      git -C "$path" fetch --quiet origin 2>/dev/null || true
    fi

    if [ -n "$branch" ]; then
      if ! git -C "$path" checkout --quiet "$branch" 2>/dev/null; then
        git -C "$path" checkout --quiet -B "$branch" "origin/$branch" 2>/dev/null \
          || die "acquire: cannot check out $branch in clone"
      fi
    fi

    echo "$path"
    ;;

  release)
    path="${1:-}"
    [ -n "$path" ] || die "release: missing workspace path"
    [ -e "$path" ] || exit 0

    if [ -f "$path/.git" ]; then
      common_dir=$(git -C "$path" rev-parse --git-common-dir 2>/dev/null || true)
      main_repo=""
      if [ -n "$common_dir" ]; then
        # rev-parse may return a relative path; resolve it. Both unix
        # (/foo) and Windows (C:/foo, C:\foo) absolute forms are already
        # resolved — only a genuinely relative path gets the $path prefix.
        case "$common_dir" in
          /* | [A-Za-z]:[\\/]*) ;;
          *) common_dir="$path/$common_dir" ;;
        esac
        main_repo=$(cd "$common_dir/.." 2>/dev/null && pwd) || main_repo=""
      fi
      if [ -n "$main_repo" ]; then
        git -C "$main_repo" worktree remove --force "$path" 2>/dev/null \
          || rm -rf "$path"
        # Always prune: on some platforms `git worktree add` records the
        # path in a form that `remove` above will not match (e.g. Windows
        # native vs. MSYS path), leaving a dangling registration the rm
        # cannot clear. Prune sweeps any such stale entry.
        git -C "$main_repo" worktree prune 2>/dev/null || true
      else
        rm -rf "$path"
      fi
    else
      rm -rf "$path"
    fi
    ;;

  *)
    die "unknown verb '${verb:-(none)}' — expected 'acquire' or 'release'"
    ;;
esac
