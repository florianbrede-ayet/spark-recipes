# GLM-5.3-Flash NVFP4 on two DGX Sparks — site overlay (KV 13,876 MiB, batch 8192)

Reproduces one running service: the GLM-5.3-Flash NVFP4 deployment on our
two-node GB10 ("Spark") pair at tensor-parallel 2. It is an **overlay** — the
image, both node Compose files, the display-KV override and the chat template
come from the upstream project below, pinned by commit and content hash and
fetched by you. Original here: a profile delta, a four-line Compose override, an
env merger, a launcher, a validator and this file. Commands are examples; audit
them against your own site first.

## Credits

**[technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks](https://github.com/technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks)**
is the upstream deployment project: the image, the Compose files, the display-KV
override, the chat template, the R28 build recipes and the qualification behind
them are theirs, and this overlay would not exist without it. Also
**[local-inference-lab](https://huggingface.co/local-inference-lab)** for the
`GLM-5.3-Flash-NVFP4-Spark` checkpoint and the vLLM fork and **B12X**
kernels/collectives the image is built on; the
**[vLLM](https://github.com/vllm-project/vllm)** project and its contributors,
and the **NVIDIA** contributors behind GB10/SM121a enablement, FlashInfer, CUDA
and the container runtime;
**[coolbho3k](https://github.com/coolbho3k/DeepSeek-v4.1-Flash-2x-DGX-Spark)**
for the display-reserved KV allocator upstream adapted.

## License

The upstream repository has **no repository-wide (root) license and therefore no
blanket grant**. Selected files there do retain their own **scoped** licenses:
Apache-2.0 for its vLLM-derived sources (`licenses/vllm-Apache-2.0.txt`) and
AGPL-3.0-only for the display-reserved KV allocator
(`files/display-kv-r28/LICENSE.AGPL-3.0`), each covering those files only.
Because nothing grants redistribution of the repository as a whole, this recipe
contains **no copy of any upstream file** — not the Compose files,
`.env.example`, chat template, display-KV allocator, scripts or docs. You clone
upstream yourself and the launcher verifies its commit and file hashes; the
file-scoped terms stay attached to those files where upstream and the image
distribute them. The repository-root [Apache-2.0 license](../LICENSE) covers only
this directory; image, weights, checkout and runtime dependencies keep their own
terms — see [third-party notices](../THIRD_PARTY_NOTICES.md).

## Pins

| Item | Value |
|---|---|
| Upstream source | `technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks` @ `74b42ffd9ef58ee80781db98c17aecfbdfccd6d5` |
| Image (digest, not tag) | `technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks@sha256:1169f797539454e3c286557d49fddd488488957d9a3f10638b01052998370622` |
| Model | `local-inference-lab/GLM-5.3-Flash-NVFP4-Spark` @ `a608241037e4c2565356bff7ca293f2133888f88` |
| Topology | 2 nodes, tensor-parallel 2; rank 0 serves the API, rank 1 headless |
| API | `http://<HEAD_FABRIC_IP>:8888/v1` — **unauthenticated, no TLS** |
| Rendezvous | `<HEAD_FABRIC_IP>:29553` over RoCE |
| Context / KV | `--max-model-len 1047552`; `13876M` (13,876 MiB) fp8 per rank |
| Scheduling | `--max-num-seqs 6`, `--max-num-batched-tokens 8192`, split pages 4096 |
| Speculation | MTP, 3 draft tokens, NVFP4 draft head, Marlin draft MoE |
| Display-reserved KV | on (upstream override): `/dev/dri/card0` + its group |
| Peer-wait mitigation | `B12X_ROCE_SPIN_LIMIT=200000000` (this recipe's override) |

`<...>` tokens are placeholders. No address, hostname, login or home directory
from our site appears in any published file; `validate.sh` enforces that.

## Quick start

```bash
# Run from this recipe directory on each node.
# 1. the pinned upstream source, on both nodes (keep it a git work tree)
git clone https://github.com/technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks.git ../up
git -C ../up checkout --detach 74b42ffd9ef58ee80781db98c17aecfbdfccd6d5

# 2. your eight site values
cp config/site.env.example config/site.env && $EDITOR config/site.env

# 3. dry run (default): verifies the pin, renders the stack, starts nothing
bash launch.sh --role worker --upstream ../up

# 4. worker (rank 1) first, then head (rank 0) on its own node
bash launch.sh --role worker --upstream ../up --apply
#   wait ~15 s for rank 1 to listen, then on the head node:
bash launch.sh --role head   --upstream ../up --apply
```

`--apply` needs an interactive terminal and a confirmation typed as exactly
`apply`. `--compose-bin` (or `$COMPOSE_BIN`) selects the Compose binary;
`docker compose` and `docker-compose` are autodetected.

Before it merges, renders or starts anything, the launcher runs
`sha256sum -c SHA256SUMS` over this directory and refuses to continue on a
mismatch. Independently, every merge re-checks `config/profile.env` and
`compose.phase1.override.yaml` against their `SHA256SUMS` entries inside
`tools/envmerge.py`, so a valid-looking edit to an image digest, model revision
or capacity value is refused even when the merger is called directly. Both are
drift guards against local edits, not authenticity proofs. If you deliberately
change a recipe file, regenerate `SHA256SUMS` first.

The stack is always these three files plus an explicit `--env-file`:

```
<upstream>/compose.{head,worker}.yaml
<upstream>/compose.display-kv.override.yaml
./compose.phase1.override.yaml
```

Two details: Compose takes its **project directory from the first `-f` file**,
which is how the upstream chat-template bind resolves inside your checkout from
any working directory; and Compose lets the **ambient environment override
`--env-file`**, so the launcher runs it under `env -i PATH=… HOME=…` (HOME kept
so the Docker CLI still finds its config and context). The launcher writes the
merged env only to a private temporary file; to keep one:

```bash
python3 tools/envmerge.py merge --upstream ../up --site config/site.env \
  --out config/merged.env          # git-ignored, mode 0600
python3 tools/envmerge.py delta --upstream ../up --site config/site.env
```

## Manual operations

`compose up -d` is the launcher's only mutating action, and it is not always
additive: it pulls the pinned image if absent, and if a `glm53` container already
exists with a different configuration Compose stops, removes and recreates it —
API downtime on rank 0, in-flight requests lost, model reloaded onto the GPUs. An
identical existing container is left running untouched. **Treat `--apply` as a
coordinated maintenance action**: agree a window, and shut the pair down (worker
and head) before relaunching a changed profile. The confirmation prompt restates
this before you commit to it.

There is no stop, restart, health loop, bootstrap or watchdog here. Those are
plain Compose commands you run deliberately with the same three `-f` files and
`--env-file`. Image and weights are manual too:

```bash
docker pull technigmaai/glm-5.3-flash-nvfp4-2x-dgx-sparks@sha256:1169f797539454e3c286557d49fddd488488957d9a3f10638b01052998370622
hf download local-inference-lab/GLM-5.3-Flash-NVFP4-Spark \
  --revision a608241037e4c2565356bff7ca293f2133888f88
```

The container runs with `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`
(inherited from the upstream Compose files), so **the pinned revision must
already be cached on both nodes**. Nothing here downloads weights — that is a
site-approved step; `compose up -d` does fetch the image if it is absent.

## Host prerequisites (operator decisions)

Nothing here changes a host: no installs, modules, initramfs rebuild, sysctls or
firewall rules. The nodes must already be:

* **Headless**, both.
* **Display-KV capable** — the upstream override reclaims the firmware-reserved
  scanout as KV backing, which needs the NVIDIA DRM parameters
  (`nvidia-drm modeset=1 fbdev=0`) in effect and `/dev/dri/card0` present.
  Putting those into an initramfs and rebooting is disruptive: schedule and
  approve it yourself after reading upstream's display-KV document. The group
  comes off the device — `stat -c '%g %G' /dev/dri/card0` → `DRM_CARD_GID`.
* **RDMA- and container-ready**: current NVIDIA driver, NVIDIA container
  runtime, `/dev/infiniband` access, Docker Compose v2+.
* **On one RoCE port per node.** The two GB10 RDMA ports are twins, each on its
  own `/30`, MTU 9000; this recipe uses exactly **one**, because the upstream
  entrypoint probes for a RoCEv2 IPv4 GID by walking every device in
  `NCCL_IB_HCA` and keeping the first match, so listing both can bind the wrong
  port. Confirm per node:

  ```bash
  ibv_devinfo -l                                   # RDMA device names
  ls /sys/class/infiniband/<dev>/device/net         # its netdev
  ip -4 addr show dev <netdev>                      # its IPv4 address
  grep -l 'RoCE v2' /sys/class/infiniband/<dev>/ports/1/gid_attrs/types/*
  ```

* On our hosts `vm.swappiness=10` is currently a **runtime-only** setting, not
  persisted across reboot. Persisting it is your change to make and own.

## Exposure

Rank 0 serves `--host 0.0.0.0 --port 8888` with no authentication, no TLS and no
API key. That is what is running; the recipe reproduces it rather than quietly
hardening it. Restrict it at your network boundary — **nothing here configures a
firewall.**

## Environment delta

Three layers: the pinned upstream `.env.example`, then `config/profile.env`, then
`config/site.env`. Any key not listed here comes from the upstream example
unchanged, and `tools/envmerge.py` fails if that is ever untrue. With our site's
values filled in, the live environment differs from the upstream example in
**19 entries: 18 changed values and one added key.**

### Profile constants — `config/profile.env` (13 keys)

| Key | Upstream example | Here | Why |
|---|---|---|---|
| `IMAGE` | `…:r28.8-a-pr58454-pr58785-pr58779-pr58594-pr58450-arm64-sm121-cu134` | `…@sha256:1169f797…370622` | Same R28.8-A image by digest; a tag can be moved to a rebuild. |
| `MODEL_PATH` | `local-inference-lab/GLM-5.3-Flash-NVFP4` | `local-inference-lab/GLM-5.3-Flash-NVFP4-Spark` | The Spark-specific checkpoint is what is loaded. |
| `MODEL_REVISION` | `175ae8ce3b5af842b0d0140dbeb43e9cfc557c49` | `a608241037e4c2565356bff7ca293f2133888f88` | Its revision, identical on both nodes. |
| `SERVED_MODEL_NAME` | a host alias plus `local-inference-lab/GLM-5.3-Flash-NVFP4` | `local-inference-lab/GLM-5.3-Flash-NVFP4-Spark` | One served id matching the checkpoint. The serve line expands it unquoted, so the merge rejects whitespace. |
| `PORT` | `8000` | `8888` | Site convention; rank 0 only. |
| `KV_CACHE_MEMORY_BYTES` | `11840M` | `13876M` | Live sizing: 13,876 **MiB** per rank. |
| `MAX_NUM_SEQS` | `4` | `6` | Six concurrent sequences. |
| `MAX_NUM_BATCHED_TOKENS` | `4096` | `8192` | Larger step budget, paired with the split size below. |
| `GLM53_SPLIT_TARGET_BLOCK_SIZE` | `1024` | `4096` | 4096-token split pages for mixed prefill/decode overlap — a scheduling choice, **not** a fix for the freeze below. |
| `B12X_ROCE_SPIN_LIMIT` | *(absent)* | `200000000` | Phase 1 peer-wait mitigation; not an upstream key, so it reaches the container only via `compose.phase1.override.yaml`. |
| `WORKER_DIR` | upstream helper path | *(blank)* | Upstream `start.sh` SSH helpers. **No Compose file reads them** and this launcher never uses SSH, so all three are blanked — which also keeps our paths, logins and hostnames out of the emitted file. |
| `WORKER_SSH_TARGET` | upstream helper `user@host` | *(blank)* | ↑ |
| `WORKER_ROCE_SSH_TARGET` | upstream helper `user@host` | *(blank)* | ↑ |

### Site values — `config/site.env` (8 keys)

Six differed from the upstream example at our site; `CONTROL_IF` and
`DRM_CARD_GID` coincided with it, which is why the live delta is 19 entries and
not 21. All eight are site-owned regardless.

| Key | Placeholder | Role |
|---|---|---|
| `HEAD_ROCE_IP` | `<HEAD_FABRIC_IP>` | rank 0 fabric address → `VLLM_HOST_IP` on the head |
| `WORKER_ROCE_IP` | `<WORKER_FABRIC_IP>` | rank 1 fabric address → `VLLM_HOST_IP` on the worker |
| `MASTER_ADDR` | `<HEAD_FABRIC_IP>` | rendezvous; must equal `HEAD_ROCE_IP` (enforced) |
| `NCCL_IB_HCA` | `<ROCE_RDMA_DEVICE>` | the one RDMA device; a list is refused |
| `NCCL_SOCKET_IFNAME` | `<ROCE_NETDEV>` | its netdev; also single-valued |
| `CONTROL_IF` | `<CONTROL_NETDEV>` | Gloo/TP/OOB netdev; also feeds `GLOO_SOCKET_IFNAME`, `TP_SOCKET_IFNAME`, `MN_IF_NAME`, `OMPI_MCA_btl_tcp_if_include` |
| `HF_CACHE` | `<ABSOLUTE_HF_CACHE_DIR>` | absolute path to the cache holding the pinned revision; bind-mounted in |
| `DRM_CARD_GID` | `<DRM_CARD_GID>` | numeric group of `/dev/dri/card0`, for the display-KV override |

Keeping the two sets apart is the point: changing an address, interface name or
cache path cannot change the recipe. The merge also refuses unknown or missing
keys, unedited placeholders, a site file setting a profile constant, and any
value containing `$`, a backtick, a quote, `#` or whitespace — no env file is
ever sourced by a shell. `config/site.env` is git-ignored.

## Validation

```bash
./validate.sh                                           # basic, offline
./validate.sh --upstream ../up --compose-bin "docker compose"   # full
```

**Basic** needs no upstream checkout, Compose binary, Docker, network or cluster:
files and modes, `bash -n`, a Python parse, `sha256sum -c SHA256SUMS`, the
profile/site key-set and placeholder guards, that this README documents every
delta key and value, a secret scan, and an identity scan rejecting any IPv4
literal outside the documentation ranges. It then runs the offline suites: the
env-merge units, and upstream-pin rejections built against throwaway git repos
(wrong commit, dirty Compose file, dirty chat template, untracked file, hash
mismatch, non-git copy).

**Full** adds the real render — `compose config` (no daemon, no pull) of the
three-file stack — asserting that its difference from the pinned upstream
baseline is *exactly* the delta above plus the site mapping; that the serve argv
matches the live service on both roles (extracted by running the rendered
entrypoint offline against a stub `vllm`); that head and worker differ only in
rank, headless mode and local address; that our override is what delivers the
spin limit and fails closed without it; and that rendering mutates nothing. It
also runs the launcher suite. Neither mode proves the digest is pullable, the
weights are cached, the fabric works or the service starts — those need the real
nodes.

## Measured data

Our own measurements. **The profiles differ between these runs — do not read
them as a series.** There is no benchmark rerun on the current 13,876 MiB /
8192-batch profile.

**Current profile, observed 4 Oct 2026** (both ranks identical): KV pool
1,882,738 tokens; `max_model_len` 1,047,552; 1,792 MiB display-reserved plus
12,079.625 MiB ordinary KV per rank. Up on this profile since 1 Oct 2026 — a few
days on one pair of machines, neither a crash-free record nor a production
qualification.

**Prefill/decode overlap, 29 Sep 2026 (Phase 1).** A 10,121-token image prompt
returned its first token after 10.52 s with the correct answer (a blue square)
while a 1,500-token text generation was still streaming: evidence that prefill
and decode overlapped in that instance, **not** of a general cure for stalls.

**Throughput, 28 Sep 2026 — KV 11,840 MiB, display-KV OFF, batch 4096.**
`llama-benchy` 0.4.0, PP 2048 / TG 128, 3 reps, `--max-num-seqs 6`, automatic
split 4096. 90 responses, 0 errors; 4 returned 127 tokens instead of 128.

| Context | Metric | C1 | C2 | C3 | C4 |
|---|---|---|---|---|---|
| depth 0 | prefill tok/s | 1546 | 1356 | 1762 | 1420 |
| depth 0 | decode tok/s | 40.0 | 43.1 | 41.3 | 43.4 |
| warm 32K | prefill tok/s | 1445 | 1461 | 1582 | 1625 |
| warm 32K | decode tok/s | 39.0 | 41.2 | 40.9 | 51.1 |

**Throughput, 28 Sep 2026 — KV 14,388 MiB (framebuffer reclaimed).**
Concurrency 1 and 4 only; 45 responses, 0 errors; 2 returned 127 tokens.

| Context | Metric | C1 | C4 |
|---|---|---|---|
| depth 0 | decode tok/s | 39.2 | 41.2 |
| warm 32K | decode tok/s | 36.3 | 48.6 |

**Tool calling, 28 Sep 2026 — KV 14,388 MiB, display-KV ON, batch 4096.** Hard
tool set at concurrency 4, temperature 1.0, top-p 0.95, seed 42: **82 pass, 4
partial, 6 fail** over 92 cases, 168 of 184 points (91/100). Three cases (TC51,
TC89, TC92) raised safety flags; the TC89 flag involves a grader mismatch, so
treat that one as inconclusive.

## Known issue: decode freeze

On **1 Oct 2026** the service froze during decode: roughly 75K tokens of prefill
across 2 in-flight requests with KV at about 20%, decode stopped progressing,
the `sample_tokens` RPC hit its 300 s timeout, and the head container then
**exited 0** — not an OOM kill — leaving the worker rank orphaned. An external
restart brought the API back at 09:02.

The same signature appeared on 29 Sep 2026 (Spark Cache) and matches the
upstream signature first recorded on 22 Sep 2026, documented upstream at
`docs/incident-2026-09-22-rpc-timeout.md` in the pinned checkout (read it
there). A plausibly matching collective/GPU-wait report is
[local-inference-lab/b12x#313](https://github.com/local-inference-lab/b12x/issues/313)
— **not** a proven root cause; the memory-pressure hypothesis is also unproven.
Nothing here fixes the freeze, and the split-4096 / batch-8192 choice was made
for prefill/decode overlap: **do not read it as a scheduler fix that eliminated
the freeze.**

**Recovery stance.** For unattended operation, use an external **death-only**
watchdog: detect that a rank process is actually gone, then stop and restart the
pair, worker first. Do not build it on upstream's API-health watchdog — stall
detection is a judgement call about your own traffic, and getting it wrong
restarts a healthy service. None is published here by design: a restart loop
should be written, reviewed and owned at the site that runs it.

## Files

`compose.phase1.override.yaml` (the spin-limit overlay), `config/profile.env`,
`config/site.env.example`, `tools/envmerge.py`, `launch.sh`, `validate.sh` and
`tests/`. `sha256sum -c SHA256SUMS` covers all of them.
