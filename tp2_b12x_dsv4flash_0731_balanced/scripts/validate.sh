#!/bin/bash
# ---------------------------------------------------------------------------
# validate.sh — offline self-check for this recipe bundle.
#
# Needs no cluster, no credentials, no Docker and no network. Safe to run
# anywhere. It changes nothing except a temporary directory it cleans up.
#
# Checks, in order:
#   1  structure      every required file is present, nothing site-local is
#   2  syntax         bash -n on every script and the launch template
#   3  lint           shellcheck if installed, plus built-in shellcheck-like rules
#   4  render         the template reproduces the canonical live argv, both ranks
#   5  references     the pinned constants appear where the docs must state them
#   6  checksums      SHA256SUMS verifies, and covers exactly the right files
#   7  placeholders   credentials are placeholders; templates keep their markers
#   8  hashes         no unexpected 64-hex string (catches container/machine IDs)
#   9  secrets        token/key-shaped strings anywhere in the tree
#
# SELF-SCAN NOTE: this file is scanned like every other file. The detector
# patterns below are written so their own literal text cannot match them (each
# begins with a fixed prefix followed by a bracket expression, so the pattern
# string is never an instance of itself). Nothing is excluded from the scan to
# hide a false positive.
# ---------------------------------------------------------------------------
set -uo pipefail

BUNDLE_ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$BUNDLE_ROOT" || exit 1

VERBOSE="false"
[[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]] && VERBOSE="true"

FAIL=0
WARN=0
CHECKS=0

# Built without a literal instance of the character, so this file does not trip
# its own SC2006 rule.
BACKTICK=$'\x60'

_c() { if [[ -t 1 ]]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
sect() { printf '\n%s\n' "$(_c '1' "== $* ==")"; }
pass() { CHECKS=$((CHECKS + 1)); [[ "$VERBOSE" == "true" ]] && printf '  %s %s\n' "$(_c '0;32' 'ok  ')" "$*"; return 0; }
fail() { CHECKS=$((CHECKS + 1)); FAIL=$((FAIL + 1)); printf '  %s %s\n' "$(_c '0;31' 'FAIL')" "$*"; return 0; }
soft() { CHECKS=$((CHECKS + 1)); WARN=$((WARN + 1)); printf '  %s %s\n' "$(_c '0;33' 'warn')" "$*"; return 0; }
note() { printf '  %s %s\n' "$(_c '0;36' 'note')" "$*"; }

# Canonical file set: everything in the bundle except site-local files,
# generated output, third-party mod content, and VCS metadata.
tracked_files() {
    find . -type f \
        -not -path './.git/*' \
        -not -path './render/*' \
        -not -path './mods/*/*' \
        -not -name 'cluster.env' \
        -not -name 'hf-credentials.env' \
        | sed 's|^\./||' | sort
}
# Files covered by SHA256SUMS: tracked files minus SHA256SUMS itself.
checksummed_files() { tracked_files | grep -v '^SHA256SUMS$'; }

# ---------------------------------------------------------------------------
sect "1. Structure"
REQUIRED=(
    README.md
    MANIFEST.md
    SHA256SUMS
    .gitignore
    config/pinned-artifacts.env
    config/mods-pins.env
    config/cluster.env.example
    config/hf-credentials.env.example
    recipe/deepseek-v4-flash-0731.yaml
    recipe/canonical-cli-rank0.txt
    recipe/canonical-cli-rank1.txt
    templates/exec-script.sh.tmpl
    mods/README.md
    docs/00-as-deployed.md
    docs/01-network.md
    docs/02-prerequisites-and-limitations.md
    docs/03-profile-gmu087.md
    docs/04-capacity-and-health.md
    docs/05-benchmarks-2026-08-23.md
    docs/06-operations-runbook.md
    docs/07-rank-differences.md
    scripts/lib/common.sh
    scripts/00-check-prereqs.sh
    scripts/05-setup-network.sh
    scripts/10-fetch-image.sh
    scripts/20-fetch-model.sh
    scripts/25-pin-mods.sh
    scripts/30-render.sh
    scripts/40-start.sh
    scripts/50-health.sh
    scripts/60-verify-deployment.sh
    scripts/90-stop.sh
    scripts/validate.sh
)
for f in "${REQUIRED[@]}"; do
    [[ -f "$f" ]] && pass "present: $f" || fail "missing required file: $f"
done

# Site-local files must never be committed.
for f in config/cluster.env config/hf-credentials.env; do
    [[ -e "$f" ]] && fail "site-local file present in the tree: $f (must never be committed)" || pass "absent: $f"
done
[[ -d render ]] && soft "render/ exists (generated output; excluded from SHA256SUMS)" || pass "no generated render/ directory"

# Executable bits on the lifecycle scripts.
while IFS= read -r s; do
    [[ -x "$s" ]] && pass "executable: $s" || fail "not executable: $s"
done < <(find scripts -maxdepth 1 -name '*.sh' | sort)
[[ -x scripts/lib/common.sh ]] && soft "scripts/lib/common.sh is executable (it is a sourced library)" || pass "scripts/lib/common.sh is not executable (correct)"

# Forbidden content classes.
if find . -type f \( -name '*.safetensors' -o -name '*.bin' -o -name '*.pt' -o -name '*.gguf' -o -name '*.tar' -o -name '*.log' \) \
        -not -path './.git/*' | grep -q .; then
    fail "model/binary/log artifacts found in the bundle"
else
    pass "no model, binary or log artifacts"
fi
BIG="$(find . -type f -size +256k -not -path './.git/*' | head -5)"
[[ -z "$BIG" ]] && pass "no file larger than 256 KiB" || soft "large files present: $(printf '%s ' $BIG)"

# ---------------------------------------------------------------------------
sect "2. Bash syntax"
while IFS= read -r s; do
    if bash -n "$s" 2>/dev/null; then pass "bash -n $s"; else
        fail "bash -n $s"; bash -n "$s" 2>&1 | sed 's/^/       /'
    fi
done < <(find . -name '*.sh' -not -path './.git/*' -not -path './mods/*/*' | sort)

if bash -n templates/exec-script.sh.tmpl 2>/dev/null; then
    pass "bash -n templates/exec-script.sh.tmpl"
else
    fail "bash -n templates/exec-script.sh.tmpl"
fi

# ---------------------------------------------------------------------------
sect "3. Lint (shellcheck-like)"
if command -v shellcheck >/dev/null 2>&1; then
    while IFS= read -r s; do
        if shellcheck -x -S warning "$s" >/dev/null 2>&1; then pass "shellcheck $s"; else
            soft "shellcheck findings in $s"
            [[ "$VERBOSE" == "true" ]] && shellcheck -x -S warning "$s" 2>&1 | sed 's/^/       /'
        fi
    done < <(find scripts -name '*.sh' | sort)
else
    note "shellcheck not installed; running the built-in rule set instead"
fi

while IFS= read -r s; do
    base="$(basename "$s")"
    head -1 "$s" | grep -q '^#!/bin/bash' \
        && pass "shebang: $s" || fail "missing '#!/bin/bash' shebang: $s"

    if grep -q 'set -euo pipefail' "$s" || grep -q 'set -uo pipefail' "$s"; then
        pass "strict mode: $s"
    else
        fail "no 'set -e/-u/-o pipefail' line: $s"
    fi

    # SC2006: legacy backtick command substitution.
    if grep -nF "$BACKTICK" "$s" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
        fail "backtick command substitution (use \$(...)): $s"
    else
        pass "no backticks: $s"
    fi

    # SC2164: bare 'cd' that is not guarded by && or ||.
    if grep -nE '(^|[;&|[:space:]])cd[[:space:]]' "$s" | grep -v '&&' | grep -v '||' | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
        fail "unguarded 'cd' (needs '&&' or '|| exit'): $s"
    else
        pass "guarded cd: $s"
    fi

    # SC2086-flavoured: destructive rm with an unquoted expansion.
    if grep -nE 'rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*\$[A-Za-z_{]' "$s" | grep -q .; then
        fail "rm with an unquoted variable expansion: $s"
    else
        pass "no unquoted rm target: $s"
    fi

    # Every mutating script must implement the dry-run gate.
    case "$base" in
        05-setup-network.sh|10-fetch-image.sh|20-fetch-model.sh|25-pin-mods.sh|40-start.sh|90-stop.sh)
            grep -q 'is_apply' "$s" && grep -q 'confirm ' "$s" \
                && pass "dry-run gate + confirmation: $s" \
                || fail "mutating script lacks is_apply/confirm gating: $s"
            ;;
        00-check-prereqs.sh|50-health.sh|60-verify-deployment.sh|validate.sh)
            if grep -qE '^\s*--apply\)' "$s"; then
                fail "read-only script accepts --apply: $s"
            else
                pass "read-only (no --apply): $s"
            fi
            ;;
    esac
