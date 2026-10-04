#!/usr/bin/env python3
"""Tests for the upstream-source gate in tools/envmerge.py.

The rejection paths run against throwaway git repositories built here, so they
need no network and no upstream checkout: the pins are redirected at the
synthetic repo, the positive control is confirmed to pass, and then each way of
getting the source wrong is shown to fail.

Set RECIPE_UPSTREAM to a real pinned checkout to additionally confirm that the
shipped pins accept it.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RECIPE = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(RECIPE, "tools"))

import envmerge  # noqa: E402

UPSTREAM_ENV = os.environ.get("RECIPE_UPSTREAM", "")
HAVE_GIT = shutil.which("git") is not None


def run(cwd, *args):
    proc = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        raise AssertionError("%s failed: %s"
                             % (" ".join(args), proc.stdout.decode()))
    return proc.stdout.decode()


@unittest.skipUnless(HAVE_GIT, "git is required")
class TestSyntheticSource(unittest.TestCase):
    """Every file name the recipe consumes, with throwaway content."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="source-pins-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = os.path.join(self.tmp, "upstream")
        os.makedirs(os.path.join(self.repo, "files"))
        for rel in envmerge.UPSTREAM_SHA256:
            path = os.path.join(self.repo, rel)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("stand-in for %s\n" % rel)
        run(self.repo, "git", "init", "-q")
        run(self.repo, "git", "config", "user.email", "t@example.invalid")
        run(self.repo, "git", "config", "user.name", "test")
        run(self.repo, "git", "add", "-A")
        run(self.repo, "git", "commit", "-qm", "synthetic")
        self.head = run(self.repo, "git", "rev-parse", "HEAD").strip()

        self._saved = (envmerge.UPSTREAM_COMMIT, dict(envmerge.UPSTREAM_SHA256))
        envmerge.UPSTREAM_COMMIT = self.head
        for rel in envmerge.UPSTREAM_SHA256:
            envmerge.UPSTREAM_SHA256[rel] = envmerge.sha256_file(
                os.path.join(self.repo, rel))
        self.addCleanup(self._restore)

    def _restore(self):
        envmerge.UPSTREAM_COMMIT = self._saved[0]
        envmerge.UPSTREAM_SHA256.clear()
        envmerge.UPSTREAM_SHA256.update(self._saved[1])

    def verify(self, role="both"):
        return envmerge.verify_source(self.repo, role, verbose=False)

    def assertRejected(self, needle):
        with self.assertRaises(envmerge.Fail) as ctx:
            self.verify()
        self.assertIn(needle, str(ctx.exception))
        return str(ctx.exception)

    def test_positive_control(self):
        self.verify()
        self.verify("head")
        self.verify("worker")

    def test_wrong_commit(self):
        run(self.repo, "git", "commit", "-q", "--allow-empty", "-m", "drift")
        msg = self.assertRejected("pinned to")
        self.assertIn(self.head, msg)

    def test_dirty_compose_file(self):
        with open(os.path.join(self.repo, "compose.head.yaml"),
                  "a", encoding="utf-8") as fh:
            fh.write("# local edit\n")
        self.assertRejected("modified in the work tree")

    def test_dirty_chat_template(self):
        with open(os.path.join(self.repo, "files/chat_template.jinja"),
                  "a", encoding="utf-8") as fh:
            fh.write("{# local edit #}\n")
        self.assertRejected("modified in the work tree")

    def test_dirty_file_is_ignored_for_the_other_role(self):
        # The worker never reads compose.head.yaml.
        with open(os.path.join(self.repo, "compose.head.yaml"),
                  "a", encoding="utf-8") as fh:
            fh.write("# local edit\n")
        self.verify("worker")
        with self.assertRaises(envmerge.Fail):
            self.verify("head")

    def test_content_hash_mismatch(self):
        envmerge.UPSTREAM_SHA256["compose.worker.yaml"] = "0" * 64
        self.assertRejected("sha256")

    def test_missing_file(self):
        os.unlink(os.path.join(self.repo, "compose.display-kv.override.yaml"))
        with self.assertRaises(envmerge.Fail):
            self.verify()

    def test_untracked_file(self):
        run(self.repo, "git", "rm", "-q", "--cached",
            "compose.display-kv.override.yaml")
        run(self.repo, "git", "commit", "-qm", "untrack")
        envmerge.UPSTREAM_COMMIT = run(
            self.repo, "git", "rev-parse", "HEAD").strip()
        self.assertRejected("tracked")

    def test_plain_copy_without_git_is_refused(self):
        plain = os.path.join(self.tmp, "plain")
        shutil.copytree(self.repo, plain,
                        ignore=shutil.ignore_patterns(".git"))
        with self.assertRaises(envmerge.Fail) as ctx:
            envmerge.verify_source(plain, "both", verbose=False)
        self.assertIn("not a git work tree", str(ctx.exception))

    def test_missing_directory_names_the_clone_command(self):
        with self.assertRaises(envmerge.Fail) as ctx:
            envmerge.verify_source(os.path.join(self.tmp, "nope"),
                                   "both", verbose=False)
        self.assertIn("git clone", str(ctx.exception))

    def test_role_file_lists_are_scoped(self):
        self.assertNotIn("compose.worker.yaml", envmerge.ROLE_FILES["head"])
        self.assertNotIn("compose.head.yaml", envmerge.ROLE_FILES["worker"])
        for role in ("head", "worker"):
            self.assertIn(".env.example", envmerge.ROLE_FILES[role])
            self.assertIn("files/chat_template.jinja",
                          envmerge.ROLE_FILES[role])
            self.assertIn("compose.display-kv.override.yaml",
                          envmerge.ROLE_FILES[role])


@unittest.skipUnless(UPSTREAM_ENV and HAVE_GIT,
                     "set RECIPE_UPSTREAM to a pinned upstream checkout")
class TestShippedPins(unittest.TestCase):
    def test_pinned_checkout_is_accepted(self):
        for role in sorted(envmerge.ROLE_FILES):
            envmerge.verify_source(UPSTREAM_ENV, role, verbose=False)

    def test_every_pinned_file_is_bound_by_commit_and_hash(self):
        for rel, want in envmerge.UPSTREAM_SHA256.items():
            got = envmerge.sha256_file(os.path.join(UPSTREAM_ENV, rel))
            self.assertEqual(got, want, rel)

    def test_recipe_files_are_not_copies_of_upstream_files(self):
        upstream_hashes = set()
        for root, _dirs, names in os.walk(UPSTREAM_ENV):
            if ".git" in root.split(os.sep):
                continue
            for name in names:
                upstream_hashes.add(
                    envmerge.sha256_file(os.path.join(root, name)))
        for root, _dirs, names in os.walk(RECIPE):
            for name in names:
                path = os.path.join(root, name)
                self.assertNotIn(
                    envmerge.sha256_file(path), upstream_hashes,
                    "%s is byte-identical to a file in the upstream "
                    "repository, which has no repository-wide license grant"
                    % path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
