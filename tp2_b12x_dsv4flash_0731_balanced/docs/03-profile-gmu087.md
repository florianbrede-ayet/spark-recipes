# The GMU.87 balanced profile

This is the exact live profile. Every value below is what the audited
deployment ran, not a recommendation to tune from.

Per the final operator directive of 2026-08-23:

> GMU 0.87, batched 4096, maxseq 6, threshold 1024, retention 4096, DSpark k5,
> FP8 KV, `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0`.

---

## 1. The profile at a glance

| Knob | Value | Flag / variable |
|---|---|---|
| GPU memory utilization | **0.87** | `--gpu-memory-utilization 0.87` |
| Max sequences (concurrency) | **6** | `--max-num-seqs 6` |
| Max batched tokens | **4096** | `--max-num-batched-tokens 4096` |
| Long-prefill token threshold | **1024** | `--long-prefill-token-threshold 1024` |
| Prefix-cache retention interval | **4096** | `VLLM_PREFIX_CACHE_RETENTION_INTERVAL=4096` |
| Speculative depth (DSpark) | **k = 5** | `--speculative-config {"num_speculative_tokens":5,...}` |
| KV cache dtype | **FP8** | `--kv-cache-dtype fp8` |
| CUDA-graph memory estimation | **disabled (0)** | `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0` |
| CUDA-graph mode / cap | **FULL_AND_PIECEWISE, 64** | `--compilation-config`, `--max-cudagraph-capture-size 64` |
| Block size | 256 | `--block-size 256` |
| Tensor parallel | 2 | `--tensor-parallel-size 2` |
| Max model len | `auto` → resolved **1,048,576** | `--max-model-len auto` |

"Balanced" is the point of the profile: it trades peak single-stream latency
for aggregate throughput at modest concurrency, while keeping a 1M-token
context ceiling and zero preemptions.

---

## 2. What each knob is doing

### `--gpu-memory-utilization 0.87`

The audited rank-1 boot budgeted `105.82 GiB` of `121.63 GiB` at 0.87. After
`80.84 GiB` of weights, `2.11 GiB` peak activation, `5.72 GiB` non-torch and
`0.05 GiB` of CUDA-graph memory, `17.14 GiB` was left for KV. That rank is the
limiting one. Full arithmetic in
[04-capacity-and-health.md](04-capacity-and-health.md).

### `--max-num-seqs 6` and `--max-num-batched-tokens 4096`

Six concurrent sequences, at most 4096 tokens scheduled per step.

Note the interaction with speculative decoding — vLLM logs at startup:

```
max_num_scheduled_tokens is set to 4072 based on the speculative decoding
settings. ... Consider increasing max_num_batched_tokens to accommodate the
additional draft token slots, or decrease num_speculative_tokens or max_num_seqs.
```

`4072 = 4096 − 24`, i.e. the 6 sequences × 4 additional draft-token slots are
reserved out of the batch budget. This is expected for this profile. The
benchmark numbers were measured with it in effect.

### `--long-prefill-token-threshold 1024`

Prefills longer than 1024 tokens are chunked so a long prompt cannot monopolise
a scheduler step. This is what keeps decode latency for the other five slots
bounded while a 100K-token prompt is being ingested. Earlier experiments in
this series used 256 and 2048/4096; 1024 is the value that shipped.

### `VLLM_PREFIX_CACHE_RETENTION_INTERVAL=4096`

Retention interval for cached prefix blocks, paired with
`--enable-prefix-caching`. Long-lived shared prefixes survive long enough to be
reused across requests, which is what the warm-cache benchmark rows measure.

### DSpark k = 5

```json
{"method":"dspark","num_speculative_tokens":5,
 "draft_sample_method":"probabilistic","attention_backend":"B12X_MLA_SPARSE"}
```

Five draft tokens per step, probabilistic draft sampling, draft attention on
the same B12X sparse-MLA backend. Measured acceptance during the 2026-08-23
benchmark window: **+14,940 drafted / +5,538 accepted = 37.1 % token
acceptance**. Runtime samples show mean acceptance length swinging roughly
2.5–5.3 with the workload, and per-position acceptance decaying sharply with
depth (typically ~0.8 at position 1 down to ~0.1–0.3 at position 5) — which is
exactly why k is 5 and not larger.

### FP8 KV cache

`--kv-cache-dtype fp8`, and the model uses DeepSeek's MLA-specific FP8 layout:

```
Using fp8 data type to store kv cache. It reduces the GPU memory footprint and
boosts the performance. Meanwhile, it may cause accuracy drop without a proper
scaling factor
Using DeepSeek's fp8_ds_mla KV cache format.
```

Two consequences worth stating plainly:

* The KV pool token counts in
  [04-capacity-and-health.md](04-capacity-and-health.md) are FP8 MLA-compressed
  slots. They are **not** comparable to a dense FP16 model's KV token counts.
* FP8 KV is an accuracy trade. It was accepted for this profile.

### `--max-cudagraph-capture-size 64` with `FULL_AND_PIECEWISE`

