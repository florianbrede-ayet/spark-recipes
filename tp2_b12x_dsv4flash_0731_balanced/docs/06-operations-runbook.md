# Operations runbook

Covers first deployment, day-to-day start/stop, restore and rollback, and
troubleshooting.

**Three standing rules:**

1. **Every mutating script is dry-run by default.** `--apply` is always
   required, and `--apply` always asks for an interactive confirmation
   (`--yes` bypasses only the prompt, never the flag).
2. **The two ranks are one unit.** Never start, stop or restart a single rank.
3. **An exact launch is not currently achievable.** The audited mod bytes are
   not in the evidence, so `scripts/40-start.sh` fails closed unless you
   explicitly ask for a NON-EXACT launch. See
   [02-prerequisites-and-limitations.md](02-prerequisites-and-limitations.md)
   and [`mods/README.md`](../mods/README.md).

---

## 1. First deployment

Run steps 1–5 on **both** nodes; step 6 on the **primary** only.

```bash
# 1. Preflight — read-only, never mutates.
scripts/00-check-prereqs.sh
scripts/00-check-prereqs.sh --strict     # optional: treat warnings as failures

# 2. Fabric — BOTH rails. Prints the nmcli plan and exits.
scripts/05-setup-network.sh --rail both              # plan only
scripts/05-setup-network.sh --rail both --apply      # execute, then auto-verify
scripts/05-setup-network.sh --rail both --verify     # read-only re-check

# 3. Image — pulled by digest, verified against the pinned image ID.
scripts/10-fetch-image.sh                         # plan only
scripts/10-fetch-image.sh --apply                 # ~21.8 GiB
# or, for the second node, from an archive:
scripts/10-fetch-image.sh --from-archive vllm-node-b12x.tar --apply

# 4. Model — pinned revision, your own HF credentials.
cp config/hf-credentials.env.example config/hf-credentials.env
chmod 600 config/hf-credentials.env
$EDITOR config/hf-credentials.env                 # replace the placeholder
scripts/20-fetch-model.sh                         # plan only
scripts/20-fetch-model.sh --apply                 # downloads the pinned commit
scripts/20-fetch-model.sh --verify-only           # snapshot completeness check

# 5. Mods — certify whatever you have.
scripts/25-pin-mods.sh                            # report state, write nothing
scripts/25-pin-mods.sh --apply                    # write MOD.sha256 per mod

# 6. Launch — PRIMARY ONLY. Orchestrates the worker over SSH.
scripts/40-start.sh                               # full dry run of both nodes
scripts/40-start.sh --apply                       # fails closed if not EXACT
scripts/40-start.sh --apply --non-exact-mods      # explicit NON-EXACT launch
```

Step 2 configures **both** rails by default. The audited node carries both;
configuring only rail A leaves the cluster in a state this recipe never had.
Because bootstrap runs before the fabric exists, that script alone identifies
the node from management identity (management IP, or a configured hostname
mapping) and refuses to guess if that is ambiguous.

Before step 6, copy `config/cluster.env.example` to `config/cluster.env` if your
addresses differ from the audited ones. `scripts/40-start.sh` requires
key-based, non-interactive SSH from the primary to the worker.

### Mod certification, and why step 6 may refuse

`scripts/40-start.sh` certifies mods before touching anything:

| State | Result |
|---|---|
| all declared mods supplied, pinned, digests match | `EXACT` — launch proceeds |
| anything else | refuses, unless `--non-exact-mods` |
| any directory under `mods/` this recipe does not declare | refuses, always |

Today `config/mods-pins.env` holds `UNAVAILABLE` for both digests, so `EXACT`
is unreachable and the default is a refusal. `--non-exact-mods` requires a
second typed confirmation (`NOT-EXACT`) and stamps
`/workspace/MODS_NON_EXACT` into both containers, after which verification
reports NON-EXACT permanently.

### What `40-start.sh` does, in order

1. Certifies mods; rejects any undeclared mod directory.
2. Verifies identity (management IP + fabric IP + interface + RDMA state) and
   refuses to run anywhere but the primary.
3. Verifies the recipe hash, image ID and model **snapshot** locally, then the
   image ID, model revision and fabric address on the worker over SSH
   (read-only commands only).
4. Refuses to continue if a `vllm_node` container is already running on either
   node.
