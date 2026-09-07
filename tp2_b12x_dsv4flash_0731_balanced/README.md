# tp2_b12x_dsv4flash_0731_balanced

DeepSeek V4 Flash 0731 on a **two-node GB10 cluster**, tensor-parallel 2, served
by vLLM from the B12X container image — the **GMU 0.87 balanced** profile,
captured exactly as it ran live.

This bundle is self-contained for orchestration and documentation, but restoring
the exact serving semantics also requires the two non-vendored vendor mods
listed below. It ships **no weights, no image layers, no logs, no caches and no
credentials**.

---

## The pins

| | |
|---|---|
| Model | `deepseek-ai/DeepSeek-V4-Flash-0731` |
| **Revision** | **`7872f01b1d1fe23eabc4c98b48bffcef5a386062`** |
| **Image** | **`eugr/spark-vllm-b12x@sha256:eb3ed2bbb0c91dc6d41282d22532267b5a449088c78a032400cd887fe9ddd2c5`** |
| **Image ID** | **`sha256:d43f15877df4176dfc70b7ebca336d5de698e1696da02fc3738b0338a65f5db2`** |
| **Live launcher SHA-256** | **`d587df37af3a37f50328e0e72030177a7e864fff41e4b2edea354c5c6e52dd1a`** |
| **Live recipe SHA-256** | **`2dcd8e9a9448ab51ea8ed6cebfb12961abdb1d278912ca4f0da4e4e8ad98379b`** |
| Topology | 2 nodes, TP2, rendezvous `10.0.7.1:29501`, API `0.0.0.0:8888` on rank 0 only |
| Profile | GMU 0.87 · maxseq 6 · batched 4096 · threshold 1024 · retention 4096 · DSpark k5 · FP8 KV |
| Capacity (audited boot) | API ceiling **1,048,576** tokens/request · limiting KV pool **2,356,056** logical tokens |

Machine-readable: [`config/pinned-artifacts.env`](config/pinned-artifacts.env).

---

## Exactness: read this before deploying

The audit evidence records that the recipe's two vendor mods were *applied*,
never what they *contained*. No trustworthy digest exists for either, so
[`config/mods-pins.env`](config/mods-pins.env) carries `UNAVAILABLE` for both
and **an exact launch is not currently achievable — `scripts/40-start.sh` fails
closed.**

You may still launch, but only by asking for it explicitly
(`--non-exact-mods`), which requires a second typed confirmation and stamps a
permanent `NON-EXACT` marker inside both containers. Verification reads that
marker and reports NON-EXACT for the life of the deployment. Nothing here will
call such a deployment a restoration of the audited one.

[`mods/README.md`](mods/README.md) explains how to reach `EXACT` if you obtain
the audited mods.

## Quick start

```bash
scripts/validate.sh                  # check this bundle (offline, safe anywhere)

# on BOTH nodes
scripts/00-check-prereqs.sh              # read-only preflight
scripts/05-setup-network.sh --rail both  # prints the nmcli plan; --apply to execute
scripts/10-fetch-image.sh                # plan; --apply to pull by digest
scripts/20-fetch-model.sh                # plan; --apply to fetch the pinned revision
scripts/25-pin-mods.sh                   # certify supplied mods; --apply to pin

# on the PRIMARY only
scripts/40-start.sh                            # full dry run of both nodes
scripts/40-start.sh --apply                    # refuses unless mods certify EXACT
scripts/40-start.sh --apply --non-exact-mods   # knowingly launch NON-EXACT
scripts/50-health.sh                           # read-only health probe
scripts/60-verify-deployment.sh --peer         # whole-cluster verification
scripts/90-stop.sh                             # plan; --apply for a coordinated stop
```

**Every mutating script is dry-run by default and needs `--apply` plus an
interactive confirmation.** Read
[docs/06-operations-runbook.md](docs/06-operations-runbook.md) first.

---

## Documentation

