#!/bin/bash
# ---------------------------------------------------------------------------
# 20-fetch-model.sh — acquire the gated model at the exact pinned revision.
#
# Default is dry-run. --apply downloads into the host-side Hugging Face cache
# that gets bind-mounted into the container.
#
# CREDENTIALS: this repository contains no tokens and never will. Copy
# config/hf-credentials.env.example to config/hf-credentials.env and put your
# own read token there, or export HF_TOKEN in your shell. A value that still
# looks like <PLACEHOLDER> is treated as unset.
#
# WHAT COUNTS AS "PRESENT"
#   refs/main is a plain text file that any hand can write, so it proves
#   nothing on its own and is never accepted as evidence. This script — and
#   every check in this bundle — requires the SNAPSHOT for the pinned revision
#   to exist and to contain what the loader actually reads:
#     snapshots/<revision>/  with config.json, generation_config.json,
#     tokenizer_config.json, a tokenizer, *.safetensors shards (plus their
#     index when there is more than one), and no unresolved blob symlinks.
#
#   The download therefore asks for the pinned commit directly, never for
#   "main". refs/main is only ever WRITTEN afterwards, derived from a snapshot
#   that has already been verified — never the other way round.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: 20-fetch-model.sh [--apply] [--yes] [--verify-only] [--establish-ref]

  --apply           Perform the download. Requires confirmation.
  --yes             Skip the confirmation (only with --apply).
  --verify-only     Report whether the pinned revision is properly materialised
                    and exit. Never writes.
  --establish-ref   Also write refs/main = the pinned revision, but only after
                    the snapshot has been verified. Requires --apply.

Default: print the plan and the credential requirements, change nothing.
USAGE
}

VERIFY_ONLY="false"
ESTABLISH_REF="false"
while [[ $# -gt 0 ]]; do
    if common_parse_flag "$1"; then shift; continue; fi
    case "$1" in
        --verify-only)   VERIFY_ONLY="true" ;;
        --establish-ref) ESTABLISH_REF="true" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

load_pins
load_cluster

CRED_FILE="${BUNDLE_ROOT}/config/hf-credentials.env"
if [[ -r "$CRED_FILE" ]]; then
    info "loading ${CRED_FILE}"
    # shellcheck source=/dev/null
    source "$CRED_FILE"
fi
HF_HOME="${HF_HOME:-${CACHE_ROOT}/.cache/huggingface}"
CACHE_DIR="$(hf_hub_root)"
SNAP_DIR="$(hf_snapshot_dir)"
REF_FILE="$(hf_ref_main)"

hdr "Pinned model"
info "repo     : ${PIN_MODEL_REPO}"
info "revision : ${PIN_MODEL_REVISION}"
info "cache    : ${CACHE_DIR}"
info "snapshot : ${SNAP_DIR}"

# --- current state ----------------------------------------------------------
hdr "Current cache state"
if probe_pinned_model; then
    ok "snapshot present and complete for the pinned revision"
    MODEL_OK="true"
else
    MODEL_OK="false"
    for p in "${HF_MODEL_PROBLEMS[@]}"; do warn "$p"; done
fi

REF_STATE="absent"
if [[ -r "$REF_FILE" ]]; then
    REF_VAL="$(tr -d '[:space:]' < "$REF_FILE")"
    if [[ "$REF_VAL" == "$PIN_MODEL_REVISION" ]]; then REF_STATE="correct"; else REF_STATE="wrong:${REF_VAL}"; fi
fi
case "$REF_STATE" in
    correct) ok "refs/main = ${PIN_MODEL_REVISION}" ;;
    absent)  info "refs/main is absent (not required; the snapshot is what the loader uses)" ;;
    *)       warn "refs/main = ${REF_STATE#wrong:}, which is NOT the pinned revision" ;;
esac
if [[ "$MODEL_OK" == "false" && "$REF_STATE" == "correct" ]]; then
    warn "refs/main claims the pinned revision but the snapshot is incomplete."
    warn "A hand-written ref is not evidence. This script trusts the snapshot only."
fi

if [[ "$MODEL_OK" == "true" && ( "$REF_STATE" == "correct" || "$ESTABLISH_REF" == "false" ) ]]; then
    if [[ "$VERIFY_ONLY" == "true" ]]; then
        hdr "Result"; ok "pinned revision is properly materialised."; exit 0
    fi
    if [[ "$REF_STATE" != "wrong:"* ]]; then
        ok "nothing to do."
        exit 0
    fi
