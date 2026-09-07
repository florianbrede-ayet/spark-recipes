# GLM-5.3-Flash AutoRound→GPTQ native MTP3 + PMU128 on two DGX Sparks

Reproducible recipe for the current native-MTP3 PMU128 service on the
two-node GB10 cluster: the pinned `Intel/GLM-5.3-Flash-W4A16-AutoRound`
checkpoint adapted to vLLM-loadable GPTQ metadata, served by an image built
from the digest-pinned public base with the exact #53388/#53906/scheduler-LCM
patch series and the current full SM121 kpool overlay applied fail-closed at
build time. It is intentionally lean: it reproduces this one service, not a
general lifecycle framework.

All commands below are examples. Operators must audit them against their own
site before changing a live system.

## Deployment pins

| Item | Value |
|---|---|
| API | `http://192.168.1.151:8888/v1` |
| Served model | `Intel/GLM-5.3-Flash-W4A16-AutoRound` |
| Rank 0 / API head | `192.168.1.151`, fabric `10.0.7.1` |
| Rank 1 / headless worker | `192.168.1.152`, fabric `10.0.7.2` |
| Topology | two nodes, tensor-parallel 2, rendezvous `10.0.7.1:29531` |
| Model | `Intel/GLM-5.3-Flash-W4A16-AutoRound@5eee1846f0321058ed73745f9aa16f2aaf0fc0a0` (GPTQ metadata adaptation below) |
| Image tag (built locally) | `spark-recipes/glm53-autoround-mtp3-pmu128:20260903` |
| Base image (digest-pinned) | `ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6` (vLLM `0.1.dev20051+g487ecf187`) |
| Native MTP | `method=mtp`, `num_speculative_tokens=3`, `disable_eagle_block_drop=true` |
| Scheduler concurrency | `--max-num-seqs 6` |
| Retrieval/pool | `--prefix-match-unit 128` (PMU128), logical pool 1,920,956 tokens |
| Prompt cache usage (next start) | `--enable-prompt-tokens-details` exposes `usage.prompt_tokens_details.cached_tokens` |

The live node-local image IDs (`sha256:e994…`, `sha256:d368…`) differ per
node because they were built independently; they are **not** the pin. The
portable pin is the digest-pinned base plus the final in-container file
hashes enforced by the Docker build (see below). The live image was produced
by applying the exact `apply_53388.py` behavior to that base.

## Base image honesty note

The digest-pinned base already contains inherited DFlash2 modules plus
target-side aux-capture and drafter-group support. Those are **inert** when
running native `method=mtp`. This recipe does not copy, rebundle, or mount
any obsolete DFlash code, but it also does **not** claim a clean
DFlash-free rebuild: exact live reproduction uses the digest-pinned base and
therefore inherits that inert code.

## Image patch series

`apply_runtime_patches.py` is a pure-Python fail-closed installer: every step
gates on the exact before-SHA, applies an exact-match hunk replacement (no
fuzz), gates on the exact after-SHA, and syntax-checks every patched file.
Any mismatch aborts before writing.

