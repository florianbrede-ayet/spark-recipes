# Reproduction prerequisites and limitations

> **Read this before assuming this bundle will run anywhere.**
>
> This recipe was audited on one specific pair of machines. This bundle lets an
> agent reproduce the **exact Docker and vLLM invocation** on a compatible pair
> of nodes. It does **not** make arbitrary stock hardware work, and it does not
> ship the things it is not allowed to ship.

---

## 1. Hard requirements

Without every one of these, do not expect this recipe to start at all.

### Hardware

* **Two nodes**, one GPU each, `--tensor-parallel-size 2` across them.
* **NVIDIA GB10** (SM121, compute capability `12.1a`). The image is built for
  `TORCH_CUDA_ARCH_LIST=12.1a` / `CUTE_DSL_ARCH=sm_121a` and the B12X kernels
  (`B12X_MLA_SPARSE`, `b12x` MoE/linear backends, `B12X_MLA_SM120_UNIFIED`)
  are SM121-specific. Other NVIDIA GPUs will not do.
* **~122 GiB of GPU-visible unified memory per node.** The audited boot saw
  `111.18/121.63 GiB` free at startup and used `80.84 GiB` for weights alone.
* **arm64 / aarch64.** The image is `linux/arm64`. There is no x86-64 variant
  in the evidence.
* **A ConnectX-7-class RoCE NIC** with at least one port up, MTU 9000 capable.
  See [01-network.md](01-network.md).

### Software (as observed — treat as the reference envelope)

| Component | Audited value | Sensitivity |
|---|---|---|
| OS | Ubuntu 24.04.4 LTS (noble) | moderate |
| Kernel | `6.17.0-1029-nvidia`, aarch64 (NVIDIA DGX OS flavour) | moderate |
| NVIDIA driver | `580.173.02` | **high** |
| Docker | `29.2.1` (client and server) | low |
| CUDA (in image) | `13.0.2` | fixed by the image |
| NCCL (in image) | `2.28.3-1` | fixed by the image |

The driver is the one to watch. These are hand-tuned FP8/MLA kernels with AOT
compilation and CUDA-graph capture; a driver change is the most likely cause of
a boot that compiles differently, captures differently, or simply crashes.

`scripts/00-check-prereqs.sh` reports each of these as an exact match, a
warning, or a hard failure. **A pass with warnings is not an exact environment
match.**

### Access and licensing

* **`deepseek-ai/DeepSeek-V4-Flash-0731` is a gated Hugging Face repository.**
  You need your own account with accepted terms and a read token. This bundle
  contains no credentials and never will; see
  [`config/hf-credentials.env.example`](../config/hf-credentials.env.example).
* **The image `eugr/spark-vllm-b12x` is a third-party build.** Its availability,
  licensing and continued publication are outside this bundle's control. The
  digest pin protects you from *silent substitution*; it cannot conjure the
  image if it is withdrawn. Mirror it yourself if you care.
* Model weights and image layers are subject to their own upstream licences.
  Nothing here grants you any right to either.

### Storage and time

* Image: `23362056860` bytes (~21.8 GiB) on disk, per node.
* Model: a very large gated download, per node — each rank loads from its own
  local cache. `80.84 GiB` ends up resident in GPU memory per rank.
* Warm caches: `~/.cache/vllm`, `~/.cache/flashinfer`, `~/.triton`,
  `~/.tilelang`. These are bind-mounted and grow. A cold node pays AOT
  compilation on first boot.
* Cold start is slow. On the audited boot, rank 1 went from container start to
  KV-cache allocation in **about 3.5 minutes** (`11:40:31` → `11:44:13`), with
  DSpark draft-model load and two CUDA-graph capture passes in between. Full
  API readiness is longer.

**This bundle ships no weights, no image layers, no cache contents and no
logs.** It is text, scripts and hashes.

---

## 2. What is deliberately not vendored

### The vendor launcher

`launch-cluster.sh`, SHA-256
`d587df37af3a37f50328e0e72030177a7e864fff41e4b2edea354c5c6e52dd1a`, is **not**
included. Two reasons:

1. It is not self-contained. It `source`s `autodiscover.sh`, which is not in
   the audit evidence, and it reads a site-local `.env`. Shipping it would ship
   something that cannot run.
2. It is a third-party framework file with its own provenance.

**This does not block reproduction.** The launcher's job was to build a
`docker run` command, drop an exec-script into each container, and dispatch the
ranks. This bundle does all three directly, from scratch, in
`scripts/40-start.sh` + `templates/exec-script.sh.tmpl`, and proves the result
is identical: `scripts/30-render.sh --rank N --check` compares the rendered
argv against `recipe/canonical-cli-rank{0,1}.txt`, captured from the live
process table. That check runs offline and is part of `scripts/validate.sh`.

The SHA-256 above is recorded so you can identify the exact launcher revision if
you obtain it independently.

### The two mods

The recipe declares:

```yaml
mods:
  - mods/instanttensor-hybrid-draft-loader
  - mods/dsv4-reasoning-effort-fix
```

These are vendor patch bundles (a directory containing `run.sh`, applied inside
the container before launch). They are not in the audit evidence and are not
vendored here.

