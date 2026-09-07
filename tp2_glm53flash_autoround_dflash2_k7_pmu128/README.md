# GLM-5.3-Flash AutoRound→GPTQ external DFlash2 k7 + PMU128 TP2

Lean reproduction recipe for the externally drafted DFlash2 k7 + PMU128
profile on the two-node GB10 cluster. The canonical repository configuration
pins the official DFlash2 revision and maximum sequence count documented
below. It starts from the digest-pinned public image, applies the complete
ordered local delta, and produces the exact installed runtime-file hashes.
Runtime patches are baked into the new image; the launcher mounts only the
target model, drafter model, and cache.

This repository work made no live mutations: it did not restart, stop,
replace, or otherwise change the live containers or either node. Read-only
inventory evidence informed the recipe. It does not promote the experimental
deployment. The sibling `tp2_glm53flash_autoround_mtp3_pmu128` recipe is
separate and is not replaced or modified.

## Exact pins

| Item | Pin |
|---|---|
| Target | `Intel/GLM-5.3-Flash-W4A16-AutoRound@5eee1846f0321058ed73745f9aa16f2aaf0fc0a0` |
| Target source metadata | config `d4deaf40c47b2ff49f1d8e0c306032d7a8b84f90b6a2743e694b712d87dd5692`; index `a250db4fcc9443d0164335a7a2c7a1da4eef91e212304e2e695a08d565a75102` |
| Adapted target config | `958beaf7c4ddf9ba1d8dcb5e938fcddc0deaa62d41e0f85909a45a12ae8c97a6` |
| External drafter | `incoai/GLM-5.3-Flash-DFlash2@bf582e4eacc1810f76656d1811693ff6c6737d2a` |
| Drafter bytes | config `c4aeac0101196a6e26705b34c45230bcd0c7c68ee2d2d1efdb242087f3712573`; `model.safetensors` LFS SHA-256 `b038e1d9d1e7833fa3880c2c0135ba9b673013f03da1b29fb831931584759dac`, size 2,342,169,800 bytes |
| Base image | `ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6` |
| Base identity | local ID `sha256:35c6f70f…`; vLLM `0.1.dev20051+g487ecf187`, commit `487ecf187d3dfe74d2cf6119a92881dba403c219` |
| Recipe image | `spark-recipes/glm53-autoround-dflash2-k7-pmu128:20260904` |
| Topology | TP2/mp; rank 0 API fabric `10.0.7.1`; rank 1 headless fabric `10.0.7.2`; rendezvous `10.0.7.1:29531` |
| API | rank 0 management `192.168.1.151`, unauthenticated bind `0.0.0.0:8888`; rank 1 management `192.168.1.152` |
| Speculation | external `dflash`, `/models/dflash2`, k7, `FLASH_ATTN`, drafter KV `auto`, `disable_eagle_block_drop=true` |
| Cache/profile | PMU128, retention 0, 13,500,000,000 B/rank, FP8 e4m3, block 2,304 / scheduler LCM 4,608, pool **1,814,557 tokens** |

The live rank-local derived image IDs are different—rank 0
`sha256:e994e9abbe716284aa5ac334be120d784bea85c8d0378601ea1be1a6aa36c166`
and rank 1
`sha256:d36866dcc3b6e13d6ff32c4dee661f74106b64fe4a4a10ef4231b69725740d46`—
because the images were built independently. They are evidence, not the
portable pin. The portable contract is the public base digest plus the exact
final hashes below.

The remaining runtime geometry is GMU 0.85; maximum model length 1,048,576;
maximum sequences 6; maximum batched tokens 8,192; Marlin MoE; image limit 4,
video limit 0; host network and IPC; 32 GiB shared memory; unlimited memlock;
and manual Docker restart policy (`--restart no`). `launch.sh` preserves the
observed RoCE/NCCL environment exactly: HCA `rocep1s0f0`, GID 3, RoCE v2,
address range `10.0.7.0/30`, and interface `enp1s0f0np0` for NCCL, Gloo, TP,
and multinode traffic.

