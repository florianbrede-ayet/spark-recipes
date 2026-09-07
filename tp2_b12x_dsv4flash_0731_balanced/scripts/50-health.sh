#!/bin/bash
# ---------------------------------------------------------------------------
# 50-health.sh — read-only health and capacity probe.
#
# Never mutates anything; there is no --apply. Safe to run against a live
# deployment. It only issues GETs against the local API and read-only docker /
# ip / rdma queries.
#
# By default it does NOT send an inference request. --smoke adds one tiny
# completion, which does consume a few tokens of real capacity.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: 50-health.sh [--smoke] [--host <addr>] [--port <n>]

  --smoke        Also send one 8-token completion request (consumes capacity).
  --host/--port  Override the API endpoint. Default 127.0.0.1:8888.

Read-only. There is no --apply.
USAGE
}

SMOKE="false"
H="127.0.0.1"
P=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --smoke) SMOKE="true" ;;
        --host)  H="${2:-}"; shift ;;
        --port)  P="${2:-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

load_pins
load_cluster
P="${P:-$API_PORT}"
BASE="http://${H}:${P}"
RC=0
bad() { warn "$*"; RC=1; }

hdr "Node"
if have_ipv4 "$PRIMARY_FABRIC_IP"; then WHO="primary (rank 0)"
elif have_ipv4 "$WORKER_FABRIC_IP"; then WHO="worker (rank 1)"
else WHO="unrecognised"; fi
info "role: ${WHO}"

hdr "Containers"
if command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        ok "container ${CONTAINER_NAME} running"
        IMG="$(docker inspect --format '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
        if [[ "$IMG" == "$PIN_IMAGE_ID" ]]; then
            ok "running the pinned image ${PIN_IMAGE_ID}"
        else
            bad "container image is ${IMG}, pin is ${PIN_IMAGE_ID}"
        fi
        for f in '{{.HostConfig.NetworkMode}}=host' '{{.HostConfig.IpcMode}}=host' '{{.HostConfig.Privileged}}=true'; do
            key="${f%%=*}"; want="${f##*=}"
            got="$(docker inspect --format "$key" "$CONTAINER_NAME" 2>/dev/null || true)"
            [[ "$got" == "$want" ]] && ok "${key} = ${got}" || bad "${key} = ${got}, expected ${want}"
        done
        NOF="$(docker inspect --format '{{range .HostConfig.Ulimits}}{{if eq .Name "nofile"}}{{.Soft}}:{{.Hard}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
        [[ "$NOF" == "${PIN_NOFILE_LIMIT}:${PIN_NOFILE_LIMIT}" ]] && ok "nofile ulimit ${NOF}" || bad "nofile ulimit ${NOF:-unset}, expected ${PIN_NOFILE_LIMIT}:${PIN_NOFILE_LIMIT}"
        PROCS="$(docker exec "$CONTAINER_NAME" ps -eo args 2>/dev/null | grep -c 'vllm serve' || true)"
        [[ "${PROCS:-0}" -ge 1 ]] && ok "vllm serve process present" || bad "no 'vllm serve' process inside the container"
    else
        bad "container ${CONTAINER_NAME} is not running on this node"
    fi
else
    warn "docker not available; skipping container checks"
fi

hdr "Fabric"
for pair in "${FABRIC_ETH_IF}:${FABRIC_IB_IF}:rail-A(in use)" "${FABRIC_B_ETH_IF}:${FABRIC_B_IB_IF}:rail-B(idle)"; do
    IFS=: read -r eth ib label <<<"$pair"
    if have_iface "$eth"; then
        info "${label}: ${eth} $(iface_state "$eth") mtu $(iface_mtu "$eth") addr $(iface_ipv4 "$eth") | ${ib} $(rdma_state "$ib")"
    else
        info "${label}: ${eth} absent"
    fi
done