done < <(find scripts -name '*.sh' | sort)

# ---------------------------------------------------------------------------
sect "4. Canonical argv render check"
for r in 0 1; do
    if out="$(./scripts/30-render.sh --rank "$r" --check --stdout 2>&1)"; then
        pass "rank ${r} render matches recipe/canonical-cli-rank${r}.txt"
    else
        fail "rank ${r} render does NOT match the canonical live argv"
        printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
    fi
done

for r in 0 1; do
    grep -q -- "--node-rank ${r}" "recipe/canonical-cli-rank${r}.txt" \
        && pass "canonical rank ${r} carries --node-rank ${r}" \
        || fail "canonical rank ${r} does not carry --node-rank ${r}"
done
grep -q -- '--headless' recipe/canonical-cli-rank1.txt \
    && pass "rank 1 canonical argv is --headless" || fail "rank 1 canonical argv lacks --headless"
grep -q -- '--headless' recipe/canonical-cli-rank0.txt \
    && fail "rank 0 canonical argv must NOT be --headless" || pass "rank 0 canonical argv is not --headless"

# ---------------------------------------------------------------------------
sect "5. Required references"
# shellcheck source=/dev/null
source config/pinned-artifacts.env

ref() {  # <description> <pattern> <file...>  -- pattern must appear in EVERY file
    local desc="$1" pat="$2"; shift 2
    local missing="" f
    for f in "$@"; do
        grep -qF -- "$pat" "$f" 2>/dev/null || missing+=" $f"
    done
    if [[ -z "$missing" ]]; then pass "$desc"; else fail "$desc — '${pat}' not found in:${missing}"; fi
}

