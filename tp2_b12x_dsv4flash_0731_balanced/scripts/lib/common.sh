#!/bin/bash
# ---------------------------------------------------------------------------
# Shared helpers for the tp2_b12x_dsv4flash_0731_balanced scripts.
#
# Design rules enforced here:
#   * Nothing mutates state unless the caller passed --apply.
#   * Anything that mutates the network, a service, or Docker also requires an
#     interactive confirmation, unless --yes was passed on top of --apply.
#   * Node identity (management IP, fabric IP, interface, RDMA device) is
#     checked before any node-specific action.
#   * Artifact pins are content-addressed and are never rewritten by a script.
#
# Source this from scripts/*.sh. Not executable on its own.
# ---------------------------------------------------------------------------
set -euo pipefail

# Derived from this library's own location, which is always
# <bundle>/scripts/lib/common.sh — so the paths are correct no matter who
# sources it or from which working directory.
_COMMON_LIB_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
SCRIPT_DIR="$(cd -- "${_COMMON_LIB_DIR}/.." && pwd)"
BUNDLE_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

APPLY="false"
ASSUME_YES="false"
ROLE=""

# --- output ---------------------------------------------------------------
_c() { if [[ -t 1 ]]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
info()  { printf '%s %s\n' "$(_c '0;36' '[info]')" "$*"; }
ok()    { printf '%s %s\n' "$(_c '0;32' '[ ok ]')" "$*"; }
warn()  { printf '%s %s\n' "$(_c '0;33' '[warn]')" "$*" >&2; }
die()   { printf '%s %s\n' "$(_c '0;31' '[fail]')" "$*" >&2; exit 1; }
hdr()   { printf '\n%s\n' "$(_c '1'  "== $* ==")"; }

# --- argument helpers -----------------------------------------------------
# Consume the flags every script understands. Returns the number of args eaten
# so callers can shift. Unknown flags are left for the caller.
common_parse_flag() {
    case "$1" in
        --apply)   APPLY="true";      return 0 ;;
        --dry-run) APPLY="false";     return 0 ;;
        --yes|-y)  ASSUME_YES="true"; return 0 ;;
        *) return 1 ;;
    esac
}

is_apply() { [[ "$APPLY" == "true" ]]; }

# Print a command that WOULD run (dry-run) or run it (apply).
# Usage: run_or_show <human description> -- <argv...>
run_or_show() {
    local desc="$1"; shift
    [[ "${1:-}" == "--" ]] && shift
    if is_apply; then
        info "running: ${desc}"
        "$@"
    else
        printf '  %s %s\n' "$(_c '0;35' 'would run:')" "$(printf '%q ' "$@")"
    fi
}

# Same, but for a command that must be shown as a literal shell string
# (remote ssh payloads, nmcli lines).
show_cmd() { printf '  %s %s\n' "$(_c '0;35' '$')" "$*"; }

# Interactive confirmation gate for anything that changes the machine.
confirm() {
    local prompt="$1" word="${2:-yes}"
    if [[ "$ASSUME_YES" == "true" ]]; then
        warn "confirmation auto-accepted via --yes: ${prompt}"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "refusing to proceed without confirmation (stdin is not a TTY). Re-run interactively, or pass --yes if you have already reviewed the plan."
    fi
    printf '\n%s\n' "$(_c '1;33' "CONFIRM: ${prompt}")"
    printf 'Type %s to proceed: ' "$(_c '1' "${word}")"
    local answer=""
    read -r answer || true
    [[ "$answer" == "$word" ]] || die "not confirmed (got '${answer}') — nothing was changed."
}

# --- config loading -------------------------------------------------------
_PINS_LOADED="false"
load_pins() {
    [[ "$_PINS_LOADED" == "true" ]] && return 0
    local f="${BUNDLE_ROOT}/config/pinned-artifacts.env"
    [[ -r "$f" ]] || die "missing ${f}"
    # shellcheck source=/dev/null
    source "$f"
    _PINS_LOADED="true"
}

_CLUSTER_LOADED="false"
load_cluster() {
    [[ "$_CLUSTER_LOADED" == "true" ]] && return 0
    local f="${BUNDLE_ROOT}/config/cluster.env"
    if [[ ! -r "$f" ]]; then
        f="${BUNDLE_ROOT}/config/cluster.env.example"
        warn "config/cluster.env not found; falling back to cluster.env.example (live values from the audit)"
    fi
    # shellcheck source=/dev/null
    source "$f"
    _CLUSTER_LOADED="true"
}

