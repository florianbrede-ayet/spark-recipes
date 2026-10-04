#!/usr/bin/env python3
"""Behaviour tests for launch.sh.

The Compose binary is replaced by a shim that records every invocation and
delegates `config` to the real binary, so these tests prove what the launcher
does and does not run. No Docker daemon is involved and nothing is started.

Needs RECIPE_UPSTREAM (the launcher verifies the pinned source first) and a
Compose binary for the delegated render.
"""

import json
import os
import pty
import re
import select
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RECIPE = os.path.dirname(HERE)
LAUNCH = os.path.join(RECIPE, "launch.sh")
sys.path.insert(0, os.path.join(RECIPE, "tools"))

from test_render_parity import SITE, compose_argv  # noqa: E402

UPSTREAM = os.environ.get("RECIPE_UPSTREAM", "")
COMPOSE = compose_argv()
REASON = ("set RECIPE_UPSTREAM to a pinned upstream checkout and provide a "
          "Compose binary (RECIPE_COMPOSE_BIN or `docker compose`)")

SHIM = """#!/usr/bin/env python3
import json, subprocess, sys
with open({log!r}, "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
if "config" in sys.argv[1:]:
    sys.exit(subprocess.run({real!r} + sys.argv[1:]).returncode)
print("shim: would have run " + " ".join(sys.argv[1:]))
"""


class LauncherCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="launcher-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.log = os.path.join(self.tmp, "compose.log")
        self.shim = os.path.join(self.tmp, "compose-shim")
        with open(self.shim, "w", encoding="utf-8") as fh:
            fh.write(SHIM.format(log=self.log, real=COMPOSE))
        os.chmod(self.shim, 0o755)
        self.site = self.write_site()

    def write_site(self, **overrides):
        values = dict(SITE)
        values.update(overrides)
        path = os.path.join(self.tmp, "site.env")
        with open(path, "w", encoding="utf-8") as fh:
            for key in sorted(values):
                fh.write("%s=%s\n" % (key, values[key]))
        return path

    def invocations(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as fh:
            return [json.loads(ln) for ln in fh if ln.strip()]

    def assertNoStart(self):
        for argv in self.invocations():
            self.assertNotIn("up", argv,
                             "the launcher invoked Compose with `up`: %s" % argv)

    def args(self, role="head", *extra):
        return ["bash", LAUNCH, "--role", role, "--upstream", UPSTREAM,
                "--site-env", self.site, "--compose-bin", self.shim] + list(extra)

    def env(self, **extra):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
               "HOME": os.environ.get("HOME", "/")}
        env.update(extra)
        return env

    def run_plain(self, args, **envkw):
        proc = subprocess.run(args, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env=self.env(**envkw))
        return proc.returncode, proc.stdout.decode(), proc.stderr.decode()

    def run_tty(self, args, answer, **envkw):
        """Run with a real controlling terminal so --apply can prompt."""
        env = self.env(**envkw)
        pid, fd = pty.fork()
        if pid == 0:                                   # child
            try:
                os.execvpe(args[0], args, env)
            finally:
                os._exit(127)
        os.write(fd, (answer + "\n").encode())
        chunks = []
        while True:
            ready, _, _ = select.select([fd], [], [], 60)
            if not ready:
                break
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            chunks.append(data)
        os.close(fd)
        _, status = os.waitpid(pid, 0)
        code = os.waitstatus_to_exitcode(status) \
            if hasattr(os, "waitstatus_to_exitcode") else status >> 8
        return code, b"".join(chunks).decode(errors="replace")