5. Creates the **worker** container, then the **primary** container — both idle
   (`sleep infinity`, entrypoint cleared).
6. Applies the certified mods to both containers, in recipe order.
7. Stamps the certification marker into both containers.
8. Renders and installs the per-rank exec scripts, each argv-verified against
   `recipe/canonical-cli-rank{0,1}.txt`.
9. **Dispatches the worker (rank 1, `--headless`) first, then the primary
   (rank 0).**

Rank 1 must already be waiting when rank 0 opens the rendezvous store on
`10.0.7.1:29501`. In the audited run the two serving processes appear about a
second apart in the process table because SSH dispatch latency partly cancels
the ordering — **the dispatch order, not the wall-clock start, is what the
sequence guarantees.**

Step 5's order is ours, not the audit's: the audited run created the primary
container first, but both start idle, so the order is free. Creating the worker
first means a failed primary creation leaves exactly one container to undo.

### If the launch fails partway

* **Before any engine is dispatched** (steps 5–8), the script removes only the
  containers *this run created*, names them, and says which it could not remove.
  Nothing else is touched.
* **At or after step 9**, nothing is removed automatically. The script prints a
  `PARTIAL DEPLOYMENT` banner with exactly what it created and what it
  dispatched, and leaves it in place. Tearing down a half-started distributed
  job destroys the evidence of why it failed.

Recover from a partial state with `scripts/90-stop.sh --apply`, then start
again. Never restart a single rank.

### Waiting for readiness

Startup is minutes, not seconds: weight load, AOT compilation, CUDA-graph
capture and DSpark capture all precede the API bind. On the audited boot rank 1
reached KV allocation about 3.5 minutes after container start; full readiness is
longer.

```bash
docker logs -f vllm_node
scripts/50-health.sh
```

---

## 2. Verifying

```bash
scripts/60-verify-deployment.sh            # this node only
scripts/60-verify-deployment.sh --peer     # from the primary: the whole cluster
```

The entire check set lives in one probe that reads its expectations from
environment variables. The same probe text is piped to `bash -s` locally and,
with `--peer`, to `ssh <worker> bash -s`. Both ranks therefore run
**byte-identical** checks, and **a worker failure fails the run** — `--peer` is
verification, not a courtesy summary.

Per rank it checks: the container exists and is running; image ID, local tag,
architecture and size; host network, privileged, host IPC, `nofile` ulimit,
runtime, workdir, cleared entrypoint and `sleep infinity`; **exactly five** bind
mounts with the right destinations, `bind` type, read-write, sources ending in
the right relative paths and sharing one root; the container environment
including that rank's own fabric IP; the model snapshot as the rank sees it
(required artifacts, tokenizer, weight shards, resolvable blobs); the live argv
against the canonical rank argv, plus `--node-rank`, rendezvous and
`--headless`; all sixteen recipe environment variables read from
`/proc/<pid>/environ`; the fabric interface state/MTU/address and RDMA state;
and rank-correct listener behaviour on `8888`.

It refuses to excuse three things:

* a **missing or not-running container** is a failure, never a skip;
* an **unreachable peer** is a failure, never an assumption of health;
* a **NON-EXACT or uncertified** mod state fails exact verification, always.

`--allow-non-exact` downgrades only the third to a warning. The report still
says NON-EXACT.

---

## 3. Stopping

```bash
scripts/90-stop.sh                    # print the shutdown plan, change nothing
scripts/90-stop.sh --apply            # confirmation required
scripts/90-stop.sh --drain --apply    # wait (≤120 s) for in-flight requests first
```

**Order: rank 0 first, then rank 1.** Stopping the primary removes the API from
service so no new work is accepted; the worker then goes down without stranding
in-flight collectives on a still-serving endpoint.

Each rank has **three** states, not two: `RUNNING`, `not running (verified)`,
and `STATE UNKNOWN`. A failed SSH or a dead Docker daemon yields `UNKNOWN`, and
that is **never** collapsed into "down" — an unreachable worker may be running
its rank perfectly well. Consequences:

* "nothing is running" is reported only when **both** ranks are verified down.
* An unreachable worker is never remotely stopped, and is reported as UNKNOWN
  with the command to check it by hand.
