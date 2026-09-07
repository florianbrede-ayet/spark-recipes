#!/bin/bash
# ---------------------------------------------------------------------------
# 60-verify-deployment.sh — prove a running deployment IS this recipe.
#
# Strictly read-only. There is no --apply and no code path that mutates
# anything: only `docker inspect` / `docker exec ... cat|ps|test`, `ip`, `ss`,
# `rdma` and file reads. Safe against a live serving cluster.
#
# WHOLE-CLUSTER VERIFICATION
#   The entire check set lives in one probe (PROBE_BODY below) that reads its
#   expectations from environment variables. The same probe text is piped to
#   `bash -s` locally and, with --peer, to `ssh <worker> bash -s`. Both ranks
#   therefore run byte-identical checks, and a worker failure is a failure of
#   the whole run — --peer is not a courtesy summary, it is verification.
#
# WHAT IT REFUSES TO EXCUSE
#   * a missing or not-running container is a FAILURE, never a skip
#   * a peer that cannot be reached is a FAILURE, never "assumed fine"
#   * a NON-EXACT mod certification fails exact verification, always
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: 60-verify-deployment.sh [--peer] [--allow-non-exact]

  --peer              Also run the identical probe on the worker over SSH and
                      fail this run if the worker fails. Primary only.
  --allow-non-exact   Downgrade the NON-EXACT mod certification failure to a
                      loud warning. The report still says NON-EXACT.

Read-only. There is no --apply.
USAGE
}

PEER="false"
ALLOW_NON_EXACT="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --peer) PEER="true" ;;
        --allow-non-exact) ALLOW_NON_EXACT="true" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

load_pins
load_cluster
load_mod_pins

# ---------------------------------------------------------------------------
# The probe. Static text: it reads everything it needs from the environment,
# so it can be shipped to any node without re-quoting.
# ---------------------------------------------------------------------------
read -r -d '' PROBE_BODY <<'PROBE_EOF' || true
set -uo pipefail

FAILS=0
emit() { printf 'CHECK|%s|%s|%s\n' "$1" "$2" "${3//$'\n'/ }"; [[ "$1" == "FAIL" ]] && FAILS=$((FAILS+1)); return 0; }
eq()   { if [[ "$2" == "$3" ]]; then emit PASS "$1" "$2"; else emit FAIL "$1" "got '${2:-<missing>}', expected '$3'"; fi; }

need() { command -v "$1" >/dev/null 2>&1; }

# --- container must exist and be running -----------------------------------
if ! need docker; then
    emit FAIL "docker.available" "docker is not installed on this node"
    printf 'RESULT|%s|UNKNOWN\n' "$FAILS"; exit 0
fi
STATE="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"
if [[ -z "$STATE" ]]; then
    emit FAIL "container.exists" "container '${CONTAINER_NAME}' does not exist on this node"
    printf 'RESULT|%s|UNKNOWN\n' "$FAILS"; exit 0
fi
eq "container.running" "$STATE" "running"
if [[ "$STATE" != "running" ]]; then
    printf 'RESULT|%s|UNKNOWN\n' "$FAILS"; exit 0
fi

di() { docker inspect --format "$1" "$CONTAINER_NAME" 2>/dev/null; }

# --- image snapshot ---------------------------------------------------------
eq "image.container"  "$(di '{{.Image}}')"                                  "$EXPECT_IMAGE_ID"
eq "image.local_tag"  "$(docker image inspect --format '{{.Id}}' "$EXPECT_IMAGE_TAG" 2>/dev/null || true)" "$EXPECT_IMAGE_ID"
eq "image.arch"       "$(docker image inspect --format '{{.Architecture}}' "$EXPECT_IMAGE_ID" 2>/dev/null || true)" "$EXPECT_IMAGE_ARCH"
eq "image.size"       "$(docker image inspect --format '{{.Size}}' "$EXPECT_IMAGE_ID" 2>/dev/null || true)"         "$EXPECT_IMAGE_SIZE"
DIGESTS="$(docker image inspect --format '{{join .RepoDigests ","}}' "$EXPECT_IMAGE_ID" 2>/dev/null || true)"
if [[ "$DIGESTS" == *"$EXPECT_IMAGE_DIGEST"* ]]; then
    emit PASS "image.repo_digest" "$EXPECT_IMAGE_DIGEST"