| Step | Upstream provenance | Files | Before → After (SHA-256) |
|---|---|---|---|
| `patches/0001-vllm-53388-native-mtp-block-drop.patch` | vLLM PR #53388, merge `481839ad9e5ebf87aecb54fa5c9d986bd5ea4b81` | `vllm/config/speculative.py`, `vllm/v1/core/kv_cache_utils.py`, `vllm/v1/core/single_type_kv_cache_manager.py`, `vllm/v1/core/sched/scheduler.py` | `eaf52a03…→7a1a9381…`, `624ea7b0…→cb7daec1…`, `41043976…→f2b6c9c8…`, `4c38a32c…→5b26e894…` |
| `patches/0002-vllm-53906-coordinator-partial-hits.patch` (exact upstream diff) | vLLM #53906 production hunk, commit `36bb3795b258e1b773cee5c2b725d9b8346b0c8d` | `vllm/v1/core/kv_cache_coordinator.py` | `f640b5c4…→2401f79b…` |
| `patches/0003-vllm-scheduler-lcm-mamba-block-align.patch` | scheduler-LCM one-liner applied after #53388: `_mamba_block_aligned_split` uses `self.block_size` | `vllm/v1/core/sched/scheduler.py` | `5b26e894…→acf44a9dbc1fba5347d7dec57deb928cd101653fe7ef0816b7bdd723e29f0478` |
| `patches/sparse_attn_indexer_kpool_sm121.py` (complete overlay asset) | current full SM121 kpool overlay, first/public commit `a5c4b197b2bd57d7be734b0ea17183e36fea962b` in [tonyd2wild/GLM-5.3-Flash-NVFP4-DFlash2-2x-DGX-Spark](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-DFlash2-2x-DGX-Spark) (repo provenance commit `050081dc41ce6edd4d3f15fa19dc3410ba4210e3`) | `vllm/model_executor/layers/sparse_attn_indexer_kpool.py` | `ab5972fd…→8a3ecfb0bab2441dd7417ed00a10d142191496149f88e5fe79fcfaea4b160980` |

`patches/base-fixture.tar.xz` (≈91 KiB, ~500 KiB uncompressed) holds the
byte-exact before-state of exactly those six files so `validate.sh` can
replay the whole series offline and confirm every final hash without Docker
or the base image. `apply_runtime_patches.py` derives and validates every
output in memory (before/after SHA-256 and per-file syntax) before the first
write, chaining state across the two scheduler steps; installation stages
temp siblings and atomically replaces each target, so a rejected preflight
leaves the tree untouched. This gives no-content-mismatch writes, not
absolute multi-file atomicity — a crash between replaces is covered by the
Docker layer rollback.

## Model metadata adaptation

The published checkpoint's AutoRound quantization metadata is not directly
loadable; `adapt_autoround_to_gptq.py` rewrites **only** `config.json`
quantization metadata. Every other regular file of the source snapshot —
index, tokenizer/chat-template/generation/processor assets, the standalone
quantization copy, aux `*.safetensors`, and any unknown extra regular file,
since the source revision is byte-pinned — is preserved byte-identically
(hardlink with staged-copy fallback, preserving relative paths, including
nested paths from `huggingface-cli --local-dir` trees). Only explicitly
transient download artifacts are excluded: `*.part`, `.download.lock`, and
`.cache/huggingface/` metadata. Symlinks are materialized only when they
resolve inside the source tree; symlinks leaving it, symlinked directories,
and non-regular files are rejected. The adapter asserts the pinned source (config
`d4deaf40c47b2ff49f1d8e0c306032d7a8b84f90b6a2743e694b712d87dd5692`, index
`a250db4fcc9443d0164335a7a2c7a1da4eef91e212304e2e695a08d565a75102`), 679
exclusion rules, 34 shards, 113,074 weight-map entries, exactly 37,152 each
of `qweight`/`qzeros`/`scales`, and that no exclusion pattern matches a
quantized module; it then replaces the quantization config with GPTQ
`bits=4 group_size=128 sym=true desc_act=false lm_head=false
true_sequential=true` and `dynamic={"-:<pattern>": {}}`, producing output
config exactly
`958beaf7c4ddf9ba1d8dcb5e938fcddc0deaa62d41e0f85909a45a12ae8c97a6`.
The historical standalone `quantization_config.json`
(`289e8d2a51fae043b52e3303609d026f8bbb4c7ca6f0f4b261b84f020637d585`) is
documented from the preserved byte-exact copy of the model repo at the
pinned revision; the recipe itself pins the source `config.json` instead.
The script is idempotent and fail-closed: creation requires an absent
destination and stages everything before renaming into place; re-running
against an existing destination is strict revalidation and a true no-op
(exact tree coverage versus the pinned source, per-file content equality,
exact transformed config hash, and a receipt matching this adapter version).
Tampered or stale trees are rejected, never repaired.
The `GPTQ-SURGERY.json` receipt is informational: a normal rerun may refresh
a missing or stale receipt only after the full payload validation has
passed, while `--check` never mutates and fails on a missing or mismatching
receipt.
`--metadata-only` writes only the transformed config plus receipt (no
weights, not loadable) and reproduces the exact output hash for validation.