ref "model revision in pins"        "7872f01b1d1fe23eabc4c98b48bffcef5a386062" config/pinned-artifacts.env
ref "model revision in README"      "7872f01b1d1fe23eabc4c98b48bffcef5a386062" README.md
ref "model revision in as-deployed" "7872f01b1d1fe23eabc4c98b48bffcef5a386062" docs/00-as-deployed.md
ref "image digest in pins"          "sha256:eb3ed2bbb0c91dc6d41282d22532267b5a449088c78a032400cd887fe9ddd2c5" config/pinned-artifacts.env
ref "image digest in README"        "sha256:eb3ed2bbb0c91dc6d41282d22532267b5a449088c78a032400cd887fe9ddd2c5" README.md
ref "image digest in as-deployed"   "sha256:eb3ed2bbb0c91dc6d41282d22532267b5a449088c78a032400cd887fe9ddd2c5" docs/00-as-deployed.md
ref "image ID in pins"              "sha256:d43f15877df4176dfc70b7ebca336d5de698e1696da02fc3738b0338a65f5db2" config/pinned-artifacts.env
ref "image ID in README"            "sha256:d43f15877df4176dfc70b7ebca336d5de698e1696da02fc3738b0338a65f5db2" README.md
ref "launcher SHA in pins"          "d587df37af3a37f50328e0e72030177a7e864fff41e4b2edea354c5c6e52dd1a" config/pinned-artifacts.env
ref "launcher SHA in README"        "d587df37af3a37f50328e0e72030177a7e864fff41e4b2edea354c5c6e52dd1a" README.md
ref "recipe SHA in pins"            "2dcd8e9a9448ab51ea8ed6cebfb12961abdb1d278912ca4f0da4e4e8ad98379b" config/pinned-artifacts.env
ref "recipe SHA in README"          "2dcd8e9a9448ab51ea8ed6cebfb12961abdb1d278912ca4f0da4e4e8ad98379b" README.md

ref "master port 29501"             "29501" config/pinned-artifacts.env config/cluster.env.example docs/00-as-deployed.md docs/01-network.md
ref "API port 8888"                 "8888"  config/pinned-artifacts.env docs/00-as-deployed.md docs/01-network.md
ref "management .151"               "192.168.1.151" docs/01-network.md config/cluster.env.example
ref "management .152"               "192.168.1.152" docs/01-network.md config/cluster.env.example
ref "rail A interface"              "enp1s0f0np0"   docs/01-network.md config/cluster.env.example
ref "rail A RDMA device"            "rocep1s0f0"    docs/01-network.md config/cluster.env.example
ref "rail A addresses"              "10.0.7.1"      docs/01-network.md
ref "rail A peer"                   "10.0.7.2"      docs/01-network.md
ref "rail B interface"              "enP2p1s0f0np0" docs/01-network.md config/cluster.env.example
ref "rail B RDMA device"            "roceP2p1s0f0"  docs/01-network.md config/cluster.env.example
ref "rail B addresses"              "10.0.7.5"      docs/01-network.md
ref "rail B peer"                   "10.0.7.6"      docs/01-network.md
ref "MTU 9000"                      "9000"          docs/01-network.md config/cluster.env.example
ref "distinct-subnet rule"          "never share a subnet" docs/01-network.md

ref "GMU 0.87"                      "0.87"     docs/03-profile-gmu087.md recipe/deepseek-v4-flash-0731.yaml
ref "max_num_seqs 6"                "max_num_seqs: 6"            recipe/deepseek-v4-flash-0731.yaml
ref "batched tokens 4096"           "max_num_batched_tokens: 4096" recipe/deepseek-v4-flash-0731.yaml
ref "long prefill threshold 1024"   "long_prefill_token_threshold: 1024" recipe/deepseek-v4-flash-0731.yaml
ref "retention interval 4096"       "VLLM_PREFIX_CACHE_RETENTION_INTERVAL" recipe/deepseek-v4-flash-0731.yaml
ref "DSpark k5"                     "num_speculative_tokens: 5"  recipe/deepseek-v4-flash-0731.yaml
ref "FP8 KV cache"                  "kv-cache-dtype fp8"         recipe/deepseek-v4-flash-0731.yaml
ref "graph-estimate flag"           "VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS" recipe/deepseek-v4-flash-0731.yaml docs/03-profile-gmu087.md
ref "graph-estimate caveat"         "did not free any physical memory"  docs/03-profile-gmu087.md
ref "cudagraph mode + cap"          "FULL_AND_PIECEWISE"         recipe/deepseek-v4-flash-0731.yaml docs/03-profile-gmu087.md
ref "cudagraph cap 64"              "max_cudagraph_capture_size: 64" recipe/deepseek-v4-flash-0731.yaml
ref "prefix caching"                "enable-prefix-caching"      recipe/deepseek-v4-flash-0731.yaml
ref "prompt token details"          "enable-prompt-tokens-details" recipe/deepseek-v4-flash-0731.yaml
ref "tool call parser"              "tool-call-parser deepseek_v4" recipe/deepseek-v4-flash-0731.yaml
ref "reasoning parser"              "reasoning-parser deepseek_v4" recipe/deepseek-v4-flash-0731.yaml

