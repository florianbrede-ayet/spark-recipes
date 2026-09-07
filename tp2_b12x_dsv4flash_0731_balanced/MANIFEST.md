# Manifest and inventory

Every file in this bundle, what it is, where it came from, and what validates
it.

**Provenance legend**

* **audit** — copied or transcribed from read-only audit evidence of the live
  nodes (`192.168.1.151`, `192.168.1.152`), captured 2026-08-23 with a runtime
  sample from 2026-08-26.
* **handover** — from the validated handover summary
  `dsv4-gmu087-graphestimate0-final-2026-08-23`.
* **benchmark** — from the validated report
  `dsv4-live-gmu087-quick-benchmark-2026-08-23`.
* **authored** — written for this bundle.

---

## 1. Inventory

### Root

| File | Mode | Provenance | Purpose |
|---|---|---|---|
| `README.md` | 644 | authored | Entry point: pins, quick start, documentation index, safety posture. |
| `MANIFEST.md` | 644 | authored | This file. |
| `SHA256SUMS` | 644 | generated | SHA-256 of every canonical artifact. Excludes itself. |
| `.gitignore` | 644 | authored | Keeps site-local config, generated output and third-party mods out of version control. |

### `recipe/` — canonical artifacts

| File | Mode | Provenance | Purpose |
|---|---|---|---|
| `deepseek-v4-flash-0731.yaml` | 644 | **audit (byte-exact)** | The live recipe, copied unmodified. SHA-256 `2dcd8e9a…98379b`, identical on both nodes and to the launcher-reported hash. |
| `canonical-cli-rank0.txt` | 644 | **audit** | The exact `vllm serve` argv of the live rank-0 process. |
| `canonical-cli-rank1.txt` | 644 | **audit** | The exact `vllm serve` argv of the live rank-1 process (`--headless`). |

The two `canonical-cli-*.txt` files are the reproduction ground truth:
`scripts/30-render.sh --rank N --check` asserts the rendered template matches
them exactly, offline.

### `config/`

| File | Mode | Provenance | Purpose |
|---|---|---|---|
| `pinned-artifacts.env` | 644 | audit + handover | Model repo and revision, image digest / ID / metadata, launcher and recipe SHA-256, topology constants, and the audited capacity outputs. Sourced by every script. No secrets. |
| `mods-pins.env` | 644 | audit + authored | The two declared mods in recipe order, their content digests (both `UNAVAILABLE` — the audited bytes are not in the evidence), the `MOD.sha256` manifest filename, and the in-container certification marker paths. This file is why an exact launch fails closed. |
| `cluster.env.example` | 644 | audit | Node addresses, interfaces, RDMA devices, rails, MTU, NM profile names, ports. Copy to `cluster.env` (untracked). |
| `hf-credentials.env.example` | 644 | authored | Placeholder-only credential template. Copy to `hf-credentials.env` (untracked, `chmod 600`). **Contains no real credentials.** |

### `docs/`

| File | Mode | Provenance | Purpose |
|---|---|---|---|
| `00-as-deployed.md` | 644 | audit | Pins, host platform, container runtime configuration, mounts, both environment layers, process tree, full serving argv, topology and endpoints, declared mods. |
| `01-network.md` | 644 | audit | Management network, rail A (in use), rail B (twin, idle), the never-share-a-subnet rule, `nmcli` reproduction, port exposure. |
| `02-prerequisites-and-limitations.md` | 644 | audit + authored | Hardware/software envelope, access and licensing, artifact sizes and cold-start cost, what is deliberately not vendored, operational limits, environment quirks. |
| `03-profile-gmu087.md` | 644 | audit + handover | Every knob of the GMU 0.87 profile, the graph-estimate accounting caveat, tokenizer/parser details, B12X backend selection. |
| `04-capacity-and-health.md` | 644 | handover + audit | The 1,048,576 ceiling vs the 2,356,056-token pool, per-rank memory arithmetic, units and caveats, health-check tables. |
| `05-benchmarks-2026-08-23.md` | 644 | benchmark | Dated provenance, TG128 and PP4096 tables, aggregate vs per-stream and cold vs warm definitions, validity controls, quoting guidance. |
| `06-operations-runbook.md` | 644 | authored | First deployment, start/stop, restore and rollback, troubleshooting. |
| `07-rank-differences.md` | 644 | audit | Intentional, incidental and forbidden differences between rank 0 and rank 1. |

### `scripts/`