else
    emit WARN "image.repo_digest" "absent (RepoDigests: ${DIGESTS:-none}) — expected on a node whose copy was loaded, not pulled; the image ID above is authoritative"
fi

# --- required runtime configuration ----------------------------------------
eq "runtime.network"     "$(di '{{.HostConfig.NetworkMode}}')"   "host"
eq "runtime.ipc"         "$(di '{{.HostConfig.IpcMode}}')"       "host"
eq "runtime.privileged"  "$(di '{{.HostConfig.Privileged}}')"    "true"
eq "runtime.readonly_rootfs" "$(di '{{.HostConfig.ReadonlyRootfs}}')" "false"
eq "runtime.runtime"     "$(di '{{.HostConfig.Runtime}}')"       "runc"
eq "runtime.workdir"     "$(di '{{.Config.WorkingDir}}')"        "$EXPECT_WORKDIR"
eq "runtime.cmd"         "$(di '{{join .Config.Cmd " "}}')"      "sleep infinity"
eq "runtime.entrypoint"  "$(di '{{if .Config.Entrypoint}}set{{else}}cleared{{end}}')" "cleared"
eq "runtime.nofile"      "$(di '{{range .HostConfig.Ulimits}}{{if eq .Name "nofile"}}{{.Soft}}:{{.Hard}}{{end}}{{end}}')" "${EXPECT_NOFILE}:${EXPECT_NOFILE}"

# --- exactly five bind mounts, each source/destination/type/RW --------------
MOUNT_DESTS="/root/.cache/huggingface /root/.cache/vllm /root/.cache/flashinfer /root/.triton /root/.tilelang"
MOUNT_RELS=".cache/huggingface .cache/vllm .cache/flashinfer .triton .tilelang"
N_MOUNTS="$(di '{{len .Mounts}}')"
eq "mounts.count" "${N_MOUNTS:-0}" "5"

