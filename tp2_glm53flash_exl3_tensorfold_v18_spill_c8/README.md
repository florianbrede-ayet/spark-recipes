# GLM-5.3-Flash EXL3 · TensorFold recipe v1.8 + disk spill tier · C8

> **Superseded** by [`../tp2_glm53flash_exl3_tensorfold_v110_c8/`](../tp2_glm53flash_exl3_tensorfold_v110_c8/) on 2026-10-09: upstream merged this spill tier as patch `0088` (v1.9), so the current deployment uses the published v1.10 image without local patches.

The deployment serving our two-Spark cluster since 2026-10-06:

- the [MiaAI-Lab TensorFold recipe](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold) v1.8;
- plus our port of its open pull request [#78](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/pull/78), a disk spill tier for kept prompt states by @wojo.

Profile: eight concurrent requests, FP8 dense layers and FP8 KV, the GPU's display reservation added to the KV pool, and 100 GiB of NVMe spill per node.

This is a concise as-deployed profile:

- upstream is cloned at a pinned commit;
- `recipe-v1.8-spill.patch` turns it into exactly the tree we run;
- `env.example` is our `.env`.

## Pins

| | |
|---|---|
| Recipe base | MiaAI-Lab recipe `main` @ `33b50fde06fd7ea604cbc6a663880068ab1e2ee4` (v1.8, patches 0001–0083) |
| Our delta | `recipe-v1.8-spill.patch` = `git diff 33b50fde e154c8b3`: patch `0084-glm-spill-tier`, its `start.sh`/`stop.sh`/`scripts/config.sh` wiring, CPU checks, `docs/PORT.md` |
| Engine | TensorFold v0.6.0 ([ashhart/TensorFold](https://github.com/ashhart/TensorFold)) + patches 0001–0084, built locally |
| Base image | `nvcr.io/nvidia/pytorch@sha256:7531d90bcbe0e43e1f7363029c7e145ce90eebeb494a7b4695fdba0329d7c3c3` |
| Model | `Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold` @ `078455ffe6472f9a52fbc1139f58b9db2881b25c` |
| Drafter | `incoai/GLM-5.3-Flash-DFlash2` @ `bf582e4eacc1810f76656d1811693ff6c6737d2a` |
| Our image | `tensorfold-glm53:v18-spill-20261006`, ID `sha256:280e280d9507…` (a rebuild gets another ID; the patch set is what counts) |
| Hosts | 2× ASUS Ascent GX10 (DGX Spark), DGX OS 7.5.0, kernel 6.17.0-1029-nvidia, driver 580.173.02 |
| API | rank 0, `http://<head>:8888/v1`, model `GLM-5.3-Flash-EXL3` |

## Host prerequisites

- **Fabric**
  - The CX7 QSFP link, with both PCIe paths up. We use `10.0.7.1/30`↔`.2` and `10.0.7.5/30`↔`.6`, MTU 9000.
  - TensorFold's RoCE transport uses both HCAs (`rocep1s0f0`, `roceP2p1s0f0`).
  - The head reaches the worker by passwordless `ssh` over the fabric address (`WORKER=`).
  - Docker on both nodes.
- **Display reservation** (`DISPLAY_KV_MIB=1792`)
  - Needs `nvidia_drm` with `modeset=1`: put `options nvidia-drm modeset=1 fbdev=0` in `/etc/modprobe.d/`, then reboot.
  - No display may be attached. We run both nodes headless (`multi-user.target`).
  - Without it, drop `DISPLAY_KV_MIB`; the pool loses 276,480 tokens.
- **Disk per node**
  - ~25 GB image, plus the ~176 GB checkpoint (`start.sh` copies it to the worker).
  - 150 GB for spill: the 100 GiB cap plus a 50 GiB free-space floor.
  - `SPILL_DIR` must be on the local NVMe.
- **Optional, runtime only (lost on reboot)**
  - `sudo nvidia-smi -lgc 200,2200`: clock cap, ~3–4 % slower prefill for 30–40 % less GPU power.
  - `sudo sysctl vm.swappiness=10`.

## Deploy (on the head)

```bash
git clone https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold.git ~/tensorfold-v18-spill
cd ~/tensorfold-v18-spill
git checkout 33b50fde06fd7ea604cbc6a663880068ab1e2ee4
git apply <spark-recipes>/tp2_glm53flash_exl3_tensorfold_v18_spill_c8/recipe-v1.8-spill.patch
cp <spark-recipes>/tp2_glm53flash_exl3_tensorfold_v18_spill_c8/env.example .env
$EDITOR .env        # WORKER, SPILL_DIR, STATE_DIR
# on BOTH nodes, right before a (re)start: page cache can shrink the start-up memory budget, and with it the pool
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches
./start.sh
```

The first `./start.sh`:

1. builds the image locally (`PULL=0`; no published image carries patch 0084);
2. streams it to the worker (`docker save | ssh docker load`);
3. downloads the pinned checkpoint and DFlash2 on the head and copies them to the worker;
4. compiles the kernels once;
5. starts the worker, then the head, and runs a smoke test.

Later starts take 2–6 minutes.

Check the start-up lines:

```bash
docker logs glm53-flash-tf 2>&1 | grep -E 'display reservation|spill:|in one pool of'
#   1792 MiB of the pool in the GPU's display reservation ... +276480 tokens
#   spill: /spill/spill-<hash> (100 GiB a rank, early writes past 70% of memory, from 8192 tokens, ...)
#   --parallel 8: ... in one pool of ~1855488 tokens
curl -s http://<head>:8888/v1/models      # GLM-5.3-Flash-EXL3
```

Operations:

- `./start.sh restart`: SIGTERM, kept prompts flushed to disk within 60 s, worker first, smoke test.
- `./stop.sh`.
- `curl -s http://<head>:8888/health`: streams, pool, kept prompts, `spill` counters. `/metrics` serves the same for Prometheus.
- There is no restart policy or autostart. After a reboot or a crash, run `./start.sh`.

## Profile (`env.example`)

| Setting | Value | Note |
|---|---|---|
| `PARALLEL` | 8 | concurrent requests |
| `DENSE` / `KV` | fp8 / fp8 | the recipe default `DENSE=q4` lost the end of turn on non-English prompts with thinking off (upstream #18) |
| `DRAFTER` | dflash2 | |
| `CONTEXT` / `MAX_TOKENS` | 262,144 / 32,768 | |
| `VISION` | 1 | |
| `COMM` / `SPLIT` | roce / 1 | both HCAs |
| `TF_ROCE_WAIT_S` | 300 | tolerates a late peer (upstream #54) |
| `MEMORY_RESERVE_GIB` | 17.6 | host RAM left free; 16.6 gives a 1.87–1.98M pool but only ~7 GiB free on the head |
| `KV_POOL_GIB` | 15 | cap; does not bind here |
| `DISPLAY_KV_MIB` | 1792 | +276,480 pool tokens |
| `SPILL_GIB` / `SPILL_MIN_TOKENS` | 100 / 8192 | per node |
| `SPILL_HIGHWATER` / `SPILL_MIN_FREE_GIB` / `SPILL_FLUSH_S` / `STOP_TIMEOUT` | 0.70 / 50 / 60 / 90 | |
| `STREAM_SMOOTH`, `TF_GLM_MULTI_WATCHDOG_S` / `_EXIT` | 0, 60 / 0 | the watchdog only dumps stacks |
| `IMAGE`, `BASE_IMAGE`, `PULL` | local tag, pinned base, 0 | build locally |

The pool size depends on free memory at start-up:

- 1,855,488 tokens at reserve 17.6 GiB, the production setting;
- 1,871,872 and 1,982,464 tokens on two starts at 16.6 GiB.

## Results (2026-10-06/07)

| Check | Result |
|---|---|
| Continuation ladder | 12/12 |
| 12 distinct 200K conversations, resent after eviction | 12/12 replies identical to the originals (greedy, same mode). Disk restores: first token after 0.59–0.65 s; a cold 200K prompt takes ~127 s |
| The same after a clean restart | all 12 restored from disk, identical |
| One 200K restore while 3 streams decode | first token after 2.25 s; the three streams kept 24–26 tok/s |
| llama-benchy 0.4.0, GPU capped at 2.2 GHz | d0: C1 52.4 tok/s (TTFT 1.26 s), C8 47.8 tok/s aggregate. d32K follow-up turn at C1: TTFT 1.6 s (20.4 s cold) |
| tool-eval-bench hard, C8, seed 42 | 92/100. The official safety gate fails (TC-51, TC-92), as on every stack we tested |
| First day in production | 92–96 % of prompt tokens from cache, no restarts or errors, head ~6.7 GiB free when idle |

Qualification ran at reserve 16.6 GiB with the same image. Production runs at 17.6 GiB.

## Caveats

- **Prompt layout decides the cache hit.**
  - A change early in a prompt forces a full re-prefill of everything after it. Examples: timestamps, or per-run notes placed before the history.
  - Neither the pool nor the disk tier can help with that.
  - Keep volatile content at the end of the conversation.
- **Kept prompts are capped at 32** (`TF_GLM_CACHE_ENTRIES`, upstream #84).
  - Many parallel conversations push live ones out.
  - The spill tier brings them back if they were written (≥ 8,192 tokens).
- **Spill write volume.**
  - Each turn of a long conversation is written as a new full state: ~6.7 KB per token per node, so 200K tokens ≈ 1.3 GB.
  - Under heavy agent traffic we saw 0.5–1 TB per day per node; 100 GiB then holds ~2 h of history.
  - Watch NVMe wear (`sudo nvme smart-log /dev/nvme0`).
- **`draft: false` requests never restore from disk.** That's upstream's design.
- **The head (rank 0) bounds the pool.** Its free RAM drops 4–5 GiB in the first hours of real traffic, then levels off.
- **Patch 0084 ports an unmerged upstream PR onto v1.8.** The merge notes are in `docs/PORT.md` inside the patch. Prefer upstream once it lands.

## Files

| File | |
|---|---|
| `recipe-v1.8-spill.patch` | turns upstream `33b50fde` into our tree `e154c8b3` (checked: identical tree) |
| `env.example` | our `.env`; only `WORKER`, `SPILL_DIR` and `STATE_DIR` are placeholders. The deployed file's SHA-256 is `9e2e6fe8…` |
| `validate.sh` | offline check: checksums and secret scan; with `--upstream DIR` (a clean clone at `33b50fde`) also that the patch applies |
| `SHA256SUMS` | checksums of the two artifacts |

## Credits and licenses

- **Recipe and its patches:** MiaAI-Lab's work, Apache-2.0.
- **TensorFold:** ashhart's work, Apache-2.0.
- **Spill tier:** @wojo's work (MiaAI-Lab #78, ashhart/TensorFold#427).
- **The patch here:** it carries @wojo's spill tier, ported, plus our integration changes, under the same license. It also extends upstream's `NOTICE` and `CREDITS.md`.
- **Weights:** downloaded from Hugging Face under their own terms and not redistributed. DFlash2 is CC BY-NC-ND 4.0 (non-commercial).

See [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md).
