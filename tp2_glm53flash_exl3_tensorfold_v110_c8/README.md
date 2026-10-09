# GLM-5.3-Flash EXL3 · TensorFold recipe v1.10 · C8

The deployment serving our two-Spark cluster since 2026-10-09 22:35 UTC.

- It runs the [MiaAI-Lab TensorFold recipe](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold) v1.10 **as published**: its pinned image, no local patches.
- Our settings are in `env.example`.
- It supersedes [`../tp2_glm53flash_exl3_tensorfold_v18_spill_c8/`](../tp2_glm53flash_exl3_tensorfold_v18_spill_c8/). Upstream merged the disk spill tier we had ported there, as patch `0088`.

## Pins

| | |
|---|---|
| Recipe | MiaAI-Lab `main` @ `7d42f905388a8d7fa91e2dc9458e0a4a68001540` (v1.10 plus a README license note) |
| Image | `ghcr.io/miaai-lab/glm-5.3-flash-exl3-2x-dgx-sparks-tensorfold:v0.6.0-a1897d591f70` @ `sha256:bc34d7d63f978cf601f42863b284bc95a567c50c10e9adb0866a635be568bf5f`. TensorFold v0.6.0 + 96 patches, pulled by the recipe; local image ID `sha256:a24e8b6f…` |
| Model | `Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold` @ `078455ffe6472f9a52fbc1139f58b9db2881b25c` |
| Drafter | `incoai/GLM-5.3-Flash-DFlash2` @ `bf582e4eacc1810f76656d1811693ff6c6737d2a` (CC BY-NC-ND 4.0, non-commercial) |
| Hosts | 2× ASUS Ascent GX10 (DGX Spark), DGX OS 7.5.0, kernel 6.17.0-1029-nvidia, driver 580.173.02 |
| API | rank 0, `http://<head>:8888/v1`, model `GLM-5.3-Flash-EXL3` |

## Host prerequisites

- **Fabric**
  - The CX7 QSFP link, with both PCIe paths up. We use `10.0.7.1/30`↔`.2` and `10.0.7.5/30`↔`.6`, MTU 9000.
  - `start.sh` probes and uses both rails.
  - The head reaches the worker by passwordless `ssh` over the fabric address (`WORKER=`).
  - Docker on both nodes.
- **Display reservation** (`DISPLAY_KV_MIB=1792`)
  - Needs `nvidia_drm` with `modeset=1` (`options nvidia-drm modeset=1 fbdev=0` in `/etc/modprobe.d/`, then reboot).
  - No display may be attached; we run headless.
  - Without it, drop the setting; the pool loses 276,480 tokens.
- **Disk per node**
  - ~25 GB image, plus the ~176 GB checkpoint (copied to the worker by `start.sh`).
  - 150 GB for spill: the 100 GiB cap plus the 50 GiB free-space floor. Keep `SPILL_DIR` on the local NVMe.
- **Optional, runtime only**
  - `sudo nvidia-smi -lgc 200,2200`: clock cap, ~3–4 % slower prefill for 30–40 % less GPU power.
  - `sudo sysctl vm.swappiness=10`.

## Deploy (on the head)

```bash
git clone https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold.git ~/tensorfold-v110
cd ~/tensorfold-v110 && git checkout 7d42f905388a8d7fa91e2dc9458e0a4a68001540
cp <spark-recipes>/tp2_glm53flash_exl3_tensorfold_v110_c8/env.example .env   # set WORKER, SPILL_DIR, STATE_DIR
# on BOTH nodes, right before every (re)start: let memory settle (see "Pool size")
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches; sleep 10
./start.sh
```

The first `./start.sh`:

1. pulls the pinned image on both nodes;
2. downloads the checkpoint and DFlash2 on the head and copies them to the worker;
3. compiles the kernels once;
4. starts the worker, then the head, and runs a smoke test.

Check the start-up lines:

```bash
docker logs glm53-flash-tf 2>&1 | grep -E 'startup estimate|display reservation|spill:|in one pool of'
#   CUDA rank 0 startup estimate 86.88 GiB within ~98 GiB ...
#   1792 MiB of the pool in the GPU's display reservation ... +276480 tokens
#   spill: /spill/spill-<hash> (100 GiB a rank, early writes past 70% of memory, from 8192 tokens, ...)
#   --parallel 8: ... in one pool of ~1853440 tokens
```

Operations:

- `./start.sh restart`: SIGTERM, kept prompts flushed to disk, worker first, smoke test.
- `./stop.sh`.
- `/health`: streams, pool, kept prompts, `spill` counters. `/metrics` serves the same for Prometheus.
- There is no restart policy in the recipe. We run a separate crash-only watchdog, which is not part of this recipe.