@unittest.skipUnless(UPSTREAM and COMPOSE, REASON)
class TestDryRun(LauncherCase):
    def test_dry_run_renders_but_starts_nothing(self):
        code, out, err = self.run_plain(self.args("head"))
        self.assertEqual(code, 0, err)
        self.assertIn("DRY RUN. Nothing was started.", out)
        calls = self.invocations()
        self.assertEqual(len(calls), 1, calls)
        self.assertIn("config", calls[0])
        self.assertNoStart()

    def test_dry_run_worker_role_renders_rank_one(self):
        code, out, err = self.run_plain(self.args("worker"))
        self.assertEqual(code, 0, err)
        self.assertIn("rank / headless 1 /", out)
        self.assertIn("none (headless rank)", out)
        self.assertNoStart()

    def test_exactly_three_compose_files_in_order(self):
        code, out, err = self.run_plain(self.args("head"))
        self.assertEqual(code, 0, err)
        line = [ln for ln in out.splitlines() if "up -d" in ln][0]
        files = re.findall(r"-f (\S+)", line)
        self.assertEqual([os.path.basename(f) for f in files], [
            "compose.head.yaml",
            "compose.display-kv.override.yaml",
            "compose.phase1.override.yaml"])
        self.assertTrue(files[0].startswith(os.path.abspath(UPSTREAM)))
        self.assertTrue(files[2].startswith(os.path.abspath(RECIPE)))
        self.assertIn("--env-file", line)

    def test_ambient_variables_cannot_replace_the_pins(self):
        code, out, err = self.run_plain(self.args("head"),
                                        IMAGE="evil/image:latest",
                                        KV_CACHE_MEMORY_BYTES="1M",
                                        COMPOSE_PROJECT_NAME="evil")
        self.assertEqual(code, 0, err)
        render = out.split("== render")[1]
        self.assertIn("@sha256:1169f797539454e3c286557d49fddd4884889", render)
        self.assertNotIn("evil/image", render)
        self.assertIn("13876M", render)

    def test_temporary_env_file_is_removed(self):
        code, out, err = self.run_plain(self.args("head"))
        self.assertEqual(code, 0, err)
        path = re.search(r"--env-file (\S+)", out).group(1)
        self.assertFalse(os.path.exists(path), path)


