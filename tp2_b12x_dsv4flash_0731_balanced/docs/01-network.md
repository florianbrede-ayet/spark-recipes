# Network

Three independent networks are involved. Only one of them carries the job.

```
                    192.168.1.0/24  (management, DHCP, default route)
                          |                          |
                    enP7s7|192.168.1.151       enP7s7|192.168.1.152
                  +-------+--------+          +------+---------+
                  |   PRIMARY      |          |    WORKER      |
                  |   rank 0       |          |    rank 1      |
                  +---+--------+---+          +---+--------+---+
   rail A  enp1s0f0np0 |        | enP2p1s0f0np0   |        |
           10.0.7.1/30 |        | 10.0.7.5/30     |        |
                       |        |                 |        |
        10.0.7.0/30 <--+--------|-----------------+        |   rail A: IN USE
                                |                          |
        10.0.7.4/30 <-----------+--------------------------+   rail B: IDLE
                       10.0.7.2/30            10.0.7.6/30
                       (worker rail A)        (worker rail B)
```

---

## 1. Management network — `enP7s7`

| Node | Address |
|---|---|
| Primary | `192.168.1.151/24` |
| Worker | `192.168.1.152/24` |

DHCP, default route `via 192.168.1.1 dev enP7s7`, route metric `102`. The
management NIC also carries IPv6 SLAAC/temporary addresses. This is the only
path used for SSH orchestration between the nodes.

**No script in this bundle ever reconfigures `enP7s7`.**

---

## 2. Rail A — the fabric the job actually uses

| Item | Primary | Worker |
|---|---|---|
| Ethernet interface | `enp1s0f0np0` | `enp1s0f0np0` |
| RDMA device | `rocep1s0f0` (ACTIVE, LINK_UP) | `rocep1s0f0` (ACTIVE, LINK_UP) |
| Address | `10.0.7.1/30` | `10.0.7.2/30` |
| Subnet | `10.0.7.0/30` | `10.0.7.0/30` |
| MTU | `9000` | `9000` |
| NetworkManager profile | `cx7-port0-a` | `cx7-port0-a` |
| IPv4 method | `manual` (static) | `manual` (static) |
| Gateway | none | none |
| IPv6 | `disabled` | `disabled` |
| Route metric | `101` | `101` |

Everything the distributed job does rides this rail:

* `--master-addr 10.0.7.1 --master-port 29501` — the torch.distributed rendezvous
* `VLLM_HOST_IP` = the node's own rail-A address
* `NCCL_SOCKET_IFNAME`, `GLOO_SOCKET_IFNAME`, `TP_SOCKET_IFNAME`,
  `UCX_NET_DEVICES`, `MN_IF_NAME`, `OMPI_MCA_btl_tcp_if_include` = `enp1s0f0np0`
* `NCCL_IB_HCA=rocep1s0f0`, `NCCL_IB_DISABLE=0` — RoCE is enabled and pinned to
  this one HCA

A `/30` gives exactly two usable addresses, which is what a point-to-point rail
between two nodes wants: there is no room for a third party and no ambiguity
about who the peer is.

---

## 3. Rail B — the twin, deliberately unused

| Item | Primary | Worker |
|---|---|---|
| Ethernet interface | `enP2p1s0f0np0` | `enP2p1s0f0np0` |
| RDMA device | `roceP2p1s0f0` (ACTIVE, LINK_UP) | `roceP2p1s0f0` (ACTIVE, LINK_UP) |
| Address | `10.0.7.5/30` | `10.0.7.6/30` |
| Subnet | `10.0.7.4/30` | `10.0.7.4/30` |
| MTU | `9000` | `9000` |
| NetworkManager profile | `cx7-port0-b` | `cx7-port0-b` |
| IPv4 method | `manual` (static) | `manual` (static) |
| Gateway | none | none |
| IPv6 | `disabled` | `disabled` |
| Route metric | `100` | `100` |

Rail B is cabled, up, and its RDMA link is ACTIVE — **and the job never touches
it.** No vLLM, NCCL, Gloo, UCX or OpenMPI variable references
`enP2p1s0f0np0` or `roceP2p1s0f0`. It is spare capacity, not a second rail the
current deployment is striping over.

Do not "fix" this by pointing `NCCL_IB_HCA` at both devices unless you are
prepared to re-benchmark: the audited numbers in
[05-benchmarks-2026-08-23.md](05-benchmarks-2026-08-23.md) were measured with a
single rail.

---

## 4. The two rails must never share a subnet

Rail A is `10.0.7.0/30`; rail B is `10.0.7.4/30`. Two distinct networks, by
design.

If both rails were given addresses in one subnet you would get:

* **Two routes to the same prefix.** The kernel picks one by metric, so all
  traffic silently collapses onto a single rail while both look "configured".
* **ARP flux.** With the default `arp_ignore`/`arp_announce` settings, either
  interface may answer for the other's address, so the peer's ARP cache decides
  which NIC is used — and it can change.
* **Non-deterministic NCCL rail selection.** NCCL matches its socket interface
  and its HCA independently; a shared subnet lets it pair the socket on one rail
  with the HCA on the other, which is slow and hard to diagnose.

