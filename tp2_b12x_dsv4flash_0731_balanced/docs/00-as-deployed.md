# As deployed — exact live configuration

Everything on this page was read from read-only audit evidence of the two live
nodes. Where a value is an *output* of a particular boot rather than an *input*
you can set, it is labelled as such.

Audit evidence: `192.168.1.151` (primary / rank 0) and `192.168.1.152`
(worker / rank 1), captured 2026-08-23 with a runtime sample from 2026-08-26.

---

## 1. Pinned artifacts

| Artifact | Value |
|---|---|
| Model repo | `deepseek-ai/DeepSeek-V4-Flash-0731` |
| **Model revision** | **`7872f01b1d1fe23eabc4c98b48bffcef5a386062`** |
| **Image digest** | **`eugr/spark-vllm-b12x@sha256:eb3ed2bbb0c91dc6d41282d22532267b5a449088c78a032400cd887fe9ddd2c5`** |
| **Image ID** | **`sha256:d43f15877df4176dfc70b7ebca336d5de698e1696da02fc3738b0338a65f5db2`** |
| Local image tags | `vllm-node-b12x:latest`, `vllm-node-b12x:deployed` (container `ConfigImage`: `vllm-node-b12x`) |
| Image platform | `linux/arm64`, created `2026-08-05T03:15:53.425328648-07:00`, size `23362056860` bytes (~21.8 GiB) |
| **Live launcher SHA-256** | **`d587df37af3a37f50328e0e72030177a7e864fff41e4b2edea354c5c6e52dd1a`** |
| **Live recipe SHA-256** | **`2dcd8e9a9448ab51ea8ed6cebfb12961abdb1d278912ca4f0da4e4e8ad98379b`** |

The model revision is the commit that `refs/main` resolved to in the live
Hugging Face hub cache on both nodes.

The image ID is the authoritative cross-node check: both nodes ran the same
content-addressable ID. Only the primary carried the registry `RepoDigests`
entry — see [07-rank-differences.md](07-rank-differences.md).

The recipe YAML is vendored byte-exact at
[`recipe/deepseek-v4-flash-0731.yaml`](../recipe/deepseek-v4-flash-0731.yaml)
and hashes to the launcher-reported value above. The launcher itself is **not**
vendored; see [02-prerequisites-and-limitations.md](02-prerequisites-and-limitations.md).

For completeness, the live deployment bundle also reported these hashes for
files that are **not** vendored here (no copies were available in the audit):
`AS_DEPLOYED.json` `e4c4a0187f5c688601466b279dc04cfb6acca23b70fb6c981ddedeaa1a6fd04d`,
`README.md` `1881404e7951093700ecf70db4a0b62cd4ca2c925a218d5d7adb11a8130fa15a`,
`FILES.sha256` `592779520e94328f644820ec4f3f1ab99461271363d8754ce906dcfcbc9d152d`.

---

## 2. Host platform (as observed on both nodes)

| Item | Observed |
|---|---|
| OS | Ubuntu 24.04.4 LTS (noble) |
| Kernel | `6.17.0-1029-nvidia`, `aarch64` |
| GPU | NVIDIA GB10 (SM121, compute `12.1a`) |
| Driver | `580.173.02` |
| Docker | client `29.2.1`, server `29.2.1` |
| Operator account | unprivileged user in the `docker` group (also `sudo`) |
| systemd | no unit for this deployment: default target `multi-user.target`, the relevant units were `inactive` / `disabled` / `inactive` |

The last row matters: **the deployment is not supervised.** Nothing restarts it.

Image-baked runtime versions (from `docker inspect` on the live containers):
CUDA `13.0.2`, NCCL `2.28.3-1`, `TORCH_CUDA_ARCH_LIST=12.1a`,
`FLASHINFER_CUDA_ARCH_LIST=12.1a`, `NVARCH=sbsa`, `VLLM_BASE_DIR=/workspace/vllm`,
`MAX_JOBS`/`CMAKE_BUILD_PARALLEL_LEVEL`=16, `DG_JIT_USE_NVRTC=0`, `USE_CUDNN=1`.
`TIKTOKEN_ENCODINGS_BASE` is set by the image and was redacted in the evidence.

---

## 3. Container runtime configuration

Identical on both nodes except for the per-node IP variables.

