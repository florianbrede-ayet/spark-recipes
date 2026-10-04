#!/usr/bin/env python3
"""Offline render parity for the three-file Compose stack.

Needs a pinned upstream checkout (RECIPE_UPSTREAM) and a Compose binary
(RECIPE_COMPOSE_BIN, or an autodetected `docker compose`). `compose config`
renders without a Docker daemon, so this runs on a machine with no Docker and
no GPU. No image is pulled, no weights are downloaded, nothing is started.

What parity means here, precisely:

* Baseline  = pinned upstream node compose file + pinned upstream .env.example.
* Recipe    = the same node compose file + the upstream display-KV override
              + this recipe's phase1 override + the merged env file.
* The test asserts the baseline-to-recipe difference is EXACTLY the documented
  profile delta plus the site mapping, and that the serve argv is exactly the
  argv of the live service with the site's own addresses substituted.

Expressing parity as a difference from the pinned upstream baseline is what
lets this test ship: it needs no copy of any upstream file, and it fails if
either side drifts.
"""

import hashlib
import json
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

UPSTREAM = os.environ.get("RECIPE_UPSTREAM", "")
COMPOSE_BIN = os.environ.get("RECIPE_COMPOSE_BIN", "")

SITE = {
    "HEAD_ROCE_IP": "198.51.100.1",
    "WORKER_ROCE_IP": "198.51.100.2",
    "MASTER_ADDR": "198.51.100.1",
    "NCCL_IB_HCA": "roceTESTa0f0",
    "NCCL_SOCKET_IFNAME": "enTESTa0f0np0",
    "CONTROL_IF": "enTESTc0f0np0",
    "HF_CACHE": "/srv/hf-cache-test",
    "DRM_CARD_GID": "1234",
}

# The live profile, as this recipe sets it. Values the site supplies are
# written as {tokens} and filled in from SITE.
EXPECTED_ENV_DELTA = {
    # profile constants
    "B12X_ROCE_SPIN_LIMIT": "200000000",
    "GLM53_SPLIT_TARGET_BLOCK_SIZE": "4096",
    "KV_CACHE_MEMORY_BYTES": "13876M",
    "MAX_NUM_BATCHED_TOKENS": "8192",
    "MAX_NUM_SEQS": "6",
    "MODEL_PATH": "local-inference-lab/GLM-5.3-Flash-NVFP4-Spark",
    "MODEL_REVISION": "a608241037e4c2565356bff7ca293f2133888f88",
    "PORT": "8888",
    "SERVED_MODEL_NAME": "local-inference-lab/GLM-5.3-Flash-NVFP4-Spark",
    # supplied by the display-KV override, from untouched upstream defaults
    "GLM53_DISPLAY_KV_ENABLE": "1",
    "GLM53_DISPLAY_KV_MIN_BYTES": "4294967296",
    # site mapping
    "MASTER_ADDR": "{MASTER_ADDR}",
    "VLLM_HOST_IP": "{LOCAL_FABRIC_IP}",
    "NCCL_IB_HCA": "{NCCL_IB_HCA}",
    "NCCL_SOCKET_IFNAME": "{NCCL_SOCKET_IFNAME}",
    "GLOO_SOCKET_IFNAME": "{CONTROL_IF}",
    "TP_SOCKET_IFNAME": "{CONTROL_IF}",
    "MN_IF_NAME": "{CONTROL_IF}",
    "OMPI_MCA_btl_tcp_if_include": "{CONTROL_IF}",
}

IMAGE_DIGEST = ("technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks@sha256:"
                "1169f797539454e3c286557d49fddd488488957d9a3f10638b01052998370622")

SPEC_CONFIG = ('{"method":"mtp","num_speculative_tokens":3,'
               '"moe_backend":"marlin","attention_backend":"B12X",'
               '"use_local_argmax_reduction":true,'
               '"disable_eagle_block_drop":true,'
               '"draft_sample_method":"greedy",'
               '"rejection_sample_method":"standard"}')


