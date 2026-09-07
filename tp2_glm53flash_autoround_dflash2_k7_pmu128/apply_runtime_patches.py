#!/usr/bin/env python3
"""Fail-closed installer for the external-DFlash2 k7 PMU128 patch series.

Applies the bundled unified diffs and the SM121 kpool overlay to the vLLM
tree of the digest-pinned base image, gating every step on exact before and
after SHA-256. It also verifies the unchanged inherited DFlash2 files. All
outputs and unchanged inputs are validated in memory (hashes + syntax)
BEFORE the first write; installation stages temp siblings and atomically
replaces each target. A completely final tree is accepted as an idempotent
no-op. Any other mismatch aborts without writing. Pure Python: no `patch` or
`git` binary is required inside the image.

Usage:
  apply_runtime_patches.py [--root DIR]            apply all steps
  apply_runtime_patches.py --root DIR --verify-only  assert final state only

ROOT is the directory containing `vllm/` (inside the image:
/usr/local/lib/python3.12/dist-packages).
"""

import argparse
import ast
import hashlib
import os
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PATCH_DIR = SCRIPT_DIR / "patches"
DEFAULT_ROOT = "/usr/local/lib/python3.12/dist-packages"

BASE_IMAGE = "ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6"

# Ordered patch steps: patch file -> {repo-relative path: (before, after) SHA-256}.
PATCH_STEPS = [
    ("0001-vllm-53388-native-mtp-block-drop.patch", {
        "vllm/config/speculative.py": (
            "eaf52a03351398f72d3e85f0d1ce3bf80d1f92e0fddc8f28bdb11738aeab7875",
            "7a1a93810f3232c4ff9b40e69e8c95d80d566eb2eca07523c027153ac9b39134"),
        "vllm/v1/core/kv_cache_utils.py": (
            "624ea7b0244972cb6c53044588912dfea54f3d6a91661cbc423af27e3b5c4b86",
            "cb7daec1354727696da42d4a7c42f770eb260304195d690ebd7a22427201062e"),
        "vllm/v1/core/single_type_kv_cache_manager.py": (
            "41043976d1d5e38e0465c8004fc04e01f35f66b39a40099c62d79b3756337d00",
            "f2b6c9c8e2bd1f6af67443af53c6b60dece315f0ef6ca0f79b4b449024b8e0db"),
        "vllm/v1/core/sched/scheduler.py": (
            "4c38a32c7405eb95eb9dd3b3d04cbfe5d0cb4ebc0b18efbaa4adc68c7a9bca5a",
            "5b26e8947e94ece009d1f30d5010079ce0b68f288caa28b4ecc22e3924857c10"),
    }),
    ("0002-vllm-53906-coordinator-partial-hits.patch", {
        "vllm/v1/core/kv_cache_coordinator.py": (
            "f640b5c42f6bc718926329a8f8b48a0fd0c8c8f24368af4e4b9ec8d13f68432f",
            "2401f79bc1162da240f7c97edff31d3349b2261a5c76ed4647e85ee85960b863"),
    }),
    ("0003-vllm-scheduler-lcm-mamba-block-align.patch", {
        "vllm/v1/core/sched/scheduler.py": (
            "5b26e8947e94ece009d1f30d5010079ce0b68f288caa28b4ecc22e3924857c10",
            "acf44a9dbc1fba5347d7dec57deb928cd101653fe7ef0816b7bdd723e29f0478"),
    }),
    ("dflash2-pmu128-swa-fine-hits.patch", {
        "vllm/v1/core/single_type_kv_cache_manager.py": (
            "f2b6c9c8e2bd1f6af67443af53c6b60dece315f0ef6ca0f79b4b449024b8e0db",
            "825ea2ad16b4db417606c9be2ca1b44af44402659b9285dfe0b2aa0a821a3561"),
        "vllm/v1/core/kv_cache_coordinator.py": (
            "2401f79bc1162da240f7c97edff31d3349b2261a5c76ed4647e85ee85960b863",
            "cf75ab28813ceb95d083aa6bec1d13a810dedb087f482f433dd9ace31b94cdc2"),
    }),
]