@unittest.skipUnless(UPSTREAM and COMPOSE, REASON)
class TestRefusals(LauncherCase):
    def test_unresolved_placeholder_is_refused(self):
        self.site = shutil.copy(
            os.path.join(RECIPE, "config/site.env.example"),
            os.path.join(self.tmp, "site.env"))
        code, out, err = self.run_plain(self.args("head"))
        self.assertNotEqual(code, 0)
        self.assertIn("placeholder", err)
        self.assertEqual(self.invocations(), [])

    def test_multi_device_site_is_refused(self):
        self.site = self.write_site(NCCL_IB_HCA="roceA,roceB")
        code, out, err = self.run_plain(self.args("head"))
        self.assertNotEqual(code, 0)
        self.assertIn("more than one device", err)
        self.assertEqual(self.invocations(), [])

    def test_wrong_upstream_commit_is_refused(self):
        other = os.path.join(self.tmp, "other-upstream")
        os.makedirs(other)
        subprocess.run(["git", "init", "-q"], cwd=other, check=True)
        code, out, err = self.run_plain(
            ["bash", LAUNCH, "--role", "head", "--upstream", other,
             "--site-env", self.site, "--compose-bin", self.shim])
        self.assertNotEqual(code, 0)
        self.assertEqual(self.invocations(), [])

    def test_bad_arguments_are_refused(self):
        for extra, needle in (
                (["--role", "bogus"], "head or worker"),
                (["--role", "head", "--role", "worker"], "given twice"),
                (["--role"], "needs a value"),
                (["--role", "head", "--nope"], "unknown argument"),
                ([], "--role is required"),
        ):
            args = ["bash", LAUNCH, "--upstream", UPSTREAM,
                    "--site-env", self.site, "--compose-bin", self.shim] + extra
            code, out, err = self.run_plain(args)
            self.assertNotEqual(code, 0, extra)
            self.assertIn(needle, err, extra)
            self.assertEqual(self.invocations(), [])

    def _tampered_copy(self, relpath, old, new):
        """Copy the recipe, edit a file, leave SHA256SUMS stale."""
        copy = os.path.join(self.tmp, "recipe-copy")
        shutil.copytree(RECIPE, copy,
                        ignore=shutil.ignore_patterns("__pycache__"))
        path = os.path.join(copy, relpath)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn(old, text, relpath)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text.replace(old, new, 1))
        return copy

    def test_untampered_copy_still_runs(self):
        copy = shutil.copytree(RECIPE, os.path.join(self.tmp, "clean-copy"),
                               ignore=shutil.ignore_patterns("__pycache__"))
        code, out, err = self.run_plain(
            ["bash", os.path.join(copy, "launch.sh"), "--role", "head",
             "--upstream", UPSTREAM, "--site-env", self.site,
             "--compose-bin", self.shim])
        self.assertEqual(code, 0, err)
        self.assertIn("recipe files match SHA256SUMS", out)

    def test_valid_profile_edit_without_new_checksums_is_refused(self):
        # Every edit below is syntactically valid and passes the key guard, so
        # only the content pin can reject it.
        for relpath, old, new in (
                ("config/profile.env", "KV_CACHE_MEMORY_BYTES=13876M",
                 "KV_CACHE_MEMORY_BYTES=9999M"),
                ("config/profile.env",
                 "IMAGE=technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks@sha256:1169f",
                 "IMAGE=technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks@sha256:0000f"),
                ("config/profile.env",
                 "MODEL_REVISION=a608241037e4c2565356bff7ca293f2133888f88",
                 "MODEL_REVISION=0000000000000000000000000000000000000000"),
                ("compose.phase1.override.yaml", "B12X_ROCE_SPIN_LIMIT",
                 "B12X_ROCE_SPIN_LIMIT_RENAMED"),
        ):
            self.setUp()
            copy = self._tampered_copy(relpath, old, new)
            code, out, err = self.run_plain(
                ["bash", os.path.join(copy, "launch.sh"), "--role", "head",
                 "--upstream", UPSTREAM, "--site-env", self.site,
                 "--compose-bin", self.shim])
            self.assertNotEqual(code, 0, relpath)
            self.assertIn("does not match its published SHA256SUMS", err)
            self.assertEqual(self.invocations(), [], relpath)

    def test_missing_site_file_is_refused(self):
        code, out, err = self.run_plain(
            ["bash", LAUNCH, "--role", "head", "--upstream", UPSTREAM,
             "--site-env", os.path.join(self.tmp, "absent.env"),
             "--compose-bin", self.shim])
        self.assertNotEqual(code, 0)
        self.assertIn("site.env.example", err)


@unittest.skipUnless(UPSTREAM and COMPOSE, REASON)
class TestApplyGate(LauncherCase):
    def test_apply_without_a_terminal_is_refused(self):
        code, out, err = self.run_plain(self.args("head", "--apply"))
        self.assertNotEqual(code, 0)
        self.assertIn("interactive terminal", err)
        self.assertNoStart()

    def test_apply_needs_the_exact_confirmation_word(self):
        for answer in ("", "y", "yes", "APPLY", "apply now"):
            self.setUp()
            code, out = self.run_tty(self.args("head", "--apply"), answer)
            self.assertNotEqual(code, 0, answer)
            self.assertIn("nothing started", out)
            self.assertNoStart()

    def test_apply_with_the_confirmation_starts_exactly_one_container(self):
        code, out = self.run_tty(self.args("worker", "--apply"), "apply")
        self.assertEqual(code, 0, out)
        ups = [c for c in self.invocations() if "up" in c]
        self.assertEqual(len(ups), 1, self.invocations())
        self.assertEqual(ups[0][-2:], ["up", "-d"])
        self.assertIn("--env-file", ups[0])
        self.assertEqual(ups[0].count("-f"), 3)
        self.assertIn("wait ~15 s, then run --role head --apply", out)

    def test_confirmation_names_the_risk_and_the_order(self):
        code, out = self.run_tty(self.args("head", "--apply"), "no")
        self.assertIn("unauthenticated", out)
        self.assertIn("Rank 1 (the worker) must ALREADY be running", out)
        # `compose up -d` is not purely additive: say so before committing.
        self.assertIn("THIS CAN INTERRUPT A RUNNING SERVICE", out)
        for phrase in ("pull the pinned image", "stopped, removed and recreated",
                       "API downtime", "reloaded onto the",
                       "agreed maintenance window", "shut the pair down first"):
            self.assertIn(phrase, out)
        self.assertNoStart()