## Runtime-byte reconstruction

The base already contains DFlash2 and GLM drafter support from the public
[`docker/dflash2-overlay`](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-DFlash2-2x-DGX-Spark/tree/050081dc41ce6edd4d3f15fa19dc3410ba4210e3/docker/dflash2-overlay)
at commit `050081dc41ce6edd4d3f15fa19dc3410ba4210e3`; rebuilding that inherited
overlay is unnecessary. The installer still gates its exact installed
DFlash2 files, registry, block pool, and KV manager. Full validation fetches
the three directly copied public source files at that commit and proves their
hashes equal the inherited image bytes.

`apply_runtime_patches.py` applies this stack in order with exact before and
after SHA-256 gates and no fuzzy matching:

| Order | Artifact and provenance | Exact result |
|---:|---|---|
| 1 | `0001-vllm-53388-native-mtp-block-drop.patch`, derived #53388 changes; vLLM commit `481839ad9e5ebf87aecb54fa5c9d986bd5ea4b81` | config `eaf52a03…→7a1a9381…`; utilities `624ea7b0…→cb7daec1…`; manager `41043976…→f2b6c9c8…`; scheduler `4c38a32c…→5b26e894…` |
| 2 | `0002-vllm-53906-coordinator-partial-hits.patch`; reviewed refs `8f8cc414d1c7648aad8808ba94e7c7fb1b6a72c2` / `4500c80c080328dfe62435d083f4063e00d987df` | coordinator `f640b5c4…→2401f79b…` |
| 3 | `0003-vllm-scheduler-lcm-mamba-block-align.patch` | scheduler `5b26e894…→acf44a9dbc1fba5347d7dec57deb928cd101653fe7ef0816b7bdd723e29f0478` |
| 4 | exact `dflash2-pmu128-swa-fine-hits.patch`, SHA-256 `302ca0cbd7d889df928d1eca7986cc50230855b5660ae72bcc8a696690bc144c` | manager `f2b6c9c8…→825ea2ad16b4db417606c9be2ca1b44af44402659b9285dfe0b2aa0a821a3561`; coordinator `2401f79b…→cf75ab28813ceb95d083aa6bec1d13a810dedb087f482f433dd9ace31b94cdc2` |
| overlay | complete `sparse_attn_indexer_kpool_sm121.py` | kpool `ab5972fd…→8a3ecfb0bab2441dd7417ed00a10d142191496149f88e5fe79fcfaea4b160980` |

The other changed-file final hashes are config
`7a1a93810f3232c4ff9b40e69e8c95d80d566eb2eca07523c027153ac9b39134`
and KV utilities
`cb7daec1354727696da42d4a7c42f770eb260304195d690ebd7a22427201062e`;
`patches/final-runtime.SHA256SUMS` records the complete 12-file final state.

The exact two-file patch was narrowly inspired by draft PR #54397 at
`69db265f558f29e287a858ce728aed1181f6425c`; this recipe installs only the
bundled patch and does **not** claim the full PR. Its final hunk carries stale
line-count metadata accepted by `git apply`; the raw artifact stays byte-exact
and digest-pinned while the pure-Python installer deterministically recounts
that header in memory before exact-block application. Final file hashes are
the authority.

The installer derives every changed output and verifies all unchanged inputs
and Python syntax before its first write, then stages temporary siblings and
uses atomic per-file replacement. A final tree is an idempotent no-op; a mixed
or tampered tree fails. This prevents writes after a rejected preflight, but it
is not a multi-file transaction across a process crash; Docker layer rollback
covers an interrupted build.

`patches/base-fixture.tar.xz` contains only the 12 byte-exact files needed for
offline replay and the CPU harness. The two adjacent manifests bind its base
and final states. No full inherited DFlash tree, image layer, model weight,
cache, log, or local experiment path is bundled.

There is deliberately **no** scheduler correction for the aligned-producer
boundary limitation described below.

