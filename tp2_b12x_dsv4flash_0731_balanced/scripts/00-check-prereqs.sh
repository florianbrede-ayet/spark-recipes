#!/bin/bash
# ---------------------------------------------------------------------------
# 00-check-prereqs.sh — read-only preflight for one node.
#
# Changes nothing, ever. There is no --apply for this script.
# Compares the local host against the audited reproduction envelope and prints
# a PASS/WARN/FAIL line per item. Exits non-zero if a hard requirement fails.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: 00-check-prereqs.sh [--strict]

  --strict   Treat WARN items as failures.

Read-only. Never mutates the host.
USAGE
}

STRICT="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict) STRICT="true" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (this script never mutates; see --help)" ;;
    esac
    shift
done

FAILED=0
WARNED=0
pass() { ok   "$*"; }
soft() { warn "$*"; WARNED=$((WARNED + 1)); }
hard() { printf '[fail] %s\n' "$*" >&2; FAILED=$((FAILED + 1)); }

load_pins
load_cluster

hdr "Platform"
ARCH="$(uname -m)"
[[ "$ARCH" == "aarch64" ]] && pass "architecture ${ARCH}" \
    || hard "architecture ${ARCH}; this recipe is arm64/aarch64 only (audited: aarch64)"

KREL="$(uname -r)"
info "kernel ${KREL} (audited: 6.17.0-1029-nvidia)"
[[ "$KREL" == *nvidia* ]] && pass "NVIDIA-flavoured kernel" \
    || soft "kernel is not an NVIDIA DGX OS flavour; audited hosts ran 6.17.0-1029-nvidia"

if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    info "os ${PRETTY_NAME:-unknown} (audited: Ubuntu 24.04.4 LTS / noble)"
    [[ "${VERSION_ID:-}" == "24.04" ]] && pass "Ubuntu 24.04 series" \
        || soft "OS is not Ubuntu 24.04; audited hosts ran 24.04.4 LTS"
else
    soft "/etc/os-release unreadable"
fi

hdr "GPU and driver"
if command -v nvidia-smi >/dev/null 2>&1; then
    GPUINFO="$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
    info "gpu: ${GPUINFO:-unreadable} (audited: NVIDIA GB10, 580.173.02)"
    [[ "$GPUINFO" == *GB10* ]] && pass "GB10 present" \
        || hard "no GB10 GPU reported; this recipe targets GB10 / SM121 (compute 12.1a) only"
    DRV="${GPUINFO##*, }"
    [[ "$DRV" == "580.173.02" ]] && pass "driver 580.173.02 (exact audited match)" \
        || soft "driver ${DRV:-unknown}; audited 580.173.02. B12X kernels are driver-sensitive."
else
    hard "nvidia-smi not found"
fi

hdr "Container runtime"
if command -v docker >/dev/null 2>&1; then
    DCLIENT="$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo unknown)"
    DSERVER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
    info "docker client=${DCLIENT} server=${DSERVER} (audited: 29.2.1 / 29.2.1)"
    [[ "$DSERVER" == "29.2.1" ]] && pass "docker 29.2.1 (exact audited match)" \
        || soft "docker server ${DSERVER}; audited 29.2.1"
    docker info >/dev/null 2>&1 && pass "docker daemon reachable by this user" \
        || hard "cannot talk to the docker daemon (is this user in the docker group?)"
else
    hard "docker not found"
fi

hdr "Node identity"
if have_ipv4 "$PRIMARY_MGMT_IP" && have_ipv4 "$PRIMARY_FABRIC_IP"; then
    pass "identified as PRIMARY (rank 0): ${PRIMARY_MGMT_IP} / ${PRIMARY_FABRIC_IP}"
elif have_ipv4 "$WORKER_MGMT_IP" && have_ipv4 "$WORKER_FABRIC_IP"; then
    pass "identified as WORKER (rank 1): ${WORKER_MGMT_IP} / ${WORKER_FABRIC_IP}"
else
    hard "host matches neither the primary nor the worker identity in config/cluster.env"
fi

hdr "Fabric — rail A (used by the job)"
if have_iface "$FABRIC_ETH_IF"; then
    ST="$(iface_state "$FABRIC_ETH_IF")"; MTU="$(iface_mtu "$FABRIC_ETH_IF")"; ADDR="$(iface_ipv4 "$FABRIC_ETH_IF")"
    [[ "$ST" == "UP" ]] && pass "${FABRIC_ETH_IF} UP" || hard "${FABRIC_ETH_IF} is ${ST}, expected UP"
    [[ "$MTU" == "$FABRIC_MTU" ]] && pass "${FABRIC_ETH_IF} MTU ${MTU}" || hard "${FABRIC_ETH_IF} MTU ${MTU}, expected ${FABRIC_MTU}"
    [[ -n "$ADDR" ]] && pass "${FABRIC_ETH_IF} address ${ADDR}" || hard "${FABRIC_ETH_IF} has no IPv4 address"