`scripts/05-setup-network.sh` refuses to emit a plan if `config/cluster.env`
puts the two rails in one subnet, and `scripts/00-check-prereqs.sh` fails the
node if rail B's live address falls inside rail A's prefix. Both use exact
prefix arithmetic, not octet matching.

---

## 5. Down / unused ports

The second port of each dual-port card is cabled-down on both nodes:

```
enp1s0f1np1     DOWN  NO-CARRIER      rocep1s0f1     DOWN  physical_state DISABLED
enP2p1s0f1np1   DOWN  NO-CARRIER      roceP2p1s0f1   DOWN  physical_state DISABLED
```

This is the expected state, not a fault. `docker0` is also down/unused
(`--network host` means Docker's bridge plays no part). The primary
additionally had a `br-*` bridge from an unrelated compose project.

---

## 6. Reproducing the fabric

`scripts/05-setup-network.sh` **prints the planned `nmcli` commands and exits.**
It changes nothing without `--apply`, and `--apply` also demands an interactive
confirmation, because reconfiguring a rail bounces RDMA and can strand a remote
session.

**It defaults to `--rail both`.** The audited node carries both rails;
configuring only one leaves the cluster in a state this recipe never had.

Because network bootstrap by definition runs *before* the fabric exists, this is
the one script that identifies the node from **management identity only** — the
management IP, or an explicitly configured `PRIMARY_HOSTNAME`/`WORKER_HOSTNAME`
mapping as a fallback. Matching both roles, or neither, is fatal rather than a
guess. Every other script keeps its full fabric-based identity check; this
relaxation is local to bootstrap and does not weaken them.

```bash
# show the plan for both rails on whichever node you are on (default, safe)
scripts/05-setup-network.sh

# apply it (interactive confirmation required), then verify automatically
scripts/05-setup-network.sh --rail both --apply

# read-only re-check at any time
scripts/05-setup-network.sh --rail both --verify
```

The plan it prints is equivalent to:

```bash
sudo nmcli connection add type ethernet con-name cx7-port0-a ifname enp1s0f0np0 \
    connection.interface-name enp1s0f0np0 \
    ipv4.method manual ipv4.addresses 10.0.7.1/30 ipv4.gateway '' \
    ipv4.never-default yes ipv4.ignore-auto-dns yes ipv4.dns '' ipv4.dns-search '' \
    ipv4.route-metric 101 ipv6.method disabled \
    802-3-ethernet.mtu 9000 connection.autoconnect yes
sudo nmcli connection up cx7-port0-a
```

…with `10.0.7.2/30` on the worker, and `cx7-port0-b` / `enP2p1s0f0np0` /
`10.0.7.5/30` and `10.0.7.6/30` at **route metric 100** for rail B.

Every property above is audited state, and each one is re-read back during
verification:

| Property | Rail A | Rail B | Why |
|---|---|---|---|
| `ipv4.method` | `manual` | `manual` | a fabric rail must not depend on DHCP |
| `ipv4.addresses` | `10.0.7.1\|.2/30` | `10.0.7.5\|.6/30` | separate /30s, never one subnet |
| `802-3-ethernet.mtu` | `9000` | `9000` | jumbo frames end to end |
| `ipv4.gateway` | unset | unset | a rail is point-to-point, not a route to anywhere |
| `ipv4.never-default` | `yes` | `yes` | the rail must never become the default route |
| `ipv4.ignore-auto-dns` / `ipv4.dns` | `yes` / unset | `yes` / unset | a storage/compute rail contributes no DNS |
| `ipv4.route-metric` | `101` | `100` | distinct metrics, so neither rail can shadow the other |
| `ipv6.method` | `disabled` | `disabled` | no SLAAC addresses on the fabric |
| `connection.autoconnect` | `yes` | `yes` | the rail returns after a reboot |

### Verifying

```bash
scripts/05-setup-network.sh --rail both --verify   # profile properties + live state
```

which checks, per rail: the NM profile exists and every property above matches;
the link is UP with the right MTU and address; the connected route carries the
expected metric; the rail contributes **no** default route; and the RDMA device
is ACTIVE. By hand:

```bash
ip -o -4 addr show enp1s0f0np0      # expect 10.0.7.1/30 or 10.0.7.2/30
ip -o link show enp1s0f0np0         # expect mtu 9000, state UP
ip -4 route show dev enp1s0f0np0    # expect metric 101 (rail B: 100)
ip -4 route show default            # must not name either rail
rdma link show                      # expect rocep1s0f0 state ACTIVE
ping -M do -s 8972 -c 3 10.0.7.2    # 9000-byte MTU end to end (8972 + 28 header)
```

`scripts/00-check-prereqs.sh` runs the equivalent checks and fails hard on a
wrong MTU, a down interface, a non-ACTIVE RDMA link, or a rail-B address that
has leaked into rail A's subnet.

---

## 7. Ports

| Port | Bound on | Purpose | Exposure |
|---|---|---|---|
| `29501` | primary, rail A (`10.0.7.1`) | torch.distributed rendezvous | fabric only |
| `8888` | primary, **`0.0.0.0`** | OpenAI-compatible API | **every interface, no auth, no TLS** |

`8888` is bound on `0.0.0.0` with `--network host`, so it is reachable on the
management address too. There is no authentication and no TLS. Treat the
management network as trusted or put your own gateway in front — see
[02-prerequisites-and-limitations.md](02-prerequisites-and-limitations.md).