| Document | Contents |
|---|---|
| [00-as-deployed.md](docs/00-as-deployed.md) | Exact live configuration: pins, host platform, container runtime, mounts, both environment layers, process tree, full serving argv |
| [01-network.md](docs/01-network.md) | Management network, rail A (in use), rail B (twin, idle), why the rails must never share a subnet, nmcli reproduction |
| [02-prerequisites-and-limitations.md](docs/02-prerequisites-and-limitations.md) | Hardware/software envelope, access and licensing, artifact sizes, what is deliberately not vendored, operational limits |
| [03-profile-gmu087.md](docs/03-profile-gmu087.md) | Every knob in the GMU 0.87 profile and what it does, including the graph-estimate accounting caveat |
| [04-capacity-and-health.md](docs/04-capacity-and-health.md) | The 1M ceiling vs the 2,356,056-token pool, per-rank memory arithmetic, units and caveats, health checks |
| [05-benchmarks-2026-08-23.md](docs/05-benchmarks-2026-08-23.md) | Dated benchmark provenance with aggregate vs per-stream and cold vs warm kept strictly apart |
| [06-operations-runbook.md](docs/06-operations-runbook.md) | First deployment, start/stop, restore and rollback, troubleshooting |
| [07-rank-differences.md](docs/07-rank-differences.md) | Intentional, incidental and forbidden differences between rank 0 and rank 1 |
| [MANIFEST.md](MANIFEST.md) | File-by-file inventory, provenance and validation coverage |

---

## How reproduction is proven

The vendor launcher is not vendored (it is not self-contained — see
[02-prerequisites-and-limitations.md](docs/02-prerequisites-and-limitations.md)).
Instead, this bundle builds the `docker run` command and the in-container launch
script from scratch, and then **proves the result is identical to the live one**:

```bash
scripts/30-render.sh --rank 0 --check
scripts/30-render.sh --rank 1 --check
```

renders [`templates/exec-script.sh.tmpl`](templates/exec-script.sh.tmpl) and
asserts the resulting `vllm serve` argv is byte-identical to
[`recipe/canonical-cli-rank0.txt`](recipe/canonical-cli-rank0.txt) /
[`canonical-cli-rank1.txt`](recipe/canonical-cli-rank1.txt), which were captured
from the live process table. The check runs offline, needs no cluster, and is
part of `scripts/validate.sh`.

The known gap is the two vendor mods, which are neither vendored nor
certifiable — see the exactness note above and
[`mods/README.md`](mods/README.md). **A launch without certified mods is not an
exact restore, and the tooling marks and reports it as NON-EXACT rather than
leaving that to memory.**

---

## Safety posture

* Dry-run by default; `--apply` plus interactive confirmation for anything that
  mutates the network, a service or Docker.
* Node identity checked by management IP **and** fabric IP **and** interface
  **and** RDMA device state before any node-specific action. Network bootstrap
  alone uses management identity (it runs before the fabric exists) and fails on
  ambiguity rather than guessing.
* Mods are certified before anything is touched: only the two declared mods, in
  recipe order, pinned by content digest. Undeclared mods are rejected outright.
  Exact launch fails closed; NON-EXACT needs a second confirmation and is marked
  permanently inside both containers.
* Start refuses to run anywhere but the primary, refuses mismatched image IDs or
  model snapshots on either node, refuses to touch an already-running
  deployment, creates the worker container first, and dispatches the worker
  before the primary. A failure before dispatch removes only what that run
  created; a failure after dispatch removes nothing and reports the partial
  state loudly.
* Stop prints its plan unless `--apply`, stops rank 0 before rank 1, treats an
  unreachable rank as UNKNOWN rather than down, and re-verifies both ranks
  before claiming success.
* Verification runs a byte-identical probe on both ranks; a missing container,
  an unreachable peer, or a NON-EXACT mod state are all failures.
* Model presence is judged by the on-disk snapshot the loader actually reads,
  never by a `refs/main` text file.
* Read-only scripts (`00`, `50`, `60`) have no `--apply` path at all.
* No credentials anywhere; `scripts/validate.sh` enforces it.

## Verifying integrity

```bash
sha256sum -c SHA256SUMS      # from inside this directory
scripts/validate.sh          # does this and much more
```

`SHA256SUMS` covers every canonical artifact and excludes itself, plus
site-local files (`config/cluster.env`, `config/hf-credentials.env`), generated
output (`render/`) and operator-supplied `mods/*/`.