ref "API ceiling 1,048,576"         "1,048,576"  docs/04-capacity-and-health.md
ref "API ceiling raw"               "1048576"    config/pinned-artifacts.env
ref "limiting KV pool"              "2,356,056"  docs/04-capacity-and-health.md
ref "limiting KV pool raw"          "2356056"    config/pinned-artifacts.env
ref "rank0 KV"                      "19.27 GiB"  docs/04-capacity-and-health.md
ref "rank1 KV (limiting)"           "17.14 GiB"  docs/04-capacity-and-health.md
ref "units caveat"                  "not a per-request limit" docs/04-capacity-and-health.md

ref "benchmark date"                "2026-08-23" docs/05-benchmarks-2026-08-23.md
ref "aggregate vs per-stream"       "Per-stream" docs/05-benchmarks-2026-08-23.md
ref "whole-batch definition"        "whole-batch" docs/05-benchmarks-2026-08-23.md
ref "cold vs warm distinction"      "warm-cache service measurement" docs/05-benchmarks-2026-08-23.md
ref "prefix cache detail"           "49,920"     docs/05-benchmarks-2026-08-23.md
ref "DSpark acceptance"             "37.1"       docs/05-benchmarks-2026-08-23.md

ref "prereq driver"                 "580.173.02" docs/02-prerequisites-and-limitations.md
ref "prereq docker"                 "29.2.1"     docs/02-prerequisites-and-limitations.md
ref "prereq kernel"                 "6.17.0-1029-nvidia" docs/02-prerequisites-and-limitations.md
ref "prereq OS"                     "Ubuntu 24.04.4"     docs/02-prerequisites-and-limitations.md
ref "prereq arch"                   "arm64"      docs/02-prerequisites-and-limitations.md
ref "prereq GPU"                    "GB10"       docs/02-prerequisites-and-limitations.md
ref "image size disclosed"          "23362056860" docs/02-prerequisites-and-limitations.md
ref "no auto recovery"              "No supervision, no auto-recovery" docs/02-prerequisites-and-limitations.md
ref "no auth/TLS"                   "No authentication, no TLS"        docs/02-prerequisites-and-limitations.md
ref "launcher not vendored"         "It is not self-contained"         docs/02-prerequisites-and-limitations.md
ref "mods not vendored"             "Neither is vendored here"         mods/README.md
ref "no arbitrary stock nodes"      "Do not claim more than this"      docs/02-prerequisites-and-limitations.md

# mod certification
ref "mods declared in recipe order" "PIN_MODS_ORDER=\"instanttensor-hybrid-draft-loader dsv4-reasoning-effort-fix\"" config/mods-pins.env
ref "mod digest A is UNAVAILABLE"   "PIN_MOD_DIGEST_INSTANTTENSOR_HYBRID_DRAFT_LOADER=\"UNAVAILABLE\"" config/mods-pins.env
ref "mod digest B is UNAVAILABLE"   "PIN_MOD_DIGEST_DSV4_REASONING_EFFORT_FIX=\"UNAVAILABLE\"" config/mods-pins.env
ref "mod manifest mechanism"        "MOD.sha256"   config/mods-pins.env mods/README.md MANIFEST.md
ref "exact marker path"             "/workspace/MODS_EXACT"     config/mods-pins.env
ref "non-exact marker path"         "/workspace/MODS_NON_EXACT" config/mods-pins.env
ref "exact apply fails closed"      "fails closed" config/mods-pins.env mods/README.md docs/02-prerequisites-and-limitations.md docs/06-operations-runbook.md README.md
ref "never pretend exact restore"   "NON-EXACT"    README.md mods/README.md docs/06-operations-runbook.md docs/02-prerequisites-and-limitations.md
ref "no exact restore today"        "There is no exact restore today" docs/06-operations-runbook.md

# network bootstrap
ref "route metric rail A"           "101" config/cluster.env.example docs/01-network.md
ref "route metric rail B"           "100" config/cluster.env.example docs/01-network.md
ref "never-default documented"      "never-default"    docs/01-network.md
ref "no DNS from a rail"            "ignore-auto-dns"  docs/01-network.md
ref "ipv4 manual documented"        "ipv4.method"      docs/01-network.md
ref "ipv6 disabled documented"      "ipv6.method"      docs/01-network.md
ref "runbook applies both rails"    "--rail both"      docs/06-operations-runbook.md README.md

# lifecycle
ref "partial-state doctrine"        "PARTIAL DEPLOYMENT" docs/06-operations-runbook.md
ref "stop three-state doctrine"     "STATE UNKNOWN"      docs/06-operations-runbook.md
ref "peer failure is a failure"     "unreachable peer"   docs/06-operations-runbook.md
ref "snapshot not refs/main"        "refs/main"          docs/06-operations-runbook.md

ref "primary-only API"              "Primary-only API behaviour" docs/00-as-deployed.md
ref "rank topology"                 "--node-rank"  docs/00-as-deployed.md docs/07-rank-differences.md
ref "host network"                  "--network host" docs/00-as-deployed.md
ref "privileged"                    "--privileged"   docs/00-as-deployed.md
ref "ipc host"                      "--ipc=host"     docs/00-as-deployed.md
ref "nofile limit"                  "1048576"        docs/00-as-deployed.md
ref "bind mounts"                   "/root/.cache/huggingface" docs/00-as-deployed.md
ref "intentional rank differences"  "Intentional"    docs/07-rank-differences.md
ref "restore/rollback"              "Restore and rollback" docs/06-operations-runbook.md
ref "troubleshooting"               "Troubleshooting"      docs/06-operations-runbook.md
ref "worker-before-primary"         "worker (rank 1"       docs/06-operations-runbook.md
ref "coordinated stop"              "rank 0 first"         docs/06-operations-runbook.md