def expected_argv(role, site):
    """The serve argv of the live service, for one role."""
    argv = [
        "serve", "local-inference-lab/GLM-5.3-Flash-NVFP4-Spark",
        "--revision", "a608241037e4c2565356bff7ca293f2133888f88",
        "--served-model-name", "local-inference-lab/GLM-5.3-Flash-NVFP4-Spark",
        "--chat-template", "/opt/glm53/chat_template.jinja",
        "--trust-remote-code",
        "--distributed-executor-backend", "mp",
        "--tensor-parallel-size", "2",
        "--decode-context-parallel-size", "1",
        "--cp-kv-cache-interleave-size", "1",
        "--nnodes", "2",
        "--node-rank", "0" if role == "head" else "1",
        "--master-addr", site["MASTER_ADDR"],
        "--master-port", "29553",
    ]
    if role == "worker":
        argv.append("--headless")
    argv += [
        "--gpu-memory-utilization", "0.87",
        "--kv-cache-memory-bytes", "13876M",
        "--dtype", "bfloat16",
        "--kv-cache-dtype", "fp8",
        "--quantization", "modelopt_mixed",
        "--attention-backend", "B12X",
        "--block-size", "256",
        "--moe-backend", "b12x",
        "--linear-backend", "b12x",
        "--no-enable-flashinfer-autotune",
        "--load-format", "instanttensor",
        "--limit-mm-per-prompt", '{"image":32,"video":0}',
        "--mm-processor-cache-gb", "1",
        "--mamba-cache-mode", "align",
        "--kda-prefill-backend", "b12x",
        "--max-model-len", "1047552",
        "--max-num-seqs", "6",
        "--max-num-batched-tokens", "8192",
        "--enable-chunked-prefill",
        "--async-scheduling",
        "--enable-prefix-caching",
        "--prefix-match-unit", "128",
        "--enable-prompt-tokens-details",
        "--speculative-config", SPEC_CONFIG,
        "--tool-call-parser", "glm47",
        "--enable-auto-tool-choice",
        "--reasoning-parser", "glm45",
    ]
    if role == "head":
        argv += ["--host", "0.0.0.0", "--port", "8888"]
    return argv


def compose_argv():
    if COMPOSE_BIN:
        if os.path.isfile(COMPOSE_BIN) and os.access(COMPOSE_BIN, os.X_OK):
            return [COMPOSE_BIN]
        return COMPOSE_BIN.split()
    if shutil.which("docker"):
        probe = subprocess.run(["docker", "compose", "version"],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
        if probe.returncode == 0:
            return ["docker", "compose"]
    if shutil.which("docker-compose"):
        return ["docker-compose"]
    return []


def tree_digest(root, skip=(".git",)):
    h = hashlib.sha256()
    for base, dirs, names in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in skip)
        for name in sorted(names):
            path = os.path.join(base, name)
            h.update(os.path.relpath(path, root).encode())
            h.update(b"\0")
            h.update(envmerge.sha256_file(path).encode())
            h.update(b"\0")
    return h.hexdigest()


COMPOSE = compose_argv()
REASON = ("set RECIPE_UPSTREAM to a pinned upstream checkout and provide a "
          "Compose binary (RECIPE_COMPOSE_BIN or `docker compose`)")