## Deterministic target adaptation

`adapt_autoround_to_gptq.py` is byte-identical to the established native
recipe adapter. It transforms only `config.json`; all other regular files are
preserved byte-for-byte (hardlink, with staged copy fallback), and unsafe
symlinks/non-regular files are rejected. It verifies the pinned config and
index, 679 exclusion rules, 34 shards, 113,074 weight-map entries, and 37,152
quantized modules before producing GPTQ metadata with 4-bit, group size 128,
symmetric, `desc_act=false`, `lm_head=false`, and `true_sequential=true`.
Creation and revalidation are fail closed and idempotent; `--check` never
mutates. `--metadata-only` exists only for validation and does not create a
loadable checkpoint.

## Build, prepare models, and verify

Run the repository-only gate first:

```bash
cd tp2_glm53flash_autoround_dflash2_k7_pmu128
./validate.sh --no-network
docker build -t spark-recipes/glm53-autoround-dflash2-k7-pmu128:20260904 .
./validate.sh --image spark-recipes/glm53-autoround-dflash2-k7-pmu128:20260904
```

The last command is the complete gate: it needs network access for immutable
public metadata/provenance and Docker for ancestry and in-image hashes. It
does not download the 2.3 GB drafter weight; an immutable-revision Hugging
Face resolve HEAD binds `X-Repo-Commit`, `X-Linked-ETag`, and `X-Linked-Size`.

Prepare the exact model revisions on each rank:

```bash
huggingface-cli download Intel/GLM-5.3-Flash-W4A16-AutoRound \
  --revision 5eee1846f0321058ed73745f9aa16f2aaf0fc0a0 \
  --local-dir /home/ubuntu/models/Intel-GLM-5.3-Flash-W4A16-AutoRound-5eee1846
python3 adapt_autoround_to_gptq.py \
  /home/ubuntu/models/Intel-GLM-5.3-Flash-W4A16-AutoRound-5eee1846 \
  /home/ubuntu/models/Intel-GLM-5.3-Flash-W4A16-AutoRound-5eee1846-gptq
huggingface-cli download incoai/GLM-5.3-Flash-DFlash2 \
  --revision bf582e4eacc1810f76656d1811693ff6c6737d2a \
  --local-dir /home/ubuntu/models/GLM-5.3-Flash-DFlash2-bf582e4e
```

Build or load the same tagged recipe image on both ranks. Re-run
`./validate.sh --image ...` on each independently before any coordinated
transition.

## Manual operations

The checked-in `launch.sh` intentionally remains mode 0644. This makes an
accidental direct execution fail; an operator must deliberately invoke it
through Bash. It validates target/drafter metadata before Docker and has a
unique container name. During an authorized transition, start the worker
first and head second, and never run mixed profile ranks:

```bash
# rank 1 / 192.168.1.152 first
bash ./launch.sh 1
# rank 0 / 192.168.1.151 second
bash ./launch.sh 0
```

Readiness, discovery, a minimal API request, status, and logs:

```bash
curl -fsS http://192.168.1.151:8888/health
curl -fsS http://192.168.1.151:8888/v1/models
curl -fsS http://192.168.1.151:8888/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Intel/GLM-5.3-Flash-W4A16-AutoRound","messages":[{"role":"user","content":"Reply OK"}],"max_tokens":8}'
docker inspect -f '{{.State.Status}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}' spark_glm53_autoround_dflash2_k7_pmu128
docker logs --tail 200 -f spark_glm53_autoround_dflash2_k7_pmu128
```

For a coordinated stop or restart, stop the API/head first and worker second;
then restart the whole pair worker first and head second:

```bash
# head / 192.168.1.151
docker stop spark_glm53_autoround_dflash2_k7_pmu128
# worker / 192.168.1.152
docker stop spark_glm53_autoround_dflash2_k7_pmu128
# recreate: bash ./launch.sh 1 on worker, then bash ./launch.sh 0 on head
```