## Build

```bash
cd tp2_glm53flash_autoround_mtp3_pmu128
docker build -t spark-recipes/glm53-autoround-mtp3-pmu128:20260903 .
NODE=gx10-6c18            # repeat for both nodes: head 192.168.1.151 and worker 192.168.1.152
docker save spark-recipes/glm53-autoround-mtp3-pmu128:20260903 | ssh "$NODE" docker load
```

The build applies the patch series to the digest-pinned base and fails the
build on any hash mismatch. After loading on a node, re-verify the final
in-container hashes (portable pin check):

```bash
docker run --rm -v "$PWD:/recipe:ro" \
  --entrypoint python3 \
  spark-recipes/glm53-autoround-mtp3-pmu128:20260903 \
  /recipe/apply_runtime_patches.py \
  --root /usr/local/lib/python3.12/dist-packages --verify-only
```

## Deploy

```bash
huggingface-cli download Intel/GLM-5.3-Flash-W4A16-AutoRound \
  --revision 5eee1846f0321058ed73745f9aa16f2aaf0fc0a0 \
  --local-dir /home/ubuntu/models/Intel-GLM-5.3-Flash-W4A16-AutoRound-5eee1846
python3 adapt_autoround_to_gptq.py \
  /home/ubuntu/models/Intel-GLM-5.3-Flash-W4A16-AutoRound-5eee1846 \
  /home/ubuntu/models/Intel-GLM-5.3-Flash-W4A16-AutoRound-5eee1846-gptq
install -m 0555 launch.sh /usr/local/bin/launch-glm53-mtp3-pmu128.sh
launch-glm53-mtp3-pmu128.sh 1        # worker (192.168.1.152) first
launch-glm53-mtp3-pmu128.sh 0        # then head/API (192.168.1.151)
curl -s http://192.168.1.151:8888/v1/models | head -c 400
```

Paths, image, and ports are env-overridable (`IMAGE`, `NAME`, `MODEL_HOST`,
`MODEL`, `CACHE_HOST`, `HEAD`, `MPORT`, `PORT`). Docker restart policy is
manual (`--restart no`); there is no proxy/8890/auth/TLS anywhere in this
profile.

`--enable-prompt-tokens-details` exposes per-request prefix-cache reuse as
`usage.prompt_tokens_details.cached_tokens`. Streaming callers must also send
`stream_options.include_usage=true` to receive final usage. Changing this flag
does not affect an already-running container: activation requires a coordinated
two-rank restart, which causes API downtime and clears the live KV cache.

Status, logs, stop (stop the head first, then the worker):

```bash
docker ps --filter name=spark_glm53_autoround_mtp3_pmu128
docker logs -f spark_glm53_autoround_mtp3_pmu128
docker stop spark_glm53_autoround_mtp3_pmu128   # on the head (192.168.1.151)
docker stop spark_glm53_autoround_mtp3_pmu128   # then the worker (192.168.1.152)
```

## Runtime profile (next coordinated start)

GMU 0.85; PMU128 prefix matching with prefix caching and retention interval
0; KV 13,500,000,000 B/rank, FP8 e4m3; `max_num_seqs=6`;
`max_num_batched_tokens=8192`; `max_model_len=1048576`; block 2304 (resolved
scheduler block 4608, Mamba 2304); Marlin MoE; multimodal image 4 / video 0;
logical KV pool 1,920,956 tokens; native MTP k=3 with
`disable_eagle_block_drop=true`; prompt token details enabled.

## Validation evidence

- MTP3 PMU smoke: 32,384 cached / 1 computed.
- Exact 200K-context reuse: 199,936 cached / 64 computed.
- True C4 runs: 4/4.
- Natural C4 acceptance: 626/1194 = **52.43%**, mean 1.573 accepted tokens per
  draft, zero safety faults.