| Setting | Value |
|---|---|
| Name | `vllm_node` |
| Network | `--network host` (`NetworkMode: host`, `NetworkSettings` empty) |
| Privilege | `--privileged` (`SecurityOpt: ["label=disable"]`, `CapAdd`/`CapDrop` null, `Devices: []`) |
| IPC | `--ipc=host` |
| GPUs | `--gpus all` (`Runtime: runc` — the NVIDIA devices arrive through the container toolkit, not the `nvidia` runtime) |
| Lifecycle | `-d --rm` — **the container is deleted when it stops** |
| Entrypoint | cleared (`--entrypoint=`); `Cmd` is `sleep infinity` |
| Working dir | `/workspace/vllm` |
| User | root (empty `User` field) |
| `nofile` ulimit | soft `1048576` / hard `1048576` |
| ShmSize | `67108864` (64 MiB — the Docker default; irrelevant because `--ipc=host` gives the container the host `/dev/shm`) |
| ReadonlyRootfs | `false` |

The container is started idle (`sleep infinity`) and the serving process is
injected afterwards with `docker exec`. That is why `docker stop` is a hard
kill of the whole rank, not a graceful vLLM shutdown.

### Bind mounts (5, host `$HOME`-relative)

```
$HOME/.cache/huggingface  ->  /root/.cache/huggingface
$HOME/.cache/vllm         ->  /root/.cache/vllm
$HOME/.cache/flashinfer   ->  /root/.cache/flashinfer
$HOME/.triton             ->  /root/.triton
$HOME/.tilelang           ->  /root/.tilelang
```

All five are read-write, `rprivate`. The order in which `docker inspect` lists
them differs between the two nodes; that is cosmetic.

### Container environment set by the launcher (`docker run -e`)

Per-node values in **bold**.

```
VLLM_HOST_IP=10.0.7.1                     (worker: 10.0.7.2)
RAY_NODE_IP_ADDRESS=10.0.7.1              (worker: 10.0.7.2)
RAY_OVERRIDE_NODE_IP_ADDRESS=10.0.7.1     (worker: 10.0.7.2)
MN_IF_NAME=enp1s0f0np0
UCX_NET_DEVICES=enp1s0f0np0
NCCL_SOCKET_IFNAME=enp1s0f0np0
GLOO_SOCKET_IFNAME=enp1s0f0np0
TP_SOCKET_IFNAME=enp1s0f0np0
OMPI_MCA_btl_tcp_if_include=enp1s0f0np0
NCCL_IB_HCA=rocep1s0f0
NCCL_IB_DISABLE=0
NCCL_IGNORE_CPU_AFFINITY=1
PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
RAY_memory_monitor_refresh_ms=0
RAY_num_prestart_python_workers=0
RAY_object_store_memory=1073741824
```

The `RAY_*` variables are set unconditionally by the launcher. **This
deployment does not use Ray** — it runs vLLM's native multi-node mode
(`--nnodes/--node-rank/--master-addr/--master-port`), and no `ray` process
appears in either rank's process table.

### Recipe environment — NOT passed with `docker run -e`

The recipe's `env:` block is exported *inside* the container launch script.
`docker inspect` on the live containers shows none of these in `Config.Env`,
while the serving process runs with all of them set:

```
CUTE_DSL_ARCH=sm_121a
VLLM_USE_AOT_COMPILE=1
VLLM_USE_BREAKABLE_CUDAGRAPH=0
VLLM_USE_MEGA_AOT_ARTIFACT=-1
VLLM_MEMORY_PROFILE_INCLUDE_ATTN=1
VLLM_USE_FLASHINFER_SAMPLER=1
VLLM_USE_B12X_WO_PROJECTION=1
VLLM_USE_B12X_MHC=1
VLLM_USE_B12X_FP8_GEMM=1
VLLM_USE_B12X_MOE=1
VLLM_USE_B12X_SPARSE_INDEXER=1
VLLM_USE_V2_MODEL_RUNNER=1
B12X_MLA_SM120_UNIFIED=1
B12X_MOE_FORCE_A8=1
VLLM_PREFIX_CACHE_RETENTION_INTERVAL=4096
VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0
```

[`templates/exec-script.sh.tmpl`](../templates/exec-script.sh.tmpl) reproduces
this exactly. `scripts/60-verify-deployment.sh` checks them by reading
`/proc/<pid>/environ` of the live serving process, not `docker inspect`.

---

## 4. Process tree

Observed on the primary (rank 0):

```
sleep infinity                                        (PID 1 of the container)
bash -c /workspace/exec-script.sh >> /proc/1/fd/1 2>&1
  /bin/bash /workspace/exec-script.sh
    /usr/bin/python3 /usr/local/bin/vllm serve ... --node-rank 0 ...
      python3 -c from multiprocessing.resource_tracker import main;main(...)
      VLLM::EngineCore
        VLLM::Worker_TP0
```

Worker (rank 1) is the same up to the launch script, then:

```
    /usr/bin/python3 /usr/local/bin/vllm serve ... --node-rank 1 ... --headless
      python3 -c from multiprocessing.resource_tracker import main;main(...)
      VLLM::Worker_TP1
```