* After stopping, both ranks are **re-probed**. The success message appears only
  if both are then verified down with no errors; otherwise the script prints a
  `STOP INCOMPLETE OR UNVERIFIED` banner and **exits non-zero**.

Both containers were created with `--rm`, so stopping them **deletes** them.
There is no "start the container again" — recovery is a full
`scripts/40-start.sh --apply`.

`90-stop.sh` touches nothing else: not the image, not the model cache, not
NetworkManager, not the rails, not any other container.

---

## 4. Restore and rollback

> **There is no exact restore today.** The audited mods cannot be certified, so
> the best achievable outcome is a deployment that is explicitly and
> permanently marked NON-EXACT. Do not describe it otherwise.

There is no in-place rollback either, because there is no in-place upgrade: the
deployment is fully described by the pins in
[`config/pinned-artifacts.env`](../config/pinned-artifacts.env) and
[`config/mods-pins.env`](../config/mods-pins.env).

### Re-deploy this configuration

```bash
scripts/90-stop.sh --apply                 # if anything is running
scripts/10-fetch-image.sh --verify-only    # both nodes
scripts/20-fetch-model.sh --verify-only    # both nodes — snapshot, not refs/main
scripts/25-pin-mods.sh --verify-only       # both nodes
scripts/40-start.sh --apply                # EXACT, or refuses
#   ... or, knowingly:
scripts/40-start.sh --apply --non-exact-mods
scripts/60-verify-deployment.sh --peer
```

### Roll back from a different configuration to this one

