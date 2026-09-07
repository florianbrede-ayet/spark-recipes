#!/bin/bash
# ---------------------------------------------------------------------------
# 40-start.sh — bring up the two-node TP2 deployment.
#
# SAFETY MODEL
#   * Dry run is the default. Without --apply this prints every docker/ssh
#     command it would run, on both nodes, and exits 0 having changed nothing.
#   * --apply additionally requires an interactive confirmation.
#   * It refuses to run anywhere except the PRIMARY node (rank 0), verified by
#     management IP + fabric IP + fabric interface + RDMA device state.
#   * It refuses to start unless the image ID, the model revision and the
#     recipe hash all match config/pinned-artifacts.env — on BOTH nodes.
#   * It refuses to start if containers are already running.
#
#   * Mods are certified before anything is touched. An EXACT launch requires
#     both declared mods, pinned, and matching config/mods-pins.env. Because the
#     audited mod digests are UNAVAILABLE, exact apply FAILS CLOSED today; a
#     NON-EXACT launch is possible only with --non-exact-mods plus a strong
#     typed confirmation, and it stamps a permanent marker in both containers.
#
# SEQUENCE
#   1. certify mods; verify pins and identity locally, then on the worker
#   2. create the WORKER container, then the PRIMARY container (both idle,
#      `sleep infinity`, entrypoint cleared)
#   3. apply the certified mods to both containers
#   4. stamp the mod-certification marker into both containers
#   5. copy the rendered per-rank exec-script into each container
#   6. dispatch the WORKER (rank 1, --headless) first, then the PRIMARY (rank 0)
#
# Step 6 order matters: rank 1 must already be waiting on the rendezvous when
# rank 0 opens the store on ${MASTER_ADDR}:${MASTER_PORT}. In the audited run
# the two serving processes appear ~1 s apart in the process table because SSH
# dispatch latency partly cancels the ordering — the dispatch order, not the
# wall-clock start, is what the sequence guarantees.
#
# Step 2 order is OURS, not the audit's. The audited run happened to create the
# primary container first, but both containers start idle, so creation order
# carries no semantics. Creating the worker first means a failure to create the
# primary leaves exactly one container to undo.
#
# PARTIAL STATE
#   Before any engine is dispatched, a failure removes only the containers this
#   run created, and says which. Once either engine has been dispatched, nothing
#   is removed automatically: the run reports the partial state loudly and
#   leaves it to the operator, because silently tearing down a half-started
#   distributed job destroys the evidence of why it failed.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: 40-start.sh [--apply] [--yes] [--non-exact-mods] [--skip-worker-checks]

  --apply                Actually create containers and launch. Requires confirmation.
  --yes                  Skip the confirmation (only with --apply).
  --non-exact-mods       Proceed although the mods cannot be certified exact
                         (missing, unpinned, tampered, or pinned UNAVAILABLE).
                         Requires its own strong typed confirmation and stamps a
                         NON-EXACT marker into both containers, after which
                         verification permanently reports NON-EXACT.
                         --allow-missing-mods is accepted as a deprecated alias.
  --skip-worker-checks   Do not SSH to the worker for pin verification. Only for
                         the case where you have already verified it by hand;
                         the start itself still needs SSH.

Default: full dry run. Prints the exact plan for both nodes and changes nothing.
USAGE
}

SKIP_WORKER_CHECKS="false"
NON_EXACT_MODS="false"
while [[ $# -gt 0 ]]; do
    if common_parse_flag "$1"; then shift; continue; fi
    case "$1" in
        --skip-worker-checks) SKIP_WORKER_CHECKS="true" ;;
        --non-exact-mods)     NON_EXACT_MODS="true" ;;
        --allow-missing-mods) NON_EXACT_MODS="true"
                              warn "--allow-missing-mods is deprecated; use --non-exact-mods" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

load_pins
load_cluster
dryrun_banner

hdr "Identity and fabric"
detect_role
require_role primary
require_fabric

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
ssh_worker() { ssh "${SSH_OPTS[@]}" "$WORKER_SSH_TARGET" "$@"; }

