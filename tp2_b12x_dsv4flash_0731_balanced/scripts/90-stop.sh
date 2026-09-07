#!/bin/bash
# ---------------------------------------------------------------------------
# 90-stop.sh — coordinated shutdown of the two-node deployment.
#
# SAFETY MODEL
#   * Default is plan-only: it prints exactly what it would stop, on which
#     node, in which order, and exits 0 having changed nothing.
#   * --apply requires an interactive confirmation.
#   * It must run on the PRIMARY; the worker is stopped over SSH.
#   * It never touches the host network, NetworkManager profiles, systemd, the
#     model cache, the image, or any other container.
#
# WHY THE ORDER MATTERS
#   The two ranks form one torch.distributed TP group over
#   ${MASTER_ADDR}:${MASTER_PORT}. There is no supervisor, no restart policy
#   and no auto-recovery: the containers run with --rm, so stopping either one
#   destroys it and the surviving rank is left in a broken collective. A
#   half-stopped cluster looks "up" (the API port may still be bound) while
#   every request that needs rank 1 hangs or fails.
#
#   So: stop rank 0 first to take the API out of service and stop accepting new
#   work, then stop rank 1. Recovery is always a full restart of both ranks via
#   scripts/40-start.sh — never a single-rank restart.
#
#   --drain waits (bounded) for in-flight requests to finish before stopping.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: 90-stop.sh [--apply] [--yes] [--drain [seconds]] [--timeout <seconds>]

  --apply             Actually stop the containers. Requires confirmation.
  --yes               Skip the confirmation (only with --apply).
  --drain [seconds]   Before stopping, wait until the API reports no running or
                      waiting requests (default budget 120s). Advisory only: it
                      does not block new requests arriving.
  --timeout <n>       'docker stop' grace period, seconds. Default 60.

Default: print the shutdown plan and change nothing.
USAGE
}

DRAIN="false"
DRAIN_BUDGET=120
STOP_TIMEOUT=60
while [[ $# -gt 0 ]]; do
    if common_parse_flag "$1"; then shift; continue; fi
    case "$1" in
        --drain)
            DRAIN="true"
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then DRAIN_BUDGET="$2"; shift; fi
            ;;
        --timeout) STOP_TIMEOUT="${2:-60}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done
[[ "$STOP_TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be an integer number of seconds"

load_pins
load_cluster
dryrun_banner

hdr "Identity"
detect_role
require_role primary

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
ssh_worker() { ssh "${SSH_OPTS[@]}" "$WORKER_SSH_TARGET" "$@"; }

# --- state probing ----------------------------------------------------------
# Three states, never two. "unknown" is what you get when the query itself
# failed, and it is NEVER collapsed into "down": an unreachable worker may be
# running the rank perfectly well.
P_UP="unknown"; P_WHY=""
W_UP="unknown"; W_WHY=""

probe_primary() {
    local out rc
    if ! command -v docker >/dev/null 2>&1; then
        P_UP="unknown"; P_WHY="docker not installed on this host"; return
    fi
    out="$(docker ps --format '{{.Names}}' 2>/dev/null)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        P_UP="unknown"; P_WHY="'docker ps' failed (rc=${rc}); is the daemon up?"; return
    fi
    if grep -qx "$CONTAINER_NAME" <<<"$out"; then P_UP="yes"; else P_UP="no"; fi
}

probe_worker() {
    local out rc
    if ! command -v ssh >/dev/null 2>&1; then
        W_UP="unknown"; W_WHY="ssh not installed on this host"; return
    fi
    out="$(ssh_worker "docker ps --format '{{.Names}}'" 2>/dev/null)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        W_UP="unknown"; W_WHY="ssh/docker query to ${WORKER_SSH_TARGET} failed (rc=${rc})"; return
    fi
    if grep -qx "$CONTAINER_NAME" <<<"$out"; then W_UP="yes"; else W_UP="no"; fi
}

state_line() {  # <label> <node> <state> <why>
    case "$3" in
        yes)     info "$1 $2: ${CONTAINER_NAME} RUNNING" ;;
        no)      info "$1 $2: ${CONTAINER_NAME} not running (verified)" ;;
        unknown) warn "$1 $2: STATE UNKNOWN — $4" ;;
    esac
}

hdr "Current state"
probe_primary
probe_worker
state_line "primary" "$PRIMARY_MGMT_IP" "$P_UP" "$P_WHY"
state_line "worker " "$WORKER_MGMT_IP"  "$W_UP" "$W_WHY"

if [[ "$P_UP" == "no" && "$W_UP" == "no" ]]; then
    ok "both ranks verified not running — no action needed."
    exit 0
fi

if [[ "$P_UP" == "unknown" || "$W_UP" == "unknown" ]]; then
    echo
    warn "At least one rank's state could not be determined. This script will not"
    warn "claim the cluster is down on the strength of a failed query. Anything it"
    warn "cannot reach, it will report as UNKNOWN and leave to you."
    if [[ "$W_UP" == "unknown" ]]; then
        info "check the worker by hand:"
        show_cmd "ssh ${WORKER_SSH_TARGET} docker ps --filter name=${CONTAINER_NAME}"
    fi
fi