ROOTS=""
set -- $MOUNT_DESTS
for rel in $MOUNT_RELS; do
    dest="$1"; shift
    line="$(docker inspect --format "{{range .Mounts}}{{if eq .Destination \"${dest}\"}}{{.Type}}|{{.Source}}|{{.RW}}{{end}}{{end}}" "$CONTAINER_NAME" 2>/dev/null)"
    if [[ -z "$line" ]]; then
        emit FAIL "mount${dest}" "no mount at this destination"
        continue
    fi
    m_type="${line%%|*}"; rest="${line#*|}"; m_src="${rest%%|*}"; m_rw="${rest##*|}"
    [[ "$m_type" == "bind" ]] || emit FAIL "mount${dest}.type" "got '${m_type}', expected 'bind'"
    [[ "$m_rw"   == "true" ]] || emit FAIL "mount${dest}.rw"   "got '${m_rw}', expected read-write"
    if [[ "$m_src" == *"/${rel}" ]]; then
        emit PASS "mount${dest}" "bind rw from ${m_src}"
        ROOTS="${ROOTS} ${m_src%"/${rel}"}"
    else
        emit FAIL "mount${dest}.source" "source '${m_src}' does not end with '/${rel}'"
    fi
done
UNIQ_ROOTS="$(printf '%s\n' $ROOTS | sort -u | tr '\n' ' ')"
UNIQ_N="$(printf '%s\n' $ROOTS | sort -u | grep -c . || true)"
if [[ "${UNIQ_N:-0}" == "1" ]]; then
    emit PASS "mounts.common_root" "${UNIQ_ROOTS% }"
    [[ -n "${EXPECT_MOUNT_ROOT:-}" && "${UNIQ_ROOTS% }" != "$EXPECT_MOUNT_ROOT" ]] && \
        emit WARN "mounts.root_vs_config" "node uses '${UNIQ_ROOTS% }', config/cluster.env says '${EXPECT_MOUNT_ROOT}'"
else
    emit FAIL "mounts.common_root" "the five binds do not share one root: ${UNIQ_ROOTS}"
fi

# --- container environment, including this rank's fabric identity ----------
cenv() { docker inspect --format "{{range .Config.Env}}{{println .}}{{end}}" "$CONTAINER_NAME" 2>/dev/null | sed -n "s/^$1=//p" | head -1; }
eq "env.VLLM_HOST_IP"                 "$(cenv VLLM_HOST_IP)"                 "$EXPECT_FABRIC_IP"
eq "env.RAY_NODE_IP_ADDRESS"          "$(cenv RAY_NODE_IP_ADDRESS)"          "$EXPECT_FABRIC_IP"
eq "env.RAY_OVERRIDE_NODE_IP_ADDRESS" "$(cenv RAY_OVERRIDE_NODE_IP_ADDRESS)" "$EXPECT_FABRIC_IP"
eq "env.NCCL_SOCKET_IFNAME"           "$(cenv NCCL_SOCKET_IFNAME)"           "$EXPECT_ETH_IF"
eq "env.GLOO_SOCKET_IFNAME"           "$(cenv GLOO_SOCKET_IFNAME)"           "$EXPECT_ETH_IF"
eq "env.TP_SOCKET_IFNAME"             "$(cenv TP_SOCKET_IFNAME)"             "$EXPECT_ETH_IF"
eq "env.UCX_NET_DEVICES"              "$(cenv UCX_NET_DEVICES)"              "$EXPECT_ETH_IF"
eq "env.MN_IF_NAME"                   "$(cenv MN_IF_NAME)"                   "$EXPECT_ETH_IF"
eq "env.OMPI_MCA_btl_tcp_if_include"  "$(cenv OMPI_MCA_btl_tcp_if_include)"  "$EXPECT_ETH_IF"
eq "env.NCCL_IB_HCA"                  "$(cenv NCCL_IB_HCA)"                  "$EXPECT_IB_IF"
eq "env.NCCL_IB_DISABLE"              "$(cenv NCCL_IB_DISABLE)"              "0"
eq "env.NCCL_IGNORE_CPU_AFFINITY"     "$(cenv NCCL_IGNORE_CPU_AFFINITY)"     "1"
eq "env.PYTORCH_CUDA_ALLOC_CONF"      "$(cenv PYTORCH_CUDA_ALLOC_CONF)"      "expandable_segments:True"
eq "env.RAY_object_store_memory"      "$(cenv RAY_object_store_memory)"      "1073741824"
eq "env.RAY_memory_monitor_refresh_ms" "$(cenv RAY_memory_monitor_refresh_ms)" "0"
eq "env.RAY_num_prestart_python_workers" "$(cenv RAY_num_prestart_python_workers)" "0"

# --- model snapshot as the rank actually sees it ---------------------------
SNAP="/root/.cache/huggingface/hub/models--${EXPECT_MODEL_REPO//\//--}/snapshots/${EXPECT_MODEL_REVISION}"
if docker exec "$CONTAINER_NAME" test -d "$SNAP" 2>/dev/null; then
    emit PASS "model.snapshot" "$SNAP"
    for a in config.json generation_config.json tokenizer_config.json; do
        if docker exec "$CONTAINER_NAME" test -e "${SNAP}/${a}" 2>/dev/null; then
            emit PASS "model.artifact.${a}" present
        else
            emit FAIL "model.artifact.${a}" "missing from the snapshot the rank loads"
        fi
    done
    if docker exec "$CONTAINER_NAME" sh -c "test -e '${SNAP}/tokenizer.json' -o -e '${SNAP}/tokenizer.model' -o -e '${SNAP}/vocab.json'" 2>/dev/null; then
        emit PASS "model.tokenizer" present
    else
        emit FAIL "model.tokenizer" "no tokenizer.json / tokenizer.model / vocab.json"
    fi
    SHARDS="$(docker exec "$CONTAINER_NAME" sh -c "ls -1 '${SNAP}'/*.safetensors 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]')"
    if [[ "${SHARDS:-0}" -gt 0 ]]; then emit PASS "model.weight_shards" "$SHARDS"
    else emit FAIL "model.weight_shards" "no *.safetensors in the snapshot"; fi
    BROKEN="$(docker exec "$CONTAINER_NAME" sh -c "find '${SNAP}' -type l ! -exec test -e {} \; -print 2>/dev/null | head -3" 2>/dev/null | tr '\n' ' ')"
    if [[ -z "${BROKEN// /}" ]]; then emit PASS "model.blobs_resolve" "all symlinks resolve"
    else emit FAIL "model.blobs_resolve" "unresolved symlinks (partial download): ${BROKEN}"; fi
else
    emit FAIL "model.snapshot" "snapshot for the pinned revision is missing inside the container: ${SNAP}"
fi
REF="/root/.cache/huggingface/hub/models--${EXPECT_MODEL_REPO//\//--}/refs/main"
REFVAL="$(docker exec "$CONTAINER_NAME" sh -c "cat '${REF}' 2>/dev/null" 2>/dev/null | tr -d '[:space:]')"
if [[ -z "$REFVAL" ]]; then emit WARN "model.refs_main" "absent (the snapshot itself is verified)"
elif [[ "$REFVAL" == "$EXPECT_MODEL_REVISION" ]]; then emit PASS "model.refs_main" "$REFVAL"
else emit FAIL "model.refs_main" "points at ${REFVAL}, expected ${EXPECT_MODEL_REVISION}"; fi

# --- serving argv, rank and headless ---------------------------------------
LIVE="$(docker exec "$CONTAINER_NAME" ps -eo args 2>/dev/null | grep -m1 'vllm serve' || true)"
if [[ -z "$LIVE" ]]; then
    emit FAIL "argv.process" "no running 'vllm serve' process inside the container"
else
    LIVE="vllm serve${LIVE#*vllm serve}"
    NORM="$(printf '%s' "$LIVE" | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//')"
    WANT="$(printf '%s' "$EXPECT_ARGV" | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//')"
    if [[ "$NORM" == "$WANT" ]]; then
        emit PASS "argv.exact" "identical to the canonical rank-${EXPECT_RANK} invocation"
    else
        emit FAIL "argv.exact" "differs from canonical rank-${EXPECT_RANK}: ${NORM}"
    fi
    case "$NORM" in
        *"--node-rank ${EXPECT_RANK}"*) emit PASS "argv.node_rank" "$EXPECT_RANK" ;;
        *) emit FAIL "argv.node_rank" "argv does not carry --node-rank ${EXPECT_RANK}" ;;
    esac
    case "$NORM" in
        *"--master-addr ${EXPECT_MASTER_ADDR} --master-port ${EXPECT_MASTER_PORT}"*)
            emit PASS "argv.rendezvous" "${EXPECT_MASTER_ADDR}:${EXPECT_MASTER_PORT}" ;;
        *) emit FAIL "argv.rendezvous" "expected --master-addr ${EXPECT_MASTER_ADDR} --master-port ${EXPECT_MASTER_PORT}" ;;
    esac
    HAS_HEADLESS=no; case "$NORM" in *--headless*) HAS_HEADLESS=yes ;; esac
    if [[ "$EXPECT_RANK" == "0" ]]; then eq "argv.headless" "$HAS_HEADLESS" "no"
    else eq "argv.headless" "$HAS_HEADLESS" "yes"; fi
fi

# --- recipe environment, read from the live process ------------------------
PID="$(docker exec "$CONTAINER_NAME" sh -c "pgrep -f 'vllm serve' | head -1" 2>/dev/null | tr -d '[:space:]')"
if [[ -z "$PID" ]]; then
    emit FAIL "recipe_env.pid" "could not locate the serving process"
else
    ENVDUMP="$(docker exec "$CONTAINER_NAME" sh -c "tr '\\0' '\\n' < /proc/${PID}/environ" 2>/dev/null)"
    penv() { printf '%s\n' "$ENVDUMP" | sed -n "s/^$1=//p" | head -1; }
    for kv in \
        CUTE_DSL_ARCH=sm_121a VLLM_USE_AOT_COMPILE=1 VLLM_USE_BREAKABLE_CUDAGRAPH=0 \
        VLLM_USE_MEGA_AOT_ARTIFACT=-1 VLLM_MEMORY_PROFILE_INCLUDE_ATTN=1 \
        VLLM_USE_FLASHINFER_SAMPLER=1 VLLM_USE_B12X_WO_PROJECTION=1 VLLM_USE_B12X_MHC=1 \
        VLLM_USE_B12X_FP8_GEMM=1 VLLM_USE_B12X_MOE=1 VLLM_USE_B12X_SPARSE_INDEXER=1 \
        VLLM_USE_V2_MODEL_RUNNER=1 B12X_MLA_SM120_UNIFIED=1 B12X_MOE_FORCE_A8=1 \
        VLLM_PREFIX_CACHE_RETENTION_INTERVAL=4096 VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0
    do
        eq "recipe_env.${kv%%=*}" "$(penv "${kv%%=*}")" "${kv#*=}"
    done
fi

# --- mod certification marker ----------------------------------------------
CERT="UNCERTIFIED"
if docker exec "$CONTAINER_NAME" test -f "$EXPECT_MARKER_EXACT" 2>/dev/null; then
    CERT="EXACT";     emit PASS "mods.certification" "EXACT marker present"
elif docker exec "$CONTAINER_NAME" test -f "$EXPECT_MARKER_NON_EXACT" 2>/dev/null; then
    CERT="NON-EXACT"; emit FAIL "mods.certification" "NON-EXACT marker present — this rank was launched without certified mods"
    docker exec "$CONTAINER_NAME" sh -c "sed -n '1,12p' '$EXPECT_MARKER_NON_EXACT'" 2>/dev/null \
        | while IFS= read -r l; do printf 'CHECK|WARN|mods.marker|%s\n' "$l"; done
else
    emit FAIL "mods.certification" "no certification marker at ${EXPECT_MARKER_EXACT} or ${EXPECT_MARKER_NON_EXACT}; this container was not started by scripts/40-start.sh"
fi

# --- host fabric ------------------------------------------------------------
if need ip; then
    ST="$(ip -o link show "$EXPECT_ETH_IF" 2>/dev/null | sed -E 's/.*state ([A-Z]+).*/\1/')"
    MTU="$(ip -o link show "$EXPECT_ETH_IF" 2>/dev/null | sed -E 's/.*mtu ([0-9]+).*/\1/')"
    eq "fabric.${EXPECT_ETH_IF}.state" "${ST:-absent}" "UP"
    eq "fabric.${EXPECT_ETH_IF}.mtu"   "${MTU:-absent}" "$EXPECT_MTU"
    ADDRS="$(ip -o -4 addr show "$EXPECT_ETH_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"
    case " $ADDRS " in
        *" $EXPECT_FABRIC_IP "*) emit PASS "fabric.address" "$EXPECT_FABRIC_IP" ;;
        *) emit FAIL "fabric.address" "got '${ADDRS:-none}', expected ${EXPECT_FABRIC_IP}" ;;
    esac