hdr "Artifact pins"
require_pinned_recipe
require_pinned_image
require_pinned_model

if [[ "$SKIP_WORKER_CHECKS" == "true" ]]; then
    warn "worker pin verification skipped by request"
else
    info "verifying the worker over SSH (read-only commands only)"
    need_cmd ssh
    W_IMAGE_ID="$(ssh_worker "docker image inspect --format '{{.Id}}' $(printf %q "$PIN_IMAGE_LOCAL_TAG") 2>/dev/null" || true)"
    W_IMAGE_ID="$(printf '%s' "$W_IMAGE_ID" | tr -d '[:space:]')"
    [[ -n "$W_IMAGE_ID" ]] || die "worker ${WORKER_SSH_TARGET} has no local image '${PIN_IMAGE_LOCAL_TAG}'. Run scripts/10-fetch-image.sh there."
    [[ "$W_IMAGE_ID" == "$PIN_IMAGE_ID" ]] || die "worker image is ${W_IMAGE_ID}, primary/pin is ${PIN_IMAGE_ID}. Both nodes must run the same content-addressable image. Refusing to start."
    ok "worker image pin matches"

    W_REF="\$HOME/.cache/huggingface/hub/models--${PIN_MODEL_REPO//\//--}/refs/main"
    W_REV="$(ssh_worker "cat ${W_REF} 2>/dev/null" || true)"
    W_REV="$(printf '%s' "$W_REV" | tr -d '[:space:]')"
    [[ "$W_REV" == "$PIN_MODEL_REVISION" ]] || die "worker model cache is at '${W_REV:-missing}', expected ${PIN_MODEL_REVISION}. Refusing to start."
    ok "worker model pin matches"

    W_FAB="$(ssh_worker "ip -o -4 addr show $(printf %q "$FABRIC_ETH_IF") 2>/dev/null | awk '{print \$4}'" || true)"
    W_FAB="$(printf '%s' "$W_FAB" | tr -d '[:space:]')"
    [[ "$W_FAB" == "${WORKER_FABRIC_IP}/30" ]] || die "worker ${FABRIC_ETH_IF} address is '${W_FAB:-none}', expected ${WORKER_FABRIC_IP}/30."
    ok "worker fabric address matches"
fi

hdr "Already running?"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    die "container '${CONTAINER_NAME}' is already running on the primary. Use scripts/90-stop.sh first; this script never restarts a live deployment."
fi
if [[ "$SKIP_WORKER_CHECKS" != "true" ]]; then
    if ssh_worker "docker ps --format '{{.Names}}'" 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        die "container '${CONTAINER_NAME}' is already running on the worker. Use scripts/90-stop.sh first."
    fi
fi
ok "no existing ${CONTAINER_NAME} containers"

# --- build the docker run argv exactly as the audited deployment did --------
CACHE_MOUNTS=(
    "${CACHE_ROOT}/.cache/huggingface:/root/.cache/huggingface"
    "${CACHE_ROOT}/.cache/vllm:/root/.cache/vllm"
    "${CACHE_ROOT}/.cache/flashinfer:/root/.cache/flashinfer"
    "${CACHE_ROOT}/.triton:/root/.triton"
    "${CACHE_ROOT}/.tilelang:/root/.tilelang"
)