# ---------------------------------------------------------------------------
sect "6. Checksums"
if [[ -f SHA256SUMS ]]; then
    if out="$(sha256sum -c --quiet SHA256SUMS 2>&1)"; then
        pass "sha256sum -c SHA256SUMS"
    else
        fail "SHA256SUMS verification failed"
        printf '%s\n' "$out" | sed 's/^/       /'
    fi
    grep -q '  SHA256SUMS$' SHA256SUMS && fail "SHA256SUMS lists itself" || pass "SHA256SUMS excludes itself"

    TMPD="$(mktemp -d)"
    checksummed_files > "$TMPD/expect"
    awk '{ $1=""; sub(/^ +/,""); print }' SHA256SUMS | sort > "$TMPD/actual"
    if diff -q "$TMPD/expect" "$TMPD/actual" >/dev/null; then
        pass "SHA256SUMS covers exactly the canonical file set ($(wc -l < "$TMPD/expect") files)"
    else
        fail "SHA256SUMS does not cover the canonical file set"
        diff "$TMPD/expect" "$TMPD/actual" | sed 's/^/       /'
    fi
    rm -rf -- "$TMPD"
else
    fail "SHA256SUMS is missing"
fi

RECIPE_HASH="$(sha256sum recipe/deepseek-v4-flash-0731.yaml 2>/dev/null | awk '{print $1}')"
[[ "$RECIPE_HASH" == "$PIN_RECIPE_SHA256" ]] \
    && pass "vendored recipe is byte-exact with the live recipe (${PIN_RECIPE_SHA256})" \
    || fail "vendored recipe hashes to ${RECIPE_HASH}, live recipe is ${PIN_RECIPE_SHA256}"

# ---------------------------------------------------------------------------
sect "7. Placeholder audit"
# The placeholder convention is an ALL-CAPS token inside angle brackets.
PH_OPEN='<'; PH_CLOSE='>'
for marker in "PUT-YOUR-HUGGINGFACE-READ-TOKEN-HERE" "OPTIONAL-REGISTRY-USERNAME" "OPTIONAL-REGISTRY-PASSWORD"; do
    grep -qF "${PH_OPEN}${marker}${PH_CLOSE}" config/hf-credentials.env.example \
        && pass "placeholder present: ${marker}" \
        || fail "placeholder missing from config/hf-credentials.env.example: ${marker}"
done

# No credential-shaped variable may be assigned a concrete literal anywhere.
CRED_ASSIGN='(HF_TOKEN|HUGGING_FACE_HUB_TOKEN|REGISTRY_PASSWORD|REGISTRY_USERNAME|HF_API_KEY)[[:space:]]*=[[:space:]]*"?[A-Za-z0-9]'
HITS="$(tracked_files | xargs -r grep -nE "$CRED_ASSIGN" 2>/dev/null | grep -v 'HF_TOKEN}' || true)"
if [[ -z "$HITS" ]]; then
    pass "no credential variable is assigned a literal value"
else
    fail "credential variable assigned a literal value:"
    printf '%s\n' "$HITS" | sed 's/^/       /'
fi

# The example credential file must not be shadowed by a real one, and the
# angle-bracket convention must be understood by the scripts.
grep -q 'is_placeholder' scripts/lib/common.sh \
    && pass "scripts treat <PLACEHOLDER> values as unset" \
    || fail "scripts/lib/common.sh has no is_placeholder guard"
grep -q 'is_placeholder' scripts/20-fetch-model.sh \
    && pass "model fetch refuses placeholder credentials" \
    || fail "scripts/20-fetch-model.sh does not check for placeholder credentials"

# Template markers must survive.
for m in '@@MODEL@@' '@@HOST@@' '@@PORT@@' '@@RANK_ARGS@@'; do
    grep -qF "$m" templates/exec-script.sh.tmpl \
        && pass "template marker intact: $m" || fail "template marker missing: $m"
done

# No unresolved authoring markers.
# Assembled from fragments so this line is not itself an instance of any
# marker it searches for.
MARKER_RE="(TO""DO|FI""XME|X""XX|REPLA""CE[_-]ME|CHANGE""ME)"
LEFTOVER="$(tracked_files | xargs -r grep -nE "$MARKER_RE" 2>/dev/null || true)"
[[ -z "$LEFTOVER" ]] && pass "no unresolved authoring markers" || { fail "unresolved authoring markers:"; printf '%s\n' "$LEFTOVER" | sed 's/^/       /'; }