# A value that still looks like <PLACEHOLDER> counts as unset.
is_placeholder() { [[ -z "${1:-}" || "${1:-}" == "<"*">" ]]; }

# --- host identity --------------------------------------------------------
have_ipv4() { ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$1"; }
have_iface() { ip -o link show "$1" >/dev/null 2>&1; }

iface_state() { ip -o link show "$1" 2>/dev/null | sed -E 's/.*state ([A-Z]+).*/\1/'; }
iface_mtu()   { ip -o link show "$1" 2>/dev/null | sed -E 's/.*mtu ([0-9]+).*/\1/'; }
iface_ipv4()  { ip -o -4 addr show "$1" 2>/dev/null | awk '{print $4}' | head -1; }

rdma_state() {
    command -v rdma >/dev/null 2>&1 || { printf 'unknown'; return; }
    rdma link show 2>/dev/null | awk -v d="$1/1" '$2==d {for(i=1;i<=NF;i++) if($i=="state") {print $(i+1); exit}}'
}

# Resolve which node we are on. Sets ROLE to "primary" or "worker".
# Refuses to guess: if neither identity matches exactly, it fails.
detect_role() {
    load_cluster
    if have_ipv4 "$PRIMARY_MGMT_IP" && have_ipv4 "$PRIMARY_FABRIC_IP"; then
        ROLE="primary"
    elif have_ipv4 "$WORKER_MGMT_IP" && have_ipv4 "$WORKER_FABRIC_IP"; then
        ROLE="worker"
    else
        die "cannot identify this host. Expected either primary (${PRIMARY_MGMT_IP} + ${PRIMARY_FABRIC_IP}) or worker (${WORKER_MGMT_IP} + ${WORKER_FABRIC_IP}) addresses on this machine. Refusing to act on an unidentified node."
    fi
    info "node identity: ${ROLE}"
}

# Resolve the role from management identity alone (management IP, or hostname
# when the mapping is configured). Used by network bootstrap, which by
# definition runs before the fabric exists. It refuses to guess: matching both
# roles, or neither, is fatal.
#
# This does NOT relax the fabric checks that every other script performs.
detect_role_mgmt() {
    load_cluster
    local hits=() how=""

    if have_ipv4 "$PRIMARY_MGMT_IP"; then hits+=("primary"); how="management IP ${PRIMARY_MGMT_IP}"; fi
    if have_ipv4 "$WORKER_MGMT_IP";  then hits+=("worker");  how="management IP ${WORKER_MGMT_IP}"; fi

    # Hostname mapping is an explicit, optional fallback for a node whose
    # management address is not up yet. Both names must be set, and they must
    # differ, or the mapping is ignored rather than trusted.
    if [[ ${#hits[@]} -eq 0 ]]; then
        local hn; hn="$(hostname -s 2>/dev/null || true)"
        if [[ -n "$hn" && -n "${PRIMARY_HOSTNAME:-}" && -n "${WORKER_HOSTNAME:-}" \
              && "${PRIMARY_HOSTNAME}" != "${WORKER_HOSTNAME}" ]]; then
            if [[ "$hn" == "$PRIMARY_HOSTNAME" ]]; then hits+=("primary"); how="hostname ${hn}"; fi
            if [[ "$hn" == "$WORKER_HOSTNAME"  ]]; then hits+=("worker");  how="hostname ${hn}"; fi
        fi
    fi

    case "${#hits[@]}" in
        1) ROLE="${hits[0]}"; info "node identity: ${ROLE} (by ${how})" ;;
        0) die "cannot identify this host from management identity. Expected management IP ${PRIMARY_MGMT_IP} (primary) or ${WORKER_MGMT_IP} (worker), or a matching PRIMARY_HOSTNAME/WORKER_HOSTNAME in config/cluster.env. Refusing to act on an unidentified node." ;;
        *) die "AMBIGUOUS node identity: this host matches BOTH the primary and the worker (${hits[*]}). That must never happen — check config/cluster.env and this host's addresses. Refusing to act." ;;
    esac
}

# Hard assert that we are the node the caller expects.
require_role() {
    local want="$1"
    [[ -n "$ROLE" ]] || detect_role
    [[ "$ROLE" == "$want" ]] || die "this script step must run on the ${want}, but this host is the ${ROLE}."
}

# Assert the fabric interface + RDMA device this recipe pins are present and up.
require_fabric() {
    load_cluster
    have_iface "$FABRIC_ETH_IF" || die "fabric interface ${FABRIC_ETH_IF} not present on this host."
    local st mtu
    st="$(iface_state "$FABRIC_ETH_IF")"
    [[ "$st" == "UP" ]] || die "fabric interface ${FABRIC_ETH_IF} is ${st}, expected UP."
    mtu="$(iface_mtu "$FABRIC_ETH_IF")"
    [[ "$mtu" == "$FABRIC_MTU" ]] || die "fabric interface ${FABRIC_ETH_IF} has MTU ${mtu}, expected ${FABRIC_MTU}."
    local rst; rst="$(rdma_state "$FABRIC_IB_IF")"
    case "$rst" in
        ACTIVE)  ok "RDMA ${FABRIC_IB_IF} ACTIVE" ;;
        unknown) warn "rdma(8) not available; cannot verify ${FABRIC_IB_IF}" ;;
        *)       die "RDMA device ${FABRIC_IB_IF} state is '${rst:-missing}', expected ACTIVE." ;;
    esac
    ok "fabric ${FABRIC_ETH_IF} UP mtu ${mtu} addr $(iface_ipv4 "$FABRIC_ETH_IF")"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# --- artifact pins --------------------------------------------------------