else
    emit FAIL "fabric.ip_tool" "ip(8) not available"
fi

if need rdma; then
    RST="$(rdma link show 2>/dev/null | awk -v d="${EXPECT_IB_IF}/1" '$2==d {for(i=1;i<=NF;i++) if($i=="state") {print $(i+1); exit}}')"
    eq "fabric.${EXPECT_IB_IF}.rdma" "${RST:-absent}" "ACTIVE"
else
    emit WARN "fabric.rdma_tool" "rdma(8) not available; RDMA state unverified"
fi

# --- listener behaviour: rank 0 serves, every other rank is silent ---------
if need ss; then
    HAS_API=no
    ss -ltn 2>/dev/null | grep -qE "[:.]${EXPECT_API_PORT}[[:space:]]" && HAS_API=yes
    if [[ "$EXPECT_RANK" == "0" ]]; then
        eq "api.listener" "$HAS_API" "yes"
    else
        if [[ "$HAS_API" == "no" ]]; then emit PASS "api.listener" "absent (correct for a headless rank)"
        else emit FAIL "api.listener" "rank ${EXPECT_RANK} is listening on ${EXPECT_API_PORT}; a headless rank must not serve the API"; fi
    fi
else
    emit WARN "api.ss_tool" "ss(8) not available; listener behaviour unverified"
