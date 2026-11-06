#!/usr/bin/env python3
"""Tests for imladris.py — driven through its command line against local bare repos."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "imladris.py"
GIT_ENV = {
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@example.com",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.com",
}


def git(cwd, *args):
    env = {**os.environ, **GIT_ENV}
    return subprocess.run(
        ["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True
    ).stdout.strip()


def make_origin(root, name):
    """A bare repo at root/name.git holding one commit on branch main."""
    bare = Path(root) / f"{name}.git"
    seed = Path(root) / f"{name}-seed"
    git(root, "init", "--bare", "-b", "main", str(bare))
    git(root, "init", "-b", "main", str(seed))
    (seed / "README.md").write_text(f"{name}\n")
    git(seed, "add", ".")
    git(seed, "commit", "-m", "first")
    git(seed, "remote", "add", "origin", str(bare))
    git(seed, "push", "origin", "main")
    return bare


def push_commit(root, name, filename, text):
    """A new commit on origin's main, made through the repo's seed clone."""
    seed = Path(root) / f"{name}-seed"
    (seed / filename).write_text(text)
    git(seed, "add", ".")
    git(seed, "commit", "-m", f"add {filename}")
    git(seed, "push", "origin", "main")


class ImladrisCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.alpha = make_origin(self.root, "alpha")
        self.beta = make_origin(self.root, "beta")
        self.ws = self.root / "ws"
        self.ws.mkdir()
        self.groups = self.root / "repo_groups.md"
        self.protected = self.root / "protected_repos.md"
        self.protected.write_text("- /home/x/Minerva → memory\n- /home/x/skadi → skadi\n")
        self.groups.write_text(
            f"alpha = {self.alpha}\nbeta = {self.beta}\n\ngreek: alpha beta\n"
        )

    def run_cli(self, *args, cwd=None, env=None):
        return subprocess.run(
            [
                sys.executable,
                "-I",
                str(SCRIPT),
                "--groups",
                str(self.groups),
                "--protected",
                str(self.protected),
                *args,
            ],
            cwd=cwd or self.ws,
            capture_output=True,
            text=True,
            env={**os.environ, **GIT_ENV, **(env or {})},
        )


class BuildTest(ImladrisCase):
    def test_clones_each_named_source_into_its_own_subfolder(self):
        expected = {"alpha", "beta"}
        result = self.run_cli("build", str(self.alpha), str(self.beta))
        actual = {p.name for p in self.ws.iterdir() if (p / ".git").is_dir()}
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(expected, actual)

    def test_group_name_clones_every_repo_the_group_lists(self):
        expected = {"alpha", "beta"}
        result = self.run_cli("build", "greek")
        actual = {p.name for p in self.ws.iterdir() if (p / ".git").is_dir()}
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(expected, actual)

    def test_records_the_repos_in_a_marker_for_sync_and_done(self):
        expected = {"alpha": str(self.alpha), "beta": str(self.beta)}
        self.run_cli("build", "greek")
        actual = json.loads((self.ws / ".imladris").read_text())["repos"]
        self.assertEqual(expected, actual)

    def test_refuses_a_folder_that_is_not_empty_and_changes_nothing(self):
        (self.ws / "notes.txt").write_text("keep me")
        expected = ["notes.txt"]
        result = self.run_cli("build", "greek")
        actual = sorted(p.name for p in self.ws.iterdir())
        self.assertEqual(1, result.returncode)
        self.assertEqual(expected, actual)

    def test_a_claude_settings_folder_does_not_count_as_content(self):
        (self.ws / ".claude").mkdir()
        result = self.run_cli("build", "greek")
        self.assertEqual(0, result.returncode, result.stderr)

    def test_refuses_a_folder_that_is_already_a_workspace(self):
        self.run_cli("build", "alpha")
        result = self.run_cli("build", "beta")
        self.assertEqual(1, result.returncode)
        self.assertIn("sync", result.stderr)

    def test_unknown_name_is_refused_with_the_known_groups_listed(self):
        result = self.run_cli("build", "nonesuch")
        self.assertEqual(1, result.returncode)
        self.assertIn("greek", result.stderr)
        self.assertEqual([], list(self.ws.iterdir()))

    def test_a_source_that_would_clone_over_git_or_the_marker_is_refused(self):
        for source in ("some/where/.git.git", "some/where/.imladris.git"):
            result = self.run_cli("build", source)
            self.assertEqual(1, result.returncode, source)
        self.assertEqual([], list(self.ws.iterdir()))

    def test_a_source_that_names_a_parent_folder_is_refused(self):
        result = self.run_cli("build", "some/path/..")
        self.assertEqual(1, result.returncode)
        self.assertEqual([], list(self.ws.iterdir()))

    def test_two_sources_whose_folders_differ_only_by_case_are_refused(self):
        other = self.root / "other"
        other.mkdir()
        shared = make_origin(other, "ALPHA")
        result = self.run_cli("build", str(self.alpha), str(shared))
        self.assertEqual(1, result.returncode)
        self.assertEqual([], list(self.ws.iterdir()))

    def test_a_git_dir_in_the_callers_environment_does_not_hijack_the_clone(self):
        result = self.run_cli("build", "alpha", env={"GIT_DIR": str(self.root / "hijack.git")})
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue((self.ws / "alpha" / ".git").is_dir())
        self.assertFalse((self.root / "hijack.git").exists())

    def test_an_alias_cannot_smuggle_in_a_protected_source(self):
        skadi = make_origin(self.root, "skadi")
        self.groups.write_text(f"cfg = {skadi}\n")
        result = self.run_cli("build", "cfg")
        self.assertEqual(1, result.returncode)
        self.assertEqual([], list(self.ws.iterdir()))

    def test_an_alias_bearing_a_protected_name_is_refused_too(self):
        self.groups.write_text(f"skadi = {self.alpha}\n")
        result = self.run_cli("build", "skadi")
        self.assertEqual(1, result.returncode)
        self.assertEqual([], list(self.ws.iterdir()))

    def test_a_repo_line_whose_source_looks_like_a_git_option_is_refused(self):
        self.groups.write_text(f"evil = --upload-pack={self.root}/pwned/x\n")
        result = self.run_cli("build", "evil")
        self.assertEqual(1, result.returncode)
        self.assertFalse((self.root / "pwned").exists())
        self.assertEqual([], list(self.ws.iterdir()))

    def test_an_option_shaped_argument_on_the_command_line_clones_nothing(self):
        result = self.run_cli("build", f"--upload-pack={self.root}/pwned/x")
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.root / "pwned").exists())
        self.assertEqual([], list(self.ws.iterdir()))

    def test_a_missing_protected_list_warns_and_still_builds(self):
        self.protected.unlink()
        result = self.run_cli("build", "alpha")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("protection not checked", result.stderr)

    def test_protected_repo_is_refused_before_anything_is_cloned(self):
        minerva = make_origin(self.root, "Minerva")
        result = self.run_cli("build", str(self.alpha), str(minerva))
        self.assertEqual(1, result.returncode)
        self.assertIn("Minerva", result.stderr)
        self.assertEqual([], list(self.ws.iterdir()))

    def test_protected_repo_named_by_a_group_is_refused_too(self):
        skadi = make_origin(self.root, "skadi")
        self.groups.write_text(f"skadi = {skadi}\nalpha = {self.alpha}\nmix: alpha skadi\n")
        result = self.run_cli("build", "mix")
        self.assertEqual(1, result.returncode)
        self.assertEqual([], list(self.ws.iterdir()))


class SyncTest(ImladrisCase):
    def setUp(self):
        super().setUp()
        self.run_cli("build", "greek")

    def test_clones_a_repo_that_has_gone_missing(self):
        shutil.rmtree(self.ws / "beta")
        result = self.run_cli("sync")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue((self.ws / "beta" / ".git").is_dir())
        self.assertIn("cloned: beta", result.stdout)

    def test_fast_forwards_a_clean_repo_that_is_behind(self):
        push_commit(self.root, "alpha", "news.txt", "fresh")
        result = self.run_cli("sync")
        self.assertIn("updated: alpha", result.stdout)
        self.assertEqual("fresh", (self.ws / "alpha" / "news.txt").read_text())

    def test_reports_a_clean_repo_that_is_already_current(self):
        result = self.run_cli("sync")
        self.assertIn("current: alpha", result.stdout)

    def test_leaves_a_dirty_repo_untouched_and_says_so(self):
        push_commit(self.root, "alpha", "news.txt", "fresh")
        (self.ws / "alpha" / "README.md").write_text("my edit")
        result = self.run_cli("sync")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("skipped: alpha", result.stdout)
        self.assertEqual("my edit", (self.ws / "alpha" / "README.md").read_text())
        self.assertFalse((self.ws / "alpha" / "news.txt").exists())

    def test_leaves_a_diverged_repo_untouched_and_says_so(self):
        local = self.ws / "alpha"
        (local / "mine.txt").write_text("local work")
        git(local, "add", ".")
        git(local, "commit", "-m", "local")
        expected = git(local, "rev-parse", "HEAD")
        push_commit(self.root, "alpha", "theirs.txt", "remote work")
        result = self.run_cli("sync")
        self.assertIn("skipped: alpha", result.stdout)
        self.assertEqual(expected, git(local, "rev-parse", "HEAD"))

    def test_a_subfolder_that_is_not_a_git_repo_is_skipped_not_probed(self):
        shutil.rmtree(self.ws / "beta")
        (self.ws / "beta").mkdir()
        result = self.run_cli("sync")
        self.assertIn("skipped: beta", result.stdout)
        self.assertEqual([], list((self.ws / "beta").iterdir()))

    def test_a_repo_whose_git_probe_fails_is_skipped_not_read_as_clean(self):
        (self.ws / "alpha" / ".git" / "index").write_bytes(b"garbage")
        result = self.run_cli("sync")
        self.assertIn("skipped: alpha", result.stdout)

    def test_a_marker_naming_a_folder_outside_the_workspace_is_refused(self):
        marker = self.ws / ".imladris"
        marker.write_text(json.dumps({"repos": {"../elsewhere": str(self.alpha)}}))
        result = self.run_cli("sync")
        self.assertEqual(1, result.returncode)
        self.assertFalse((self.root / "elsewhere").exists())

    def test_a_symlinked_clone_is_skipped_and_its_target_left_alone(self):
        shutil.rmtree(self.ws / "beta")
        target = self.root / "real-beta"
        git(self.root, "clone", "--quiet", str(self.beta), str(target))
        push_commit(self.root, "beta", "news.txt", "fresh")
        (self.ws / "beta").symlink_to(target, target_is_directory=True)
        result = self.run_cli("sync")
        self.assertIn("skipped: beta", result.stdout)
        self.assertFalse((target / "news.txt").exists())

    def test_refuses_a_folder_that_was_never_built(self):
        bare = self.root / "bare-ws"
        bare.mkdir()
        result = self.run_cli("sync", cwd=bare)
        self.assertEqual(1, result.returncode)
        self.assertIn("not a workspace", result.stderr)


class DoneTest(ImladrisCase):
    def setUp(self):
        super().setUp()
        self.run_cli("build", "greek")

    def present(self):
        return sorted(p.name for p in self.ws.iterdir() if (p / ".git").is_dir())

    def test_a_check_without_confirm_reports_clean_repos_and_deletes_nothing(self):
        expected = ["alpha", "beta"]
        result = self.run_cli("done")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("clean: alpha", result.stdout)
        self.assertEqual(expected, self.present())

    def test_confirm_removes_every_clone_and_the_marker_when_all_are_clean(self):
        result = self.run_cli("done", "--confirm")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.present())
        self.assertFalse((self.ws / ".imladris").exists())

    def test_an_uncommitted_change_blocks_everything_even_the_clean_repos(self):
        expected = ["alpha", "beta"]
        (self.ws / "alpha" / "README.md").write_text("unsaved")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertIn("blocked: alpha", result.stdout)
        self.assertEqual(expected, self.present())

    def test_an_untracked_file_counts_as_unsaved_work(self):
        (self.ws / "beta" / "scratch.txt").write_text("x")
        result = self.run_cli("done")
        self.assertEqual(1, result.returncode)
        self.assertIn("blocked: beta", result.stdout)

    def test_a_commit_not_on_any_remote_blocks(self):
        local = self.ws / "alpha"
        (local / "mine.txt").write_text("local work")
        git(local, "add", ".")
        git(local, "commit", "-m", "local")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertIn("not pushed", result.stdout)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_a_commit_on_a_side_branch_not_on_any_remote_blocks(self):
        local = self.ws / "alpha"
        git(local, "checkout", "-b", "side")
        (local / "side.txt").write_text("work")
        git(local, "add", ".")
        git(local, "commit", "-m", "side")
        git(local, "checkout", "main")
        result = self.run_cli("done")
        self.assertEqual(1, result.returncode)
        self.assertIn("not pushed", result.stdout)

    def test_a_commit_made_on_a_detached_head_blocks(self):
        local = self.ws / "alpha"
        git(local, "checkout", "--detach")
        (local / "drift.txt").write_text("work")
        git(local, "add", ".")
        git(local, "commit", "-m", "detached")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_ignored_files_do_not_block_but_are_named_before_they_go(self):
        local = self.ws / "alpha"
        (local / ".git" / "info" / "exclude").write_text(".env\n")
        (local / ".env").write_text("SECRET=1")
        result = self.run_cli("done")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("ignored", result.stdout)
        self.assertIn(".env", result.stdout)

    def test_a_repo_whose_git_probe_fails_blocks_instead_of_reading_clean(self):
        (self.ws / "alpha" / ".git" / "index").write_bytes(b"garbage")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_a_symlinked_clone_blocks(self):
        shutil.rmtree(self.ws / "beta")
        target = self.root / "real-beta"
        git(self.root, "clone", "--quiet", str(self.beta), str(target))
        (self.ws / "beta").symlink_to(target, target_is_directory=True)
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertIn("blocked: beta", result.stdout)

    def test_a_repo_already_gone_is_announced(self):
        shutil.rmtree(self.ws / "beta")
        result = self.run_cli("done")
        self.assertIn("absent: beta", result.stdout)

    def test_a_marker_naming_a_folder_outside_the_workspace_deletes_nothing(self):
        outside = self.root / "outside"
        shutil.copytree(self.ws / "alpha", outside)
        marker = self.ws / ".imladris"
        marker.write_text(json.dumps({"repos": {"../outside": str(self.alpha)}}))
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertTrue((outside / ".git").is_dir())

    def test_a_commit_reachable_only_from_the_reflog_blocks(self):
        local = self.ws / "alpha"
        git(local, "checkout", "--detach")
        (local / "drift.txt").write_text("work")
        git(local, "add", ".")
        git(local, "commit", "-m", "abandoned")
        git(local, "checkout", "main")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_a_linked_worktree_blocks(self):
        local = self.ws / "alpha"
        git(local, "worktree", "add", "--detach", str(self.root / "outside-tree"))
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertIn("worktree", result.stdout)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_unpushed_commits_inside_a_submodule_block(self):
        sub = make_origin(self.root, "inner")
        local = self.ws / "alpha"
        allow = ("-c", "protocol.file.allow=always")
        git(local, *allow, "submodule", "add", str(sub), "inner")
        git(local, "commit", "-m", "add submodule")
        git(local, "push", "origin", "main")
        inner = local / "inner"
        git(inner, "checkout", "-b", "feat")
        (inner / "work.txt").write_text("only here")
        git(inner, "add", ".")
        git(inner, "commit", "-m", "inner work")
        git(local, "add", "inner")
        git(local, "commit", "-m", "record inner")
        git(local, "push", "origin", "main")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertIn("submodule", result.stdout)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_untracked_work_blocks_even_when_git_is_set_to_hide_untracked_files(self):
        local = self.ws / "alpha"
        git(local, "config", "status.showUntrackedFiles", "no")
        (local / "newwork.txt").write_text("only here")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_edits_inside_a_submodule_block_even_when_gitmodules_ignores_it(self):
        sub = make_origin(self.root, "inner")
        local = self.ws / "alpha"
        git(local, "-c", "protocol.file.allow=always", "submodule", "add", str(sub), "inner")
        git(local, "config", "-f", ".gitmodules", "submodule.inner.ignore", "all")
        git(local, "add", ".")
        git(local, "commit", "-m", "add submodule, ignored")
        git(local, "push", "origin", "main")
        (local / "inner" / "README.md").write_text("edited inside")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_an_edit_hidden_by_assume_unchanged_blocks(self):
        local = self.ws / "alpha"
        git(local, "update-index", "--assume-unchanged", "README.md")
        (local / "README.md").write_text("hidden edit")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_an_edit_hidden_by_skip_worktree_blocks(self):
        local = self.ws / "alpha"
        git(local, "update-index", "--skip-worktree", "README.md")
        (local / "README.md").write_text("hidden edit")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_a_marker_with_folders_differing_only_by_case_is_refused(self):
        marker = self.ws / ".imladris"
        marker.write_text(json.dumps({"repos": {"alpha": str(self.alpha), "ALPHA": str(self.alpha)}}))
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_a_git_dir_in_the_callers_environment_cannot_redirect_the_probes(self):
        local = self.ws / "alpha"
        (local / "README.md").write_text("stash me")
        git(local, "stash")
        decoy = self.ws / "beta" / ".git"
        result = self.run_cli("done", "--confirm", env={"GIT_DIR": str(decoy)})
        self.assertEqual(1, result.returncode)
        self.assertIn("stash", result.stdout)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_an_ignored_folder_holding_its_own_repo_blocks(self):
        local = self.ws / "alpha"
        (local / ".git" / "info" / "exclude").write_text("vend/\n")
        vend = local / "vend"
        vend.mkdir()
        git(vend, "init", "-b", "main")
        (vend / "only.txt").write_text("history exists nowhere else")
        git(vend, "add", ".")
        git(vend, "commit", "-m", "private")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertIn("vend", result.stdout)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_a_read_only_folder_inside_a_clone_does_not_stop_the_teardown(self):
        local = self.ws / "beta"
        (local / ".git" / "info" / "exclude").write_text("cache/\n")
        cache = local / "cache"
        cache.mkdir()
        (cache / "f").write_text("x")
        cache.chmod(0o555)
        result = self.run_cli("done", "--confirm")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.present())

    def test_an_ignored_bare_repo_blocks(self):
        local = self.ws / "alpha"
        (local / ".git" / "info" / "exclude").write_text("bk/\n")
        git(self.root, "clone", "--bare", "--quiet", str(self.alpha), str(local / "bk"))
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertIn("bk", result.stdout)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_teardown_never_changes_the_mode_of_what_a_symlink_points_at(self):
        outside = self.root / "outside-dir"
        outside.mkdir()
        outside.chmod(0o755)
        cache = self.ws / "beta" / "cache"
        (self.ws / "beta" / ".git" / "info" / "exclude").write_text("cache/\n")
        cache.mkdir()
        (cache / "link").symlink_to(outside, target_is_directory=True)
        cache.chmod(0o555)
        result = self.run_cli("done", "--confirm")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(0o755, outside.stat().st_mode & 0o777)

    def test_teardown_never_changes_the_mode_of_a_file_hard_linked_from_outside(self):
        outside = self.root / "outside.txt"
        outside.write_text("keep")
        outside.chmod(0o444)
        cache = self.ws / "beta" / "cache"
        (self.ws / "beta" / ".git" / "info" / "exclude").write_text("cache/\n")
        cache.mkdir()
        os.link(outside, cache / "hardlink")
        cache.chmod(0o555)
        result = self.run_cli("done", "--confirm")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(0o444, outside.stat().st_mode & 0o777)

    def test_teardown_never_changes_the_mode_of_the_workspace_itself(self):
        self.ws.chmod(0o555)
        self.addCleanup(self.ws.chmod, 0o755)
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertEqual(0o555, self.ws.stat().st_mode & 0o777)

    def _tag_a_side_commit_on_the_remote(self):
        """A release-style tag whose commit is on no branch, pushed to origin and fetched."""
        seed = self.root / "alpha-seed"
        git(seed, "checkout", "-b", "side")
        (seed / "rel.txt").write_text("release")
        git(seed, "add", ".")
        git(seed, "commit", "-m", "release")
        git(seed, "tag", "rel1")
        git(seed, "push", "origin", "rel1")
        git(seed, "checkout", "main")
        git(self.ws / "alpha", "fetch", "--tags", "--quiet")

    def test_a_tag_the_remote_also_holds_does_not_block(self):
        self._tag_a_side_commit_on_the_remote()
        result = self.run_cli("done")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("clean: alpha", result.stdout)

    def test_a_local_only_tag_on_an_unpushed_commit_blocks(self):
        local = self.ws / "alpha"
        git(local, "checkout", "--detach")
        (local / "mine.txt").write_text("local")
        git(local, "add", ".")
        git(local, "commit", "-m", "local")
        git(local, "tag", "mine")
        git(local, "checkout", "main")
        git(local, "reflog", "expire", "--expire=now", "--all")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_a_remote_tag_moved_locally_to_an_unpushed_commit_blocks(self):
        self._tag_a_side_commit_on_the_remote()
        local = self.ws / "alpha"
        (local / "mine.txt").write_text("local")
        git(local, "add", ".")
        git(local, "commit", "-m", "local")
        git(local, "tag", "-f", "rel1")
        git(local, "reflog", "expire", "--expire=now", "--all")
        git(local, "reset", "--hard", "origin/main")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_tags_that_cannot_be_confirmed_with_the_remote_block_and_say_why(self):
        self._tag_a_side_commit_on_the_remote()
        git(self.ws / "alpha", "remote", "set-url", "origin", str(self.root / "gone.git"))
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertIn("could not be read", result.stdout)
        self.assertEqual(["alpha", "beta"], self.present())

    def _local_tag_on_an_unpushed_commit(self, clone):
        git(clone, "checkout", "--detach")
        (clone / "mine.txt").write_text("local")
        git(clone, "add", ".")
        git(clone, "commit", "-m", "local")
        git(clone, "tag", "mine")
        git(clone, "checkout", "main")
        git(clone, "reflog", "expire", "--expire=now", "--all")

    def test_a_remote_that_is_the_clone_itself_does_not_vouch_for_its_tags(self):
        local = self.ws / "alpha"
        self._local_tag_on_an_unpushed_commit(local)
        git(local, "remote", "add", "selfie", str(local / ".git"))
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertIn("blocked: alpha", result.stdout)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_a_remote_that_is_a_sibling_clone_does_not_vouch_for_its_tags(self):
        local = self.ws / "alpha"
        self._local_tag_on_an_unpushed_commit(local)
        git(self.ws / "beta", "fetch", "--quiet", str(local), "refs/tags/mine:refs/tags/mine")
        git(local, "remote", "add", "sibling", str(self.ws / "beta"))
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertIn("blocked: alpha", result.stdout)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_a_remote_that_stalls_is_given_up_on_and_the_clone_is_blocked(self):
        self._tag_a_side_commit_on_the_remote()
        local = self.ws / "alpha"
        git(local, "remote", "set-url", "origin", "ssh://example.invalid/x")
        git(local, "config", "core.sshCommand", 'sh -c "sleep 6" --')
        result = self.run_cli("done", "--confirm", env={"IMLADRIS_REMOTE_TIMEOUT": "1"})
        self.assertEqual(1, result.returncode)
        self.assertIn("timed out", result.stdout)
        self.assertEqual(["alpha", "beta"], self.present())

    def test_a_remote_named_like_an_upload_pack_option_runs_nothing(self):
        self._tag_a_side_commit_on_the_remote()
        marker = self.root / "pwned.txt"
        script = self.root / "evil.sh"
        script.write_text(f"#!/bin/sh\ntouch {marker}\n")
        script.chmod(0o755)
        local = self.ws / "alpha"
        git(local, "remote", "add", "--", f"--upload-pack={script}", str(self.alpha))
        self.run_cli("done")
        self.assertFalse(marker.exists())

    def test_a_stash_blocks(self):
        local = self.ws / "alpha"
        (local / "README.md").write_text("stash me")
        git(local, "stash")
        result = self.run_cli("done")
        self.assertEqual(1, result.returncode)
        self.assertIn("stash", result.stdout)

    def test_a_repo_already_gone_does_not_block_the_rest(self):
        shutil.rmtree(self.ws / "beta")
        result = self.run_cli("done", "--confirm")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.present())

    def test_a_subfolder_that_is_not_a_git_repo_blocks(self):
        shutil.rmtree(self.ws / "beta")
        (self.ws / "beta").mkdir()
        result = self.run_cli("done", "--confirm")
        self.assertEqual(1, result.returncode)
        self.assertIn("blocked: beta", result.stdout)
        self.assertTrue((self.ws / "beta").is_dir())

    def test_refuses_a_folder_that_was_never_built(self):
        bare = self.root / "bare-ws"
        bare.mkdir()
        result = self.run_cli("done", cwd=bare)
        self.assertEqual(1, result.returncode)
        self.assertIn("not a workspace", result.stderr)


class TeardownFailureTest(ImladrisCase):
    def setUp(self):
        super().setUp()
        self.run_cli("build", "greek")
        sys.path.insert(0, str(SCRIPT.parent))
        import imladris

        self.module = imladris

    def test_a_removal_that_fails_is_reported_and_keeps_the_marker(self):
        import contextlib
        import io
        from unittest import mock

        real = self.module._remove_tree

        def fail_for_beta(path):
            if Path(path).name == "beta":
                raise OSError("boom")
            real(path)

        out = io.StringIO()
        with mock.patch.object(self.module, "_remove_tree", side_effect=fail_for_beta):
            with contextlib.redirect_stdout(out):
                blocked = self.module.done(self.ws, confirm=True)
        self.assertGreater(blocked, 0)
        self.assertTrue((self.ws / ".imladris").exists())
        self.assertIn("removed: alpha", out.getvalue())
        self.assertIn("failed: beta", out.getvalue())
        self.assertIn("do not run `sync`", out.getvalue())

    def test_listing_ignored_items_in_a_non_repo_raises_instead_of_reading_empty(self):
        with self.assertRaises(self.module.GitError):
            self.module.ignored_items(self.root)


class DecodingTest(unittest.TestCase):
    def test_git_output_that_is_not_utf8_does_not_crash_the_probe(self):
        sys.path.insert(0, str(SCRIPT.parent))
        import imladris

        done = imladris._run(["printf"], ["\\377"])
        self.assertEqual(0, done.returncode)


class FolderNameTest(unittest.TestCase):
    def test_a_windows_path_clones_into_its_last_part(self):
        sys.path.insert(0, str(SCRIPT.parent))
        import imladris

        expected = "repo"
        self.assertEqual(expected, imladris.folder_name("C:\\x\\repo"))


if __name__ == "__main__":
    unittest.main()
