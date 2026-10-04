#!/usr/bin/env python3
"""Unit tests for tools/envmerge.py. Offline, stdlib only; no upstream
checkout and no Compose binary needed.

The upstream .env.example is not vendored here: these tests build a small
synthetic example that declares the same key names, which is all the merge
logic depends on.
"""

import os
import shutil
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RECIPE = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(RECIPE, "tools"))

import envmerge  # noqa: E402

GOOD_SITE = {
    "HEAD_ROCE_IP": "198.51.100.1",
    "WORKER_ROCE_IP": "198.51.100.2",
    "MASTER_ADDR": "198.51.100.1",
    "NCCL_IB_HCA": "roceTESTa0f0",
    "NCCL_SOCKET_IFNAME": "enTESTa0f0np0",
    "CONTROL_IF": "enTESTa0f0np0",
    "HF_CACHE": "/srv/hf-cache-test",
    "DRM_CARD_GID": "1044",
}


def write(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


def site_body(values):
    return "".join("%s=%s\n" % (k, values[k]) for k in sorted(values))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="envmerge-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.upstream = os.path.join(self.tmp, "upstream")
        os.makedirs(self.upstream)
        lines = ["# synthetic stand-in for the pinned upstream .env.example"]
        for key in envmerge.PROFILE_KEYS + envmerge.SITE_KEYS:
            if key not in envmerge.ADDED_KEYS:
                lines.append("%s=upstream-%s" % (key, key.lower()))
        # keys the recipe never touches, to prove they pass through
        lines += ["MAX_MODEL_LEN=1047552", "KV_CACHE_DTYPE=fp8",
                  "UNUSED_BY_RECIPE=keep-me", "EMPTY_ON_PURPOSE="]
        write(os.path.join(self.upstream, ".env.example"),
              "\n".join(lines) + "\n")

    def site(self, **overrides):
        values = dict(GOOD_SITE)
        for key, value in overrides.items():
            if value is None:
                values.pop(key, None)
            else:
                values[key] = value
        return write(os.path.join(self.tmp, "site.env"), site_body(values))

    def raw_site(self, body):
        return write(os.path.join(self.tmp, "site.env"), body)

    def merge(self, site_path):
        return envmerge.build_merged(self.upstream, site_path)

    def assertFail(self, needle, site_path):
        with self.assertRaises(envmerge.Fail) as ctx:
            self.merge(site_path)
        self.assertIn(needle, str(ctx.exception))
        return str(ctx.exception)


class TestMerge(Base):
    def test_three_layers_compose_in_order(self):
        merged, _, _ = self.merge(self.site())
        for key, value in envmerge.load_profile().items():
            self.assertEqual(merged[key], value, key)
        for key, value in GOOD_SITE.items():
            self.assertEqual(merged[key], value, key)
        self.assertEqual(merged["MAX_MODEL_LEN"], "1047552")
        self.assertEqual(merged["UNUSED_BY_RECIPE"], "keep-me")
        self.assertEqual(merged["EMPTY_ON_PURPOSE"], "")

    def test_key_set_is_upstream_plus_one_added_key(self):
        merged, example, order = self.merge(self.site())
        self.assertEqual(set(merged), set(example) | {"B12X_ROCE_SPIN_LIMIT"})
        self.assertEqual(order[-1], "B12X_ROCE_SPIN_LIMIT")
        self.assertEqual(len(order), len(set(order)))

    def test_nothing_changes_outside_the_declared_overlay(self):
        merged, example, _ = self.merge(self.site())
        overlay = set(envmerge.PROFILE_KEYS) | set(envmerge.SITE_KEYS)
        for key in example:
            if key not in overlay:
                self.assertEqual(merged[key], example[key], key)

    def test_ssh_helper_keys_are_blanked(self):
        merged, example, _ = self.merge(self.site())
        for key in envmerge.DISCARDED_KEYS:
            self.assertNotEqual(example[key], "")
            self.assertEqual(merged[key], "", key)

    def test_render_is_deterministic_and_carries_provenance(self):
        merged, _, order = self.merge(self.site())
        site_path = self.site()
        first = envmerge.render_merged(merged, order, site_path)
        self.assertEqual(first, envmerge.render_merged(merged, order, site_path))
        self.assertIn(envmerge.UPSTREAM_COMMIT, first)
        body = [ln for ln in first.splitlines() if not ln.startswith("#")]
        self.assertEqual(body, ["%s=%s" % (k, merged[k]) for k in order])

    def test_emitted_file_is_private_and_replaced_atomically(self):
        merged, _, order = self.merge(self.site())
        out = os.path.join(self.tmp, "merged.env")
        write(out, "stale world-readable content\n")
        os.chmod(out, 0o644)
        envmerge.write_private(out, envmerge.render_merged(
            merged, order, self.site()))
        self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o600)
        with open(out, encoding="utf-8") as fh:
            self.assertNotIn("stale", fh.read())
        self.assertEqual(
            [n for n in os.listdir(self.tmp) if n.startswith(".envmerge.")], [])

    def test_offline_flags_and_tokens_are_not_in_the_env_file(self):
        # The offline posture comes from the upstream compose files; setting it
        # here would let a site file turn it off.
        merged, _, _ = self.merge(self.site())
        for key in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_TOKEN",
                    "HUGGING_FACE_HUB_TOKEN"):
            self.assertNotIn(key, merged)