Rank 1 has no `APIServer` and no `EngineCore`. The launch script does **not**
`exec` vLLM, so the `bash` parent stays in the tree; the template preserves
that so the process tree matches.

---

## 5. Exact serving invocation

Byte-exact copies live in
[`recipe/canonical-cli-rank0.txt`](../recipe/canonical-cli-rank0.txt) and
[`recipe/canonical-cli-rank1.txt`](../recipe/canonical-cli-rank1.txt), taken
from the live process table. `scripts/30-render.sh --rank N --check` renders the
template and asserts the argv is identical to those files — offline, with no
cluster required.

```
vllm serve deepseek-ai/DeepSeek-V4-Flash-0731 \
    --host 0.0.0.0 \
    --port 8888 \
    --trust-remote-code \
    --tensor-parallel-size 2 \
    --kv-cache-dtype fp8 \
    --block-size 256 \
    --max-model-len auto \
    --max-num-seqs 6 \
    --max-num-batched-tokens 4096 \
    --long-prefill-token-threshold 1024 \
    --gpu-memory-utilization 0.87 \
    --enable-prefix-caching \
    --enable-prompt-tokens-details \
    --tokenizer-mode deepseek_v4 \
    --tool-call-parser deepseek_v4 \
    --enable-auto-tool-choice \
    --reasoning-parser deepseek_v4 \
    --reasoning-config '{"reasoning_parser":"deepseek_v4","reasoning_start_str":"","reasoning_end_str":""}' \
    --default-chat-template-kwargs.thinking=true \
    --default-chat-template-kwargs.reasoning_effort=high \
    --override-generation-config '{"temperature":1.0,"top_p":0.95}' \
    --load-format instanttensor \
    --moe-backend b12x \
    --linear-backend b12x \
    --attention-backend B12X_MLA_SPARSE \
    --max-cudagraph-capture-size 64 \
    --compilation-config '{"cudagraph_mode":"FULL_AND_PIECEWISE","custom_ops":["all"]}' \
    --speculative-config '{"method":"dspark","num_speculative_tokens":5,"draft_sample_method":"probabilistic","attention_backend":"B12X_MLA_SPARSE"}' \
    --nnodes 2 --node-rank 0 --master-addr 10.0.7.1 --master-port 29501
```

Rank 1 is identical except `--node-rank 1` and a trailing `--headless`.

Notes on how the argv is assembled:

* The rank arguments are appended **after** `--speculative-config`, in the
  order `--nnodes --node-rank --master-addr --master-port [--headless]`. That
  is the order the vendor launcher used when it patched the per-node script.
* `--distributed-executor-backend` is deliberately absent. The launcher strips
  it in non-Ray mode.
* `--max-model-len auto` is an input; the **resolved** value on the audited
  boot was `1048576` — an output. See
  [04-capacity-and-health.md](04-capacity-and-health.md).

### Topology and endpoints

| Item | Value |
|---|---|
| Nodes | 2 (`--nnodes 2`) |
| Tensor parallel | 2 (one GPU per node) |
| Rendezvous | `10.0.7.1:29501` — **master port 29501**, on rail A |
| Rank 0 | primary, `192.168.1.151` / `10.0.7.1`, serves the API |
| Rank 1 | worker, `192.168.1.152` / `10.0.7.2`, `--headless`, no listener |
| API | `0.0.0.0:8888`, HTTP, **no auth, no TLS** |

**Primary-only API behaviour.** Only rank 0 binds `8888`. The audit shows the
worker with no listening sockets at all. Do not health-check the worker on
`8888`; do not put both nodes behind a load balancer for that port.

Unrelated to this recipe, the primary also had a listener on
`192.168.1.151:3000` (an operator dashboard). It is a separate host service and
is out of scope here.

---

## 6. Mods declared by the recipe

```yaml
mods:
  - mods/instanttensor-hybrid-draft-loader
  - mods/dsv4-reasoning-effort-fix
```

These are vendor-framework artifacts applied to the container at launch. They
are **not** present in the audit evidence and are **not** vendored here, and —
critically — the evidence records only that they were *applied*, never their
contents. No trustworthy digest exists for either, so `config/mods-pins.env`
carries `UNAVAILABLE` for both and **an exact launch fails closed**. A launch is
possible only as an explicitly marked NON-EXACT one. See
[`mods/README.md`](../mods/README.md).

The startup log confirms the first one was active:

```
Hybrid draft loading: using lazy safetensors for speculative draft weights while
preserving InstantTensor for the target model (INSTANTTENSOR_DRAFT_LOADER=auto).
```

See [`mods/README.md`](../mods/README.md) and
[02-prerequisites-and-limitations.md](02-prerequisites-and-limitations.md).