This remains an experimental, manually launched service. It is exposed
without authentication on `0.0.0.0:8888` and has no systemd unit, automatic
restart, proxy, TLS, traffic recovery, or failover. Operators must supply
those controls outside this recipe before any broader exposure.

## Evidence and accepted caveat

The measurements in this section were collected on 2026-09-04 with the
predecessor drafter revision and maxseq8 profile preserved in the rollback
note below. They are historical runtime-patch evidence, not validation of the
new drafter weights or maxseq6 capacity.

### PMU128 behavior

The ordinary live warm-replay rows were:

| Case | Prompt tokens | Local cache hit | Local compute |
|---|---:|---:|---:|
| primary | 32,385 | 32,384 | 1 |
| aligned | 32,257 | 32,256 | 1 |
| residue 1 | 32,258 | 32,256 | 2 |
| residue 127 | 32,384 | 32,256 | 128 |

For ordinary uniformly distributed residues, the operational estimate was
approximately 82 recomputed tokens.

Accepted carve-out: a divergent producer whose prompt length is exactly
4,608-aligned does not materialize the replay-cap Mamba checkpoint. At
`N=36,864`, the mathematically desired result is 36,736 hit / 128 compute,
but live behavior was **0 hit / 36,864 compute**. This is a latency/cache-use
failure, not a claim of correct boundary handling. The focused regression
executes the final scheduler split plus full-attention, kpool opt-out, Mamba,
SWA, retention-zero, and hybrid fixed-point path and deliberately asserts
that bad current result. It also proves the adjacent ordinary `N=36,865`
case still gives 36,864/1. No proposed scheduler fix is installed.

### N8 retention, not C8

Retention was 8/8: eight distinct 200,000-token prefixes were retained and
each isolated recall returned exactly 199,936 cached / 64 compute; aggregate
1,599,488 / 512.
Extending the oldest by 4,608 returned 199,936 cached / 4,672 compute; its
immediate repeat returned 204,544 cached / 64 compute. However, server peak
admission was only 2 running with 7 waiting, so the N8 gate failed and this is
**not** true C8 proof. There was also no final post-extension sweep of all
eight original prefixes.

### PP/TG (llama-benchy 0.4.0, PP2048/TG128)

| Depth/concurrency | Phase | PP tok/s | TG tok/s |
|---|---|---:|---:|
| d0 C1 | standard | 1,678.91 | 33.09 |
| d0 C4 | standard | 1,653.54 | 54.69 |
| d32K C1 | cold | 1,622.67 | 30.68 |
| d32K C1 | warm | 1,097.19 | 24.01 |
| d32K C4 | cold | 1,560.00 | 7.86 |
| d32K C4 | warm | 1,198.13 | 36.00 |

Every C4 phase was true server `running=4`. Warm cached tokens were exactly
129,024 for C1 and 516,096 for C4. DFlash accepted 5,566 / 16,401 drafted
tokens (33.94%). A few client SSE streams exposed only 127 token IDs, while
server counters confirmed exact TG128.

### Hard tool evaluation

The authoritative complete retry used the exact prior 88-case configuration
(temperature 1, top-p 0.95, seed 42, max turns 8, timeout 600 seconds,
parallel 4, fingerprint `46f0a5cc8e76`): 90/100, 158/176 points, with 75
pass, 8 partial, and 5 fail. True-C4 sampling
showed 8,071 / 10,529 samples at four running requests. DFlash accepted
43,415 / 116,666 drafted tokens (37.21%). The safety gate failed on TC-33 and
TC-43. An earlier partial attempt was invalidated by a local sandbox restart;
only the complete retry is authoritative.

### Runtime warnings and health

Startup produced **145 rank-1 NVRM `NV_ERR_NO_MEMORY` lines**. A later PMU
window produced another **7 on rank 0 and 5 on rank 1**. They did not kill or
restart the observed containers, but they are material failures of the strict
safety gates and must not be minimized. The later N8, PP/TG, and complete tool
evaluation windows were clean. Across those later windows there was no crash,
restart, `OOMKilled`, Xid, CUDA/NCCL functional failure, preemption, or
external-KV failure; both containers remained running with restart count 0.