class TestKeyGuard(Base):
    def test_unedited_placeholder(self):
        msg = self.assertFail("placeholder", self.site(
            HEAD_ROCE_IP="<HEAD_FABRIC_IP>"))
        self.assertIn("<HEAD_FABRIC_IP>", msg)

    def test_unknown_site_key(self):
        self.assertFail("does not accept",
                        self.raw_site(site_body(GOOD_SITE) + "HF_TOKEN=abc\n"))

    def test_profile_constant_cannot_be_overridden_per_site(self):
        self.assertFail("MAX_NUM_BATCHED_TOKENS", self.raw_site(
            site_body(GOOD_SITE) + "MAX_NUM_BATCHED_TOKENS=16384\n"))

    def test_missing_site_key(self):
        self.assertFail("missing", self.site(DRM_CARD_GID=None))

    def test_shipped_profile_passes_its_own_guard(self):
        profile = envmerge.load_profile()
        self.assertEqual(set(profile), set(envmerge.PROFILE_KEYS))
        for key in envmerge.DISCARDED_KEYS:
            self.assertEqual(profile[key], "")

    def test_shipped_site_example_is_placeholders_only(self):
        example, _ = envmerge.parse_env(
            os.path.join(RECIPE, "config/site.env.example"), "example")
        self.assertEqual(set(example), set(envmerge.SITE_KEYS))
        for key, value in example.items():
            self.assertTrue(envmerge.PLACEHOLDER_RE.fullmatch(value),
                            "%s=%r is not a bare <PLACEHOLDER>" % (key, value))

    def test_profile_and_site_key_sets_are_disjoint(self):
        self.assertFalse(set(envmerge.PROFILE_KEYS) & set(envmerge.SITE_KEYS))
        for key in envmerge.ADDED_KEYS + envmerge.DISCARDED_KEYS:
            self.assertIn(key, envmerge.PROFILE_KEYS)