fi

printf 'RESULT|%s|%s\n' "$FAILS" "$CERT"
PROBE_EOF

# ---------------------------------------------------------------------------
probe_env() {   # <rank> <fabric_ip>
    local rank="$1" fip="$2"
    local argv; argv="$(cat "${BUNDLE_ROOT}/recipe/canonical-cli-rank${rank}.txt")"
    local kv
    for kv in \
        "CONTAINER_NAME=${CONTAINER_NAME}" \
        "EXPECT_RANK=${rank}" \
        "EXPECT_FABRIC_IP=${fip}" \
        "EXPECT_ETH_IF=${FABRIC_ETH_IF}" \
        "EXPECT_IB_IF=${FABRIC_IB_IF}" \
        "EXPECT_MTU=${FABRIC_MTU}" \
        "EXPECT_API_PORT=${API_PORT}" \
        "EXPECT_MASTER_ADDR=${MASTER_ADDR}" \
        "EXPECT_MASTER_PORT=${MASTER_PORT}" \
        "EXPECT_IMAGE_ID=${PIN_IMAGE_ID}" \
        "EXPECT_IMAGE_TAG=${PIN_IMAGE_LOCAL_TAG}" \
        "EXPECT_IMAGE_ARCH=${PIN_IMAGE_ARCH}" \
        "EXPECT_IMAGE_SIZE=${PIN_IMAGE_SIZE_BYTES}" \
        "EXPECT_IMAGE_DIGEST=${PIN_IMAGE_DIGEST}" \
        "EXPECT_MODEL_REPO=${PIN_MODEL_REPO}" \
        "EXPECT_MODEL_REVISION=${PIN_MODEL_REVISION}" \
        "EXPECT_WORKDIR=${PIN_CONTAINER_WORKDIR}" \
        "EXPECT_NOFILE=${PIN_NOFILE_LIMIT}" \
        "EXPECT_MOUNT_ROOT=${CACHE_ROOT}" \
        "EXPECT_MARKER_EXACT=${PIN_MOD_MARKER_EXACT}" \
        "EXPECT_MARKER_NON_EXACT=${PIN_MOD_MARKER_NON_EXACT}" \
        "EXPECT_ARGV=${argv}"
    do
        printf 'export %s\n' "$(printf '%s=%q' "${kv%%=*}" "${kv#*=}")"
    done
}

NODE_FAILS=0
NODE_CERT=""
render_report() {   # reads probe output on stdin
    local status name detail line
    NODE_FAILS=-1; NODE_CERT="UNKNOWN"
    while IFS= read -r line; do
        case "$line" in
            CHECK\|*)
                IFS='|' read -r _ status name detail <<<"$line"
                case "$status" in
                    PASS) ok   "${name}: ${detail}" ;;
                    WARN) warn "${name}: ${detail}" ;;
                    FAIL) printf '[fail] %s: %s\n' "$name" "$detail" >&2 ;;
                esac
                ;;
            RESULT\|*)
                IFS='|' read -r _ NODE_FAILS NODE_CERT <<<"$line"
                ;;
            *) [[ -n "$line" ]] && info "probe: ${line}" ;;
        esac
    done
}

