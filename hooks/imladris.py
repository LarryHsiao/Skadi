#!/usr/bin/env python3
"""imladris.py — gather several repos into one empty folder, to work across them.

    imladris.py --groups FILE --protected FILE build <group|repo|source>...
    imladris.py --groups FILE --protected FILE sync
    imladris.py --groups FILE --protected FILE done [--confirm]

The folder it runs in is the workspace; each repo is cloned into its own
subfolder and the set is recorded in `.imladris` so later verbs can find it.
`repo_groups.md` (FILE after --groups) holds two line shapes, `#` comments and
a leading `- ` being ignored:

    alpha = git@host:org/alpha.git       a repo: folder name = source
    greek: alpha beta                    a group: a name for several repos

A name resolves to a group, else a repo; anything that looks like a git source
(contains `/` or `:`, or ends `.git`) is cloned as it stands. Repos registered
in the protected-repos file (FILE after --protected) are refused, by the alias
and by the folder the source would clone into.

`done` only reports unless given --confirm, and deletes nothing while any clone
holds work no remote has (uncommitted or untracked files, a stash, a commit on
any ref, a git that cannot be read, a symlink in the clone's place).

Python 3 standard library only; git must be on PATH. macOS and Windows alike.
"""

import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

MARKER = ".imladris"
IGNORED_ENTRIES = frozenset({".claude", ".DS_Store"})
# Compared case-folded: a folder must not stand over git's own directory or the marker.
UNSAFE_FOLDERS = frozenset({"", ".", "..", ".git", MARKER})
SAFE_FOLDER = re.compile(r"[^/\\:]+")
SOURCE_HINT = re.compile(r"[/:]|\.git$")
FOLDER_SPLIT = re.compile(r"[/\\:]")
REPO_LINE = re.compile(r"^(?P<name>[\w.-]+)\s*=\s*(?P<source>\S+)$")
GROUP_LINE = re.compile(r"^(?P<name>[\w.-]+):\s+(?P<members>.+)$")
PROTECTED_LINE = re.compile(r"^-\s+(?P<path>.+?)\s+(?:→|->)\s+")
IGNORED_SHOWN = 3
# Seconds to wait for a remote when confirming its tags; override for tests.
REMOTE_TIMEOUT = int(os.environ.get("IMLADRIS_REMOTE_TIMEOUT", "30"))
# Variables that tell git which repository to act on. Left in the caller's
# environment they override `git -C <repo>`, so every probe would read another
# repo (git itself sets GIT_DIR for the hooks it runs).
REPO_LOCATION_VARS = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_NAMESPACE",
    "GIT_PREFIX",
)
UNPUSHED = ("rev-list", "--count", "--all", "--reflog", "--not", "--remotes")
# The flags override user and .gitmodules settings (status.showUntrackedFiles=no,
# submodule.<name>.ignore=all) that would otherwise let a dirty clone read clean.
STATUS = ("status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none")


class Refusal(Exception):
    """A request the verb will not carry out; the message says why."""


class GitError(Exception):
    """A git probe that exited non-zero; its empty output must not read as 'clean'."""


def _lines(text):
    for raw in text.splitlines():
        line = raw.strip().removeprefix("- ").strip()
        if line and not line.startswith("#"):
            yield line


def parse_state(text):
    """(repos, groups) read from repo_groups.md text."""
    repos, groups = {}, {}
    for line in _lines(text):
        repo, group = REPO_LINE.match(line), GROUP_LINE.match(line)
        if repo:
            repos[repo["name"]] = repo["source"]
        elif group:
            groups[group["name"]] = group["members"].split()
    return repos, groups


def folder_name(source):
    """The subfolder a source clones into: its last path part, sans `.git`."""
    tail = FOLDER_SPLIT.split(source.rstrip("/\\"))[-1]
    return tail.removesuffix(".git")


