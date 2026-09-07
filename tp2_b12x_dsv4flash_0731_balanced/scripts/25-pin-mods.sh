#!/bin/bash
# ---------------------------------------------------------------------------
# 25-pin-mods.sh — certify operator-supplied mod directories.
#
# The recipe declares exactly two mods, in a fixed order. Their audited bytes
# are NOT in the evidence, so config/mods-pins.env carries UNAVAILABLE for both
# and an exact launch fails closed. This script is how an operator who has
# obtained the real mods pins them so an exact launch becomes possible.
#
# It writes only inside mods/<name>/MOD.sha256. It never edits
# config/mods-pins.env: promoting a digest to a pin is a deliberate human act,
# because it is the moment someone asserts "these bytes are the audited ones".
#
# Default is dry-run (report only). --apply writes the manifests.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: 25-pin-mods.sh [--apply] [--yes] [--verify-only]

  --apply        Write MOD.sha256 into each supplied mod directory.
  --yes          Skip the confirmation (only with --apply).
  --verify-only  Report certification state and exit; never write.

Reports, for each declared mod: whether it is supplied, whether its manifest
matches its contents, its content digest, and how that compares to the pin in
config/mods-pins.env.
USAGE
}

VERIFY_ONLY="false"
while [[ $# -gt 0 ]]; do
    if common_parse_flag "$1"; then shift; continue; fi
    case "$1" in
        --verify-only) VERIFY_ONLY="true" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

load_mod_pins
assert_no_foreign_mods

hdr "Declared mods (recipe order)"
i=0
while IFS= read -r name; do
    i=$((i + 1))
    info "${i}. ${name}   pinned digest: $(mod_pinned_digest "$name")"
done < <(mods_required)

hdr "Supplied mod directories"
SUPPLIED=()
while IFS= read -r name; do
    d="${BUNDLE_ROOT}/mods/${name}"
    if [[ -d "$d" ]]; then
        if [[ -r "${d}/run.sh" ]]; then
            SUPPLIED+=("$name"); ok "mods/${name} present"
        else
            warn "mods/${name} present but has no run.sh — not a usable mod"
        fi
    else
        warn "mods/${name} not supplied"
    fi
done < <(mods_required)

if [[ ${#SUPPLIED[@]} -eq 0 ]]; then
    hdr "Result"
    warn "no mod directories are supplied, so there is nothing to pin."
    info "Obtain the audited mods from the vendor and place them at:"
    while IFS= read -r name; do show_cmd "mods/${name}/run.sh"; done < <(mods_required)
    info "Then re-run this script with --apply."
    exit 0
fi

dryrun_banner
hdr "Plan"
for name in "${SUPPLIED[@]}"; do
    d="${BUNDLE_ROOT}/mods/${name}"
    n_files="$(mod_manifest_body "$d" | wc -l)"
    digest="$(mod_content_digest "$d")"
    printf '  %s\n' "mods/${name}: ${n_files} file(s), content digest ${digest}"
    show_cmd "write mods/${name}/${PIN_MOD_MANIFEST}"
done

if [[ "$VERIFY_ONLY" == "true" ]] || ! is_apply; then
    hdr "Certification state"
    probe_mods
    print_mods_report
    info "overall: ${MODS_STATE}"
    if [[ "$MODS_STATE" != "EXACT" ]]; then
        echo
        warn "This bundle cannot certify an EXACT launch."
        info "To reach EXACT you must, for each mod above:"
        info "  1. confirm the directory really is the audited vendor mod,"
        info "  2. run this script with --apply to write its ${PIN_MOD_MANIFEST},"
        info "  3. copy the printed digest into config/mods-pins.env, replacing UNAVAILABLE."
        info "Step 3 is deliberately manual. Never paste a digest for a mod you"
        info "cannot independently confirm is the audited one."
    fi
    exit 0
fi

confirm "write ${PIN_MOD_MANIFEST} into ${#SUPPLIED[@]} mod director(y|ies) under mods/" "PIN"

for name in "${SUPPLIED[@]}"; do
    d="${BUNDLE_ROOT}/mods/${name}"
    mod_manifest_body "$d" > "${d}/${PIN_MOD_MANIFEST}"
    chmod 0644 "${d}/${PIN_MOD_MANIFEST}"
    ok "wrote mods/${name}/${PIN_MOD_MANIFEST}"
done

hdr "Digests to pin"
for name in "${SUPPLIED[@]}"; do
    d="${BUNDLE_ROOT}/mods/${name}"
    var="$(_mod_pin_var "$name")"
    printf '  %s="%s"\n' "$var" "$(mod_content_digest "$d")"
done
echo
info "Copy the lines above into config/mods-pins.env, replacing UNAVAILABLE,"
info "only if you can confirm these directories are the audited vendor mods."
info "Until then scripts/40-start.sh will keep refusing an exact launch."