## Rollback boundary

For a configuration-only rollback, restore external drafter revision
`7d74cdd881ed7e32c31175984a67823127b66cfe`, host directory
`/home/ubuntu/models/GLM-5.3-Flash-DFlash2-7d74cdd8`, and
`model.safetensors` LFS SHA-256
`8931dc522be0aa31760a7463f8d2f8044fa3e6d40be2e87aa08e9fd17bfd6683`,
then restore the maxseq8 profile (`--max-num-seqs 8`, MNBT 8192). Its config
SHA-256 remains
`c4aeac0101196a6e26705b34c45230bcd0c7c68ee2d2d1efdb242087f3712573`
and its weight size is 2,342,169,800 bytes; all other launch parameters stay
unchanged.

The rollback reference is the separate native recipe
`../tp2_glm53flash_autoround_mtp3_pmu128/` and the on-node canonical native
launcher `/home/ubuntu/launch-intel-autoround-exp.sh`. The frozen inventory
found that the only separate DFlash2 PMU128 launcher is under the staged
experimental path
`/home/ubuntu/intel-glm53-debug-20260904/dflash2-pmu128-candidate-20260904T135308Z/launcher/`;
no separate canonical or durable DFlash2 launcher exists outside staging. The
canonical launcher remains native MTP3 and was untouched. Rollback execution
is coordinated and manual—stop both external-DFlash ranks, verify the native
artifacts, then start native worker first and head second. No rollback was
performed by this repository work.

## Validation contract and layout

```text
Dockerfile                         digest-pinned base; bake/verify exact stack
apply_runtime_patches.py           pure-Python preflight + idempotent installer
adapt_autoround_to_gptq.py         deterministic metadata-only transformation
launch.sh                          exact two-rank profile, deliberately mode 0644
patches/                           four diffs, kpool overlay, base/final fixture pins
tests/run.sh                       self-contained Python 3.12 CPU regression runner
tests/fixtures/                    small pinned source/config fixtures only
validate.sh                        offline, remote provenance, base/image gates
SHA256SUMS                         every artifact except this file itself
```

`./validate.sh --no-network` verifies checksum closure, syntax, secret/local
path scans, exact launcher and Dockerfile invariants, deterministic full-stack
replay, final-tree tamper rejection, idempotence, all-input preflight
atomicity, and all 15 CPU regressions (the original 14 focused cases plus the
full-hybrid accepted-limitation case). It is self-consistency only and is
always labeled `OFFLINE UNIT VALIDATION ONLY`, never complete.

Without the offline flag, validation also binds both Hugging Face revisions,
the target config/index and exact adapter output, the drafter config plus its
immutable resolve-HEAD commit/LFS metadata, and public overlay commit content.
A complete byte-level reconstruction run additionally requires one of:

```bash
./validate.sh --base-root /path/to/caller-supplied/dist-packages
./validate.sh --image spark-recipes/glm53-autoround-dflash2-k7-pmu128:20260904
```

Default network mode uses local Docker to bind/pull the digest-pinned base
when available. `--base-root` proves only that the caller-supplied tree's 12
files match the pinned before hashes and replay to the exact final hashes; it
copies them to a temporary tree, never mutates the supplied root, and makes no
independent claim about their source or digest ancestry. Such a run is labeled
COMPLETE specifically for byte-level reconstruction. True public-digest
source/ancestry binding requires either the default Docker digest check or the
`--image` check. The latter requires the built image's ordered
`RootFS.Layers` to extend the exact base prefix, checks the base-digest label,
and verifies every final/unchanged hash inside the container. Network drift or
missing metadata fails closed. If no base-tree binding is possible, the
otherwise successful network run exits 3 and says `PARTIAL`.