def protected_names(text):
    """Lower-cased folder names of the repos the protected file registers."""
    found = (PROTECTED_LINE.match(line) for line in text.splitlines())
    return {Path(m["path"]).name.lower() for m in found if m}


def _require_safe_folder(folder):
    """A folder must be one plain path part, or it could land outside the workspace."""
    if folder.casefold() in UNSAFE_FOLDERS or not SAFE_FOLDER.fullmatch(folder):
        raise Refusal(f"'{folder}' is not a folder of its own beneath the workspace")


def _require_distinct(folders):
    """Two folders differing only by case are one folder on macOS and Windows."""
    if len({folder.casefold() for folder in folders}) != len(list(folders)):
        raise Refusal("two folders differ only by letter case — they would collide on this system")


def _vetted(source):
    if source.startswith("-"):
        raise Refusal(f"'{source}' looks like a git option, not a repo name or source")
    return source


def _source_of(token, repos, groups):
    if token in repos:
        source = _vetted(repos[token])
        _require_safe_folder(token)
        return token, source
    if SOURCE_HINT.search(token):
        folder = folder_name(_vetted(token))
        _require_safe_folder(folder)
        return folder, token
    known = ", ".join(sorted(groups)) or "none"
    raise Refusal(f"unknown name '{_vetted(token)}' — known groups: {known}")


def resolve(tokens, repos, groups):
    """Ordered (folder, source) pairs for every token, groups expanded."""
    wanted = {}
    for token in tokens:
        members = groups.get(token) or [token]
        for member in members:
            folder, source = _source_of(member, repos, groups)
            if wanted.setdefault(folder, source) != source:
                raise Refusal(f"two different sources would both clone into '{folder}'")
    _require_distinct(wanted)
    return list(wanted.items())


def refuse_protected(pairs, protected):
    for folder, source in pairs:
        if {folder.lower(), folder_name(source).lower()} & protected:
            raise Refusal(f"'{folder}' ({source}) is a protected repo — work on it from its own session")


def require_empty(workspace):
    if (workspace / MARKER).exists():
        raise Refusal("this folder is already a workspace — use `sync` to repair it")
    content = sorted(p.name for p in workspace.iterdir() if p.name not in IGNORED_ENTRIES)
    if content:
        raise Refusal(f"folder is not empty ({', '.join(content[:5])}) — start in an empty one")


def _git_env():
    return {k: v for k, v in os.environ.items() if k not in REPO_LOCATION_VARS}


def clone(source, destination):
    done = subprocess.run(
        ["git", "clone", "--quiet", "--", source, str(destination)],
        capture_output=True,
        text=True,
        errors="replace",
        env=_git_env(),
    )
    if done.returncode != 0:
        raise Refusal(f"clone of {source} failed: {done.stderr.strip()}")


def write_marker(workspace, pairs):
    record = {"repos": dict(pairs)}
    (workspace / MARKER).write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")


def read_marker(workspace):
    """The recorded {folder: source}, each folder re-checked: a hand-edited marker is not trusted."""
    marker = workspace / MARKER
    if not marker.is_file():
        raise Refusal("this folder is not a workspace — `build` one in an empty folder first")
    try:
        repos = json.loads(marker.read_text(encoding="utf-8"))["repos"]
    except (ValueError, KeyError, TypeError) as why:
        raise Refusal(f"{MARKER} cannot be read ({why})") from why
    for folder in repos:
        _require_safe_folder(folder)
    _require_distinct(repos)
    return repos


def _run(prefix, args, timeout=None):
    return subprocess.run(
        [*prefix, *args],
        capture_output=True,
        text=True,
        errors="replace",
        env=_git_env(),
        timeout=timeout,
    )


def _git(repo, *args):
    return _run(["git", "-C", str(repo)], args)


def _first_line(text):
    lines = text.strip().splitlines()
    return lines[0] if lines else "no detail"