PATCH_SHA256 = {
    "0001-vllm-53388-native-mtp-block-drop.patch":
        "fbc000dc69bae656771635f88be1721431905bdf7f63c63bd11e8ea0823a3d74",
    "0002-vllm-53906-coordinator-partial-hits.patch":
        "a207e7848dc739517963d9bad29efef502be4734def736bba1e8433f6c73d2be",
    "0003-vllm-scheduler-lcm-mamba-block-align.patch":
        "73cfe8033326c1d6897d28b11a6899818ea30aa881df45b7b67357b56eb81c3c",
    "dflash2-pmu128-swa-fine-hits.patch":
        "302ca0cbd7d889df928d1eca7986cc50230855b5660ae72bcc8a696690bc144c",
}

# The exact candidate artifact has one stale hunk count (git apply accepts
# and recounts it). Preserve the digest-pinned bytes, but normalize that one
# metadata line in memory for this strict pure-Python parser.
PATCH_HEADER_RECOUNTS = {
    "dflash2-pmu128-swa-fine-hits.patch": {
        "@@ -790,11 +793,15 @@ class HybridKVCacheCoordinator(KVCacheCoordinator):":
        "@@ -790,12 +793,16 @@ class HybridKVCacheCoordinator(KVCacheCoordinator):",
    },
}

# Complete-file overlay: target -> (before, after, bundled asset name).
OVERLAY = {
    "vllm/model_executor/layers/sparse_attn_indexer_kpool.py": (
        "ab5972fdea99fb19e78d2e34ff364012dd43e0b9314869854c279d0b26e30065",
        "8a3ecfb0bab2441dd7417ed00a10d142191496149f88e5fe79fcfaea4b160980",
        "sparse_attn_indexer_kpool_sm121.py"),
}

# Files inherited unchanged from the digest-pinned public DFlash2 base. The
# three DFlash2 implementation hashes match the pinned public overlay commit;
# the registry is that overlay's deterministic derived result. The cache core
# hashes bind the exact alias/CoW machinery exercised by the CPU regressions.
BASE_UNCHANGED = {
    "vllm/model_executor/models/qwen3_dflash2.py":
        "c141daa4b2059c0098224ac36471c2197b7052c100bef0a4dbc2ca79b627053f",
    "vllm/model_executor/models/registry.py":
        "4ec20f260e4c9b47d2e25c196b9ae4d0f792bb6efcfa9e8c608471d7b0298b64",
    "vllm/v1/core/block_pool.py":
        "ddee56dccb2208411b3a035918e917ce8f56a9858471e9ca12b420d5d79bc69c",
    "vllm/v1/core/kv_cache_manager.py":
        "9747090b01f758487ac7488fb0721c7cfe5507e8aeb55f4ea3795349bfff0968",
    "vllm/v1/worker/gpu/spec_decode/dflash2/__init__.py":
        "e3c55cbb0d7a8bd47df6f3378835644645f5d3bc89b45793b5d5a02d013e5c58",
    "vllm/v1/worker/gpu/spec_decode/dflash2/speculator.py":
        "66aa43b74abfdaa9aa09e00e6511fab273e7c8a1c5da6c0d06e1daa07216ffd5",
}

HUNK_HEADER = re.compile(r"^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@")


def die(msg: str) -> "None":
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_text(path: Path) -> str:
    with open(path, "r", encoding="utf-8", newline="") as fh:
        return fh.read()