# ---------------------------------------------------------------------------
sect "8. Hash inventory (blocks raw machine/container IDs)"
# Any 64-hex string in the bundle must be a known, documented artifact hash or
# one of our own SHA256SUMS entries. Docker container IDs and image IDs from the
# live machines are also 64-hex, so this check is what keeps them out.
ALLOWED_HASHES=(
    "2dcd8e9a9448ab51ea8ed6cebfb12961abdb1d278912ca4f0da4e4e8ad98379b"  # live recipe
    "d587df37af3a37f50328e0e72030177a7e864fff41e4b2edea354c5c6e52dd1a"  # live launcher
    "eb3ed2bbb0c91dc6d41282d22532267b5a449088c78a032400cd887fe9ddd2c5"  # image digest
    "d43f15877df4176dfc70b7ebca336d5de698e1696da02fc3738b0338a65f5db2"  # image ID
    "e4c4a0187f5c688601466b279dc04cfb6acca23b70fb6c981ddedeaa1a6fd04d"  # live bundle AS_DEPLOYED.json
    "1881404e7951093700ecf70db4a0b62cd4ca2c925a218d5d7adb11a8130fa15a"  # live bundle README.md
    "592779520e94328f644820ec4f3f1ab99461271363d8754ce906dcfcbc9d152d"  # live bundle FILES.sha256
)
TMPD="$(mktemp -d)"
printf '%s\n' "${ALLOWED_HASHES[@]}" > "$TMPD/allow"
[[ -f SHA256SUMS ]] && awk '{print $1}' SHA256SUMS >> "$TMPD/allow"
sort -u "$TMPD/allow" -o "$TMPD/allow"
tracked_files | xargs -r grep -ohE '\b[0-9a-f]{64}\b' 2>/dev/null | sort -u > "$TMPD/found"
UNKNOWN="$(comm -23 "$TMPD/found" "$TMPD/allow")"
if [[ -z "$UNKNOWN" ]]; then
    pass "every 64-hex string is a documented artifact hash ($(wc -l < "$TMPD/found") distinct)"
else
    fail "undocumented 64-hex string(s) — possible container/machine ID:"
    printf '%s\n' "$UNKNOWN" | sed 's/^/       /'
fi
rm -rf -- "$TMPD"

# The specific live container IDs must never appear. The prefixes are spliced
# from fragments so this denylist is not itself a copy of what it denies.
for cid in "57f8a9""50" "037e05""8c"; do
    if tracked_files | xargs -r grep -lF "$cid" 2>/dev/null | grep -q .; then
        fail "live container ID prefix '${cid}' appears in the bundle"
    else
        pass "live container ID prefix '${cid}' absent"
    fi
done

# ---------------------------------------------------------------------------
sect "9. Secret scan"
# Each pattern is a fixed prefix followed by a bracket expression, so the
# pattern's own literal text is never an instance of the pattern.
declare -a PATTERNS=(
    'hf_[A-Za-z0-9]{30,}'
    'AKIA[0-9A-Z]{16}'
    'ASIA[0-9A-Z]{16}'
    'gh[pousr]_[A-Za-z0-9]{20,}'
    'sk-[A-Za-z0-9]{20,}'
    'xox[abprs]-[A-Za-z0-9-]{10,}'
    'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'ssh-rsa [A-Za-z0-9+/]{100,}'
    '(password|passwd|secret|api_?key|auth_?token)[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9/+_-]{16,}'
)
SECRET_HITS=""
for p in "${PATTERNS[@]}"; do
    h="$(tracked_files | xargs -r grep -nEI -- "$p" 2>/dev/null || true)"
    [[ -n "$h" ]] && SECRET_HITS+="${h}"$'\n'
done
if [[ -z "${SECRET_HITS//[$'\n\t ']/}" ]]; then
    pass "no token, key or credential-shaped strings found (${#PATTERNS[@]} patterns, all files including this one)"
else
    fail "possible secret material:"
    printf '%s' "$SECRET_HITS" | sed 's/^/       /'
fi

# Sanity-check the detector itself so a broken regex cannot silently pass.
TMPD="$(mktemp -d)"
{ printf 'hf_%s\n' "$(printf 'a%.0s' {1..34})"
  printf 'AKIA%s\n' "ABCDEFGHIJKLMNOP"
  printf 'password = %s\n' "$(printf 'b%.0s' {1..20})"; } > "$TMPD/canary"
DETECTED=0
for p in "${PATTERNS[@]}"; do
    grep -qEI -- "$p" "$TMPD/canary" 2>/dev/null && DETECTED=$((DETECTED + 1))
done
[[ "$DETECTED" -ge 3 ]] \
    && pass "detector self-test: ${DETECTED} patterns fired on synthetic canaries" \
    || fail "detector self-test failed (only ${DETECTED} patterns fired) — the secret scan is not trustworthy"
rm -rf -- "$TMPD"

# ---------------------------------------------------------------------------
sect "10. Recipe policy invariants"
# These assert that the safety behaviours this recipe claims are actually
# implemented, not merely described in prose.

inv() {  # <description> <file> <pattern...>  -- every pattern must be present
    local desc="$1" f="$2"; shift 2
    local missing="" pat
    for pat in "$@"; do grep -qF -- "$pat" "$f" 2>/dev/null || missing+=" [${pat}]"; done
    if [[ -z "$missing" ]]; then pass "$desc"; else fail "${desc} — ${f} lacks:${missing}"; fi
}

# -- mod certification --
inv "start fails closed on non-exact mods" scripts/40-start.sh \
    "refusing to launch: exact mod certification is not achievable" \
    "--non-exact-mods" "NOT-EXACT" "CERT_MODE"