class TestLauncherStatics(unittest.TestCase):
    """Properties of launch.sh that must hold by construction."""

    @classmethod
    def setUpClass(cls):
        with open(LAUNCH, encoding="utf-8") as fh:
            cls.text = fh.read()
        cls.lines = cls.text.splitlines()

    def test_is_not_executable_so_it_cannot_be_run_by_accident(self):
        self.assertFalse(os.access(LAUNCH, os.X_OK),
                         "launch.sh must be run as `bash launch.sh`")

    def test_fails_fast_and_loudly(self):
        self.assertIn("set -euo pipefail", self.text)

    def test_only_one_mutating_invocation_and_it_follows_the_prompt(self):
        runs = [i for i, ln in enumerate(self.lines)
                if '"${COMPOSE_CMD[@]}" "${COMPOSE_ARGS[@]}"' in ln]
        mutating = [i for i in runs if self.lines[i].rstrip().endswith("up -d")]
        self.assertEqual(len(mutating), 1, [self.lines[i] for i in mutating])
        for marker in ('read -r answer </dev/tty', '"$answer" == "apply"'):
            at = [i for i, ln in enumerate(self.lines) if marker in ln]
            self.assertEqual(len(at), 1, marker)
            self.assertLess(at[0], mutating[0], marker)
        for index in runs:
            line = self.lines[index].strip()
            # Either it only prints the command, or it runs it scrubbed.
            self.assertTrue(line.startswith("printf ")
                            or line.startswith('"${SCRUB[@]}"'),
                            "unscrubbed Compose invocation: %r" % line)

    def test_no_lifecycle_or_host_mutating_commands(self):
        banned = (r"\bssh\b", r"\bscp\b", r"\brsync\b",
                  r"compose[^\n]*\bdown\b",
                  r"docker[^\n]*\b(stop|rm|kill|restart|pull|exec)\b",
                  r"\bsystemctl\b", r"\breboot\b", r"\bsysctl\b",
                  r"\bmodprobe\b", r"\bupdate-initramfs\b", r"\bapt\b",
                  r"\bpip\b", r"\bcurl\b", r"\bwget\b", r"\bchown\b",
                  r"\bmount\b", r"\btee\b")
        for pattern in banned:
            self.assertIsNone(re.search(pattern, self.text),
                              "launch.sh must not reference %s" % pattern)

    def test_writes_only_into_a_private_temporary_directory(self):
        self.assertIn('WORK="$(mktemp -d)"', self.text)
        self.assertIn('chmod 700 -- "$WORK"', self.text)
        self.assertIn("trap cleanup EXIT", self.text)
        self.assertEqual(self.text.count("rm -rf"), 1)
        self.assertIn('rm -rf -- "$WORK"', self.text)

    def test_never_sources_an_env_file(self):
        for pattern in (r"(?m)^\s*(source|\.)\s",
                        r"(?:;|&&|\|\|)\s*(source|\.)\s",
                        r"\beval\b", r"\$\(cat ", r"\bexport -f\b"):
            match = re.search(pattern, self.text)
            self.assertIsNone(match, "launch.sh matches %s: %r"
                              % (pattern, match.group(0) if match else ""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