| File | Mode | Mutates? | Purpose |
|---|---|---|---|
| `lib/common.sh` | 644 | — | Shared library (sourced, not executed): logging, the `--apply` gate, `confirm`, node-identity and fabric checks, artifact-pin enforcement. |
| `00-check-prereqs.sh` | 755 | **never** | Read-only preflight against the audited envelope. No `--apply` path exists. |
| `05-setup-network.sh` | 755 | `--apply` + confirm | Prints the planned `nmcli` commands by default; only `--apply` executes. Defaults to **both** rails. Identifies the node from management identity (this runs before the fabric exists) and fails on ambiguity. Sets and then re-verifies method/address/MTU/gateway/never-default/no-DNS/route-metric/IPv6 per rail. Refuses a same-subnet rail layout. `--verify` is read-only. |
| `10-fetch-image.sh` | 755 | `--apply` + confirm | Pulls by digest (or loads an archive), verifies the resulting image ID against the pin, then tags. Never rewrites the pin. |
| `20-fetch-model.sh` | 755 | `--apply` + confirm | Downloads the pinned **commit** directly (never "main") using *your* credentials; refuses placeholder tokens. Judges presence by the on-disk snapshot — required artifacts, tokenizer, weight shards, resolvable blobs — never by `refs/main`. `--establish-ref` writes `refs/main` only after that snapshot verifies. |
| `25-pin-mods.sh` | 755 | `--apply` + confirm | Certifies operator-supplied mod directories: writes each `MOD.sha256` manifest and prints the resulting content digests. Never edits `config/mods-pins.env` — promoting a digest to a pin is deliberately a human act. |
| `30-render.sh` | 755 | bundle only | Renders the per-rank launch script into `render/`. `--check` proves the argv matches the canonical live invocation. |
| `40-start.sh` | 755 | `--apply` + confirm | Full dry run by default. Primary-only. Certifies mods first and **fails closed** unless every declared mod is pinned and matches; `--non-exact-mods` needs a second typed confirmation and stamps a NON-EXACT marker into both containers. Verifies pins on both nodes, refuses a running deployment, creates the **worker container first**, applies mods in recipe order, stamps the certification marker, installs exec scripts, and dispatches **worker before primary**. A failure before dispatch removes only the containers that run created; after dispatch it removes nothing and reports the partial state. |
| `50-health.sh` | 755 | **never** | Read-only health and capacity probe. `--smoke` optionally sends one small request. |
| `60-verify-deployment.sh` | 755 | **never** | Proves a running deployment *is* this recipe. One probe, read from environment variables, is piped to `bash -s` locally and to `ssh <worker> bash -s` for `--peer`, so both ranks run byte-identical checks and a peer failure fails the run. Covers: container exists and runs; image ID/tag/arch/size; host network, privileged, host IPC, `nofile`, runtime, workdir, entrypoint, cmd; exactly five bind mounts with destination, type, RW, source suffix and common root; container env including the rank's own fabric IP; model snapshot as the rank sees it; live argv, `--node-rank`, rendezvous and `--headless`; all sixteen recipe env vars from `/proc`; fabric state/MTU/address and RDMA; rank-correct listeners; and the mod-certification marker. A missing container, an unreachable peer, and a NON-EXACT or uncertified mod state are all failures. |
| `90-stop.sh` | 755 | `--apply` + confirm | Prints the shutdown plan by default. Coordinated stop: rank 0 first, then rank 1. Optional `--drain`. Each rank has three states — running, verified down, or **UNKNOWN** — and a failed SSH or dead daemon is never collapsed into "down". Re-verifies both ranks afterwards and exits non-zero unless both are confirmed down. |
| `validate.sh` | 755 | **never** | Offline self-check of this bundle. See §3. |

### `templates/` and `mods/`

| File | Mode | Provenance | Purpose |
|---|---|---|---|
| `templates/exec-script.sh.tmpl` | 644 | audit | The in-container launch script: the recipe `env:` exports plus the exact `vllm serve` invocation. Markers `@@MODEL@@`, `@@HOST@@`, `@@PORT@@`, `@@RANK_ARGS@@`. |
| `mods/README.md` | 644 | authored | Why the two declared mods are neither vendored nor certifiable, what they did, the `MOD.sha256` manifest mechanism, the certification states, and how to reach `EXACT`. |

---

## 2. Deliberate exclusions

| Excluded | Why |
|---|---|
| Model weights, tokenizer files, any `.safetensors`/`.bin` | Size and licensing. Fetched by `scripts/20-fetch-model.sh` at the pinned revision. |
| Container image layers | Size and licensing. Fetched by `scripts/10-fetch-image.sh` by digest. |
| `~/.cache/vllm`, `flashinfer`, `triton`, `tilelang` contents | Machine-specific, large, regenerated on first boot. |
| Bulk logs | Volume and transient content. The few load-bearing log lines are quoted inline with context. |
| The vendor launcher `launch-cluster.sh` | Not self-contained (it sources an `autodiscover.sh` absent from the evidence) and third-party. Its SHA-256 is recorded; its behaviour is reproduced from scratch and machine-verified. |
| The two vendor mods | Not present in the audit evidence, which records only that they were *applied*, never their contents. Both digests in `config/mods-pins.env` are therefore `UNAVAILABLE`, an exact launch fails closed, and a NON-EXACT launch is marked as such inside both containers. This is the one real reproduction gap. |
| Container IDs, PIDs, MAC addresses, NM connection UUIDs, hostnames, IPv6 host addresses | Raw machine/transient identifiers. `validate.sh` §8 actively blocks 64-hex strings that are not documented artifact hashes, which catches container IDs. |
| Any credential | `validate.sh` §7 and §9 enforce this. |