if [[ "$P_UP" != "$W_UP" && "$P_UP" != "unknown" && "$W_UP" != "unknown" ]]; then
    warn "the two ranks disagree (primary=${P_UP}, worker=${W_UP})."
    warn "That is a half-stopped cluster: the surviving rank cannot serve on its"
    warn "own. Completing this stop and then running scripts/40-start.sh is the"
    warn "only supported recovery."
fi

hdr "Plan"
echo "0. (optional) drain: poll ${PIN_API_BIND}:${API_PORT} until running+waiting == 0"
echo "1. stop rank 0 (primary, API server) — removes the endpoint from service:"
show_cmd "docker stop --timeout ${STOP_TIMEOUT} ${CONTAINER_NAME}"
echo "2. stop rank 1 (worker, headless):"
show_cmd "ssh ${WORKER_SSH_TARGET} docker stop --timeout ${STOP_TIMEOUT} ${CONTAINER_NAME}"
echo
info "both containers were created with --rm, so stopping them also removes them."
info "Nothing else is touched: image, model cache, NetworkManager profiles, the"
info "RoCE rails and any unrelated container all stay exactly as they are."
info "To bring the deployment back, run scripts/40-start.sh (both ranks together)."

if ! is_apply; then
    echo
    info "plan only. Nothing was changed. Re-run with --apply to execute."
    exit 0
fi

confirm "stop the live ${PIN_MODEL_REPO} deployment on both nodes. In-flight requests will be lost and the API on ${API_PORT} will go away. There is no auto-restart." "STOP"

if [[ "$DRAIN" == "true" ]]; then
    hdr "Draining (budget ${DRAIN_BUDGET}s)"
    if command -v curl >/dev/null 2>&1; then
        DEADLINE=$(( SECONDS + DRAIN_BUDGET ))
        while (( SECONDS < DEADLINE )); do
            M="$(curl -fsS --max-time 5 "http://127.0.0.1:${API_PORT}/metrics" 2>/dev/null || true)"
            [[ -z "$M" ]] && { warn "metrics unreachable; not waiting further"; break; }
            R="$(grep -E '^vllm:num_requests_running' <<<"$M" | awk '{print $NF}' | head -1)"
            Q="$(grep -E '^vllm:num_requests_waiting' <<<"$M" | awk '{print $NF}' | head -1)"
            info "running=${R:-?} waiting=${Q:-?}"
            case "${R:-1}${Q:-1}" in
                "00"|"0.00.0"|"00.0"|"0.00") ok "idle"; break ;;
            esac
            sleep 5
        done
    else
        warn "curl not available; skipping drain"
    fi
fi

STOP_ERRORS=""

hdr "Stopping rank 0 (primary)"
case "$P_UP" in
    yes)
        if docker stop --timeout "$STOP_TIMEOUT" "$CONTAINER_NAME" >/dev/null 2>&1; then
            ok "rank 0 stop issued"
        else
            warn "docker stop failed on the primary"; STOP_ERRORS+=" primary-stop-failed"
        fi
        ;;
    no)      info "primary was verified not running; nothing to stop" ;;
    unknown) warn "primary state unknown — attempting the stop anyway, which is safe if it is already down"
             docker stop --timeout "$STOP_TIMEOUT" "$CONTAINER_NAME" >/dev/null 2>&1 \
                || warn "stop attempt on the primary did not succeed (it may simply not be running)" ;;
esac

hdr "Stopping rank 1 (worker)"
case "$W_UP" in
    yes)
        if ssh_worker "docker stop --timeout $(printf %q "$STOP_TIMEOUT") $(printf %q "$CONTAINER_NAME")" >/dev/null 2>&1; then
            ok "rank 1 stop issued"
        else
            warn "docker stop failed on the worker"; STOP_ERRORS+=" worker-stop-failed"
        fi
        ;;
    no)      info "worker was verified not running; nothing to stop" ;;
    unknown) warn "worker state unknown and unreachable — NOT attempting a remote stop"
             STOP_ERRORS+=" worker-unreachable" ;;
esac

hdr "Result — re-verifying"
probe_primary
probe_worker
state_line "primary" "$PRIMARY_MGMT_IP" "$P_UP" "$P_WHY"
state_line "worker " "$WORKER_MGMT_IP"  "$W_UP" "$W_WHY"

if [[ "$P_UP" == "no" && "$W_UP" == "no" && -z "$STOP_ERRORS" ]]; then
    ok "coordinated stop complete — BOTH ranks verified down and their containers removed (--rm)."
    info "Restart with: scripts/40-start.sh --apply   (never restart a single rank)"
    exit 0
fi

echo
warn "############################################################"
warn "# STOP INCOMPLETE OR UNVERIFIED                            #"
warn "############################################################"
warn "primary: ${P_UP}${P_WHY:+ (${P_WHY})}"
warn "worker : ${W_UP}${W_WHY:+ (${W_WHY})}"
[[ -n "$STOP_ERRORS" ]] && warn "problems:${STOP_ERRORS}"
warn "This run will NOT report the cluster as down, because it could not verify"
warn "that it is. Resolve each rank by hand before starting anything:"
show_cmd "docker ps --filter name=${CONTAINER_NAME}                       # primary"
show_cmd "ssh ${WORKER_SSH_TARGET} docker ps --filter name=${CONTAINER_NAME}   # worker"
exit 1