docker_run_argv() {   # <fabric_ip>
    local ip="$1"
    local -a argv=(
        docker run
        --privileged
        --ulimit "nofile=${PIN_NOFILE_LIMIT}:${PIN_NOFILE_LIMIT}"
        --ipc=host
        --gpus all
        -d --rm
        --network host
        --name "$CONTAINER_NAME"
        --entrypoint=
        -e "NCCL_IGNORE_CPU_AFFINITY=1"
        -e "PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
        -e "VLLM_HOST_IP=${ip}"
        -e "RAY_NODE_IP_ADDRESS=${ip}"
        -e "RAY_OVERRIDE_NODE_IP_ADDRESS=${ip}"
        -e "MN_IF_NAME=${FABRIC_ETH_IF}"
        -e "UCX_NET_DEVICES=${FABRIC_ETH_IF}"
        -e "NCCL_SOCKET_IFNAME=${FABRIC_ETH_IF}"
        -e "NCCL_IB_HCA=${FABRIC_IB_IF}"
        -e "NCCL_IB_DISABLE=0"
        -e "OMPI_MCA_btl_tcp_if_include=${FABRIC_ETH_IF}"
        -e "GLOO_SOCKET_IFNAME=${FABRIC_ETH_IF}"
        -e "TP_SOCKET_IFNAME=${FABRIC_ETH_IF}"
        -e "RAY_memory_monitor_refresh_ms=0"
        -e "RAY_num_prestart_python_workers=0"
        -e "RAY_object_store_memory=1073741824"
    )
    local m
    for m in "${CACHE_MOUNTS[@]}"; do argv+=(-v "$m"); done
    argv+=("$PIN_IMAGE_LOCAL_TAG" sleep infinity)
    printf '%s\0' "${argv[@]}"
}

quote_argv() { local -a a=(); mapfile -d '' -t a < <("$@"); printf '%q ' "${a[@]}"; }

# --- mod certification ------------------------------------------------------
# Runs before the plan, because it decides whether a launch is permitted at all.
hdr "Mod certification"
load_mod_pins
probe_mods
print_mods_report
info "declared mods (recipe order): ${PIN_MODS_ORDER}"
info "certification state: ${MODS_STATE}"

if [[ "$MODS_STATE" == "EXACT" ]]; then
    CERT_MODE="EXACT"
    ok "all declared mods are supplied, pinned, and match config/mods-pins.env"
elif [[ "$NON_EXACT_MODS" == "true" ]]; then
    CERT_MODE="NON-EXACT"
    warn "proceeding NON-EXACT by explicit request (--non-exact-mods)"
else
    echo
    warn "This launch cannot be certified as an exact reproduction."
    warn "The audited mod bytes are not in the evidence, so config/mods-pins.env"
    warn "carries UNAVAILABLE for both declared mods and no supplied directory"
    warn "can be proven to be the audited one."
    echo
    info "Your options are:"
    info "  * obtain the audited mods, pin them with scripts/25-pin-mods.sh, and"
    info "    record their digests in config/mods-pins.env — then this is EXACT; or"
    info "  * re-run with --non-exact-mods to launch a deployment that is"
    info "    permanently and visibly marked NON-EXACT."
    die "refusing to launch: exact mod certification is not achievable and --non-exact-mods was not given."
fi

# --- plan ------------------------------------------------------------------
hdr "Plan"
echo "0. mod certification: ${CERT_MODE}"
if [[ "$CERT_MODE" == "NON-EXACT" ]]; then
    echo "   a marker will be written to ${PIN_MOD_MARKER_NON_EXACT} in BOTH containers"
    echo "   and scripts/60-verify-deployment.sh will fail exact verification forever after"
else
    echo "   a marker will be written to ${PIN_MOD_MARKER_EXACT} in BOTH containers"
