#!/usr/bin/env python3
"""Adapt Intel/GLM-5.3-Flash-W4A16-AutoRound metadata to vLLM GPTQ metadata.

Transforms ONLY config.json; every other regular file of the source snapshot
is preserved byte-identically (hardlink, copy fallback), so the destination
is a complete loadable checkpoint. The source revision is byte-pinned, so
unknown extra files are preserved rather than ignored. Only explicitly
transient download artifacts are excluded:
  * `*.part` partial downloads
  * `.download.lock` lock files
  * `.cache/huggingface/` metadata written by --local-dir downloads
Symlinks are materialized only when they resolve to a regular file inside the
source tree; symlinks pointing outside and non-regular files are rejected.

Fail-closed and idempotent:
  * creation requires non-nested roots (SRC must not lie inside DST and vice
    versa) and an absent DST; everything is staged in a temporary directory
    and renamed into place only after all checks pass;
  * re-running against an existing DST is strict revalidation and a true
    no-op: exact destination tree coverage versus the pinned source (after
    the transient exclusions above), exact transformed config hash, per-file
    content equality versus the source. The GPTQ-SURGERY.json receipt is
    informational: a normal rerun may refresh a missing or stale receipt
    ONLY after the full payload validation has passed, while --check never
    mutates and fails on a missing or mismatching receipt;
  * the source config and index are pinned; the collision scan (no exclusion
    may match a quantized module) runs once at creation.

Usage:
  adapt_autoround_to_gptq.py SRC DST                 full checkpoint (loadable)
  adapt_autoround_to_gptq.py SRC DST --metadata-only  transformed config+receipt only
  adapt_autoround_to_gptq.py SRC DST --check          strict validation, no writes
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
from pathlib import Path

REVISION = "5eee1846f0321058ed73745f9aa16f2aaf0fc0a0"
SOURCE_CONFIG_SHA = (
    "d4deaf40c47b2ff49f1d8e0c306032d7a8b84f90b6a2743e694b712d87dd5692")
SOURCE_INDEX_SHA = (
    "a250db4fcc9443d0164335a7a2c7a1da4eef91e212304e2e695a08d565a75102")
OUTPUT_CONFIG_SHA = (
    "958beaf7c4ddf9ba1d8dcb5e938fcddc0deaa62d41e0f85909a45a12ae8c97a6")
EXPECTED_EXTRA_RULES = 679
EXPECTED_SHARDS = 34
EXPECTED_WEIGHT_MAP_ENTRIES = 113074
EXPECTED_QUANTIZED_MODULES = 37152
RECEIPT_NAME = "GPTQ-SURGERY.json"
TRANSIENT_SUFFIX = ".part"
TRANSIENT_NAMES = {".download.lock"}
HF_CACHE_MARKERS = (".cache", "huggingface")

_HARD_METACHARS = "?+{|()[]^$"
_LITERAL_RUN = re.compile(r"(?:\\\.|[A-Za-z0-9_/-])+")


def required_literal(pattern: str) -> "str | None":
    """Longest literal substring any match must contain, or None.

    Sound when the pattern has no alternation/classes/anchors and every `*`
    belongs to a `.*` run: each literal run must then occur contiguously in
    any match, so a containment prefilter can safely narrow candidates before
    the exact re.match check.
    """
    if any(c in pattern for c in _HARD_METACHARS):
        return None
    for i, ch in enumerate(pattern):
        if ch == "*" and (i == 0 or pattern[i - 1] not in "."):
            return None
        if ch == "\\" and pattern[i + 1:i + 2] != ".":
            return None
    runs = _LITERAL_RUN.findall(pattern)
    if not runs:
        return None
    return max(runs, key=len).replace("\\.", ".")


def die(msg: str) -> "None":
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def is_transient(rel: Path) -> bool:
    """Known download-transient metadata, excluded on both sides."""
    if rel.suffix == TRANSIENT_SUFFIX or rel.name in TRANSIENT_NAMES:
        return True
    parts = rel.parts
    return any(parts[i:i + 2] == HF_CACHE_MARKERS for i in range(len(parts)))


def walk_source(source_root: Path) -> list:
    """All regular files (and safe within-source symlinks) recursively.
    Rejects symlinks leaving the source, symlinked directories, and any
    non-regular entry, so nothing is silently ignored."""
    resolved_root = source_root.resolve()
    entries = []
    for dirpath, dirnames, filenames in os.walk(source_root, followlinks=False):
        here = Path(dirpath)
        for name in dirnames:
            if (here / name).is_symlink():
                die(f"symlinked directory not supported: "
                    f"{(here / name).relative_to(source_root).as_posix()}")
        for name in sorted(filenames):
            full = here / name
            rel = full.relative_to(source_root)
            if full.is_symlink():
                target = full.resolve()
                if not target.is_file() or not target.is_relative_to(resolved_root):
                    die(f"symlink {rel.as_posix()} does not resolve to a file "
                        "inside the source tree")
                entries.append((target, rel))
            elif full.is_file():
                entries.append((full, rel))
            else:
                die(f"unsupported non-regular source entry: {rel.as_posix()}")
    return entries


def load_source_metadata(src: Path):
    """Hash-gate and structurally validate the pinned source metadata."""
    cfg_data = (src / "config.json").read_bytes()
    if sha256_bytes(cfg_data) != SOURCE_CONFIG_SHA:
        die(f"src config.json SHA mismatch against pinned {SOURCE_CONFIG_SHA}")
    cfg = json.loads(cfg_data)
    q = cfg["quantization_config"]
    extra = q["extra_config"]
    if len(extra) != EXPECTED_EXTRA_RULES:
        die(f"extra_config has {len(extra)} rules, expected {EXPECTED_EXTRA_RULES}")
    if q["bits"] != 4 or q["group_size"] != 128 or q["sym"] is not True:
        die("source quantization is not W4A16 group-128 sym")
    for pattern, rule in extra.items():
        re.compile(pattern)  # raises on an invalid pattern
        if rule.get("bits", 16) < 16 or rule.get("data_type", "float") not in ("float", "fp"):
            die(f"exclusion {pattern!r} does not retain a full-precision module")

    idx_data = (src / "model.safetensors.index.json").read_bytes()
    if sha256_bytes(idx_data) != SOURCE_INDEX_SHA:
        die(f"src model.safetensors.index.json SHA mismatch against pinned {SOURCE_INDEX_SHA}")
    idx = json.loads(idx_data)
    weight_map = idx["weight_map"]
    if idx["metadata"]["total_shards"] != EXPECTED_SHARDS:
        die(f"total_shards != {EXPECTED_SHARDS}")
    if len(weight_map) != EXPECTED_WEIGHT_MAP_ENTRIES:
        die(f"weight_map has {len(weight_map)} entries, expected {EXPECTED_WEIGHT_MAP_ENTRIES}")
    quantized = {name.rsplit(".", 1)[0] for name in weight_map if name.endswith(".qweight")}
    if len(quantized) != EXPECTED_QUANTIZED_MODULES:
        die(f"{len(quantized)} quantized modules, expected {EXPECTED_QUANTIZED_MODULES}")
    for suffix in (".qzeros", ".scales"):
        if sum(name.endswith(suffix) for name in weight_map) != EXPECTED_QUANTIZED_MODULES:
            die(f"count of *{suffix} entries != {EXPECTED_QUANTIZED_MODULES}")
    return cfg, extra, set(weight_map.values()), len(weight_map), len(quantized), quantized


def check_collisions(extra: dict, quantized: set) -> None:
    """Exact re.match scan: no exclusion may match a quantized module."""
    modules = tuple(sorted(quantized))
    for pattern in extra:
        lit = required_literal(pattern)
        candidates = (name for name in modules if lit in name) if lit else modules
        for name in candidates:
            if re.match(pattern, name):
                die(f"exclusion pattern {pattern!r} collides with quantized module {name!r}")


def transformed_config(cfg) -> bytes:
    extra = cfg["quantization_config"]["extra_config"]
    out = json.loads(json.dumps(cfg))
    out["quantization_config"] = {
        "quant_method": "gptq",
        "bits": 4,
        "group_size": 128,
        "sym": True,
        "desc_act": False,
        "lm_head": False,
        "true_sequential": True,
        "dynamic": {"-:" + pattern: {} for pattern in extra},
    }
    return (json.dumps(out, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def expected_receipt(src_config_sha, out_config_sha, extra_n, wm_n, qmod_n, mode) -> dict:
    script = Path(__file__).resolve()
    return {
        "extra_rules": extra_n,
        "mode": mode,
        "output_config_sha256": out_config_sha,
        "quantized_modules": qmod_n,
        "revision": REVISION,
        "script_sha256": sha256_bytes(script.read_bytes()),
        "source_config_sha256": src_config_sha,
        "weight_map_entries": wm_n,
    }


def write_receipt(dst: Path, receipt: dict) -> None:
    body = (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode("utf-8")
    receipt_path = dst / RECEIPT_NAME
    with open(receipt_path, "wb") as fh:
        fh.write(body)
    os.chmod(receipt_path, 0o640)


def preserve_file(src_abs: Path, target: Path) -> None:
    """Byte-identical preservation: hardlink preferred, staged copy fallback."""
    try:
        os.link(src_abs, target)
    except OSError:
        tmp = target.parent / f".{target.name}.copy-tmp-{os.getpid()}"
        shutil.copy2(src_abs, tmp)
        os.replace(tmp, target)


def create(src: Path, dst: Path, metadata_only: bool) -> None:
    cfg, extra, shard_names, wm_n, qmod_n, quantized = load_source_metadata(src)
    check_collisions(extra, quantized)
    entries = walk_source(src)
    skipped = sum(1 for _, rel in entries if is_transient(rel))
    present = {rel.as_posix() for path, rel in entries if not is_transient(rel)}
    if not metadata_only:
        missing = sorted(shard_names - present)
        if missing:
            die(f"src is missing {len(missing)} weight shard(s), e.g. {missing[:3]}")
    new_cfg = transformed_config(cfg)
    got = sha256_bytes(new_cfg)
    if got != OUTPUT_CONFIG_SHA:
        die(f"transformed config SHA {got} != pinned output {OUTPUT_CONFIG_SHA}; refusing to write")
    mode = "metadata-only" if metadata_only else "full"
    receipt = expected_receipt(SOURCE_CONFIG_SHA, got, len(extra), wm_n, qmod_n, mode)
    staging = dst.parent / f".{dst.name}.tmp-{os.getpid()}"
    if staging.exists():
        die(f"staging path {staging} already exists")
    try:
        dst.parent.mkdir(parents=True, exist_ok=True, mode=0o750)
        staging.mkdir(mode=0o750)
        written = 0
        for path, rel in entries:
            if is_transient(rel):
                continue
            target = staging / rel
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o750)
            if rel.as_posix() == "config.json":
                with open(target, "wb") as fh:
                    fh.write(new_cfg)
                os.chmod(target, 0o640)
            else:
                if metadata_only:
                    continue
                preserve_file(path, target)
            written += 1
        write_receipt(staging, receipt)
        try:
            staging.rename(dst)
        except OSError:
            die(f"destination {dst} appeared during adaptation")
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    print(f"created {dst} ({mode}): {written} files written "
          f"({skipped} transient source artifacts skipped), output config {got}")


def revalidate(src: Path, dst: Path, metadata_only: bool, check_only: bool) -> None:
    """Strict validation of an existing destination.

    A normal rerun (check_only=False) may refresh a missing or mismatching
    receipt only after the entire payload has passed validation; --check
    never writes and requires a correct receipt to already be present."""
    if not dst.is_dir():
        die(f"{dst}: not a directory (partial state)")
    cfg_path = dst / "config.json"
    if not cfg_path.is_file():
        die(f"{dst}/config.json missing (partial state)")
    got = sha256_bytes(cfg_path.read_bytes())
    if got != OUTPUT_CONFIG_SHA:
        die(f"{dst}/config.json SHA {got} != pinned output {OUTPUT_CONFIG_SHA}: "
            "incorrect existing destination")
    if sha256_bytes((src / "config.json").read_bytes()) != SOURCE_CONFIG_SHA:
        die(f"src config.json SHA mismatch against pinned {SOURCE_CONFIG_SHA}")
    if sha256_bytes((src / "model.safetensors.index.json").read_bytes()) != SOURCE_INDEX_SHA:
        die(f"src model.safetensors.index.json SHA mismatch against pinned {SOURCE_INDEX_SHA}")
    _, extra, shard_names, wm_n, qmod_n, _ = load_source_metadata(src)
    mode = "metadata-only" if metadata_only else "full"

    if metadata_only:
        expected = {"config.json"}
    else:
        entries = walk_source(src)
        expected = {rel.as_posix() for path, rel in entries if not is_transient(rel)}
        missing = sorted(shard_names - expected)
        if missing:
            die(f"src is missing {len(missing)} weight shard(s), e.g. {missing[:3]}")
    actual = set()
    for path in dst.rglob("*"):
        rel = path.relative_to(dst)
        if path.is_symlink():
            die(f"unexpected symlink in destination: {rel.as_posix()}")
        if path.is_dir():
            continue
        if is_transient(rel) or rel.as_posix() == RECEIPT_NAME:
            continue
        actual.add(rel.as_posix())
    if actual != expected:
        missing = sorted(expected - actual)
        extra_files = sorted(actual - expected)
        hint = ("; destination contains weight shards, use full mode"
                if metadata_only and extra_files else "")
        die(f"destination tree mismatch (mode {mode}{hint}): "
            f"missing={missing[:5]} unexpected={extra_files[:5]}")

    if not metadata_only:
        for path, rel in entries:
            if is_transient(rel) or rel.as_posix() == "config.json":
                continue
            dpath = dst / rel
            try:
                if os.path.samefile(path, dpath):
                    continue  # hardlink to the pinned source: identical by construction
            except OSError:
                die(f"destination missing preserved file: {rel.as_posix()}")
            if sha256_file(path) != sha256_file(dpath):
                die(f"destination preserved file differs from source: {rel.as_posix()}")

    receipt = expected_receipt(
        SOURCE_CONFIG_SHA, OUTPUT_CONFIG_SHA, len(extra), wm_n, qmod_n, mode)
    receipt_path = dst / RECEIPT_NAME
    current = None
    if receipt_path.is_file():
        try:
            current = json.loads(receipt_path.read_text())
        except (json.JSONDecodeError, OSError) as exc:
            die(f"{receipt_path} unreadable: {exc}")
    if current != receipt:
        if check_only:
            die(f"{receipt_path} missing or does not match this adapter version / "
                "expected receipt; re-run without --check to refresh it after "
                "payload validation, or re-create the destination")
        write_receipt(dst, receipt)
        print(f"refreshed {receipt_path} (payload fully validated)")
        return
    verb = "check OK" if check_only else "no-op"
    print(f"{verb}: {dst} strictly validated (mode {mode}, config {OUTPUT_CONFIG_SHA[:12]}..)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("src", help="source checkpoint directory (pinned revision)")
    ap.add_argument("dst", help="destination checkpoint directory")
    ap.add_argument("--metadata-only", action="store_true",
                    help="use only config.json + index; write transformed config+receipt, no weights")
    ap.add_argument("--check", action="store_true",
                    help="strictly validate an existing DST only; never write")
    args = ap.parse_args()
    src, dst = Path(args.src), Path(args.dst)
    # resolve() is non-strict, so a nonexistent DST resolves too; nesting is
    # rejected before creation or revalidation touches the filesystem.
    src_r, dst_r = src.resolve(), dst.resolve()
    if src_r == dst_r:
        die("src and dst must differ")
    if src_r.is_relative_to(dst_r):
        die(f"src {src_r} lies inside dst {dst_r}: nested roots are rejected")
    if dst_r.is_relative_to(src_r):
        die(f"dst {dst_r} lies inside src {src_r}: nested roots are rejected")
    if args.check:
        revalidate(src, dst, args.metadata_only, check_only=True)
        return
    if dst.exists():
        revalidate(src, dst, args.metadata_only, check_only=False)
    else:
        create(src, dst, args.metadata_only)


if __name__ == "__main__":
    main()