def parse_unified_diff(text: str) -> dict:
    """Parse a unified diff into {path: [(old_lines, new_lines), ...]}.

    Strict: multi-file diffs supported, every hunk must be complete and
    well-formed or the installer aborts.
    """
    files: dict = {}
    state = {"path": None, "hunks": None, "old": None, "new": None,
             "rem_old": 0, "rem_new": 0, "in_hunk": False}

    def flush_file() -> None:
        if state["path"] is None:
            return
        if state["in_hunk"]:
            die(f"{state['path']}: truncated hunk in diff")
        if not state["hunks"]:
            die(f"{state['path']}: no hunks in diff section")
        files[state["path"]] = state["hunks"]

    def flush_hunk() -> None:
        if state["rem_old"] != 0 or state["rem_new"] != 0:
            die(f"{state['path']}: hunk ended early "
                f"(old missing {state['rem_old']}, new missing {state['rem_new']})")
        state["hunks"].append((state["old"], state["new"]))
        state["in_hunk"] = False
        state["old"] = state["new"] = None

    for line in text.split("\n"):
        if state["in_hunk"]:
            if line.startswith("\\"):
                die("\\ No newline at end of file is not supported by this installer")
            if line.startswith("+"):
                state["new"].append(line[1:])
                state["rem_new"] -= 1
            elif line.startswith("-"):
                state["old"].append(line[1:])
                state["rem_old"] -= 1
            elif line.startswith(" "):
                state["old"].append(line[1:])
                state["new"].append(line[1:])
                state["rem_old"] -= 1
                state["rem_new"] -= 1
            elif line == "" and (state["rem_old"] > 0 or state["rem_new"] > 0):
                state["old"].append("")
                state["new"].append("")
                state["rem_old"] -= 1
                state["rem_new"] -= 1
            else:
                flush_hunk()
            if state["in_hunk"] and state["rem_old"] == 0 and state["rem_new"] == 0:
                flush_hunk()
            continue
        if line.startswith("@@") and HUNK_HEADER.match(line):
            match = re.match(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", line)
            state["rem_old"] = int(match.group(1)) if match.group(1) else 1
            state["rem_new"] = int(match.group(3)) if match.group(3) else 1
            state["old"], state["new"] = [], []
            state["in_hunk"] = True
        elif line.startswith("--- a/"):
            flush_file()
            state["path"] = line[6:]
            state["hunks"] = []
        elif line.startswith("+++ b/"):
            if state["path"] is None or line[6:] != state["path"]:
                die(f"unsupported diff header pair for {state['path']!r} / {line[6:]!r}")
        elif line.startswith("diff --git") or line.startswith("index ") or line == "":
            continue
        else:
            die(f"unexpected line outside hunk: {line!r}")
    if state["in_hunk"]:
        flush_hunk()
    flush_file()
    if not files:
        die("no usable hunks found in patch")
    return files


def apply_hunks(source: str, hunks: list, rel: str) -> str:
    lines = source.split("\n")
    for old_block, new_block in hunks:
        span = len(old_block)
        hits = [i for i in range(len(lines) - span + 1)
                if lines[i:i + span] == old_block]
        if len(hits) != 1:
            die(f"{rel}: hunk old-block match count {len(hits)} (need exactly 1), "
                f"first line {old_block[0]!r}")
        lines[hits[0]:hits[0] + span] = new_block
    return "\n".join(lines)


def plan_all(root: Path) -> list:
    """Preflight: derive every output in memory and validate before/after
    SHA-256 plus syntax (the overlay asset is AST-parsed as well), chaining
    in-memory state across steps (the scheduler is patched twice).
    Returns [(target, data, rel, first_before, last_after)]. Performs no
    writes."""
    state: dict = {}        # rel -> current in-memory bytes
    first_before: dict = {}
    last_after: dict = {}
    for patch_name, targets in PATCH_STEPS:
        patch_path = PATCH_DIR / patch_name
        if not patch_path.is_file():
            die(f"missing bundled patch: {patch_name}")
        got_patch_sha = sha256_file(patch_path)
        if got_patch_sha != PATCH_SHA256[patch_name]:
            die(
                f"{patch_name}: SHA {got_patch_sha} != exact bundled "
                f"artifact {PATCH_SHA256[patch_name]}"
            )
        patch_text = read_text(patch_path)
        for old_header, new_header in PATCH_HEADER_RECOUNTS.get(
            patch_name, {}
        ).items():
            if patch_text.count(old_header) != 1:
                die(f"{patch_name}: expected stale header not found exactly once")
            patch_text = patch_text.replace(old_header, new_header)
        parsed = parse_unified_diff(patch_text)
        if set(parsed) != set(targets):
            die(f"{patch_name}: patch touches {sorted(parsed)}, expected {sorted(targets)}")
        for rel, (before, after) in targets.items():
            if rel not in state:
                target = root / rel
                if not target.is_file():
                    die(f"{rel}: missing from tree")
                state[rel] = target.read_bytes()
                first_before[rel] = before
            if hashlib.sha256(state[rel]).hexdigest() != before:
                die(f"{rel}: current SHA {hashlib.sha256(state[rel]).hexdigest()} "
                    f"!= expected before {before}")
            patched = apply_hunks(state[rel].decode("utf-8"), parsed[rel], rel).encode("utf-8")
            if hashlib.sha256(patched).hexdigest() != after:
                die(f"{rel}: computed post-patch SHA != expected after {after}")
            if rel.endswith(".py"):
                try:
                    ast.parse(patched.decode("utf-8"))
                except SyntaxError as exc:
                    die(f"{rel}: patched content fails syntax check: {exc}")
            state[rel] = patched
            last_after[rel] = after
    for rel, (before, after, asset) in OVERLAY.items():
        if rel not in state:
            target = root / rel
            if not target.is_file():
                die(f"{rel}: missing from tree")
            state[rel] = target.read_bytes()
            first_before[rel] = before
        if hashlib.sha256(state[rel]).hexdigest() != before:
            die(f"{rel}: current SHA {hashlib.sha256(state[rel]).hexdigest()} "
                f"!= expected before {before}")
        data = (PATCH_DIR / asset).read_bytes()
        if hashlib.sha256(data).hexdigest() != after:
            die(f"bundled asset {asset}: SHA mismatch against expected after {after}")
        try:
            ast.parse(data.decode("utf-8"))
        except SyntaxError as exc:
            die(f"bundled asset {asset}: syntax check failed: {exc}")
        state[rel] = data
        last_after[rel] = after
    # These do not produce writes, but they are part of the preflight so a
    # late inherited-file mismatch still leaves every patch target untouched.
    for rel, expected in BASE_UNCHANGED.items():
        target = root / rel
        if not target.is_file():
            die(f"{rel}: missing unchanged inherited file")
        data = target.read_bytes()
        got = hashlib.sha256(data).hexdigest()
        if got != expected:
            die(f"{rel}: unchanged SHA {got} != expected {expected}")
        if rel.endswith(".py"):
            try:
                ast.parse(data.decode("utf-8"))
            except SyntaxError as exc:
                die(f"{rel}: unchanged content fails syntax check: {exc}")

    return [(root / rel, state[rel], rel, first_before[rel], last_after[rel])
            for rel in sorted(last_after)]


def install(plans: list) -> None:
    staged = []
    try:
        for target, data, rel, before, after in plans:
            tmp = target.parent / f".{target.name}.tmp-{os.getpid()}"
            with open(tmp, "wb") as fh:
                fh.write(data)
            staged.append(tmp)
            os.replace(tmp, target)
            print(f"  {rel}: {before[:12]}.. -> {after[:12]}..")
    finally:
        for tmp in staged:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass


def expected_final_hashes() -> dict[str, str]:
    expected = {}
    for _, targets in PATCH_STEPS:
        for rel, (_, after) in targets.items():
            expected[rel] = after
    for rel, (_, after, _) in OVERLAY.items():
        expected[rel] = after
    expected.update(BASE_UNCHANGED)
    return expected


def tree_is_final(root: Path) -> bool:
    return all(
        (root / rel).is_file() and sha256_file(root / rel) == expected
        for rel, expected in expected_final_hashes().items()
    )


def verify(root: Path) -> None:
    expected = expected_final_hashes()
    bad = []
    for rel in sorted(expected):
        target = root / rel
        if not target.is_file():
            bad.append(rel)
            print(f"  MISSING {rel}")
            continue
        got = sha256_file(target)
        print(f"  {'OK' if got == expected[rel] else 'MISMATCH'} {rel} {got}")
        if got != expected[rel]:
            bad.append(rel)
        if rel.endswith(".py"):
            try:
                ast.parse(read_text(target))
            except SyntaxError as exc:
                die(f"{rel}: syntax check failed: {exc}")
    if bad:
        die(f"{len(bad)} file(s) not at final hashes: {sorted(bad)}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=DEFAULT_ROOT,
                    help="directory containing vllm/ (default: %(default)s)")
    ap.add_argument("--verify-only", action="store_true",
                    help="do not patch; assert every target is at its final hash")
    args = ap.parse_args()
    root = Path(args.root)
    if not (root / "vllm").is_dir():
        die(f"{root}: no vllm/ tree (base image {BASE_IMAGE} expected)")
    print(f"patch installer root={root} base={BASE_IMAGE}")
    if args.verify_only:
        verify(root)
        print("verify-only OK")
        return
    if tree_is_final(root):
        verify(root)
        print("already at exact final state; no writes needed")
        return
    plans = plan_all(root)
    print(
        f"preflight OK: {len(plans)} file writes derived and "
        f"{len(BASE_UNCHANGED)} inherited files validated in memory"
    )
    install(plans)
    verify(root)
    print("all patches applied and final hashes verified")


if __name__ == "__main__":
    main()