fi
echo
echo "1. worker container (${WORKER_FABRIC_IP}), created first, over ssh ${WORKER_SSH_TARGET}:"
show_cmd "ssh ${WORKER_SSH_TARGET} $(printf %q "$(quote_argv docker_run_argv "$WORKER_FABRIC_IP")")"
echo
echo "2. primary container (${PRIMARY_FABRIC_IP}), created second:"
show_cmd "$(quote_argv docker_run_argv "$PRIMARY_FABRIC_IP")"
echo
echo "3. mods, applied to both containers in recipe order:"
if [[ ${#MODS_PRESENT[@]} -eq 0 ]]; then
    echo "   (none supplied — NON-EXACT)"
else
    for d in "${MODS_PRESENT[@]}"; do echo "   - $(basename "$d")"; done
fi
echo
echo "4. certification marker -> both containers"
echo
echo "5. per-rank exec scripts:"
show_cmd "scripts/30-render.sh --rank 1 --check   -> worker:${PIN_CONTAINER_EXEC_SCRIPT}"
show_cmd "scripts/30-render.sh --rank 0 --check   -> primary:${PIN_CONTAINER_EXEC_SCRIPT}"
echo
echo "6. dispatch — WORKER (rank 1) first, then PRIMARY (rank 0):"
show_cmd "ssh ${WORKER_SSH_TARGET} docker exec -d ${CONTAINER_NAME} bash -c '${PIN_CONTAINER_EXEC_SCRIPT} >> /proc/1/fd/1 2>&1'"
show_cmd "docker exec -d ${CONTAINER_NAME} bash -c '${PIN_CONTAINER_EXEC_SCRIPT} >> /proc/1/fd/1 2>&1'"
echo
info "rendezvous ${MASTER_ADDR}:${MASTER_PORT} over ${FABRIC_ETH_IF}/${FABRIC_IB_IF}; API on rank 0 only, ${API_HOST}:${API_PORT}"
info "failure before step 6 removes only the containers this run created;"
info "failure at or after step 6 leaves the partial state in place for inspection."

if ! is_apply; then
    echo
    info "dry run complete. Nothing was changed. Re-run with --apply to execute this plan."
    exit 0
fi

# --- apply -----------------------------------------------------------------
confirm "start the ${PIN_MODEL_REPO} TP2 deployment on ${PRIMARY_MGMT_IP} and ${WORKER_MGMT_IP}. This creates privileged host-network containers on both nodes and begins loading ~80 GiB of weights per rank." "START"

if [[ "$CERT_MODE" == "NON-EXACT" ]]; then
    echo
    warn "SECOND CONFIRMATION — NON-EXACT LAUNCH"
    warn "The mods that shaped the audited deployment's draft-weight loading and"
    warn "reasoning-effort behaviour cannot be certified. The resulting service"
    warn "will be marked NON-EXACT inside both containers, permanently, and must"
    warn "never be described as a restoration of the audited deployment."
    confirm "launch a deployment that is NOT an exact reproduction and will be marked NON-EXACT" "NOT-EXACT"
fi

# --- partial-state bookkeeping ---------------------------------------------
CREATED_WORKER="false"
CREATED_PRIMARY="false"
DISPATCHED="none"          # none | worker | both
COMPLETED="false"

partial_state_report() {
    local rc="$1"
    echo
    warn "############################################################"
    warn "# PARTIAL DEPLOYMENT — MANUAL ACTION REQUIRED              #"
    warn "############################################################"
    warn "the run failed (exit ${rc}) AFTER dispatching an engine, so nothing"
    warn "was removed automatically. Current known state:"
    warn "  worker  container created by this run : ${CREATED_WORKER}"
    warn "  primary container created by this run : ${CREATED_PRIMARY}"
    warn "  engines dispatched                    : ${DISPATCHED}"
    echo
    warn "A half-dispatched TP group cannot serve. Inspect first, then stop both:"
    show_cmd "docker logs ${CONTAINER_NAME}                      # on each node"
    show_cmd "scripts/90-stop.sh            # shows the plan"
    show_cmd "scripts/90-stop.sh --apply    # coordinated stop of both ranks"
    warn "Do NOT restart a single rank."
}

cleanup_created() {
    local rc="$1" failed=""
    echo
    warn "start failed (exit ${rc}) before any engine was dispatched."
    if [[ "$CREATED_PRIMARY" != "true" && "$CREATED_WORKER" != "true" ]]; then
        info "no containers were created by this run; nothing to undo."
        return 0
    fi
    warn "removing only the containers THIS RUN created; nothing else is touched."
    if [[ "$CREATED_PRIMARY" == "true" ]]; then
        if docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1; then
            ok "removed primary ${CONTAINER_NAME}"
        else
            failed+=" primary(${PRIMARY_MGMT_IP})"
        fi
    fi
    if [[ "$CREATED_WORKER" == "true" ]]; then
        if ssh_worker "docker rm -f $(printf %q "$CONTAINER_NAME")" >/dev/null 2>&1; then
            ok "removed worker ${CONTAINER_NAME}"
        else
            failed+=" worker(${WORKER_MGMT_IP})"
        fi
    fi
    if [[ -n "$failed" ]]; then
        warn "could NOT remove:${failed} — remove them by hand before retrying."
    fi
}

on_exit() {
    local rc=$?
    trap - EXIT
    [[ "$COMPLETED" == "true" ]] && return 0
    if [[ "$DISPATCHED" != "none" ]]; then
        partial_state_report "$rc"
    else
        cleanup_created "$rc"
    fi
    return 0
}
trap on_exit EXIT

hdr "Rendering exec scripts"
"${BUNDLE_ROOT}/scripts/30-render.sh" --rank 0 --check >/dev/null
"${BUNDLE_ROOT}/scripts/30-render.sh" --rank 1 --check >/dev/null
R0="${BUNDLE_ROOT}/render/exec-script.rank0.sh"
R1="${BUNDLE_ROOT}/render/exec-script.rank1.sh"
[[ -r "$R0" && -r "$R1" ]] || die "render step did not produce both rank scripts"
ok "rank 0 and rank 1 scripts rendered and argv-verified against the canonical live invocation"

hdr "Creating containers — worker first"
W_MKDIRS=""
for d in "${CACHE_MOUNTS[@]}"; do W_MKDIRS+=" $(printf %q "${d%%:*}")"; done
mapfile -d '' -t W_ARGV < <(docker_run_argv "$WORKER_FABRIC_IP")
info "worker: creating ${CONTAINER_NAME}"
ssh_worker "mkdir -p${W_MKDIRS}"
ssh_worker "$(printf '%q ' "${W_ARGV[@]}")"
CREATED_WORKER="true"
ok "worker container created (idle)"

for d in "${CACHE_MOUNTS[@]}"; do mkdir -p "${d%%:*}"; done
mapfile -d '' -t P_ARGV < <(docker_run_argv "$PRIMARY_FABRIC_IP")
info "primary: creating ${CONTAINER_NAME}"
"${P_ARGV[@]}"
CREATED_PRIMARY="true"
ok "primary container created (idle)"

hdr "Applying mods"
if [[ ${#MODS_PRESENT[@]} -eq 0 ]]; then
    warn "no mods to apply (NON-EXACT launch)"
else
    for d in "${MODS_PRESENT[@]}"; do
        name="$(basename "$d")"
        dest="${PIN_CONTAINER_WORKSPACE}/mods/${name}"

        info "mod ${name} -> worker"
        tmp="/tmp/mod_${name}.$$"
        ssh_worker "mkdir -p $(printf %q "$tmp")"
        scp "${SSH_OPTS[@]}" -r "${d}/." "${WORKER_SSH_TARGET}:${tmp}/"
        ssh_worker "docker exec -w / $(printf %q "$CONTAINER_NAME") mkdir -p $(printf %q "$dest")"
        ssh_worker "docker cp $(printf %q "${tmp}/.") $(printf %q "${CONTAINER_NAME}:${dest}/")"
        ssh_worker "docker exec $(printf %q "$CONTAINER_NAME") bash -c 'export WORKSPACE_DIR=\$PWD && cd $(printf %q "$dest") && chmod +x run.sh && ./run.sh'"
        ssh_worker "rm -rf $(printf %q "$tmp")"

        info "mod ${name} -> primary"
        docker exec -w / "$CONTAINER_NAME" mkdir -p "$dest"
        docker cp "${d}/." "${CONTAINER_NAME}:${dest}/"
        docker exec "$CONTAINER_NAME" bash -c "export WORKSPACE_DIR=\$PWD && cd $(printf %q "$dest") && chmod +x run.sh && ./run.sh"
    done
    ok "mods applied to both ranks"
fi

hdr "Stamping mod certification"
# Non-secret, human-readable. Read back by scripts/60-verify-deployment.sh.
MARKER_PATH="$PIN_MOD_MARKER_EXACT"
[[ "$CERT_MODE" == "NON-EXACT" ]] && MARKER_PATH="$PIN_MOD_MARKER_NON_EXACT"
MARKER_LOCAL="$(mktemp)"
{
    printf 'mod_certification=%s\n' "$CERT_MODE"
    printf 'recipe=tp2_b12x_dsv4flash_0731_balanced\n'
    printf 'model=%s@%s\n' "$PIN_MODEL_REPO" "$PIN_MODEL_REVISION"
    printf 'image_id=%s\n' "$PIN_IMAGE_ID"
    printf 'mods_declared=%s\n' "$PIN_MODS_ORDER"
    for line in "${MODS_REPORT[@]}"; do printf 'mod_state=%s\n' "$line"; done
    if [[ "$CERT_MODE" == "NON-EXACT" ]]; then
        printf 'note=%s\n' "this deployment is NOT an exact reproduction of the audited one"
    fi
} > "$MARKER_LOCAL"

docker cp "$MARKER_LOCAL" "${CONTAINER_NAME}:${MARKER_PATH}"
M_TMP="/tmp/modcert.$$"
scp "${SSH_OPTS[@]}" "$MARKER_LOCAL" "${WORKER_SSH_TARGET}:${M_TMP}"
ssh_worker "docker cp $(printf %q "$M_TMP") $(printf %q "${CONTAINER_NAME}:${MARKER_PATH}") && rm -f $(printf %q "$M_TMP")"
rm -f "$MARKER_LOCAL"
ok "certification marker ${MARKER_PATH} written to both containers (${CERT_MODE})"

hdr "Installing exec scripts"
W_TMP="/tmp/exec-script.rank1.$$"
scp "${SSH_OPTS[@]}" "$R1" "${WORKER_SSH_TARGET}:${W_TMP}"
ssh_worker "docker exec -w / $(printf %q "$CONTAINER_NAME") mkdir -p $(printf %q "$PIN_CONTAINER_WORKSPACE")"
ssh_worker "docker cp $(printf %q "$W_TMP") $(printf %q "${CONTAINER_NAME}:${PIN_CONTAINER_EXEC_SCRIPT}")"
ssh_worker "docker exec -w / $(printf %q "$CONTAINER_NAME") chmod +x $(printf %q "$PIN_CONTAINER_EXEC_SCRIPT")"
ssh_worker "rm -f $(printf %q "$W_TMP")"

docker exec -w / "$CONTAINER_NAME" mkdir -p "$PIN_CONTAINER_WORKSPACE"
docker cp "$R0" "${CONTAINER_NAME}:${PIN_CONTAINER_EXEC_SCRIPT}"
docker exec -w / "$CONTAINER_NAME" chmod +x "$PIN_CONTAINER_EXEC_SCRIPT"
ok "exec scripts installed on both ranks"

hdr "Dispatching — worker first"
warn "from this point a failure leaves partial state in place; nothing will be removed automatically."
ssh_worker "docker exec -d $(printf %q "$CONTAINER_NAME") bash -c $(printf %q "${PIN_CONTAINER_EXEC_SCRIPT} >> /proc/1/fd/1 2>&1")"
DISPATCHED="worker"
ok "rank 1 dispatched (headless)"

docker exec -d "$CONTAINER_NAME" bash -c "${PIN_CONTAINER_EXEC_SCRIPT} >> /proc/1/fd/1 2>&1"
DISPATCHED="both"
ok "rank 0 dispatched (API server)"

COMPLETED="true"
trap - EXIT

echo
info "mod certification: ${CERT_MODE}"
[[ "$CERT_MODE" == "NON-EXACT" ]] && warn "this deployment is NOT an exact reproduction; verification will report NON-EXACT."
info "startup is long: weight load, AOT compile, CUDA graph capture and DSpark"
info "capture all happen before the API binds. In the audited boot, rank 1 went"
info "from container start to KV allocation in roughly 3.5 minutes; full readiness"
info "is longer. Follow progress with:"
show_cmd "docker logs -f ${CONTAINER_NAME}"
show_cmd "scripts/50-health.sh"
show_cmd "scripts/60-verify-deployment.sh --peer"