fi
if [[ "$VERIFY_ONLY" == "true" ]]; then
    die "the pinned revision is not properly materialised (--verify-only requested, nothing was changed)."
fi

# --- credentials ------------------------------------------------------------
hdr "Credentials"
if is_placeholder "${HF_TOKEN:-}"; then
    warn "HF_TOKEN is unset or still a placeholder."
    info "This model repository is gated. Provide a token before running with --apply:"
    show_cmd "cp config/hf-credentials.env.example config/hf-credentials.env"
    show_cmd "chmod 600 config/hf-credentials.env"
    show_cmd "\$EDITOR config/hf-credentials.env   # replace <PUT-YOUR-HUGGINGFACE-READ-TOKEN-HERE>"
    HAVE_TOKEN="false"
else
    ok "HF_TOKEN is set (value not printed)"
    HAVE_TOKEN="true"
fi

dryrun_banner
hdr "Plan"
show_cmd "export HF_HOME=${HF_HOME}"
show_cmd "huggingface-cli download ${PIN_MODEL_REPO} \\"
show_cmd "    --revision ${PIN_MODEL_REVISION} \\"
show_cmd "    --cache-dir ${CACHE_DIR}"
echo
show_cmd "# then verify what the loader will actually read:"
show_cmd "test -d ${SNAP_DIR}"
show_cmd "ls ${SNAP_DIR}/config.json ${SNAP_DIR}/tokenizer_config.json"
show_cmd "find ${SNAP_DIR} -type l ! -exec test -e {} \; -print    # must print nothing"
if [[ "$ESTABLISH_REF" == "true" ]]; then
    echo
    show_cmd "# only after the above passes:"
    show_cmd "printf %s ${PIN_MODEL_REVISION} > ${REF_FILE}"
fi
echo
warn "this is a very large download. Check free space on ${HF_HOME} first; the"
warn "audited hosts kept the model plus warm vLLM/FlashInfer/Triton/TileLang caches"
warn "on the same volume. This repository ships no weights and no cache contents."

if ! is_apply; then
    echo
    info "plan only. Re-run with --apply once credentials are in place."
    exit 0
fi

# --- apply ------------------------------------------------------------------
if [[ "$MODEL_OK" == "false" ]]; then
    [[ "$HAVE_TOKEN" == "true" ]] || die "refusing to download without a real HF token."
    need_cmd huggingface-cli
    confirm "download ${PIN_MODEL_REPO}@${PIN_MODEL_REVISION} into ${CACHE_DIR}" "FETCH"

    export HF_HOME
    export HF_TOKEN
    mkdir -p "$CACHE_DIR"
    # The pinned commit is requested directly. "main" is never resolved, so a
    # moving branch cannot silently substitute a different revision.
    run_or_show "huggingface-cli download" -- huggingface-cli download "$PIN_MODEL_REPO" \
        --revision "$PIN_MODEL_REVISION" --cache-dir "$CACHE_DIR"

    hdr "Verifying the download"
    if ! probe_pinned_model; then
        for p in "${HF_MODEL_PROBLEMS[@]}"; do warn "$p"; done
        die "the download completed but the snapshot is not usable. Nothing else was changed; refs/main was NOT written."
    fi
    ok "snapshot verified: ${SNAP_DIR}"
else
    ok "snapshot already verified; no download needed"
fi

if [[ "$ESTABLISH_REF" == "true" ]]; then
    hdr "Establishing refs/main"
    # Deterministic and derived: written only now, only because the snapshot
    # above has already been verified.
    probe_pinned_model || die "refusing to write refs/main for an unverified snapshot."
    confirm "write refs/main = ${PIN_MODEL_REVISION} (derived from the verified snapshot)" "SET-REF"
    mkdir -p "$(dirname -- "$REF_FILE")"
    printf '%s' "$PIN_MODEL_REVISION" > "$REF_FILE"
    ok "refs/main = $(tr -d '[:space:]' < "$REF_FILE")"
fi

hdr "Result"
ok "model materialised at the pinned revision."
info "run this on BOTH nodes; each node loads weights from its own local cache."