def _checked(done, args):
    if done.returncode != 0:
        raise GitError(_first_line(done.stderr) if done.stderr.strip() else f"git {args[0]} failed")
    return done.stdout.strip()


def _probe(prefix, *args, timeout=None):
    """Stdout of a git probe; a failure of any kind raises, so silence never reads as 'clean'."""
    try:
        return _checked(_run(prefix, args, timeout), args)
    except subprocess.TimeoutExpired as why:
        raise GitError(f"git {args[0]} timed out after {timeout}s") from why
    except OSError as why:
        raise GitError(f"git {args[0]} could not be run ({why})") from why


def _repo_prefix(repo):
    return ["git", "-C", str(repo)]


def git_text(repo, *args):
    return _probe(_repo_prefix(repo), *args)


def _fast_forward(destination):
    if git_text(destination, *STATUS):
        return "skipped", "uncommitted changes"
    before = git_text(destination, "rev-parse", "HEAD")
    pulled = _git(destination, "pull", "--ff-only", "--quiet")
    if pulled.returncode != 0:
        return "skipped", f"cannot fast-forward ({_first_line(pulled.stderr)})"
    return ("current" if git_text(destination, "rev-parse", "HEAD") == before else "updated"), ""


def _clone_verb(source, destination):
    try:
        clone(source, destination)
    except Refusal as why:
        return "failed", str(why)
    return "cloned", ""


def sync_one(destination, source):
    """(verb, note) for one repo: cloned, updated, current, skipped or failed."""
    if destination.is_symlink():
        return "skipped", "a symlink stands in its place"
    if not destination.exists():
        return _clone_verb(source, destination)
    if not (destination / ".git").exists():
        return "skipped", "not a git repo"
    try:
        return _fast_forward(destination)
    except GitError as why:
        return "skipped", f"git could not be read ({why})"


def sync(workspace):
    """Repair the workspace; returns how many repos failed outright."""
    results = []
    for folder, source in read_marker(workspace).items():
        verb, note = sync_one(workspace / folder, source)
        print(f"{verb}: {folder}" + (f" — {note}" if note else ""))
        results.append(verb)
    return sum(1 for verb in results if verb == "failed")


def _linked_worktrees(repo):
    """Paths of worktrees attached to the clone besides its own; the first listed is its own."""
    listing = git_text(repo, "worktree", "list", "--porcelain").splitlines()
    return [line.removeprefix("worktree ") for line in listing if line.startswith("worktree ")][1:]


def _is_gitdir(dirs, files):
    """The shape of a git directory: a HEAD file beside an objects folder."""
    return "HEAD" in files and "objects" in dirs


def _module_gitdirs(repo):
    """Every submodule git dir beneath .git/modules, nested ones included."""
    found = []
    for root, dirs, files in os.walk(repo / ".git" / "modules"):
        if _is_gitdir(dirs, files):
            found.append(Path(root))
        dirs[:] = [d for d in dirs if d != "objects"]
    return found


def _local_path(url):
    """The filesystem path a remote URL names, or None for a network address."""
    if url.startswith("file://"):
        return Path(url.removeprefix("file://"))
    if "://" in url or ":" in url.split("/", 1)[0]:
        return None
    return Path(url).expanduser()


def _remote_is_within(url, repo, workspace):
    """True when a remote is the clone itself or a sibling clone — not a place work is safe."""
    path = _local_path(url)
    if path is None:
        return False
    target = (path if path.is_absolute() else repo / path).resolve()
    root = workspace.resolve()
    return target == root or root in target.parents