TOTAL_FAILS=0
CERT_LOCAL=""; CERT_PEER=""

hdr "Identity"
detect_role
RANK=0; FIP="$PRIMARY_FABRIC_IP"
if [[ "$ROLE" == "worker" ]]; then RANK=1; FIP="$WORKER_FABRIC_IP"; fi
info "this node is ${ROLE} => rank ${RANK}"

hdr "Bundle artifacts"
require_pinned_recipe
for f in canonical-cli-rank0.txt canonical-cli-rank1.txt; do
    [[ -r "${BUNDLE_ROOT}/recipe/${f}" ]] || die "missing recipe/${f}"
done
ok "canonical argv references present"

# Probe output goes to a file, never straight into a pipe: a `... | while read`
# loop runs in a subshell, so its counters would be lost on the way out.
CERT_FAILS=0
LOCAL_OUT="$(mktemp)"
hdr "Local node (rank ${RANK})"
{ probe_env "$RANK" "$FIP"; printf '%s\n' "$PROBE_BODY"; } | bash -s > "$LOCAL_OUT" 2>/dev/null || true
render_report < "$LOCAL_OUT"
rm -f "$LOCAL_OUT"
if [[ "$NODE_FAILS" == "-1" ]]; then
    printf '[fail] local probe produced no RESULT line\n' >&2
    TOTAL_FAILS=$((TOTAL_FAILS + 1))