## Profile (`env.example`)

| Setting | Value | Note |
|---|---|---|
| `PARALLEL` | 8 | concurrent requests |
| `DENSE` / `KV` | fp8 / fp8 | the recipe default `DENSE=q4` lost the end of turn on non-English prompts with thinking off (upstream #18) |
| `DRAFTER` | dflash2 | |
| `CONTEXT` / `MAX_TOKENS` | 262,144 / 32,768 | |
| `VISION`, `COMM`, `SPLIT` | 1, roce, 1 | |
| `TF_ROCE_WAIT_S` | 300 | tolerates a late peer (upstream #54) |
| `MEMORY_RESERVE_GIB` | 17.6 | host RAM left free |
| `KV_POOL_GIB` | 15 | cap; does not bind here |
| `DISPLAY_KV_MIB` | 1792 | +276,480 pool tokens |
| `SPILL_GIB` / `SPILL_MIN_TOKENS` / `SPILL_HIGHWATER` / `SPILL_MIN_FREE_GIB` / `SPILL_FLUSH_S` | 100 / 8192 / 0.70 / 50 / 60 | disk tier (patch 0088), per node |
| `STOP_TIMEOUT` | 90 | room for the flush |
| `TF_GLM_LOOP_GUARD` | 1 | closes a thinking block that collapsed into repetition (patch 0091). We had logged two 32,768-token runaways on v1.8 |
| `STREAM_SMOOTH`, `TF_GLM_MULTI_WATCHDOG_S` / `_EXIT` | 0, 60 / 0 | the watchdog only dumps stacks |

Left at the recipe defaults:

- `NUCLEUS_UNION=1`;
- `TF_GLM_CACHE_SHARE_PCT=0` (more kept prompts for less pool, #84);
- `TF_GLM_EFFORT_TAIL=0`.

### Pool size

The pool is what is free at start, minus the reserve and the engine estimate (86.88 GiB on rank 0), plus the display reservation.

- At 17.6 GiB reserve: **1,853,440 tokens**, with a start budget of 98.03 GiB.
- A start right after pulling the image got only **1,435,648 tokens** (budget 95.40 GiB). About 2.6 GiB was not yet free.
- So flush caches and wait a few seconds before every start.

## Results

- **v1.10 on this cluster:** checked with smoke tests and in production since 2026-10-09 22:35 UTC. The longer battery was skipped on purpose.
- **The full qualification** (exact disk restores of 12 × 200K conversations across a restart, llama-benchy, tool-eval 92/100) ran on v1.8 with the same settings and the same spill-tier code. See the v1.8 recipe.
- **Production on v1.8 for comparison:**
  - 92–98 % of prompt tokens from cache;
  - a 200K disk restore takes ~0.6 s to first token, vs ~127 s cold.

## Caveats

- **Prompt layout decides the cache hit.** A change early in a prompt (timestamps, per-run notes placed before the history) forces a full re-prefill of everything after it.
- **Kept prompts are capped at 32** unless `TF_GLM_CACHE_SHARE_PCT` is set. Live conversations can be pushed out; the disk tier brings back those it wrote (≥ 8,192 tokens).
- **Spill write volume.**
  - Each turn of a long conversation is written as a new full state, ~6.7 KB per token per node.
  - We saw 0.5–1 TB per day per node under agent traffic. Watch NVMe wear.
- **`draft: false` requests never restore from disk.** That's upstream's design.
- **The head's free RAM drifts down over days.** It went from ~12 to ~5.4 GiB in three days at 17.6. Plan a restart every few days, or watch it.
- **Very long outputs from short prompts happen.** We logged 16–33K-token replies. Give clients sensible `max_tokens`.

## Files

| File | |
|---|---|
| `env.example` | our `.env`; only `WORKER`, `SPILL_DIR` and `STATE_DIR` are placeholders. The deployed file's SHA-256 is `3cc98e80…` |
| `validate.sh` | offline check: checksums and secret scan; with `--upstream DIR`, also that DIR is an unmodified clone at the pin |
| `SHA256SUMS` | checksum of `env.example` |

## Credits and licenses

- **Recipe and image:** MiaAI-Lab (Apache-2.0).
- **TensorFold:** ashhart (Apache-2.0).
- **Spill tier:** @wojo (patch 0088).
- **Loop guard and the other v1.9/v1.10 patches:** their contributors, as credited upstream.
- **This directory:** bundles no upstream files.
- **Weights:** downloaded under their own terms. DFlash2 is CC BY-NC-ND 4.0 (non-commercial).