- MTP5 inherited evidence (N8 8/8 at 199,936/64) is **inherited** from the
  sibling MTP5 profile and is quoted only because MTP3 runs the same PMU
  machinery with a larger pool; MTP3-only measurements are the numbers above.
- Broad PP/TG sweeps and the 91/100 hard-tool-evaluation score are
  **MTP5-only** results and must not be presented as MTP3 evidence.
- Known limitation: the first novel arbitrary interior fork landing exactly
  on the PMU boundary may fall back to the prior 4608-token Mamba checkpoint
  (latency only); ordinary tail continuation stays on PMU128.

## Rollback provenance

Rollback launchers are intentionally not bundled. Their SHA-256 pins:

| Artifact | SHA-256 |
|---|---|
| MTP5 launcher | `cd82c90d90a0b0e2b90744236cbf1a769d8d85f889c79b442913153ba3a4bc39` |
| DFlash2 rollback launcher | `b9e4ebcbac320c8beca7cb5eaa13e08925caddd08c6b5f7c0ce9cec72ea6d2d0` |

## Recipe layout and validation

```
README.md                     this file (pins, sequence, evidence)
Dockerfile                    digest-pinned base + deterministic patch application
launch.sh                     rank-aware launcher (archival copy; installed 0555)
apply_runtime_patches.py      fail-closed patch installer (pure Python)
adapt_autoround_to_gptq.py    AutoRound→GPTQ metadata adapter (idempotent)
patches/                      unified diffs, kpool overlay asset, base fixture
validate.sh                   offline + network validation
SHA256SUMS                    checksums for every artifact except itself
```

```bash
cd tp2_glm53flash_autoround_mtp3_pmu128 && ./validate.sh   # full check, needs network
./validate.sh --no-network            # offline unit validation only
./validate.sh --base-root /path/to/dist-packages-of-pinned-base
./validate.sh --image spark-recipes/glm53-autoround-mtp3-pmu128:20260903
```

Always run: bash/Python syntax, checksums, secret and local-path scan,
launcher invariants, applier-preflight atomicity, and the full patch-series
replay against the base fixture with exact before/after hashes plus tamper
rejection. With network (default), it also downloads the pinned public
config + index and proves the GPTQ adapter reproduces the exact output
config hash, exercises full-mode tree preservation and strict revalidation
on synthetic sparse shards, and rejects nested SRC/DST roots; a download
failure fails the run. Completion is tracked by two independent gates: the
MODEL gate (public metadata + adapter tests) and the BASE gate. A run is
COMPLETE only when both ran — via `--base-root`, via Docker auto-binding, or
via `--image`. Default mode binds the base automatically when Docker is
present (it pulls the exact digest if absent and confirms the six pinned
before-hashes inside it); with `--base-root DIR` it verifies the same six
files in an extracted image root and replays the whole series there.
`--image TAG` binds by ancestry: the candidate's `RootFS.Layers` must extend
the exact ordered layer prefix of the digest-pinned base and add at least one
layer, and its `org.opencontainers.image.base.digest` label must equal the
pinned digest — a rootfs-prefix binding, not a cryptographic Dockerfile
proof — followed by the applier's `--verify-only` inside the image. Without
a base binding, a default run prints PARTIAL and exits nonzero: it must
never be read as a complete reproducibility pass. `--offline-unit` (alias
`--no-network`) skips the model gate, may exit 0, and is never COMPLETE —
even when `--base-root` passes. Unknown or conflicting flags (`--image`
with `--offline-unit`, or with `--base-root`) are rejected. The complete
reproduction gate is:

1. `docker build` from the digest-pinned base (the build itself fails on any
   base/patch mismatch), then
2. `./validate.sh --image <built tag>` (ancestry binding plus the applier's
   `--verify-only` inside the built image), or
   `./validate.sh --base-root <dist-packages>` extracted from that digest.

`--offline-unit` only proves offline self-consistency; its final message
says so and does not imply complete reproducibility.
