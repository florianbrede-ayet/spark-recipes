# Capacity and health

Two numbers describe this deployment's capacity, they mean different things,
and confusing them is the most common way to misread it.

| Number | What it is |
|---|---|
| **1,048,576** | The API context ceiling — the maximum `max_model_len` for **one** request. |
| **2,356,056** | The limiting **KV pool**, in logical tokens, **shared by all concurrent requests**. |

Both are **outputs of the audited boot**, not settings you choose. `--max-model-len`
is `auto`; the pool size falls out of `--gpu-memory-utilization 0.87` minus what
weights, activations and non-torch allocations actually consumed.

---

## 1. The 1M ceiling

`--max-model-len auto` resolved to **1,048,576** tokens (1 Mi) on the audited
boot. The handover records it as "API maxlen 1,048,576" and the benchmark run
re-confirmed "API ceiling 1,048,576" and "the 1M ceiling healthy".

This is a per-request cap. One request may use up to 1,048,576 tokens of
context. It is *not* a promise that six such requests fit at once — see below.

Because it is derived from free memory at startup, **a different boot can
resolve to a different value.** `scripts/50-health.sh` compares the live
`max_model_len` against `1048576` and warns (does not fail) on a difference,
because a difference is a genuine signal that this boot has a different KV
budget, not a configuration error.

---

## 2. The limiting KV pool: 2,356,056 logical tokens

The two ranks do not get equal KV memory, and the **smaller one governs the
cluster**.

| Rank | Node | CUDA-graph estimate | Actual graph pool | **Available KV** |
|---|---|---|---|---|
| 0 | `192.168.1.151` / `10.0.7.1` | 0.17 GiB | 0.01 GiB | 19.27 GiB |
| 1 | `192.168.1.152` / `10.0.7.2` | 0.71 GiB (0.35 GiB retained in the reusable pool) | 0.05 GiB | **17.14 GiB** |

Rank 1 is the limiting rank. The resulting cluster-wide pool recorded in the
handover is **2,356,056 logical tokens**.

### Rank-1 memory arithmetic, as logged

```
Free memory on device (111.18/121.63 GiB) on startup.
Desired GPU memory utilization is (0.87, 105.82 GiB).
Actual usage is 80.84 GiB for weight, 2.11 GiB for peak activation,
5.72 GiB for non-torch memory, and 0.05 GiB for CUDAGraph memory.
Current kv cache memory in use is 17.14 GiB.
Cleared 0.25 GiB of cached CUDA allocator memory before KV cache allocation.
```

vLLM also offered two explicit alternatives for that boot:

* `--kv-cache-memory-bytes=18201753416` (16.95 GiB) — to fit inside the
  requested budget exactly;
* `--kv-cache-memory-bytes=23956655616` (22.31 GiB) — to fully utilise GPU
  memory.

Neither was used. The live profile stays on `--gpu-memory-utilization 0.87`.

### Units and caveats — read before quoting 2,356,056

* **It is a pool, not a per-request limit.** All concurrent requests
  (`--max-num-seqs 6`) draw from it, and `--enable-prefix-caching` means cached
  prefixes occupy it too, until retention expires.
* **A single request is still capped at 1,048,576 tokens.** The pool being
  larger than the ceiling does not mean two 1M-token requests fit; it means
  there is room for the ceiling plus concurrent traffic plus cached prefixes.
* **These are FP8 MLA-compressed KV slots**, not dense FP16 KV entries
  (`--kv-cache-dtype fp8`, `fp8_ds_mla` format, `--block-size 256`). Comparing
  this token count to another model's KV token count is meaningless.
* **Do not derive bytes-per-token** by dividing 17.14 GiB by 2,356,056. The
  evidence does not record the per-layer MLA layout or how it is sharded across
  TP2, so any such ratio would be invented.
* **Blocks are 256 tokens.** Allocation is block-granular, so a partially used
  block still consumes a whole block.