def _tags_held_by_remotes(prefix, repo):
    """Objects of the local tags a remote also holds under the same name.

    A fetched tag is indistinguishable from a local one by ref alone, and a
    release tag may point at a commit on no branch; only the remote can say.
    Remotes lying inside the workspace are not asked: they die with it.
    """
    held = set()
    for remote in _probe(prefix, "remote").split():
        if _remote_is_within(_probe(prefix, "remote", "get-url", "--", remote), repo, repo.parent):
            continue
        listing = _probe(
            prefix, "ls-remote", "--tags", "--refs", "--", remote, timeout=REMOTE_TIMEOUT
        )
        for line in listing.splitlines():
            sha, _, ref = line.partition("\t")
            held.add((ref, sha))
    local = _probe(prefix, "for-each-ref", "refs/tags", "--format=%(refname) %(objectname)")
    pairs = (line.split(" ", 1) for line in local.splitlines())
    return [sha for ref, sha in pairs if (ref, sha) in held]


def _unpushed_count(prefix, repo):
    """Commits on any ref or in the reflog that no remote holds, as a string.

    Tags count at first; only when they are what stands between the clone and
    zero does the remote get asked which of them it already holds.
    """
    count = _probe(prefix, *UNPUSHED)
    if count == "0":
        return count
    pushed_tags = _tags_held_by_remotes(prefix, repo)
    return _probe(prefix, *UNPUSHED, *pushed_tags) if pushed_tags else count


def _unpushed_in_modules(repo):
    """Submodule history lives in .git/modules and is deleted with the clone."""
    for gitdir in _module_gitdirs(repo):
        count = _unpushed_count(["git", "--git-dir", str(gitdir)], repo)
        if count != "0":
            name = gitdir.relative_to(repo / ".git" / "modules")
            return f"submodule {name} holds {count} commit(s) no remote has"
    return ""


def _hides_edits(repo):
    """True when a file is flagged assume-unchanged or skip-worktree, so status cannot see its edits."""
    listing = git_text(repo, "ls-files", "-v").splitlines()
    return any(line[:1] == "S" or line[:1].islower() for line in listing)


def _unsaved_in(repo):
    if git_text(repo, *STATUS):
        return "uncommitted or untracked files"
    if _hides_edits(repo):
        return "files flagged assume-unchanged or skip-worktree can hide edits from git"
    if git_text(repo, "stash", "list"):
        return "a stash holds work"
    if _linked_worktrees(repo):
        return "a linked worktree is attached — `git worktree remove` it first"
    unpushed = _unpushed_count(_repo_prefix(repo), repo)
    if unpushed != "0":
        return f"{unpushed} commit(s) not pushed to any remote (the reflog counts)"
    return _ignored_repo(repo) or _unpushed_in_modules(repo)


def unsaved_work(repo):
    """Why a clone cannot be thrown away, or "" when nothing would be lost."""
    if repo.is_symlink():
        return "a symlink stands in its place — remove it by hand"
    if not (repo / ".git").exists():
        return "not a git repo — remove it by hand"
    try:
        return _unsaved_in(repo)
    except GitError as why:
        return f"git could not be read ({why})"


def ignored_items(repo):
    """Git-ignored paths (a .env, a build folder) — not work to push, but they go with the clone."""
    listing = git_text(repo, "status", "--porcelain", "-z", "--ignored").split("\0")
    return [entry[3:] for entry in listing if entry.startswith("!! ")]


def _holds_own_repo(folder):
    """A worktree (`.git` dir or gitfile) or a bare/separate git dir lives somewhere in it."""
    return any(
        ".git" in dirs or ".git" in files or _is_gitdir(dirs, files)
        for _, dirs, files in os.walk(folder)
    )


def _ignored_repo(repo):
    """An ignored folder with a git repo of its own holds history no remote has."""
    for item in ignored_items(repo):
        if item.endswith("/") and _holds_own_repo(repo / item):
            return f"ignored folder {item} holds a git repo of its own"
    return ""


def _may_chmod(victim, root):
    """True only for a path inside the clone that no outside name can reach.

    chmod follows symlinks and changes a hard-linked inode for every name it has,
    and the clone's parent is the workspace; so a symlink, a file with a second
    link, or anything outside the clone is left alone.
    """
    if victim != root and root not in victim.parents:
        return False
    if victim.is_symlink():
        return False
    return victim.is_dir() or victim.stat().st_nlink == 1


