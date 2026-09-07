# Rank differences — intentional, incidental, and forbidden

The two nodes run the same image, the same recipe and nearly the same command.
The differences that exist fall into three groups, and it matters which is
which.

---

## 1. Intentional — these differences are the design

| Aspect | Rank 0 (primary) | Rank 1 (worker) |
|---|---|---|
| Management address | `192.168.1.151` | `192.168.1.152` |
| Fabric (rail A) address | `10.0.7.1/30` | `10.0.7.2/30` |
| `--node-rank` | `0` | `1` |
| `--headless` | **absent** | **present** |
| API listener | `0.0.0.0:8888` | **none** |
| Processes | `APIServer`, `VLLM::EngineCore`, `VLLM::Worker_TP0` | `VLLM::Worker_TP1` only |
| `VLLM_HOST_IP` | `10.0.7.1` | `10.0.7.2` |
| `RAY_NODE_IP_ADDRESS` / `RAY_OVERRIDE_NODE_IP_ADDRESS` | `10.0.7.1` | `10.0.7.2` |
| Role in launch sequence | dispatched **second** | dispatched **first** |
| Role in stop sequence | stopped **first** | stopped **second** |
| Rail B address | `10.0.7.5/30` | `10.0.7.6/30` |

Shared by both, identically: `--nnodes 2`, `--master-addr 10.0.7.1`,
`--master-port 29501`, `--tensor-parallel-size 2`, the image ID, the model
revision, every recipe environment variable, every interface variable
(`NCCL_SOCKET_IFNAME` etc. = `enp1s0f0np0`, `NCCL_IB_HCA` = `rocep1s0f0`), the
container name, the five bind mounts, and the full privileged/host-network/
host-IPC/`nofile 1048576` runtime configuration.

### Primary-only API behaviour

Only rank 0 serves HTTP. The audit shows the worker with **no listening sockets
at all**. Consequences:

* Point clients, health checks and any load balancer at the **primary only**.
* A listener on `8888` on the worker means rank 1 is not headless — that is a
  fault. `scripts/60-verify-deployment.sh` fails on it.
* Rank 1 being "silent" is not a sign it is unhealthy. Check it with
  `docker exec`/process presence and RDMA state, not with HTTP.

### Launch order

Rank 1 first, rank 0 second, so the worker is waiting when the primary opens the
rendezvous store. In the audited run the two serving processes appear about one
second apart in the process table, because SSH dispatch latency partly cancels
the ordering. The dispatch order is the guarantee; the wall-clock start is not.

Container *creation* went the other way in the audited run — primary at
`11:40:09.788`, worker at `11:40:10.679` — because the containers start idle
(`sleep infinity`) and the serving processes are injected afterwards. Creation
order carries no semantics.

`scripts/40-start.sh` deliberately creates the **worker first**, which is the one
place it departs from the audited sequence. Because both containers are idle at
that point the choice is free, and it makes failure handling cleaner: if the
primary container cannot be created, exactly one container exists to undo. Launch
order — worker before primary — is unchanged and *is* load-bearing.

### Stop order

Rank 0 first (removes the endpoint from service), then rank 1. See
[06-operations-runbook.md](06-operations-runbook.md).

---

## 2. Incidental — real, observed, and not a problem

**Registry digest presence.** The primary's image carried
`RepoDigests: ["eugr/spark-vllm-b12x@sha256:eb3ed2bb…dd2c5"]`; the worker's
`RepoDigests` was **empty**. Both nodes resolved to the identical image ID
`sha256:d43f15877df4…a65f5db2`.

That is the signature of an image that was *pulled* on one node and
*transferred* (`docker save` / `docker load`) to the other. It is exactly why
the **image ID, not the digest, is the cross-node check**:
`scripts/40-start.sh` compares IDs across both nodes, and
`scripts/60-verify-deployment.sh` reports a missing digest as informational
rather than a failure.

**Bind-mount ordering.** `docker inspect` lists the five binds in a different
order on each node. Cosmetic; the set is identical.

**Available KV memory.** Rank 0 got 19.27 GiB, rank 1 got 17.14 GiB, and the
CUDA-graph estimates differed (0.17 vs 0.71 GiB). This is structural, not a
misconfiguration: rank 1 also carries the DSpark draft model's capture, and
non-torch/activation peaks differ per rank. **The smaller rank governs the
cluster's KV pool** — 2,356,056 logical tokens. Expect asymmetry; expect it to
vary by boot. See [04-capacity-and-health.md](04-capacity-and-health.md).

**Unrelated host state.** The primary had an extra Docker bridge from an
unrelated compose project and a dashboard listener on `192.168.1.151:3000`.
Neither is part of this recipe.

**GPU temperature.** 45 °C vs 44 °C at capture time. Noise.

---

## 3. Forbidden — differences that mean something is wrong

| Difference | Why it is a fault |
|---|---|
| Different image **ID** between nodes | Different code on each rank. `40-start.sh` refuses to start. |
| Different model **revision** between nodes | Different weights or different `trust-remote-code` code. Refused. |
| Both ranks `--headless`, or neither | No API server, or two engines fighting over one TP group. |
| Rank 1 listening on `8888` | Not headless; the topology is wrong. |
| Different `--master-addr` / `--master-port` | The ranks will never meet. |
| Different `NCCL_IB_HCA` or `NCCL_SOCKET_IFNAME` | Split-brain fabric selection; at best slow, at worst hung collectives. |
| Rail A and rail B on the same subnet on either node | ARP flux and non-deterministic rail selection. See [01-network.md](01-network.md). |
| Different recipe environment (`VLLM_*`, `B12X_*`) between ranks | Ranks compile and capture differently; undefined behaviour. |
| One rank running, the other not | A broken collective behind a possibly-still-bound API port. Stop both, start both. |

`scripts/60-verify-deployment.sh --peer` checks every row of this table that can
be observed from the primary.