else
    hard "rail-A interface ${FABRIC_ETH_IF} not present"
fi
RA="$(rdma_state "$FABRIC_IB_IF")"
case "$RA" in
    ACTIVE)  pass "RDMA ${FABRIC_IB_IF} ACTIVE" ;;
    unknown) soft "rdma(8) unavailable; cannot check ${FABRIC_IB_IF}" ;;
    *)       hard "RDMA ${FABRIC_IB_IF} state '${RA:-missing}', expected ACTIVE" ;;
esac

hdr "Fabric — rail B (present, deliberately unused)"
# ipv4_to_int / in_same_subnet let us prove the two rails are on distinct
# networks instead of eyeballing the octets.
ipv4_to_int() {
    local IFS=. a b c d
    read -r a b c d <<<"${1%%/*}"
    printf '%s' "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}
in_same_subnet() {  # <addr> <cidr>
    local ai ni plen mask
    plen="${2##*/}"
    ai="$(ipv4_to_int "$1")"; ni="$(ipv4_to_int "$2")"
    mask=$(( plen == 0 ? 0 : (0xFFFFFFFF << (32 - plen)) & 0xFFFFFFFF ))
    [[ $(( ai & mask )) -eq $(( ni & mask )) ]]
}

if have_iface "$FABRIC_B_ETH_IF"; then
    B_STATE="$(iface_state "$FABRIC_B_ETH_IF")"
    B_MTU="$(iface_mtu "$FABRIC_B_ETH_IF")"
    BADDR="$(iface_ipv4 "$FABRIC_B_ETH_IF")"
    info "${FABRIC_B_ETH_IF} ${B_STATE:-?} mtu ${B_MTU:-?} addr ${BADDR:-none}"
    if [[ -n "$BADDR" ]]; then
        if in_same_subnet "$BADDR" "$FABRIC_SUBNET"; then
            hard "rail B address ${BADDR} is inside rail A's ${FABRIC_SUBNET}; the two rails must never share a subnet"
        else
            pass "rail B ${BADDR} is outside rail A ${FABRIC_SUBNET}"
        fi
        [[ "$B_MTU" == "$FABRIC_B_MTU" ]] && pass "rail B MTU ${B_MTU}" \
            || soft "rail B MTU ${B_MTU}, documented ${FABRIC_B_MTU}"
    fi
else
    soft "rail-B interface ${FABRIC_B_ETH_IF} not present (the job does not need it)"
fi

hdr "Ports"
if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | grep -qE "[:.]${API_PORT}[[:space:]]"; then
        soft "TCP ${API_PORT} already has a listener — a deployment may already be running"
    else
        pass "TCP ${API_PORT} free"
    fi
    if ss -ltn 2>/dev/null | grep -qE "[:.]${MASTER_PORT}[[:space:]]"; then
        soft "TCP ${MASTER_PORT} (rendezvous) already has a listener"
    else
        pass "TCP ${MASTER_PORT} free"
    fi
else
    soft "ss(8) not available; skipped port checks"
fi

hdr "Storage"
CR="${CACHE_ROOT:-$HOME}"
AVAIL_KB="$(df -Pk "$CR" 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -n "${AVAIL_KB:-}" ]]; then
    AVAIL_GIB=$(( AVAIL_KB / 1024 / 1024 ))
    info "free space on ${CR}: ${AVAIL_GIB} GiB"
    # The image alone is 23,362,056,860 bytes (~21.8 GiB) and the model plus the
    # vLLM/FlashInfer/Triton/TileLang caches are far larger again.
    if (( AVAIL_GIB < 400 )); then
        soft "under 400 GiB free. The image is ~21.8 GiB and the gated model plus warm caches are much larger; sizing is your responsibility."
    else
        pass "plenty of headroom for image + model + caches"
    fi
fi

hdr "Summary"
printf 'hard failures: %d, warnings: %d\n' "$FAILED" "$WARNED"
if (( FAILED > 0 )); then
    die "preflight failed. Do not assume this node can reproduce the recipe."
fi
if [[ "$STRICT" == "true" && $WARNED -gt 0 ]]; then
    die "preflight has ${WARNED} warning(s) and --strict was requested."
fi
ok "preflight passed (warnings are not the same as an exact environment match — read docs/02-prerequisites-and-limitations.md)"