1. Stop whatever is running (`scripts/90-stop.sh --apply`, or the other
   configuration's own stop procedure). Confirm it reports **both** ranks
   verified down; if it reports UNKNOWN, resolve that first.
2. Ensure the pinned image ID and the model **snapshot** are present on both
   nodes. `10-fetch-image.sh` and `20-fetch-model.sh` restore them; they never
   rewrite the pins to match whatever is on disk.
3. Certify mods with `scripts/25-pin-mods.sh`.
4. `scripts/40-start.sh --apply`, then `scripts/60-verify-deployment.sh --peer`.

Because the pins are content-addressed, a rollback either lands on
byte-identical artifacts or fails loudly. There is no partial state — except the
mods, where the honest answer is currently "unknown", and the tooling says so
rather than guessing.

### Reaching an exact deployment

1. Obtain the audited mod directories from the vendor.
2. Place them at `mods/instanttensor-hybrid-draft-loader/` and
   `mods/dsv4-reasoning-effort-fix/`, each with its `run.sh`.
3. `scripts/25-pin-mods.sh --apply` writes each `MOD.sha256` and prints the
   content digests.
4. Manually copy those digests into `config/mods-pins.env`, replacing
   `UNAVAILABLE` — **only** if you can independently confirm the directories are
   the audited ones. This step is manual on purpose: it is where a human asserts
   that specific bytes are the audited bytes.
5. `scripts/40-start.sh --apply` will then certify `EXACT` and launch without
   the override.

### If you must change a pin

Do not edit a pin to make a check pass. A mismatch means the deployment is not
this recipe. If you intend a genuinely different deployment, change the pin,
regenerate `SHA256SUMS`, re-run `scripts/validate.sh`, and re-do the capacity
and benchmark work: every number in
[04-capacity-and-health.md](04-capacity-and-health.md) and
[05-benchmarks-2026-08-23.md](05-benchmarks-2026-08-23.md) is specific to these
artifacts.

---

## 5. Troubleshooting

### `40-start.sh` refuses to run

| Message | Meaning | Fix |
|---|---|---|
| *refusing to launch: exact mod certification is not achievable* | Expected today. The audited mod digests are `UNAVAILABLE`. | Either certify real mods (§4) or re-run with `--non-exact-mods`. |
| *mods/ contains content this recipe does not declare* | An undeclared directory or a stray executable under `mods/`. | Remove it. This recipe applies exactly two mods. |
| *cannot identify this host* | Neither the primary nor the worker address pair is present. | Run on the right node, or correct `config/cluster.env`. |
| *AMBIGUOUS node identity* | The host matches both roles. | Fix `config/cluster.env` or the host's addresses. |
| *must run on the primary* | You are on the worker. | Run from the primary; it drives the worker over SSH. |
| *image … resolves to … but this recipe is pinned to …* | Wrong image. | `scripts/10-fetch-image.sh --apply`. Never edit the pin. |
| *worker image is … , primary/pin is …* | The nodes disagree. | Re-fetch on the mismatched node. |
| *the pinned model revision … is not properly materialised* | The snapshot is missing or incomplete — a correct `refs/main` does not change this. | `scripts/20-fetch-model.sh --apply`. |
| *container … is already running* | A deployment is live. | `scripts/90-stop.sh --apply` first. |
| *fabric interface … MTU …, expected 9000* | Rail misconfigured. | `scripts/05-setup-network.sh --rail both` (plan), then `--apply`. |
| *refusing to proceed without confirmation (stdin is not a TTY)* | Running non-interactively. | Review the dry-run output, then re-run with `--apply --yes`. |

### `PARTIAL DEPLOYMENT` banner

The run failed after dispatching at least one engine. Nothing was removed. Read
the banner for exactly what exists, inspect the logs, then:

```bash
docker logs vllm_node          # on each node
scripts/90-stop.sh --apply     # coordinated stop of both ranks
```

### `STOP INCOMPLETE OR UNVERIFIED` banner

`90-stop.sh` could not verify that both ranks are down. It will not claim they
are. Resolve each rank by hand:

```bash
docker ps --filter name=vllm_node
ssh 192.168.1.152 docker ps --filter name=vllm_node
```

### The cluster starts but the API never comes up

1. `docker logs -f vllm_node` on **both** nodes. Rank 1's log carries the KV
   sizing and graph capture messages.
2. Confirm rank 1 actually started, and started **first**. If rank 0 opened the
   rendezvous with no peer, it will sit waiting on `10.0.7.1:29501`.
3. Check the rail end to end: `ping -M do -s 8972 -c 3 10.0.7.2` from the
   primary, and `scripts/05-setup-network.sh --rail both --verify` on both.
4. Remember cold start is minutes. Do not conclude failure at 60 seconds.

### Verification says NON-EXACT or UNCERTIFIED

* **NON-EXACT** — the deployment was launched with `--non-exact-mods`. Expected,
  if that is what you did. It is not an exact reproduction and must not be
  described as one.
* **UNCERTIFIED** — no marker file in the container, meaning it was not started
  by `scripts/40-start.sh`. Nothing is known about its mods. Stop it and start
  it through the bundle.
* **ranks disagree on mod certification** — the two ranks were started
  differently. Stop both and start again.

### Verification says the peer is unreachable

That is a verification failure, not a warning. Fix SSH, then re-run. A rank you
cannot inspect is a rank you cannot vouch for.

### The worker is listening on 8888

Rank 1 must run `--headless`. `scripts/60-verify-deployment.sh` fails this case
explicitly on the worker.

### One rank died

The surviving rank cannot serve. The API port may still be bound while every
request that needs the dead rank hangs or errors. There is no auto-recovery.

```bash
scripts/90-stop.sh --apply      # completes the half-stop, verifying both ranks
scripts/40-start.sh --apply     # full restart of both ranks
```

### `max_model_len` came up different from 1,048,576

Expected. `--max-model-len auto` is resolved from free memory at startup. See
[04-capacity-and-health.md](04-capacity-and-health.md).

### Preemptions are climbing

The audited profile ran at **zero cumulative preemptions**. Sustained preemption
means the KV pool is oversubscribed — too many concurrent long-context requests
for a 17.14 GiB limiting-rank pool. Reduce concurrency or context length.
Changing `--gpu-memory-utilization` puts you outside this recipe.

### `_memdescAllocInternal` NVRM warnings

Expected. They occurred during the audited runs and were explicitly accepted by
operator directive.

### The container refuses to start with an NVIDIA driver requirement error

The image declares `NVIDIA_REQUIRE_CUDA` bands up to `driver<576`, while the
audited hosts run `580.173.02`. The live deployment ran regardless. If your
container toolkit enforces the constraint you may need `NVIDIA_DISABLE_REQUIRE=1`
— add it only if your toolkit actually refuses.

---

## 6. Validating this bundle

```bash
scripts/validate.sh          # syntax, structure, checksums, placeholders, secrets
scripts/validate.sh -v       # verbose
```

Runs offline, needs no cluster, and is safe anywhere. See
[`MANIFEST.md`](../MANIFEST.md) for what it checks.