hdr "API (rank 0 only)"
if [[ "$WHO" == "worker (rank 1)" ]]; then
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE "[:.]${P}[[:space:]]"; then
        bad "the worker is listening on ${P}. Rank 1 runs --headless and must NOT serve the API."
    else
        ok "worker has no API listener — correct for a headless rank"
    fi
    hdr "Summary"; [[ $RC -eq 0 ]] && ok "worker healthy" || warn "worker checks reported problems"
    exit "$RC"
fi

need_cmd curl
if ! curl -fsS --max-time 10 "${BASE}/health" >/dev/null 2>&1; then
    bad "${BASE}/health did not return 200"
else
    ok "${BASE}/health 200"
fi

MODELS="$(curl -fsS --max-time 10 "${BASE}/v1/models" 2>/dev/null || true)"
if [[ -n "$MODELS" ]]; then
    if command -v jq >/dev/null 2>&1; then
        MID="$(printf '%s' "$MODELS" | jq -r '.data[0].id // empty')"
        MLEN="$(printf '%s' "$MODELS" | jq -r '.data[0].max_model_len // empty')"
    else
        MID="$(printf '%s' "$MODELS" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
        MLEN="$(printf '%s' "$MODELS" | sed -n 's/.*"max_model_len":\([0-9]*\).*/\1/p' | head -1)"
    fi
    [[ "$MID" == "$PIN_MODEL_REPO" ]] && ok "served model ${MID}" || bad "served model '${MID}', expected ${PIN_MODEL_REPO}"
    if [[ -n "${MLEN:-}" ]]; then
        [[ "$MLEN" == "$PIN_API_MAX_MODEL_LEN" ]] \
            && ok "max_model_len ${MLEN} (matches the audited ceiling)" \
            || warn "max_model_len ${MLEN}; the audited boot resolved ${PIN_API_MAX_MODEL_LEN}. 'auto' is memory-dependent, so a difference means this boot has a different KV budget."
    fi
else
    bad "${BASE}/v1/models unreachable"
fi

hdr "Capacity counters"
METRICS="$(curl -fsS --max-time 10 "${BASE}/metrics" 2>/dev/null || true)"
if [[ -n "$METRICS" ]]; then
    grep -E '^vllm:(num_requests_running|num_requests_waiting|gpu_cache_usage_perc|num_preemptions_total|gpu_prefix_cache_hit_rate|spec_decode_num_(draft|accepted)_tokens_total)' <<<"$METRICS" \
        | sed 's/^/  /' || true
    PREEMPT="$(grep -E '^vllm:num_preemptions_total' <<<"$METRICS" | awk '{print $NF}' | head -1 || true)"
    if [[ -n "${PREEMPT:-}" ]]; then
        case "$PREEMPT" in
            0|0.0) ok "cumulative preemptions 0" ;;
            *)     warn "cumulative preemptions ${PREEMPT}; the audited profile ran at zero. Sustained preemption means the KV pool is oversubscribed for the offered load." ;;
        esac
    fi
else
    warn "${BASE}/metrics unreachable"
fi
info "reference capacity from the audited boot: API ceiling ${PIN_API_MAX_MODEL_LEN} tokens per request;"
info "limiting KV pool ${PIN_LIMITING_KV_TOKENS} logical tokens shared across all ${PIN_MODEL_REPO} requests."
info "See docs/04-capacity-and-health.md before comparing these numbers to anything."

if [[ "$SMOKE" == "true" ]]; then
    hdr "Smoke (consumes capacity)"
    OUT="$(curl -fsS --max-time 120 "${BASE}/v1/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${PIN_MODEL_REPO}\",\"prompt\":\"ping\",\"max_tokens\":8,\"temperature\":0}" 2>/dev/null || true)"
    [[ -n "$OUT" ]] && ok "completion returned $(printf '%s' "$OUT" | wc -c) bytes" || bad "smoke completion failed"
fi

hdr "Summary"
if [[ $RC -eq 0 ]]; then ok "primary healthy"; else warn "primary checks reported problems"; fi
exit "$RC"