inv "start stamps a certification marker" scripts/40-start.sh \
    "PIN_MOD_MARKER_EXACT" "PIN_MOD_MARKER_NON_EXACT" "docker cp \"\$MARKER_LOCAL\""
inv "foreign mods are rejected" scripts/lib/common.sh \
    "assert_no_foreign_mods() {" "    assert_no_foreign_mods" \
    "unknown mod directory" "unexpected executable file in mods/" \
    "does not declare"
inv "mods are certified by content digest" scripts/lib/common.sh \
    "mod_manifest_body" "mod_content_digest" "UNPINNABLE" "TAMPERED" "MISMATCH" \
    "| LC_ALL=C sort | xargs -r sha256sum" "! -name \"\$PIN_MOD_MANIFEST\""
inv "pin promotion stays manual" scripts/25-pin-mods.sh \
    "Copy the lines above into config/mods-pins.env"

# -- verification --
inv "verify fails on a missing container" scripts/60-verify-deployment.sh \
    "does not exist on this node" "container.running"
inv "verify fails on an unreachable peer" scripts/60-verify-deployment.sh \
    "peer.unreachable" "not an assumption of health"
inv "verify fails on NON-EXACT certification" scripts/60-verify-deployment.sh \
    "mods.certification" "NON-EXACT marker present" "no certification marker"
inv "verify checks required runtime config" scripts/60-verify-deployment.sh \
    "runtime.network" "runtime.privileged" "runtime.ipc" "runtime.nofile"
inv "verify checks all five mounts exactly" scripts/60-verify-deployment.sh \
    "mounts.count" "mounts.common_root" ".cache/huggingface .cache/vllm .cache/flashinfer .triton .tilelang"
inv "verify checks rank fabric env" scripts/60-verify-deployment.sh \
    "env.VLLM_HOST_IP" "env.RAY_NODE_IP_ADDRESS" "EXPECT_FABRIC_IP"
inv "verify checks recipe env from /proc" scripts/60-verify-deployment.sh \
    "recipe_env." "/proc/" "VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0"
inv "verify checks argv, rank and headless" scripts/60-verify-deployment.sh \
    "argv.exact" "argv.node_rank" "argv.headless" "argv.rendezvous"
inv "verify checks fabric and listeners" scripts/60-verify-deployment.sh \
    "fabric.address" "rdma link show" "api.listener"
inv "peer runs the identical probe" scripts/60-verify-deployment.sh \
    "PROBE_BODY" "ssh \"\${SSH_OPTS[@]}\" \"\$WORKER_SSH_TARGET\" 'bash -s'"

# -- network bootstrap --
inv "network bootstrap uses management identity" scripts/05-setup-network.sh "detect_role_mgmt"
inv "management detection rejects ambiguity" scripts/lib/common.sh "AMBIGUOUS node identity"
inv "network defaults to both rails" scripts/05-setup-network.sh 'RAIL="both"'
inv "network sets the audited properties" scripts/05-setup-network.sh \
    "ipv4.method|manual" "ipv4.never-default|yes" "ipv4.ignore-auto-dns|yes" \
    "ipv4.dns|" "ipv4.route-metric" "ipv6.method|disabled" "802-3-ethernet.mtu"
inv "network verifies what it applied" scripts/05-setup-network.sh \
    "verify_rail" "route metric" "carries a DEFAULT route"
for f in scripts/40-start.sh scripts/60-verify-deployment.sh scripts/90-stop.sh; do
    inv "fabric identity check retained: $(basename "$f")" "$f" "detect_role"
done
inv "fabric assertion still enforced" scripts/lib/common.sh \
    "require_fabric" "expected UP" "expected ACTIVE"

# -- lifecycle --
inv "start creates the worker container first" scripts/40-start.sh \
    "Creating containers — worker first" "CREATED_WORKER" "CREATED_PRIMARY"
inv "start cleans up only what it created" scripts/40-start.sh \
    "cleanup_created" "removing only the containers THIS RUN created"
inv "start never silently removes after dispatch" scripts/40-start.sh \
    "partial_state_report" "PARTIAL DEPLOYMENT" 'DISPATCHED="worker"' 'DISPATCHED="both"'
inv "stop distinguishes unknown from down" scripts/90-stop.sh \
    "STATE UNKNOWN" "NEVER collapsed into" "worker-unreachable"
inv "stop re-verifies before claiming success" scripts/90-stop.sh \
    "Result — re-verifying" "BOTH ranks verified down" "STOP INCOMPLETE OR UNVERIFIED"

# -- model pin --
inv "model pin requires a real snapshot" scripts/lib/common.sh \
    "if ! probe_pinned_model; then" "hf_snapshot_dir" \
    "HF_REQUIRED_ARTIFACTS=(config.json generation_config.json tokenizer_config.json)" \
    "tokenizer.json" "safetensors" "model.safetensors.index.json" \
    "partial download" "Refusing to start on an unverified model"
inv "refs/main is never sufficient alone" scripts/lib/common.sh \
    "operator-writable text file and is never sufficient"
inv "fetch requests the pinned commit directly" scripts/20-fetch-model.sh \
    "--revision" "The pinned commit is requested directly" "--establish-ref"
inv "refs/main is only ever derived" scripts/20-fetch-model.sh \
    "refusing to write refs/main for an unverified snapshot"

