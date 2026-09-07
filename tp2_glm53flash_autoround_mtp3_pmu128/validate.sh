#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

IMAGE_TAG="spark-recipes/glm53-autoround-mtp3-pmu128:20260903"
MODEL_REV="5eee1846f0321058ed73745f9aa16f2aaf0fc0a0"
SRC_CONFIG_SHA="d4deaf40c47b2ff49f1d8e0c306032d7a8b84f90b6a2743e694b712d87dd5692"
SRC_INDEX_SHA="a250db4fcc9443d0164335a7a2c7a1da4eef91e212304e2e695a08d565a75102"
OUT_CONFIG_SHA="958beaf7c4ddf9ba1d8dcb5e938fcddc0deaa62d41e0f85909a45a12ae8c97a6"
EXPLICIT_OFFLINE=0
IMAGE_CHECK=""
BASE_ROOT=""
MODEL_BOUND=0
BASE_BOUND=0
IMAGE_BOUND=0
BASE_DIGEST="ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6"
BASE_DIGEST_VALUE="${BASE_DIGEST##*@}"
usage() { echo "usage: validate.sh [--offline-unit|--no-network] [--base-root DIR] [--image TAG]"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-network|--offline-unit) EXPLICIT_OFFLINE=1 ;;
    --image)
      [[ $# -ge 2 ]] || { echo "--image requires a tag"; usage; exit 2; }
      IMAGE_CHECK="$2"; shift ;;
    --base-root)
      [[ $# -ge 2 ]] || { echo "--base-root requires a directory"; usage; exit 2; }
      BASE_ROOT="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done
if [[ -n "$IMAGE_CHECK" && "$EXPLICIT_OFFLINE" == 1 ]]; then
  echo "conflicting args: --image needs the network; drop --offline-unit/--no-network"; exit 2
fi
if [[ -n "$IMAGE_CHECK" && -n "$BASE_ROOT" ]]; then
  echo "conflicting args: --image and --base-root are alternative base bindings; use one"; exit 2
fi
APPLIER="$PWD/apply_runtime_patches.py"
ADAPTER="$PWD/adapt_autoround_to_gptq.py"

echo "== required files =="
for f in README.md Dockerfile launch.sh apply_runtime_patches.py \
         adapt_autoround_to_gptq.py validate.sh SHA256SUMS \
         patches/0001-vllm-53388-native-mtp-block-drop.patch \
         patches/0002-vllm-53906-coordinator-partial-hits.patch \
         patches/0003-vllm-scheduler-lcm-mamba-block-align.patch \
         patches/sparse_attn_indexer_kpool_sm121.py \
         patches/base-fixture.tar.xz; do
  [[ -f "$f" ]] || { echo "missing $f"; exit 1; }
done
[[ -x validate.sh ]] || { echo "validate.sh must be executable (chmod 0755)"; exit 1; }

echo "== syntax =="
bash -n launch.sh validate.sh
PYTHONDONTWRITEBYTECODE=1 python3 -c 'import ast,pathlib
for n in ("apply_runtime_patches.py","adapt_autoround_to_gptq.py"):
    ast.parse(pathlib.Path(n).read_text(encoding="utf-8"))
print("python ast OK")'

echo "== checksums =="
sha256sum -c SHA256SUMS

echo "== secret and local-path scan =="
SCAN_TARGETS="README.md Dockerfile launch.sh apply_runtime_patches.py adapt_autoround_to_gptq.py patches"
if grep -rEn 'hf_[0-9A-Za-z]{20,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|password[[:space:]]*=' \
      $SCAN_TARGETS >/dev/null; then
  echo "secret pattern found"; exit 1
fi
if grep -rEn '\.recipe-provenance|intel-glm53-autoround-dflash2|intel-autoround-runtime|intel-glm53-debug' \
      $SCAN_TARGETS >/dev/null; then
  echo "local experiment path found"; exit 1
fi

echo "== launcher invariants =="
[[ ! -x launch.sh ]]
grep -Fq -- '--speculative-config '\''{"method":"mtp","num_speculative_tokens":3,"disable_eagle_block_drop":true}'\''' launch.sh
grep -Fq -- '--prefix-match-unit 128' launch.sh
grep -Fq -- '--kv-cache-memory 13500000000' launch.sh
grep -Fq -- '--kv-cache-dtype fp8_e4m3' launch.sh
grep -Fq -- '--max-num-batched-tokens 8192' launch.sh
grep -Fq -- '--max-num-seqs 6' launch.sh
grep -Fq -- '--max-model-len 1048576' launch.sh
grep -Fq -- '--block-size 2304' launch.sh
grep -Fq -- '--moe-backend marlin' launch.sh
grep -Fq -- '--enable-prefix-caching --enable-prompt-tokens-details --prefix-match-unit 128' launch.sh
[[ "$(grep -Fo -- '--enable-prompt-tokens-details' launch.sh | wc -l)" == 1 ]]
grep -Fq -- 'VLLM_PREFIX_CACHE_RETENTION_INTERVAL=0' launch.sh
grep -Fq -- '--gpu-memory-utilization 0.85' launch.sh
grep -Fq -- '--restart no' launch.sh
grep -Fq -- '--limit-mm-per-prompt '\''{"image":4,"video":0}'\''' launch.sh
grep -Fq -- '--tool-call-parser glm47' launch.sh
grep -Fq -- '--reasoning-parser glm45' launch.sh
grep -Fq -- '--master-addr "$HEAD"' launch.sh
grep -Fq -- 'VLLM_ENGINE_READY_TIMEOUT_S=3600' launch.sh
! grep -Eq -- '-v [^ ]*dist-packages' launch.sh
! grep -Fq -- '--restart always' launch.sh
! grep -Fq -- 'dflash' launch.sh
grep -Fq "$IMAGE_TAG" launch.sh README.md

echo "== Dockerfile static checks =="
grep -Fq 'FROM ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6' Dockerfile
grep -Fq 'patches/0001-vllm-53388-native-mtp-block-drop.patch' Dockerfile
grep -Fq 'patches/0002-vllm-53906-coordinator-partial-hits.patch' Dockerfile
grep -Fq 'patches/0003-vllm-scheduler-lcm-mamba-block-align.patch' Dockerfile
grep -Fq 'patches/sparse_attn_indexer_kpool_sm121.py' Dockerfile
grep -Fq 'VLLM_DIST=/usr/local/lib/python3.12/dist-packages' Dockerfile
grep -Fq -- '--verify-only' Dockerfile
! grep -Eq '<<-' Dockerfile

echo "== static gate markers =="
grep -Fq 'RootFS.Layers' validate.sh
grep -Fq 'org.opencontainers.image.base.digest' validate.sh
grep -Fq 'BASE_DIGEST_VALUE="${BASE_DIGEST##*@}"' validate.sh
grep -Fq 'ast.parse(data.decode("utf-8"))' apply_runtime_patches.py
echo "static gates OK (image ancestry check with digest-only label comparison, overlay AST preflight)"

echo "== patch series replay against base fixture =="
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
tar -xJf patches/base-fixture.tar.xz -C "$WORK"
cat > "$WORK/before.SHA256SUMS" <<'EOF'
eaf52a03351398f72d3e85f0d1ce3bf80d1f92e0fddc8f28bdb11738aeab7875  vllm/config/speculative.py
ab5972fdea99fb19e78d2e34ff364012dd43e0b9314869854c279d0b26e30065  vllm/model_executor/layers/sparse_attn_indexer_kpool.py
f640b5c42f6bc718926329a8f8b48a0fd0c8c8f24368af4e4b9ec8d13f68432f  vllm/v1/core/kv_cache_coordinator.py
624ea7b0244972cb6c53044588912dfea54f3d6a91661cbc423af27e3b5c4b86  vllm/v1/core/kv_cache_utils.py
4c38a32c7405eb95eb9dd3b3d04cbfe5d0cb4ebc0b18efbaa4adc68c7a9bca5a  vllm/v1/core/sched/scheduler.py
41043976d1d5e38e0465c8004fc04e01f35f66b39a40099c62d79b3756337d00  vllm/v1/core/single_type_kv_cache_manager.py
EOF
(cd "$WORK" && sha256sum -c before.SHA256SUMS >/dev/null)
PYTHONDONTWRITEBYTECODE=1 python3 "$APPLIER" --root "$WORK" >/dev/null
PYTHONDONTWRITEBYTECODE=1 python3 "$APPLIER" --root "$WORK" --verify-only
printf '\n# tampered\n' >> "$WORK/vllm/config/speculative.py"
if PYTHONDONTWRITEBYTECODE=1 python3 "$APPLIER" --root "$WORK" --verify-only >/dev/null 2>&1; then
  echo "tampered tree unexpectedly verified"; exit 1
fi
echo "patch series replay OK (exact before/after hashes, tamper rejected)"

echo "== applier preflight atomicity (late-input tamper) =="
PF="$WORK/preflight"
mkdir -p "$PF"
tar -xJf patches/base-fixture.tar.xz -C "$PF"
printf 'x' >> "$PF/vllm/model_executor/layers/sparse_attn_indexer_kpool.py"
BEFORE="$(cd "$PF" && find . -type f | sort | xargs sha256sum | sha256sum | awk '{print $1}')"
if PYTHONDONTWRITEBYTECODE=1 python3 "$APPLIER" --root "$PF" >/dev/null 2>&1; then
  echo "tampered late input unexpectedly passed preflight"; exit 1
fi
AFTER="$(cd "$PF" && find . -type f | sort | xargs sha256sum | sha256sum | awk '{print $1}')"
[[ "$BEFORE" == "$AFTER" ]] || { echo "applier wrote despite failed preflight"; exit 1; }
echo "preflight atomicity OK: no write happens before every output is validated"

if [[ -n "$BASE_ROOT" ]]; then
  echo "== public base binding (--base-root $BASE_ROOT) =="
  [[ -d "$BASE_ROOT/vllm" ]] || { echo "no vllm/ tree under --base-root"; exit 1; }
  BR="$WORK/base-root"
  while IFS= read -r rel; do
    mkdir -p "$BR/$(dirname "$rel")"
    cp "$BASE_ROOT/$rel" "$BR/$rel"
  done <<'EOF'
vllm/config/speculative.py
vllm/model_executor/layers/sparse_attn_indexer_kpool.py
vllm/v1/core/kv_cache_coordinator.py
vllm/v1/core/kv_cache_utils.py
vllm/v1/core/sched/scheduler.py
vllm/v1/core/single_type_kv_cache_manager.py
EOF
  (cd "$BR" && sha256sum -c "$WORK/before.SHA256SUMS" >/dev/null)
  PYTHONDONTWRITEBYTECODE=1 python3 "$APPLIER" --root "$BR" >/dev/null
  PYTHONDONTWRITEBYTECODE=1 python3 "$APPLIER" --root "$BR" --verify-only
  BASE_BOUND=1
  echo "public base binding verified: the six pinned before-files under --base-root are byte-exact and the full patch series lands on the exact final hashes"
elif [[ "$EXPLICIT_OFFLINE" == 0 ]] && command -v docker >/dev/null 2>&1; then
  echo "== public base binding via Docker (digest pull if absent) =="
  docker image inspect "$BASE_DIGEST" >/dev/null 2>&1 || docker pull "$BASE_DIGEST"
  docker run --rm --entrypoint sh -w /usr/local/lib/python3.12/dist-packages \
    -v "$WORK/before.SHA256SUMS:/tmp/before.SHA256SUMS:ro" \
    "$BASE_DIGEST" sha256sum -c /tmp/before.SHA256SUMS >/dev/null
  BASE_BOUND=1
  echo "public base binding verified: pulled $BASE_DIGEST and confirmed the six pinned before-hashes inside it"
fi

if [[ "$EXPLICIT_OFFLINE" == 1 ]]; then
  echo "SKIP: model metadata tests (--offline-unit/--no-network)"
else
  echo "== model metadata tests (network; download failure fails the run) =="
  META="$WORK/hf-meta"
  mkdir -p "$META"
  BASE_URL="https://huggingface.co/Intel/GLM-5.3-Flash-W4A16-AutoRound/resolve/$MODEL_REV"
  curl -fsSL -o "$META/config.json" "$BASE_URL/config.json" \
    || { echo "FAIL: huggingface.co download error for config.json; use --no-network for offline-only validation"; exit 1; }
  curl -fsSL -o "$META/model.safetensors.index.json" "$BASE_URL/model.safetensors.index.json" \
    || { echo "FAIL: huggingface.co download error for model.safetensors.index.json; use --no-network for offline-only validation"; exit 1; }
  echo "$SRC_CONFIG_SHA  $META/config.json" | sha256sum -c - >/dev/null
  echo "$SRC_INDEX_SHA  $META/model.safetensors.index.json" | sha256sum -c - >/dev/null
  DST="$WORK/gptq-dst"
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$META" "$DST" --metadata-only
  [[ "$(sha256sum "$DST/config.json" | awk '{print $1}')" == "$OUT_CONFIG_SHA" ]]
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$META" "$DST" --metadata-only
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$META" "$DST" --metadata-only --check
  printf '\n' >> "$DST/config.json"
  if PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$META" "$DST" --metadata-only >/dev/null 2>&1; then
    echo "tampered destination unexpectedly accepted"; exit 1
  fi
  echo "model metadata adaptation OK (exact output config hash, idempotent, tamper rejected)"

  echo "== adapter nested-root rejection (both directions) =="
  NS="$WORK/nest-parent"
  mkdir -p "$NS/src"
  cp "$META/config.json" "$META/model.safetensors.index.json" "$NS/src/"
  if PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$NS/src" "$NS" >/dev/null 2>&1; then
    echo "dst-ancestor-of-src unexpectedly accepted"; exit 1
  fi
  if PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$NS/src" "$NS" --check >/dev/null 2>&1; then
    echo "check accepted dst-ancestor-of-src"; exit 1
  fi
  if PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$META" "$META/nested-dst" >/dev/null 2>&1; then
    echo "dst-inside-src unexpectedly accepted"; exit 1
  fi
  echo "nested-root rejection OK (dst ancestor of src, dst inside src; create and --check)"

  echo "== adapter full-mode preservation test (synthetic sparse shards, no weights) =="
  FSRC="$WORK/hf-meta-full"
  mkdir -p "$FSRC"
  cp "$META/config.json" "$META/model.safetensors.index.json" "$FSRC/"
  PYTHONDONTWRITEBYTECODE=1 python3 - "$META/model.safetensors.index.json" "$FSRC" <<'PY'
import json, sys
from pathlib import Path
index, root = Path(sys.argv[1]), Path(sys.argv[2])
for name in sorted({v for v in json.loads(index.read_text())["weight_map"].values()}):
    (root / name).write_bytes(b"shard:" + name.encode())
(root / "tokenizer_config.json").write_text('{"tokenizer_class":"G"}\n')
(root / "generation_config.json").write_text('{"eos_token_id":1}\n')
PY
  FDST="$WORK/gptq-full-dst"
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$FSRC" "$FDST"
  [[ -f "$FDST/model.safetensors.index.json" ]]
  [[ "$(sha256sum "$FDST/model.safetensors.index.json" | awk '{print $1}')" == "$SRC_INDEX_SHA" ]]
  [[ "$(sha256sum "$FDST/tokenizer_config.json" | awk '{print $1}')" == "$(sha256sum "$FSRC/tokenizer_config.json" | awk '{print $1}')" ]]
  [[ "$(sha256sum "$FDST/generation_config.json" | awk '{print $1}')" == "$(sha256sum "$FSRC/generation_config.json" | awk '{print $1}')" ]]
  [[ "$(sha256sum "$FDST/config.json" | awk '{print $1}')" == "$OUT_CONFIG_SHA" ]]
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$FSRC" "$FDST"
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$FSRC" "$FDST" --check
  printf 'tampered' > "$FDST/model-00001-of-00034.safetensors.new"
  mv "$FDST/model-00001-of-00034.safetensors.new" "$FDST/model-00001-of-00034.safetensors"
  if PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$FSRC" "$FDST" >/dev/null 2>&1; then
    echo "tampered shard unexpectedly accepted"; exit 1
  fi
  cp "$FSRC/model-00001-of-00034.safetensors" "$FDST/model-00001-of-00034.safetensors"
  rm "$FDST/GPTQ-SURGERY.json"
  if PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$FSRC" "$FDST" --check >/dev/null 2>&1; then
    echo "check accepted missing receipt"; exit 1
  fi
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$FSRC" "$FDST"
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$FSRC" "$FDST" --check
  printf '{"tampered":true}\n' > "$FDST/GPTQ-SURGERY.json"
  if PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$FSRC" "$FDST" --check >/dev/null 2>&1; then
    echo "check accepted tampered receipt"; exit 1
  fi
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$FSRC" "$FDST"
  echo "full-mode preservation OK (index/tokenizer/generation preserved byte-identically, config transformed, strict rerun; tamper rejected without refresh; missing/tampered receipt rejected by --check and refreshed by rerun)"
  MODEL_BOUND=1
fi

if [[ -n "$IMAGE_CHECK" ]]; then
  echo "== built-image ancestry/rootfs-prefix binding (--image $IMAGE_CHECK) =="
  command -v docker >/dev/null || { echo "docker not available for --image check"; exit 1; }
  docker image inspect "$BASE_DIGEST" >/dev/null 2>&1 || docker pull "$BASE_DIGEST"
  docker image inspect "$IMAGE_CHECK" >/dev/null
  BASE_LAYERS="$(docker image inspect --format '{{json .RootFS.Layers}}' "$BASE_DIGEST")"
  CAND_LAYERS="$(docker image inspect --format '{{json .RootFS.Layers}}' "$IMAGE_CHECK")"
  CAND_LABELS="$(docker image inspect --format '{{json .Config.Labels}}' "$IMAGE_CHECK")"
  PYTHONDONTWRITEBYTECODE=1 python3 - "$BASE_DIGEST_VALUE" "$BASE_LAYERS" "$CAND_LAYERS" "$CAND_LABELS" <<'PY'
import json, sys
digest, base_raw, cand_raw, labels_raw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
base, cand = list(json.loads(base_raw) or []), list(json.loads(cand_raw) or [])
labels = json.loads(labels_raw) or {}
if not base or not cand:
    raise SystemExit("ERROR: empty RootFS.Layers from docker inspect")
if len(cand) <= len(base):
    raise SystemExit(f"ERROR: candidate adds no layers on top of the base ({len(cand)} <= {len(base)})")
if cand[:len(base)] != base:
    raise SystemExit("ERROR: candidate RootFS.Layers do not start with the exact ordered base layer prefix")
label = labels.get("org.opencontainers.image.base.digest", "")
if label != digest:
    raise SystemExit(f"ERROR: candidate label org.opencontainers.image.base.digest={label!r} != pinned {digest}")
print("ancestry OK: candidate extends the exact ordered base RootFS.Layers prefix and carries the pinned base-digest label (rootfs-prefix binding, not a cryptographic Dockerfile proof)")
PY
  docker run --rm --entrypoint python3 -v "$PWD:/recipe:ro" "$IMAGE_CHECK" \
    /recipe/apply_runtime_patches.py --root /usr/local/lib/python3.12/dist-packages --verify-only
  IMAGE_BOUND=1
  echo "built-image binding verified: rootfs-prefix ancestry to the digest-pinned base plus exact final patch hashes inside the image"
fi

if [[ "$MODEL_BOUND" == 1 && ( "$BASE_BOUND" == 1 || "$IMAGE_BOUND" == 1 ) ]]; then
  if [[ "$IMAGE_BOUND" == 1 ]]; then
    echo "OK: COMPLETE validation passed (built image $IMAGE_CHECK: rootfs-prefix ancestry to the pinned base, exact final hashes inside, HF model metadata bound)"
  else
    echo "OK: COMPLETE validation passed (public base binding via --base-root, HF model metadata bound, exact final hashes replayed)"
  fi
  exit 0
fi
if [[ "$EXPLICIT_OFFLINE" == 1 ]]; then
  echo "OFFLINE UNIT VALIDATION ONLY - the model remote binding and a public-base digest binding were NOT both checked; this is never a COMPLETE pass even when --base-root passed. Complete gate: ./validate.sh (network; Docker auto-binds the base), --base-root <dist-packages of the pinned base> without an offline flag, or --image <built tag>"
  exit 0
fi
echo "PARTIAL: HF model metadata binding and offline patch replay passed, but the public base digest was NOT bound (no Docker detected and no --base-root given). Do not treat this as a complete reproducibility pass. Complete gate: --base-root <dist-packages of the pinned base>, Docker default run, or --image <built tag>"
exit 3