def _remove_tree(path):
    """Delete a clone, clearing read-only flags only where `_may_chmod` allows."""
    root = Path(path)

    def force(function, target, _error):
        for victim in (Path(target), Path(target).parent):
            if _may_chmod(victim, root):
                try:
                    os.chmod(victim, stat.S_IRWXU)
                except OSError:
                    pass  # the retry below fails loudly if the flag really was the obstacle
        function(target)

    handler = "onexc" if sys.version_info >= (3, 12) else "onerror"
    shutil.rmtree(root, **{handler: force})


def _done_line(workspace, folder, reasons):
    if folder not in reasons:
        return f"absent: {folder}"
    if reasons[folder]:
        return f"blocked: {folder} — {reasons[folder]}"
    try:
        ignored = ignored_items(workspace / folder)
    except GitError as why:
        return f"clean: {folder} — ignored files could not be listed ({why})"
    shown = ", ".join(ignored[:IGNORED_SHOWN])
    note = f" — {len(ignored)} ignored item(s) go with it ({shown})" if ignored else ""
    return f"clean: {folder}{note}"


def _teardown(workspace, folders):
    """Remove each clone; returns how many could not be removed (the marker stays then)."""
    failed = 0
    for folder in folders:
        try:
            _remove_tree(workspace / folder)
        except OSError as why:
            print(f"failed: {folder} — could not be removed ({why}); remove it by hand")
            failed += 1
        else:
            print(f"removed: {folder}")
    if failed:
        print("imladris: the workspace is partly torn down — remove the folders marked `failed`"
              " and then `.imladris` by hand; do not run `sync`, it would clone the removed ones back")
    else:
        (workspace / MARKER).unlink()
    return failed


def done(workspace, *, confirm):
    """Report each clone; delete them all only if every one is safe. Returns blocked count."""
    folders = list(read_marker(workspace))
    reasons = {f: unsaved_work(workspace / f) for f in folders if os.path.lexists(workspace / f)}
    for folder in folders:
        print(_done_line(workspace, folder, reasons))
    blocked = sum(1 for reason in reasons.values() if reason)
    if confirm and not blocked:
        return _teardown(workspace, list(reasons))
    return blocked


def build(workspace, tokens, state_text, protected_text):
    repos, groups = parse_state(state_text)
    pairs = resolve(tokens, repos, groups)
    refuse_protected(pairs, protected_names(protected_text))
    require_empty(workspace)
    write_marker(workspace, pairs)
    for folder, source in pairs:
        clone(source, workspace / folder)
        print(f"cloned: {folder}")


def read_optional(path):
    candidate = Path(path)
    return candidate.read_text(encoding="utf-8") if candidate.is_file() else ""


def read_protected(path):
    """The protected list's text; an absent list is said aloud, never taken as 'nothing protected'."""
    if not Path(path).is_file():
        print(f"imladris: no protected-repos list at {path} — protection not checked", file=sys.stderr)
        return ""
    return read_optional(path)


def parser():
    top = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    top.add_argument("--groups", required=True, help="repo_groups.md path")
    top.add_argument("--protected", required=True, help="protected_repos.md path")
    verbs = top.add_subparsers(dest="verb", required=True)
    verbs.add_parser("build").add_argument("tokens", nargs="+")
    verbs.add_parser("sync")
    verbs.add_parser("done").add_argument("--confirm", action="store_true")
    return top


def main(argv):
    args = parser().parse_args(argv)
    workspace = Path.cwd()
    try:
        if args.verb == "build":
            build(workspace, args.tokens, read_optional(args.groups), read_protected(args.protected))
            return 0
        if args.verb == "sync":
            return 1 if sync(workspace) else 0
        return 1 if done(workspace, confirm=args.confirm) else 0
    except Refusal as why:
        print(f"imladris: {why}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