# -- live behaviour of the helpers, not just their text --
# shellcheck source=lib/common.sh
if ( set +u; source scripts/lib/common.sh >/dev/null 2>&1; load_mod_pins; probe_mods
     [[ "$MODS_STATE" != "EXACT" ]] ) 2>/dev/null; then
    pass "probe_mods reports non-EXACT with no certified mods (fail-closed default holds)"
else
    fail "probe_mods claims EXACT although no mods are supplied — the fail-closed default is broken"
fi

# A cache containing ONLY a hand-written refs/main must be rejected. This is the
# falsification the model pin exists to defeat, so it is tested live.
# The verdict is read from an explicit token, not from the subshell's exit
# status: with `set -e` and `pipefail` inherited from the library, a subshell
# can die for an unrelated reason and look like a correct rejection.
probe_model_verdict() {   # <populate-fn>
    (
        set +u
        # shellcheck source=lib/common.sh
        source scripts/lib/common.sh >/dev/null 2>&1
        set +e +o pipefail
        load_pins >/dev/null 2>&1
        export HF_HOME="$TMPH"
        "$1"
        if probe_pinned_model >/dev/null 2>&1; then echo ACCEPTED; else echo REJECTED; fi
    ) 2>/dev/null
}

TMPH="$(mktemp -d)"
populate_ref_only() {
    mkdir -p "$(dirname -- "$(hf_ref_main)")"
    printf '%s' "$PIN_MODEL_REVISION" > "$(hf_ref_main)"
}
export -f populate_ref_only 2>/dev/null || true
V="$(TMPH="$TMPH" probe_model_verdict populate_ref_only)"
if [[ "$V" == "REJECTED" ]]; then
    pass "a hand-written refs/main alone is rejected as evidence of the model"
else
    fail "probe_pinned_model returned '${V}' for a cache holding only refs/main and no snapshot"
fi
rm -rf -- "$TMPH"

# ...and the converse, so the rejection above is not vacuous.
TMPH="$(mktemp -d)"
populate_complete() {
    local snap; snap="$(hf_snapshot_dir)"
    mkdir -p "$snap" "$(dirname -- "$(hf_ref_main)")"
    : > "${snap}/config.json"; : > "${snap}/generation_config.json"
    : > "${snap}/tokenizer_config.json"; : > "${snap}/tokenizer.json"
    : > "${snap}/model.safetensors"
    printf '%s' "$PIN_MODEL_REVISION" > "$(hf_ref_main)"
}
V="$(TMPH="$TMPH" probe_model_verdict populate_complete)"
if [[ "$V" == "ACCEPTED" ]]; then
    pass "a complete snapshot is accepted (the model check is not vacuously strict)"
else
    fail "probe_pinned_model returned '${V}' for a complete snapshot"
fi
rm -rf -- "$TMPH"

# A snapshot directory that EXISTS but is incomplete must also be rejected.
# This is the case that exercises the probe's final verdict rather than its
# early "directory missing" return, so a weakened verdict cannot hide here.
TMPH="$(mktemp -d)"
populate_incomplete() {
    local snap; snap="$(hf_snapshot_dir)"
    mkdir -p "$snap" "$(dirname -- "$(hf_ref_main)")"
    : > "${snap}/config.json"            # and nothing else
    printf '%s' "$PIN_MODEL_REVISION" > "$(hf_ref_main)"
}
V="$(TMPH="$TMPH" probe_model_verdict populate_incomplete)"
if [[ "$V" == "REJECTED" ]]; then
    pass "an existing but incomplete snapshot is rejected"
else
    fail "probe_pinned_model returned '${V}' for a snapshot missing its tokenizer and weights"
fi
rm -rf -- "$TMPH"

TMPD="$(mktemp -d)"
mkdir -p "$TMPD/m/sub"; printf 'a\n' > "$TMPD/m/run.sh"; printf 'b\n' > "$TMPD/m/sub/x"
D1="$( set +u; source scripts/lib/common.sh >/dev/null 2>&1; load_mod_pins; mod_content_digest "$TMPD/m" )"
printf 'b\n' > "$TMPD/m/sub/x"
D2="$( set +u; source scripts/lib/common.sh >/dev/null 2>&1; load_mod_pins; mod_content_digest "$TMPD/m" )"
printf 'CHANGED\n' > "$TMPD/m/sub/x"
D3="$( set +u; source scripts/lib/common.sh >/dev/null 2>&1; load_mod_pins; mod_content_digest "$TMPD/m" )"
if [[ -n "$D1" && "$D1" == "$D2" && "$D1" != "$D3" ]]; then
    pass "mod content digest is deterministic and content-sensitive"
else
    fail "mod content digest is not deterministic or not content-sensitive (${D1} / ${D2} / ${D3})"
fi
rm -rf -- "$TMPD"

# ---------------------------------------------------------------------------
sect "Result"
printf '  checks: %d   failures: %d   warnings: %d\n' "$CHECKS" "$FAIL" "$WARN"
if [[ "$FAIL" -gt 0 ]]; then
    printf '\n%s\n' "$(_c '0;31' 'VALIDATION FAILED')"
    exit 1
fi
printf '\n%s\n' "$(_c '0;32' 'VALIDATION PASSED')"
[[ "$WARN" -gt 0 ]] && printf '%s\n' "(with ${WARN} warning(s))"
exit 0