# Refuse to continue unless the local image resolves to the pinned image ID.
require_pinned_image() {
    load_pins
    need_cmd docker
    local got
    got="$(docker image inspect --format '{{.Id}}' "$PIN_IMAGE_LOCAL_TAG" 2>/dev/null || true)"
    [[ -n "$got" ]] || die "image '${PIN_IMAGE_LOCAL_TAG}' is not present locally. Run scripts/10-fetch-image.sh first."
    [[ "$got" == "$PIN_IMAGE_ID" ]] || die "image '${PIN_IMAGE_LOCAL_TAG}' resolves to ${got}, but this recipe is pinned to ${PIN_IMAGE_ID}. Refusing to start."
    ok "image pin matches: ${PIN_IMAGE_ID}"
}

# Hugging Face cache layout helpers.
hf_hub_root()     { load_pins; load_cluster; printf '%s' "${HF_HOME:-${CACHE_ROOT}/.cache/huggingface}/hub"; }
hf_model_root()   { printf '%s/models--%s' "$(hf_hub_root)" "${PIN_MODEL_REPO//\//--}"; }
hf_snapshot_dir() { printf '%s/snapshots/%s' "$(hf_model_root)" "$PIN_MODEL_REVISION"; }
hf_ref_main()     { printf '%s/refs/main' "$(hf_model_root)"; }

# Artifacts that must exist in the snapshot before we will call the model
# "present". A hand-written refs/main proves nothing; these are what vLLM
# actually loads.
HF_REQUIRED_ARTIFACTS=(config.json generation_config.json tokenizer_config.json)