Site-local and generated paths (`config/cluster.env`, `config/hf-credentials.env`,
`render/`, `mods/*/`) are excluded from both `SHA256SUMS` and version control.

---

## 3. Validation coverage

`scripts/validate.sh` runs offline with no cluster, no credentials, no Docker
and no network. It changes nothing.

| # | Check | What it enforces |
|---|---|---|
| 1 | **Structure** | Every required file present; no site-local file committed; correct executable bits; no model/binary/log artifacts; no oversized files. |
| 2 | **Syntax** | `bash -n` on every `*.sh` **and** on `templates/exec-script.sh.tmpl`. |
| 3 | **Lint** | `shellcheck -x -S warning` when installed, plus built-in rules that always run: shebang, strict mode, no backticks (SC2006), no unguarded `cd` (SC2164), no `rm` with an unquoted expansion, mutating scripts must have both an `is_apply` gate and a `confirm` call, read-only scripts must have no `--apply` path. |
| 4 | **Render** | `30-render.sh --rank {0,1} --check` — the template reproduces the canonical live argv exactly; rank 1 is `--headless` and rank 0 is not. |
| 5 | **References** | ~70 pinned constants must appear in **every** document that is supposed to state them: model revision, image digest and ID, launcher and recipe SHA-256, ports 29501/8888, both management IPs, both rails' interfaces/RDMA devices/addresses/MTU, the same-subnet rule, every profile knob, the graph-estimate caveat, the capacity figures, benchmark date and cold/warm and aggregate/per-stream language, the prerequisite envelope, the not-vendored disclosures, rank topology and primary-only API behaviour, restore/rollback and troubleshooting sections, the worker-before-primary and rank-0-first orders. |
| 6 | **Checksums** | `sha256sum -c SHA256SUMS` passes; `SHA256SUMS` excludes itself and covers *exactly* the canonical file set (no missing, no extra); the vendored recipe hashes to the live recipe hash. |
| 7 | **Placeholders** | Credential placeholders present in the example file; no credential variable is assigned a literal value anywhere; scripts honour the `<PLACEHOLDER>`-is-unset convention; template markers intact; no unresolved authoring markers left anywhere in the tree. |
| 8 | **Hash inventory** | Every 64-hex string in the tree is either a documented artifact hash or one of our own `SHA256SUMS` entries. This is what blocks live container and machine IDs; the two live container ID prefixes are additionally denied by name. |
| 9 | **Secret scan** | Ten token/key patterns (Hugging Face, AWS, GitHub, OpenAI-style, Slack, JWT, PEM private key, SSH public key, and a generic credential-assignment pattern) across every tracked file — **including `validate.sh` itself**. The patterns are written so their own literal text cannot match them, so nothing needs to be excluded to avoid a false positive. A self-test then runs the detector against synthetic canaries and fails the whole validation if fewer than three patterns fire, so a broken regex cannot silently pass. |
| 10 | **Policy invariants** | That the safety behaviours are implemented, not merely described: start fails closed on non-exact mods and stamps a marker; foreign mods rejected; digests are content-based; pin promotion stays manual; verify fails on missing container / unreachable peer / NON-EXACT, and checks runtime, all five mounts, rank fabric env, recipe env from `/proc`, argv/rank/headless, fabric and listeners; network bootstrap uses management identity, rejects ambiguity, defaults to both rails, sets and re-verifies every audited NM property, while the other scripts keep their fabric checks; start creates the worker first, cleans up only what it created, and never silently removes after dispatch; stop distinguishes unknown from down and re-verifies; model pin requires a real snapshot and `refs/main` is only ever derived. It also *executes* `probe_mods` (must report non-EXACT with nothing supplied) and `mod_content_digest` (must be deterministic and content-sensitive). |

Exit status is non-zero on any failure. Warnings do not fail the run.

```bash
scripts/validate.sh        # summary
scripts/validate.sh -v     # per-check detail
```

---

## 4. Regenerating `SHA256SUMS`

`SHA256SUMS` is generated **last**, after every other file is final, and lists
every canonical artifact except itself:

```bash
cd tp2_b12x_dsv4flash_0731_balanced
find . -type f \
    -not -path './.git/*' \
    -not -path './render/*' \
    -not -path './mods/*/*' \
    -not -name 'cluster.env' \
    -not -name 'hf-credentials.env' \
    -not -name 'SHA256SUMS' \
  | sed 's|^\./||' | sort | xargs -r sha256sum > SHA256SUMS
scripts/validate.sh
```

Check 6 fails if the file set and `SHA256SUMS` ever drift apart, so a forgotten
regeneration cannot pass validation.