```json
{"cudagraph_mode":"FULL_AND_PIECEWISE","custom_ops":["all"]}
```

`FULL_AND_PIECEWISE` captures full-graph replays for the shapes it can and
piecewise graphs for the rest. The cap of **64** bounds the largest captured
batch shape, which bounds capture time and captured-graph memory. Combined with
`VLLM_USE_BREAKABLE_CUDAGRAPH=0` and `VLLM_USE_AOT_COMPILE=1`, this is why cold
start is minutes rather than seconds.

### `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0` — the accounting caveat

**This flag does not disable CUDA-graph capture.** Graphs are still captured.
What it disables is the memory *profiler's estimate* of graph memory being
subtracted from the KV budget.

On the audited boot the estimate was far larger than reality:

| Rank | Estimated graph memory | Actual graph pool | Available KV |
|---|---|---|---|
| 0 | 0.17 GiB | 0.01 GiB | 19.27 GiB |
| 1 | 0.71 GiB (0.35 GiB retained in the reusable pool) | 0.05 GiB | **17.14 GiB** (limiting) |

So the flag **did not free any physical memory**. It stopped KV sizing from
reserving bytes that graphs were never going to use. Estimates and actuals vary
by boot and by rank.

vLLM warns about this at startup, and its suggested alternative is recorded
here for completeness:

```
CUDA graph memory profiling is disabled (VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0).
Without it, CUDA graph memory is not accounted for during KV cache allocation,
which may require lowering --gpu-memory-utilization to avoid OOM. Consider
re-enabling it (the default as of v0.21.0) and increasing
--gpu-memory-utilization from 0.8700 to 0.8759.
```

If you re-enable estimation, `0.8759` is the compensating GMU vLLM itself
suggested **for that boot**. It is not a general constant.

---

## 3. Tokenizer, parsers and prompt handling

| Flag | Value |
|---|---|
| `--tokenizer-mode` | `deepseek_v4` |
| `--tool-call-parser` | `deepseek_v4` (with `--enable-auto-tool-choice`) |
| `--reasoning-parser` | `deepseek_v4` |
| `--reasoning-config` | `{"reasoning_parser":"deepseek_v4","reasoning_start_str":"","reasoning_end_str":""}` |
| Default chat template | `thinking=true`, `reasoning_effort=high` |
| Generation overrides | `{"temperature":1.0,"top_p":0.95}` |
| Prefix caching | `--enable-prefix-caching` |
| Prompt token detail | `--enable-prompt-tokens-details` |

Notes:

* **Empty reasoning delimiters are intentional.** `reasoning_start_str` and
  `reasoning_end_str` are empty strings; the `deepseek_v4` reasoning parser
  handles the boundary itself. Do not "fix" them to `<think>`/`</think>`.
* **Thinking is on by default** and effort is `high`. Per-request chat-template
  kwargs override it. The behaviour of `reasoning_effort` depended on the
  `dsv4-reasoning-effort-fix` mod, which is not vendored — see
  [02-prerequisites-and-limitations.md](02-prerequisites-and-limitations.md).
* **`--enable-prompt-tokens-details`** is what makes the API report exact
  cached-vs-computed prompt token counts. Every cache-hit figure in
  [05-benchmarks-2026-08-23.md](05-benchmarks-2026-08-23.md) comes from it.
* **`temperature 1.0` / `top_p 0.95` are server-side defaults**, not caps. They
  are overrides applied to the generation config; requests can still specify
  their own.
* Prefix-cache blocks are 256 tokens (`--block-size 256`), which is why a
  50,000-token prefix cached as exactly `49,920` tokens: `195 × 256 = 49,920`,
  with the 80-token remainder not forming a complete block.

---

## 4. B12X backend selection

| Flag / variable | Value |
|---|---|
| `--attention-backend` | `B12X_MLA_SPARSE` |
| `--moe-backend` | `b12x` |
| `--linear-backend` | `b12x` |
| `--load-format` | `instanttensor` |
| `VLLM_USE_B12X_*` | `WO_PROJECTION`, `MHC`, `FP8_GEMM`, `MOE`, `SPARSE_INDEXER` — all `1` |
| `B12X_MLA_SM120_UNIFIED` | `1` |
| `B12X_MOE_FORCE_A8` | `1` |
| `VLLM_USE_V2_MODEL_RUNNER` | `1` |
| `VLLM_USE_FLASHINFER_SAMPLER` | `1` |
| `VLLM_USE_AOT_COMPILE` | `1` |
| `VLLM_USE_BREAKABLE_CUDAGRAPH` | `0` |
| `VLLM_USE_MEGA_AOT_ARTIFACT` | `-1` |
| `VLLM_MEMORY_PROFILE_INCLUDE_ATTN` | `1` |
| `CUTE_DSL_ARCH` | `sm_121a` |

These are tied to the pinned image. They are not portable knobs: the same flags
against a different vLLM build will at best be ignored and at worst fail to
start.