# Verify the pinned revision is genuinely materialised on disk.
#   * the snapshot directory for the exact revision exists,
#   * it contains the required config/tokenizer artifacts,
#   * it contains weight shards plus their index,
#   * every symlink in it resolves to a real blob (an unresolved symlink means
#     a partial or pruned download, which refs/main would happily hide).
# Returns 0/1 and prints findings; does not exit. Sets HF_MODEL_PROBLEMS.
probe_pinned_model() {
    load_pins; load_cluster
    HF_MODEL_PROBLEMS=()
    local snap; snap="$(hf_snapshot_dir)"

    if [[ ! -d "$snap" ]]; then
        HF_MODEL_PROBLEMS+=("snapshot directory for the pinned revision is missing: ${snap}")
        return 1
    fi

    local a
    for a in "${HF_REQUIRED_ARTIFACTS[@]}"; do
        [[ -e "${snap}/${a}" ]] || HF_MODEL_PROBLEMS+=("missing required artifact: ${a}")
    done

    # A tokenizer must be present in one of its accepted forms.
    if [[ ! -e "${snap}/tokenizer.json" && ! -e "${snap}/tokenizer.model" && ! -e "${snap}/vocab.json" ]]; then
        HF_MODEL_PROBLEMS+=("no tokenizer artifact (tokenizer.json / tokenizer.model / vocab.json)")
    fi

    # The pipelines below are guarded: callers run with `set -e` and
    # `pipefail`, and a probe must be able to REPORT a problem rather than
    # abort the script that asked it to look.
    local shards
    shards="$( { find "$snap" -maxdepth 1 -name '*.safetensors' 2>/dev/null || true; } | wc -l || true)"
    if [[ "${shards:-0}" -eq 0 ]]; then
        HF_MODEL_PROBLEMS+=("no *.safetensors weight shards in the snapshot")
    elif [[ "${shards}" -gt 1 && ! -e "${snap}/model.safetensors.index.json" ]]; then
        HF_MODEL_PROBLEMS+=("${shards} weight shards but no model.safetensors.index.json")
    fi

    # Broken symlinks == blobs that were never fetched or were pruned.
    local broken
    broken="$( { find "$snap" -type l ! -exec test -e {} \; -print 2>/dev/null || true; } | head -5 || true)"
    if [[ -n "$broken" ]]; then
        HF_MODEL_PROBLEMS+=("symlinks in the snapshot do not resolve to blobs (partial download): $(printf '%s ' $broken)")
    fi

    [[ ${#HF_MODEL_PROBLEMS[@]} -eq 0 ]]
}

# Refuse to continue unless the pinned revision is genuinely materialised.
# refs/main is checked too, but only as a secondary consistency signal: it is
# an operator-writable text file and is never sufficient on its own.
require_pinned_model() {
    load_pins; load_cluster
    local snap ref
    snap="$(hf_snapshot_dir)"; ref="$(hf_ref_main)"

    if ! probe_pinned_model; then
        local p
        for p in "${HF_MODEL_PROBLEMS[@]}"; do warn "model cache: ${p}"; done
        die "the pinned model revision ${PIN_MODEL_REVISION} is not properly materialised under $(hf_model_root). Run scripts/20-fetch-model.sh --apply. Refusing to start on an unverified model."
    fi
    ok "model snapshot verified: ${snap}"

    if [[ -r "$ref" ]]; then
        local got; got="$(tr -d '[:space:]' < "$ref")"
        if [[ "$got" == "$PIN_MODEL_REVISION" ]]; then
            ok "refs/main agrees with the pin"
        else
            die "refs/main says ${got} but the pinned revision is ${PIN_MODEL_REVISION}. The cache holds more than one revision and 'main' points at the wrong one. Refusing to start."
        fi
    else
        warn "refs/main is absent; the snapshot itself is verified, which is what the loader uses."
        warn "run 'scripts/20-fetch-model.sh --establish-ref --apply' to write it deterministically."
    fi
    ok "model pin matches: ${PIN_MODEL_REPO}@${PIN_MODEL_REVISION}"
}

# Refuse to continue unless the vendored recipe YAML is byte-identical to live.
require_pinned_recipe() {
    load_pins
    local f="${BUNDLE_ROOT}/${PIN_RECIPE_FILE}"
    [[ -r "$f" ]] || die "missing ${f}"
    local got; got="$(sha256sum "$f" | awk '{print $1}')"
    [[ "$got" == "$PIN_RECIPE_SHA256" ]] || die "recipe ${PIN_RECIPE_FILE} hashes to ${got}, expected ${PIN_RECIPE_SHA256}."
    ok "recipe pin matches: ${PIN_RECIPE_SHA256}"
}

# --- mod certification ----------------------------------------------------
_MODPINS_LOADED="false"
load_mod_pins() {
    [[ "$_MODPINS_LOADED" == "true" ]] && return 0
    local f="${BUNDLE_ROOT}/config/mods-pins.env"
    [[ -r "$f" ]] || die "missing ${f}"
    # shellcheck source=/dev/null
    source "$f"
    _MODPINS_LOADED="true"
}

mods_required() { load_mod_pins; printf '%s\n' $PIN_MODS_ORDER; }

# mod name -> pin variable name (dashes are not legal in shell identifiers).
_mod_pin_var() {
    local n="${1//-/_}"
    printf 'PIN_MOD_DIGEST_%s' "$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]')"
}
mod_pinned_digest() {
    load_mod_pins
    local v; v="$(_mod_pin_var "$1")"
    printf '%s' "${!v:-UNAVAILABLE}"
}

# Canonical manifest for a mod directory: sha256 of every file except the
# manifest itself, relative paths, byte-sorted. Deterministic across machines.
mod_manifest_body() {
    local dir="$1"
    ( cd "$dir" && find . -type f ! -name "$PIN_MOD_MANIFEST" -printf '%P\n' \
        | LC_ALL=C sort | xargs -r sha256sum )
}
# The mod's single content digest: sha256 of the canonical manifest body.
mod_content_digest() {
    load_mod_pins
    mod_manifest_body "$1" | sha256sum | awk '{print $1}'
}

# Reject anything under mods/ that is not one of the two declared mods.
# Runs in every mode, exact or not: an unknown mod is never acceptable.
assert_no_foreign_mods() {
    load_mod_pins
    local root="${BUNDLE_ROOT}/mods" d name bad=0
    [[ -d "$root" ]] || return 0

    while IFS= read -r d; do
        name="$(basename "$d")"
        if ! printf '%s\n' $PIN_MODS_ORDER | grep -qx -- "$name"; then
            warn "unknown mod directory: mods/${name}"
            bad=1
        fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)

    # An executable dropped directly into mods/ is not a mod and must not be
    # mistaken for bundle content.
    local x
    while IFS= read -r x; do
        warn "unexpected executable file in mods/: ${x#"${BUNDLE_ROOT}/"}"
        bad=1
    done < <(find "$root" -maxdepth 1 -type f -perm -u+x | LC_ALL=C sort)

    [[ $bad -eq 0 ]] || die "mods/ contains content this recipe does not declare. This recipe applies exactly these mods, in this order: ${PIN_MODS_ORDER}. Remove anything else before launching."
}

# Inspect the supplied mods and decide what certification is achievable.
# Sets:
#   MODS_STATE   EXACT | INCOMPLETE
#   MODS_REPORT  array of human-readable per-mod lines
#   MODS_PRESENT array of mod dirs, in recipe order
# Never exits; the caller decides the policy.
probe_mods() {
    load_mod_pins
    assert_no_foreign_mods
    MODS_REPORT=(); MODS_PRESENT=(); MODS_STATE="EXACT"
    local name dir pin got manifest

    while IFS= read -r name; do
        dir="${BUNDLE_ROOT}/mods/${name}"
        pin="$(mod_pinned_digest "$name")"

        if [[ ! -d "$dir" ]]; then
            MODS_REPORT+=("${name}: NOT SUPPLIED (mods/${name} is absent)")
            MODS_STATE="INCOMPLETE"; continue
        fi
        if [[ ! -r "${dir}/run.sh" ]]; then
            MODS_REPORT+=("${name}: INVALID (no run.sh)")
            MODS_STATE="INCOMPLETE"; continue
        fi

        manifest="${dir}/${PIN_MOD_MANIFEST}"
        if [[ ! -r "$manifest" ]]; then
            MODS_REPORT+=("${name}: NOT PINNED (no ${PIN_MOD_MANIFEST}; run scripts/25-pin-mods.sh)")
            MODS_STATE="INCOMPLETE"; MODS_PRESENT+=("$dir"); continue
        fi
        if ! diff -q <(mod_manifest_body "$dir") "$manifest" >/dev/null 2>&1; then
            MODS_REPORT+=("${name}: TAMPERED (contents do not match its own ${PIN_MOD_MANIFEST})")
            MODS_STATE="INCOMPLETE"; MODS_PRESENT+=("$dir"); continue
        fi

        got="$(mod_content_digest "$dir")"
        if [[ "$pin" == "UNAVAILABLE" ]]; then
            MODS_REPORT+=("${name}: UNPINNABLE (supplied digest ${got}, but the audited digest is UNAVAILABLE)")
            MODS_STATE="INCOMPLETE"
        elif [[ "$got" == "$pin" ]]; then
            MODS_REPORT+=("${name}: EXACT (${got})")
        else
            MODS_REPORT+=("${name}: MISMATCH (supplied ${got}, pinned ${pin})")
            MODS_STATE="INCOMPLETE"
        fi
        MODS_PRESENT+=("$dir")
    done < <(mods_required)
}

print_mods_report() {
    local l
    for l in "${MODS_REPORT[@]}"; do
        case "$l" in
            *": EXACT "*) ok   "mod ${l}" ;;
            *)            warn "mod ${l}" ;;
        esac
    done
}

dryrun_banner() {
    if is_apply; then
        warn "APPLY MODE — this run will change the machine."
    else
        info "dry run (default). Nothing will be changed. Add --apply to execute."
    fi
}
