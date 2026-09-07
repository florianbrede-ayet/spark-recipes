#!/bin/bash
# ---------------------------------------------------------------------------
# 30-render.sh — render the in-container launch script for one rank.
#
# Pure and local. It writes only into render/ inside this bundle and never
# touches Docker, the network, or any service. There is no --apply.
#
# --check compares the rendered `vllm serve` argv against the canonical argv
# captured from the live process table (recipe/canonical-cli-rank{0,1}.txt).
# That comparison is the bundle's proof that these templates reproduce the
# exact live invocation, and it runs offline on any machine.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: 30-render.sh --rank <0|1> [--out <file>] [--check] [--stdout]

  --rank <0|1>   0 = primary (serves the API), 1 = worker (--headless).
  --out <file>   Where to write. Default: render/exec-script.rank<N>.sh
  --check        Also diff the rendered argv against the canonical live argv.
  --stdout       Print the rendered script instead of writing a file.

Read-only with respect to the system. Writes only inside this bundle.
USAGE
}

RANK=""
OUT=""
CHECK="false"
TO_STDOUT="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rank)   RANK="${2:-}"; shift ;;
        --out)    OUT="${2:-}"; shift ;;
        --check)  CHECK="true" ;;
        --stdout) TO_STDOUT="true" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done
[[ "$RANK" == "0" || "$RANK" == "1" ]] || { usage >&2; die "--rank must be 0 or 1"; }

load_pins
load_cluster

TEMPLATE="${BUNDLE_ROOT}/templates/exec-script.sh.tmpl"
[[ -r "$TEMPLATE" ]] || die "missing ${TEMPLATE}"

# Rank args are appended verbatim after --speculative-config, matching the
# order the vendor launcher used when it patched the per-node script.
RANK_ARGS="--nnodes ${PIN_NNODES} --node-rank ${RANK} --master-addr ${MASTER_ADDR} --master-port ${MASTER_PORT}"
if [[ "$RANK" == "1" ]]; then
    # Only rank 0 runs the API server. Every non-zero rank is headless: it
    # joins the TP group, runs its worker, and opens no HTTP listener.
    RANK_ARGS="${RANK_ARGS} --headless"
fi

render() {
    sed -e "s|@@MODEL@@|${PIN_MODEL_REPO}|g" \
        -e "s|@@HOST@@|${API_HOST}|g" \
        -e "s|@@PORT@@|${API_PORT}|g" \
        -e "s|@@RANK_ARGS@@|${RANK_ARGS}|g" \
        "$TEMPLATE"
}

# Flatten the rendered script's `vllm serve` invocation into the single-line
# argv form that ps(1) shows: join continuations, collapse runs of whitespace,
# and drop the shell quoting around the JSON arguments (the JSON itself
# contains no single quotes, so this is lossless).
flatten() {
    awk '/^vllm serve /,0' \
    | tr '\n' ' ' \
    | sed -e 's/\\ / /g' -e "s/'//g" -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//'
}

if [[ "$TO_STDOUT" == "true" ]]; then
    render
else
    OUT="${OUT:-${BUNDLE_ROOT}/render/exec-script.rank${RANK}.sh}"
    mkdir -p "$(dirname -- "$OUT")"
    render > "$OUT"
    chmod 0755 "$OUT"
    ok "wrote ${OUT}"
fi

if [[ "$CHECK" == "true" ]]; then
    CANON="${BUNDLE_ROOT}/recipe/canonical-cli-rank${RANK}.txt"
    [[ -r "$CANON" ]] || die "missing canonical reference ${CANON}"
    GOT="$(render | flatten)"
    WANT="$(sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//' "$CANON")"
    if [[ "$GOT" == "$WANT" ]]; then
        ok "rank ${RANK} argv is byte-identical to the canonical live invocation"
    else
        printf '%s\n' "--- canonical (live) ---" >&2
        printf '%s\n' "$WANT" | tr ' ' '\n' >&2
        printf '%s\n' "--- rendered ---" >&2
        printf '%s\n' "$GOT" | tr ' ' '\n' >&2
        die "rendered argv does not match the canonical live invocation for rank ${RANK}"
    fi
fi
