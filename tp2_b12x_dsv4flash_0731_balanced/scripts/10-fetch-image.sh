#!/bin/bash
# ---------------------------------------------------------------------------
# 10-fetch-image.sh — acquire and pin the B12X serving image.
#
# Default is dry-run: it prints the exact docker commands and exits.
# --apply pulls by digest (immutable), verifies the resulting image ID against
# config/pinned-artifacts.env, and only then applies the local tag the recipe
# expects. A digest that resolves to a different image ID is a hard failure —
# the script never rewrites the pin to match reality.
#
# No registry credentials are stored in this repository. If your mirror needs
# auth, run 'docker login <registry>' yourself beforehand.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: 10-fetch-image.sh [--apply] [--yes] [--from-archive <file.tar>] [--verify-only]

  --apply                 Execute the pull/load and tag. Requires confirmation.
  --yes                   Skip the confirmation (only with --apply).
  --from-archive <file>   Load the image from a 'docker save' archive instead of
                          pulling. Useful for the second node, and for how the
                          audited worker got its copy (it had no repo digest).
  --verify-only           Only check whether the pinned image is already present.

Default (no flags): print the plan, change nothing.
USAGE
}

ARCHIVE=""
VERIFY_ONLY="false"
while [[ $# -gt 0 ]]; do
    if common_parse_flag "$1"; then shift; continue; fi
    case "$1" in
        --from-archive) ARCHIVE="${2:-}"; shift ;;
        --verify-only)  VERIFY_ONLY="true" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

load_pins
need_cmd docker

current_id() { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || true; }

hdr "Pinned image"
info "reference : ${PIN_IMAGE_REF}"
info "image id  : ${PIN_IMAGE_ID}"
info "local tag : ${PIN_IMAGE_LOCAL_TAG}"
info "platform  : ${PIN_IMAGE_OS}/${PIN_IMAGE_ARCH}, ${PIN_IMAGE_SIZE_BYTES} bytes on disk (~21.8 GiB)"

EXISTING="$(current_id "$PIN_IMAGE_LOCAL_TAG")"
if [[ "$EXISTING" == "$PIN_IMAGE_ID" ]]; then
    ok "image already present and matches the pin — nothing to do."
    exit 0
elif [[ -n "$EXISTING" ]]; then
    warn "local tag ${PIN_IMAGE_LOCAL_TAG} currently resolves to ${EXISTING}, which is NOT the pin."
fi
if [[ "$VERIFY_ONLY" == "true" ]]; then
    die "pinned image is not present locally (--verify-only requested, nothing was changed)."
fi

dryrun_banner
hdr "Plan"
if [[ -n "$ARCHIVE" ]]; then
    show_cmd "docker load -i ${ARCHIVE}"
else
    show_cmd "docker pull ${PIN_IMAGE_REF}"
fi
show_cmd "docker image inspect --format '{{.Id}}' ${PIN_IMAGE_ID}   # must succeed"
show_cmd "docker tag ${PIN_IMAGE_ID} ${PIN_IMAGE_LOCAL_TAG}:latest"
show_cmd "docker tag ${PIN_IMAGE_ID} ${PIN_IMAGE_LOCAL_TAG}:deployed"
echo
info "the audited nodes carried both tags; the primary also retained the registry"
info "repo digest, while the worker's copy had none (it was transferred, not pulled)."

if ! is_apply; then
    echo
    info "plan only. Re-run with --apply to fetch. Expect a multi-gigabyte transfer."
    exit 0
fi

confirm "download/load and tag a ~21.8 GiB container image on this host" "FETCH"

if [[ -n "$ARCHIVE" ]]; then
    [[ -r "$ARCHIVE" ]] || die "archive not readable: ${ARCHIVE}"
    run_or_show "docker load" -- docker load -i "$ARCHIVE"
else
    run_or_show "docker pull by digest" -- docker pull "$PIN_IMAGE_REF"
fi

GOT="$(current_id "$PIN_IMAGE_ID")"
[[ "$GOT" == "$PIN_IMAGE_ID" ]] || die "after fetch, ${PIN_IMAGE_ID} is not resolvable locally (got '${GOT:-nothing}'). The registry content does not match the pin. Refusing to tag."

ARCH_GOT="$(docker image inspect --format '{{.Architecture}}' "$PIN_IMAGE_ID")"
[[ "$ARCH_GOT" == "$PIN_IMAGE_ARCH" ]] || die "fetched image architecture is ${ARCH_GOT}, expected ${PIN_IMAGE_ARCH}."

run_or_show "tag :latest"   -- docker tag "$PIN_IMAGE_ID" "${PIN_IMAGE_LOCAL_TAG}:latest"
run_or_show "tag :deployed" -- docker tag "$PIN_IMAGE_ID" "${PIN_IMAGE_LOCAL_TAG}:deployed"

ok "image ${PIN_IMAGE_ID} present and tagged ${PIN_IMAGE_LOCAL_TAG}:{latest,deployed}"
info "run this on BOTH nodes. 40-start.sh refuses to start if the two nodes disagree."