else
    CERT_LOCAL="$NODE_CERT"
    info "local: ${NODE_FAILS} failure(s), mod certification ${CERT_LOCAL}"
    TOTAL_FAILS=$((TOTAL_FAILS + NODE_FAILS))
    [[ "$CERT_LOCAL" != "EXACT" ]] && CERT_FAILS=$((CERT_FAILS + 1))
fi

if [[ "$PEER" == "true" ]]; then
    require_role primary
    hdr "Peer node (worker, rank 1) — identical probe over SSH"
    need_cmd ssh
    SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
    PEER_OUT="$(mktemp)"
    if { probe_env 1 "$WORKER_FABRIC_IP"; printf '%s\n' "$PROBE_BODY"; } \
            | ssh "${SSH_OPTS[@]}" "$WORKER_SSH_TARGET" 'bash -s' > "$PEER_OUT" 2>/dev/null; then
        render_report < "$PEER_OUT"
        if [[ "$NODE_FAILS" == "-1" ]]; then
            printf '[fail] peer probe produced no RESULT line\n' >&2
            TOTAL_FAILS=$((TOTAL_FAILS + 1))
        else
            CERT_PEER="$NODE_CERT"
            info "peer: ${NODE_FAILS} failure(s), mod certification ${CERT_PEER}"
            TOTAL_FAILS=$((TOTAL_FAILS + NODE_FAILS))
            [[ "$CERT_PEER" != "EXACT" ]] && CERT_FAILS=$((CERT_FAILS + 1))
        fi
    else
        printf '[fail] peer.unreachable: could not run the probe on %s. An unverifiable peer is a verification FAILURE, not an assumption of health.\n' "$WORKER_SSH_TARGET" >&2
        TOTAL_FAILS=$((TOTAL_FAILS + 1))
    fi
    rm -f "$PEER_OUT"

    hdr "Cluster coherence"
    if [[ -n "$CERT_LOCAL" && -n "$CERT_PEER" ]]; then
        if [[ "$CERT_LOCAL" == "$CERT_PEER" ]]; then
            ok "both ranks agree on mod certification: ${CERT_LOCAL}"
        else
            printf '[fail] ranks disagree on mod certification: primary=%s worker=%s\n' "$CERT_LOCAL" "$CERT_PEER" >&2
            TOTAL_FAILS=$((TOTAL_FAILS + 1))
        fi
    fi
else
    info "run with --peer from the primary to verify the worker as well;"
    info "without it this run has checked ONE rank, not the cluster."
fi

hdr "Result"
CERT_OVERALL="${CERT_LOCAL:-UNKNOWN}"
[[ -n "$CERT_PEER" && "$CERT_PEER" != "$CERT_LOCAL" ]] && CERT_OVERALL="${CERT_LOCAL:-UNKNOWN}/${CERT_PEER}"
info "mod certification: ${CERT_OVERALL}"

if [[ "$CERT_OVERALL" == *"NON-EXACT"* || "$CERT_OVERALL" == *UNCERTIFIED* || "$CERT_OVERALL" == *UNKNOWN* ]]; then
    warn "############################################################"
    warn "# THIS DEPLOYMENT IS NOT CERTIFIED AS AN EXACT REPRODUCTION #"
    warn "############################################################"
    warn "It must not be described as a restoration of the audited deployment."
    if [[ "$ALLOW_NON_EXACT" == "true" ]]; then
        warn "--allow-non-exact was given, so the ${CERT_FAILS} certification failure(s) alone do not fail the run."
        TOTAL_FAILS=$((TOTAL_FAILS - CERT_FAILS))
        [[ $TOTAL_FAILS -lt 0 ]] && TOTAL_FAILS=0
    fi
fi

if [[ $TOTAL_FAILS -eq 0 ]]; then
    ok "verified: this deployment matches the pinned recipe"
    exit 0
fi
die "${TOTAL_FAILS} failed check(s) — this is NOT the audited recipe as deployed"