@unittest.skipUnless(UPSTREAM and COMPOSE, REASON)
class TestRenderParity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="render-parity-")
        cls.site_path = os.path.join(cls.tmp, "site.env")
        with open(cls.site_path, "w", encoding="utf-8") as fh:
            for key in sorted(SITE):
                fh.write("%s=%s\n" % (key, SITE[key]))
        cls.merged = os.path.join(cls.tmp, "merged.env")
        envmerge.verify_source(UPSTREAM, "both", verbose=False)
        merged, _, order = envmerge.build_merged(UPSTREAM, cls.site_path)
        envmerge.write_private(cls.merged, envmerge.render_merged(
            merged, order, cls.site_path))
        cls.upstream_digest = tree_digest(UPSTREAM)
        cls.recipe_digest = tree_digest(RECIPE)
        # A fake `vllm` that reports its argv instead of serving anything.
        cls.fake = os.path.join(cls.tmp, "bin")
        os.makedirs(cls.fake)
        shim = os.path.join(cls.fake, "vllm")
        with open(shim, "w", encoding="utf-8") as fh:
            fh.write('#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done\n')
        os.chmod(shim, 0o755)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, True)

    # ---------------------------------------------------------------- helpers
    def render(self, files, env_file):
        cmd = COMPOSE + ["--env-file", env_file]
        for path in files:
            cmd += ["-f", path]
        cmd.append("config")
        cmd.append("--format")
        cmd.append("json")
        # Compose lets the ambient environment override --env-file, so render
        # with an explicit minimal environment, exactly as launch.sh does.
        env = {"PATH": "/usr/local/bin:/usr/bin:/bin",
               "HOME": os.environ.get("HOME", "/")}
        proc = subprocess.run(cmd, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env=env)
        return proc

    def baseline(self, role):
        node = "compose.head.yaml" if role == "head" else "compose.worker.yaml"
        proc = self.render([os.path.join(UPSTREAM, node)],
                           os.path.join(UPSTREAM, ".env.example"))
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        return json.loads(proc.stdout.decode())["services"]["glm53"]

    def recipe(self, role, env_file=None):
        node = "compose.head.yaml" if role == "head" else "compose.worker.yaml"
        proc = self.render([
            os.path.join(UPSTREAM, node),
            os.path.join(UPSTREAM, "compose.display-kv.override.yaml"),
            os.path.join(RECIPE, "compose.phase1.override.yaml"),
        ], env_file or self.merged)
        return proc

    def recipe_service(self, role):
        proc = self.recipe(role)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        return json.loads(proc.stdout.decode())["services"]["glm53"]

    def expected_delta(self, role):
        fill = dict(SITE)
        fill["LOCAL_FABRIC_IP"] = SITE["HEAD_ROCE_IP"] if role == "head" \
            else SITE["WORKER_ROCE_IP"]
        return dict((k, v.format(**fill)) for k, v in EXPECTED_ENV_DELTA.items())

    def argv(self, service):
        script = service["command"][1].replace("$$", "$")
        env = {
            "PATH": self.fake + ":/usr/bin:/bin",
            # The container's entrypoint discovers this by walking sysfs on the
            # node. Preset it here so the probe's absence does not abort the
            # script under `set -u`; it does not appear in the serve argv.
            "NCCL_IB_GID_INDEX": "3",
        }
        env.update(dict((k, "" if v is None else v)
                        for k, v in service["environment"].items()))
        proc = subprocess.run(
            ["bash", "--noprofile", "--norc", "-lc", script],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        lines = proc.stdout.decode().splitlines()
        self.assertTrue(lines[0].startswith("[glm53] NODE_RANK="), lines[:1])
        return lines[1:]

    # ------------------------------------------------------------------ tests
    def test_env_delta_is_exactly_the_documented_overlay(self):
        for role in ("head", "worker"):
            base = self.baseline(role)["environment"]
            got = self.recipe_service(role)["environment"]
            delta = dict((k, got.get(k)) for k in set(base) | set(got)
                         if base.get(k) != got.get(k))
            self.assertEqual(delta, self.expected_delta(role), role)

    def test_untouched_upstream_keys_pass_through(self):
        for role in ("head", "worker"):
            base = self.baseline(role)["environment"]
            got = self.recipe_service(role)["environment"]
            expected = self.expected_delta(role)
            for key, value in base.items():
                if key not in expected:
                    self.assertEqual(got[key], value, "%s/%s" % (role, key))

    def test_image_is_the_digest_pin_not_a_tag(self):
        for role in ("head", "worker"):
            image = self.recipe_service(role)["image"]
            self.assertEqual(image, IMAGE_DIGEST, role)
            self.assertIn("@sha256:", image)
            self.assertNotEqual(image, self.baseline(role)["image"])

    def test_display_kv_override_adds_the_drm_device_and_group(self):
        for role in ("head", "worker"):
            base = self.baseline(role)
            got = self.recipe_service(role)
            self.assertEqual(got["group_add"], [SITE["DRM_CARD_GID"]], role)
            self.assertIsNone(base.get("group_add"), role)
            added = [d for d in got["devices"] if d not in base["devices"]]
            self.assertEqual([d["source"] for d in added], ["/dev/dri/card0"])

    def test_hf_cache_bind_comes_from_the_site_layer(self):
        for role in ("head", "worker"):
            got = self.recipe_service(role)
            binds = dict((v["target"], v) for v in got["volumes"])
            cache = binds["/root/.cache/huggingface"]
            self.assertEqual(cache["source"], SITE["HF_CACHE"], role)
            template = binds["/opt/glm53/chat_template.jinja"]
            self.assertTrue(template.get("read_only"))
            self.assertEqual(
                os.path.realpath(template["source"]),
                os.path.realpath(os.path.join(UPSTREAM,
                                              "files/chat_template.jinja")),
                "the chat template must resolve inside the pinned upstream "
                "checkout, not be copied into this recipe")

    def test_overlay_changes_no_serve_logic(self):
        for role in ("head", "worker"):
            self.assertEqual(self.recipe_service(role)["command"],
                             self.baseline(role)["command"], role)

    def test_serve_argv_matches_the_live_service(self):
        for role in ("head", "worker"):
            self.assertEqual(self.argv(self.recipe_service(role)),
                             expected_argv(role, SITE), role)

    def test_head_and_worker_differ_only_in_rank_headless_and_local_ip(self):
        head = self.recipe_service("head")
        worker = self.recipe_service("worker")
        env_diff = sorted(k for k in set(head["environment"])
                          | set(worker["environment"])
                          if head["environment"].get(k)
                          != worker["environment"].get(k))
        self.assertEqual(env_diff, ["HEADLESS", "NODE_RANK", "VLLM_HOST_IP"])
        for key in set(head) | set(worker):
            if key != "environment":
                self.assertEqual(head[key], worker[key], key)
        head_argv = self.argv(head)
        worker_argv = self.argv(worker)
        self.assertNotIn("--headless", head_argv)
        self.assertIn("--headless", worker_argv)
        self.assertIn("--host", head_argv)
        self.assertNotIn("--host", worker_argv)
        self.assertNotIn("--port", worker_argv)

    def test_unauthenticated_api_is_only_on_rank_zero(self):
        head_argv = self.argv(self.recipe_service("head"))
        self.assertEqual(head_argv[head_argv.index("--host") + 1], "0.0.0.0")
        self.assertEqual(head_argv[head_argv.index("--port") + 1], "8888")
        for flag in ("--api-key", "--ssl-keyfile", "--ssl-certfile"):
            self.assertNotIn(flag, head_argv)

    def test_offline_posture_is_inherited_from_the_compose_files(self):
        for role in ("head", "worker"):
            env = self.recipe_service(role)["environment"]
            self.assertEqual(env["HF_HUB_OFFLINE"], "1", role)
            self.assertEqual(env["TRANSFORMERS_OFFLINE"], "1", role)
        with open(self.merged, encoding="utf-8") as fh:
            body = fh.read()
        for key in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_TOKEN"):
            self.assertNotIn("\n%s=" % key, body)

    def test_phase1_override_is_what_delivers_the_spin_limit(self):
        node = os.path.join(UPSTREAM, "compose.head.yaml")
        display = os.path.join(UPSTREAM, "compose.display-kv.override.yaml")
        proc = self.render([node, display], self.merged)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode())
        without = json.loads(proc.stdout.decode())
        self.assertNotIn("B12X_ROCE_SPIN_LIMIT",
                         without["services"]["glm53"]["environment"])
        self.assertEqual(
            self.recipe_service("head")["environment"]["B12X_ROCE_SPIN_LIMIT"],
            "200000000")

    def test_phase1_override_fails_closed_without_the_value(self):
        stripped = os.path.join(self.tmp, "no-spin.env")
        with open(self.merged, encoding="utf-8") as src:
            kept = [ln for ln in src
                    if not ln.startswith("B12X_ROCE_SPIN_LIMIT=")]
        with open(stripped, "w", encoding="utf-8") as dst:
            dst.writelines(kept)
        proc = self.recipe("head", env_file=stripped)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("spin limit required", proc.stderr.decode())

    def test_rendering_mutates_nothing(self):
        for role in ("head", "worker"):
            self.recipe_service(role)
            self.baseline(role)
        self.assertEqual(tree_digest(UPSTREAM), self.upstream_digest,
                         "the upstream checkout changed during rendering")
        self.assertEqual(tree_digest(RECIPE), self.recipe_digest,
                         "the recipe directory changed during rendering")


if __name__ == "__main__":
    unittest.main(verbosity=2)