**This is the one real gap in reproduction, and it is a hard one.** The Docker
and vLLM invocations are exact and machine-verified. The mods are an extra
in-container patch layer that this bundle cannot supply — and, worse, the
evidence records only that they were *applied*, never their *contents*. No
trustworthy digest exists for either.

Consequences, stated plainly:

* `config/mods-pins.env` carries `UNAVAILABLE` for both mod digests.
* **An exact launch is impossible today and fails closed.**
  `scripts/40-start.sh` refuses rather than launching something it cannot vouch
  for.
* A launch is possible only via `--non-exact-mods`, which requires a second
  typed confirmation and stamps `/workspace/MODS_NON_EXACT` into both
  containers. `scripts/60-verify-deployment.sh` then reports **NON-EXACT** and
  fails exact verification, permanently.
* **Nothing in this bundle will describe such a deployment as a restoration of
  the audited one, and neither should you.**

To reach exactness you must obtain the audited mod directories, pin them with
`scripts/25-pin-mods.sh --apply`, and manually record their digests in
`config/mods-pins.env`. That last step is deliberately manual: it is where a
human asserts that specific bytes are the audited ones.

Without the mods:

* The **InstantTensor hybrid draft loader** is absent. The audited startup log
  shows it active — *"Hybrid draft loading: using lazy safetensors for
  speculative draft weights while preserving InstantTensor for the target model
  (`INSTANTTENSOR_DRAFT_LOADER=auto`)"*. With `--load-format instanttensor` and
  a DSpark draft model, expect a different (or failing) draft-weight load path.
* The **DSv4 reasoning-effort fix** is absent, so
  `--default-chat-template-kwargs.reasoning_effort=high` may not behave as it
  did live.

`scripts/40-start.sh` applies certified mod directories using the same
copy-and-`run.sh` procedure the vendor launcher used, in recipe order, and
rejects any directory under `mods/` that this recipe does not declare. See
[`mods/README.md`](../mods/README.md).

### Everything else that is excluded on purpose

No raw machine identifiers (container IDs, PIDs, MAC addresses, NetworkManager
connection UUIDs, hostnames, IPv6 host addresses), no bulk logs, no model files,
no cache contents, no credentials of any kind. `scripts/validate.sh` enforces
the credential part with a secret scan and a placeholder audit.

---

## 3. Operational limitations of the deployment itself

These are properties of the audited deployment, not of this bundle.

* **No supervision, no auto-recovery.** No systemd unit, no restart policy. The
  audited hosts had the relevant units `inactive` / `disabled`. If a rank dies,
  it stays dead.
* **`--rm` containers.** Stopping a container destroys it. There is no
  "restart the container" — only a full re-launch of both ranks.
* **No single-rank recovery.** The two ranks are one TP group. Losing rank 1
  leaves rank 0 with a broken collective while the API port may still be bound.
  Recovery is always: stop both, start both.
* **No authentication, no TLS, no rate limiting** on `0.0.0.0:8888`.
* **`--privileged`, `--network host`, `--ipc=host`.** The container is not a
  security boundary. Anyone who can reach the API can drive a privileged
  process on the host's network namespace.
* **`--trust-remote-code`** executes model-repository Python. That is another
  reason the revision pin is not optional.
* **Capacity is per-boot.** `--max-model-len auto` resolved to `1048576` on the
  audited boot as a function of the memory that happened to be free. A
  different boot can resolve differently. See
  [04-capacity-and-health.md](04-capacity-and-health.md).

---

## 4. Known environment quirks observed in the evidence

* **`NVIDIA_REQUIRE_CUDA` vs the host driver.** The image declares driver bands
  up to `driver<576`, while both hosts run `580.173.02`. The live deployment ran
  anyway (`Runtime: runc`, GPUs injected by the container toolkit). If your
  toolkit enforces that constraint you will need to relax it (for example
  `NVIDIA_DISABLE_REQUIRE=1`) — the audited containers did not carry that
  variable, so do not add it "to match": add it only if your toolkit refuses.
* **Speculative decoding reduces the effective batch budget.** vLLM logs
  *"`max_num_scheduled_tokens` is set to 4072 based on the speculative decoding
  settings"* — `--max-num-batched-tokens 4096` minus draft slots. This is
  expected for this profile, not a misconfiguration.
* **Benign NVRM warnings.** Generic `_memdescAllocInternal` NVRM warnings were
  recorded during the audited runs and were explicitly accepted by operator
  directive rather than treated as a failure. Expect to see them.
* **`RAY_*` variables with no Ray.** Set unconditionally by the launcher and
  reproduced here for fidelity; no `ray` process runs.

---

## 5. Do not claim more than this

Concretely, this bundle supports the statement:

> *"On two GB10 / arm64 nodes with driver 580.173.02, Docker 29.2.1, both RoCE
> rails configured as documented, access to the pinned image and the pinned
> gated model revision, these scripts reproduce the exact Docker and vLLM
> invocation that was audited live."*

It does **not** support:

> ~~"Run this on any two Linux boxes with GPUs."~~

> ~~"This restores the audited deployment."~~ It cannot, today: the mods are
> uncertifiable, so the closest achievable result is an explicitly NON-EXACT
> deployment that is marked as such inside both containers.

Operational limits that verification will not paper over: a missing or
not-running container is a failure, an unreachable peer is a failure, and a
`refs/main` file claiming the pinned revision is never accepted as evidence that
the model is actually present.