class TestProfileContentPin(Base):
    """Keys and syntax are not enough; the profile's content is pinned too."""

    def _recipe_copy(self):
        copy = tempfile.mkdtemp(dir=self.tmp, prefix="recipe-copy-")
        shutil.copytree(RECIPE, copy, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__"))
        original = envmerge.RECIPE
        envmerge.RECIPE = copy
        self.addCleanup(setattr, envmerge, "RECIPE", original)
        return copy

    def _edit(self, copy, relpath, old, new):
        path = os.path.join(copy, relpath)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn(old, text, relpath)
        write(path, text.replace(old, new, 1))

    def test_untouched_copy_loads(self):
        self._recipe_copy()
        envmerge.load_profile()

    def test_valid_profile_value_edit_is_refused(self):
        for relpath, old, new in (
                ("config/profile.env", "KV_CACHE_MEMORY_BYTES=13876M",
                 "KV_CACHE_MEMORY_BYTES=9999M"),
                ("config/profile.env", "MAX_NUM_BATCHED_TOKENS=8192",
                 "MAX_NUM_BATCHED_TOKENS=16384"),
                ("config/profile.env", "@sha256:1169f", "@sha256:0000f"),
                ("config/profile.env",
                 "MODEL_REVISION=a608241037e4c2565356bff7ca293f2133888f88",
                 "MODEL_REVISION=0000000000000000000000000000000000000000"),
        ):
            copy = self._recipe_copy()
            self._edit(copy, relpath, old, new)
            with self.assertRaises(envmerge.Fail) as ctx:
                envmerge.load_profile()
            self.assertIn("does not match its SHA256SUMS entry",
                          str(ctx.exception), new)

    def test_edited_overlay_is_refused(self):
        copy = self._recipe_copy()
        self._edit(copy, "compose.phase1.override.yaml",
                   "B12X_ROCE_SPIN_LIMIT", "B12X_ROCE_SPIN_LIMIT_RENAMED")
        with self.assertRaises(envmerge.Fail) as ctx:
            envmerge.load_profile()
        self.assertIn("compose.phase1.override.yaml", str(ctx.exception))

    def test_a_missing_manifest_entry_is_refused(self):
        copy = self._recipe_copy()
        manifest = os.path.join(copy, "SHA256SUMS")
        with open(manifest, encoding="utf-8") as fh:
            kept = [ln for ln in fh if "config/profile.env" not in ln]
        write(manifest, "".join(kept))
        with self.assertRaises(envmerge.Fail) as ctx:
            envmerge.load_profile()
        self.assertIn("does not list config/profile.env", str(ctx.exception))

    def test_both_recipe_authored_files_are_pinned(self):
        self.assertEqual(set(envmerge.PINNED_RECIPE_FILES),
                         {"config/profile.env", "compose.phase1.override.yaml"})


class TestSiteInvariants(Base):
    def test_multi_device_lists_are_refused(self):
        for key in envmerge.SINGLE_DEVICE_KEYS:
            self.assertFail("more than one device",
                            self.site(**{key: "devA,devB"}))

    def test_master_addr_must_equal_head(self):
        self.assertFail("must equal HEAD_ROCE_IP",
                        self.site(MASTER_ADDR="198.51.100.9"))

    def test_head_and_worker_must_differ(self):
        self.assertFail("two-node", self.site(WORKER_ROCE_IP="198.51.100.1"))

    def test_relative_hf_cache(self):
        self.assertFail("absolute path", self.site(HF_CACHE="relative/cache"))

    def test_hf_cache_with_colon_would_split_the_bind_mount(self):
        self.assertFail("split the compose bind mount",
                        self.site(HF_CACHE="/srv/a:b"))


class TestUnsafeValues(Base):
    def test_shell_metacharacters_are_refused(self):
        for bad, needle in (("/srv/$HOME", "'$'"), ("/srv/`id`", "'`'"),
                            ("/srv/a#b", "'#'"), ('/srv/a"b', "contains"),
                            ("/srv/two words", "whitespace")):
            self.assertFail(needle, self.site(HF_CACHE=bad))

    def test_command_substitution_is_never_executed(self):
        marker = os.path.join(self.tmp, "pwned")
        values = dict(GOOD_SITE, HF_CACHE="/srv/$(touch %s)" % marker)
        with self.assertRaises(envmerge.Fail):
            self.merge(self.raw_site(site_body(values)))
        self.assertFalse(os.path.exists(marker),
                         "the env file was interpreted by a shell")

    def test_quoted_value_with_space_is_still_refused(self):
        self.assertFail("whitespace", self.raw_site(
            site_body(dict(GOOD_SITE, HF_CACHE='"/srv/two words"'))))

    def test_duplicate_key(self):
        self.assertFail("duplicate key",
                        self.raw_site(site_body(GOOD_SITE)
                                      + "HF_CACHE=/srv/other\n"))

    def test_export_prefix(self):
        self.assertFail("'export' is not accepted",
                        self.raw_site("export " + site_body(GOOD_SITE)))

    def test_malformed_line(self):
        self.assertFail("not a KEY=VALUE line",
                        self.raw_site(site_body(GOOD_SITE) + "not an assignment\n"))

    def test_control_character(self):
        self.assertFail("control or non-ASCII", self.raw_site(
            site_body(GOOD_SITE).replace("DRM_CARD_GID=1044",
                                         "DRM_CARD_GID=10\x0744")))

    def test_comments_and_blank_lines_are_ignored(self):
        merged, _, _ = self.merge(self.raw_site(
            "# comment\n\n   \n"
            + "".join("  %s=%s\n" % kv for kv in GOOD_SITE.items())))
        self.assertEqual(merged["HF_CACHE"], GOOD_SITE["HF_CACHE"])


class TestUpstreamDrift(Base):
    def _example_without(self, key):
        path = os.path.join(self.upstream, ".env.example")
        with open(path, encoding="utf-8") as fh:
            kept = [ln for ln in fh if not ln.startswith(key + "=")]
        write(path, "".join(kept))

    def test_upstream_dropping_a_profile_key_is_refused(self):
        self._example_without("MAX_NUM_SEQS")
        self.assertFail("no longer defines MAX_NUM_SEQS", self.site())

    def test_upstream_dropping_a_site_key_is_refused(self):
        self._example_without("HF_CACHE")
        self.assertFail("no longer defines the site key", self.site())

    def test_upstream_adopting_our_added_key_is_refused(self):
        with open(os.path.join(self.upstream, ".env.example"),
                  "a", encoding="utf-8") as fh:
            fh.write("B12X_ROCE_SPIN_LIMIT=1\n")
        self.assertFail("now defines B12X_ROCE_SPIN_LIMIT", self.site())


if __name__ == "__main__":
    unittest.main(verbosity=2)