* **Speculative decoding consumes budget too.** `max_num_scheduled_tokens`
  drops to 4072 (from 4096) to reserve draft slots.
* **It is per-boot.** Graph estimates and actuals "vary by boot/rank", in the
  handover's words. Treat 2,356,056 as the audited figure, not a constant.

### Why the ranks differ

The CUDA-graph estimate differed between ranks (0.17 vs 0.71 GiB), and rank 1
also carries the DSpark draft model's capture. With
`VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0` the estimate is not subtracted
from the KV budget, but the underlying per-rank differences in weights,
activation peaks and non-torch memory remain. The consequence is structural:
**expect the ranks to be asymmetric, and expect the smaller to govern.**

---

## 3. Health checks

`scripts/50-health.sh` is read-only and safe against a live cluster. It does not
send an inference request unless you pass `--smoke`.

```bash
scripts/50-health.sh                 # read-only probe
scripts/50-health.sh --smoke         # + one 8-token completion (consumes capacity)
```

### On the primary (rank 0)

| Check | Expected |
|---|---|
| Container `vllm_node` | running, image `sha256:d43f…f5db2` |
| `NetworkMode` / `IpcMode` / `Privileged` | `host` / `host` / `true` |
| `nofile` ulimit | `1048576:1048576` |
| `vllm serve` process | present |
| `GET /health` | HTTP 200 |
| `GET /v1/models` | id `deepseek-ai/DeepSeek-V4-Flash-0731`, `max_model_len` 1048576 |
| API listener on 8888 | **present** |
| RDMA `rocep1s0f0` | `ACTIVE` |

### On the worker (rank 1)

| Check | Expected |
|---|---|
| Container `vllm_node` | running |
| `vllm serve … --headless` | present, `VLLM::Worker_TP1` only |
| API listener on 8888 | **absent — this is correct** |
| RDMA `rocep1s0f0` | `ACTIVE` |

A listener on 8888 on the worker is a *failure*, not a bonus: it means rank 1
is not headless and the cluster is misconfigured.

### Counters worth watching

From `GET /metrics`:

* `vllm:num_requests_running` / `vllm:num_requests_waiting` — the audited idle
  gate required both at 0 for 30.43 s before benchmarking.
* `vllm:num_preemptions_total` — **the audited profile ran at zero, cumulative,
  throughout.** Sustained preemption means the KV pool is oversubscribed for the
  offered load. `50-health.sh` warns if it is non-zero.
* `vllm:gpu_cache_usage_perc` — KV pool occupancy. Runtime samples show single
  digits for short generations and low double digits under long prefills.
* `vllm:gpu_prefix_cache_hit_rate` — runtime samples sat around 95.8–96.0 % on a
  workload with heavy prefix reuse. This is workload-dependent, not a target.
* Speculative-decoding counters — see the acceptance discussion in
  [03-profile-gmu087.md](03-profile-gmu087.md).

### Whole-cluster verification

`scripts/60-verify-deployment.sh` goes further than health: it proves the
running deployment *is this recipe* by comparing the live argv against
`recipe/canonical-cli-rank{0,1}.txt`, the container runtime configuration and
mounts against the pins, and the recipe environment against
`/proc/<pid>/environ`. Run it on each node, or `--peer` from the primary.

### What "healthy" meant in the audited validation

From the 2026-08-23 handover: exact non-thinking / reasoning / tool smokes
passed; cached-prefix `c1`/`c4`/`c6` passed all marker, no-BOS and
no-repetition checks; an exact 100,015-prompt-token test returned the required
literal; API, both ranks, both containers, both RoCE HCAs and the 1M ceiling all
healthy; **zero preemptions**; no Xid, no OOM kill, no fatal CUDA/NCCL/B12X/
EngineCore error, no rank loss, no output corruption. Generic
`_memdescAllocInternal` NVRM warnings occurred and were explicitly accepted by
operator directive rather than treated as a veto.
