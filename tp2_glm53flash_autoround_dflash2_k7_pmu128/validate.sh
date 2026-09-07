#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

IMAGE_TAG="spark-recipes/glm53-autoround-dflash2-k7-pmu128:20260904"
BASE_DIGEST="ghcr.io/tonyd2wild/vllm-glm53-flash@sha256:4def0ef644cb2e9814136dcffd5e385e21bc594f48f3b292234051904abe85a6"
BASE_DIGEST_VALUE="${BASE_DIGEST##*@}"
TARGET_REV="5eee1846f0321058ed73745f9aa16f2aaf0fc0a0"
TARGET_CONFIG_SHA="d4deaf40c47b2ff49f1d8e0c306032d7a8b84f90b6a2743e694b712d87dd5692"
TARGET_INDEX_SHA="a250db4fcc9443d0164335a7a2c7a1da4eef91e212304e2e695a08d565a75102"
TARGET_OUTPUT_SHA="958beaf7c4ddf9ba1d8dcb5e938fcddc0deaa62d41e0f85909a45a12ae8c97a6"
DRAFT_REV="bf582e4eacc1810f76656d1811693ff6c6737d2a"
DRAFT_CONFIG_SHA="c4aeac0101196a6e26705b34c45230bcd0c7c68ee2d2d1efdb242087f3712573"
DRAFT_LFS_SHA="b038e1d9d1e7833fa3880c2c0135ba9b673013f03da1b29fb831931584759dac"
DRAFT_LFS_SIZE=2342169800
DRAFT_HOST_DEFAULT="/home/ubuntu/models/GLM-5.3-Flash-DFlash2-bf582e4e"
OVERLAY_REV="050081dc41ce6edd4d3f15fa19dc3410ba4210e3"

EXPLICIT_OFFLINE=0
IMAGE_CHECK=""
BASE_ROOT=""
MODEL_BOUND=0
OVERLAY_BOUND=0
BASE_BOUND=0
IMAGE_BOUND=0
BASE_BINDING=""

usage() {
  echo "usage: validate.sh [--offline-unit|--no-network] [--base-root DIR] [--image TAG]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-network|--offline-unit)
      EXPLICIT_OFFLINE=1
      ;;
    --image)
      [[ $# -ge 2 ]] || { echo "--image requires a tag"; usage; exit 2; }
      IMAGE_CHECK=$2
      shift
      ;;
    --base-root)
      [[ $# -ge 2 ]] || { echo "--base-root requires a directory"; usage; exit 2; }
      BASE_ROOT=$2
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1"
      usage
      exit 2
      ;;
  esac
  shift
done

if [[ -n $IMAGE_CHECK && $EXPLICIT_OFFLINE == 1 ]]; then
  echo "conflicting args: --image requires the complete network gate"
  exit 2
fi
if [[ -n $IMAGE_CHECK && -n $BASE_ROOT ]]; then
  echo "conflicting args: --image and --base-root are alternative base bindings"
  exit 2
fi

APPLIER="$PWD/apply_runtime_patches.py"
ADAPTER="$PWD/adapt_autoround_to_gptq.py"
BASE_SUMS="$PWD/patches/base-fixture.SHA256SUMS"
FINAL_SUMS="$PWD/patches/final-runtime.SHA256SUMS"

echo "== required files and modes =="
required=(
  README.md Dockerfile launch.sh apply_runtime_patches.py
  adapt_autoround_to_gptq.py validate.sh SHA256SUMS
  patches/0001-vllm-53388-native-mtp-block-drop.patch
  patches/0002-vllm-53906-coordinator-partial-hits.patch
  patches/0003-vllm-scheduler-lcm-mamba-block-align.patch
  patches/dflash2-pmu128-swa-fine-hits.patch
  patches/sparse_attn_indexer_kpool_sm121.py
  patches/base-fixture.tar.xz patches/base-fixture.SHA256SUMS
  patches/final-runtime.SHA256SUMS
  tests/run.sh tests/exact_image_harness.py tests/test_runtime_profile.py
  tests/fixtures/dflash2-config.json
  tests/fixtures/vllm_config_487ecf.py
  tests/fixtures/worker_utils_487ecf.py
  tests/fixtures/gpu_model_runner_487ecf.py
)
for file in "${required[@]}"; do
  [[ -f $file ]] || { echo "missing $file"; exit 1; }
done
[[ -x validate.sh ]] || { echo "validate.sh must be executable"; exit 1; }
[[ -x tests/run.sh ]] || { echo "tests/run.sh must be executable"; exit 1; }
[[ ! -x launch.sh ]] || { echo "launch.sh must remain deliberately non-executable"; exit 1; }

echo "== syntax =="
bash -n launch.sh validate.sh tests/run.sh
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import ast
from pathlib import Path

for path in sorted(Path(".").rglob("*.py")):
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
print("all bundled Python parses")
PY

echo "== checksum closure =="
! grep -Eq '[[:space:]]SHA256SUMS$' SHA256SUMS || {
  echo "SHA256SUMS must exclude itself"
  exit 1
}
sha256sum --check --strict SHA256SUMS
listed=$(mktemp)
actual=$(mktemp)
cleanup_lists() { rm -f -- "$listed" "$actual"; }
trap cleanup_lists EXIT
cut -c67- SHA256SUMS | sort >"$listed"
find . -type f ! -name SHA256SUMS ! -path '*/__pycache__/*' ! -name '*.pyc' \
  -printf '%P\n' | sort >"$actual"
diff -u "$actual" "$listed" || {
  echo "SHA256SUMS coverage mismatch"
  exit 1
}
rm -f -- "$listed" "$actual"
trap - EXIT

echo "== secret and repository-dependency scan =="
scan_targets=(README.md Dockerfile launch.sh apply_runtime_patches.py \
  adapt_autoround_to_gptq.py patches tests)
if grep -rIEn 'hf_[0-9A-Za-z]{20,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|password[[:space:]]*=' \
    "${scan_targets[@]}" >/dev/null; then
  echo "secret pattern found"
  exit 1
fi
if grep -rIEn '\.recipe-provenance|intel-glm53-autoround-dflash2|DFLASH2_CANDIDATE_ROOT' \
    "${scan_targets[@]}" >/dev/null; then
  echo "local experiment dependency found"
  exit 1
fi

echo "== exact launcher invariants =="
grep -Fq "$IMAGE_TAG" launch.sh
grep -Fq 'DRAFT=/models/dflash2' launch.sh
grep -Fq "DRAFT_HOST=\"\${DRAFT_HOST:-${DRAFT_HOST_DEFAULT}}\"" launch.sh
grep -Fq 'HEAD="${HEAD:-10.0.7.1}"' launch.sh
grep -Fq 'MPORT="${MPORT:-29531}"' launch.sh
grep -Fq 'PORT="${PORT:-8888}"' launch.sh
grep -Fq 'HOST_IP=10.0.7.1' launch.sh
grep -Fq 'HOST_IP=10.0.7.2' launch.sh
grep -Fq 'HEADLESS=(--headless)' launch.sh
grep -Fq -- '--speculative-config '\''{"method":"dflash","model":"/models/dflash2","num_speculative_tokens":7,"attention_backend":"FLASH_ATTN","kv_cache_dtype":"auto","disable_eagle_block_drop":true}'\''' launch.sh
grep -Fq -- '--prefix-match-unit 128' launch.sh
grep -Fq -- '--kv-cache-memory 13500000000' launch.sh
grep -Fq -- '--kv-cache-dtype fp8_e4m3' launch.sh
grep -Fq -- '--max-num-batched-tokens 8192' launch.sh
grep -Fq -- '--max-num-seqs 6' launch.sh
grep -Fq -- '--max-model-len 1048576' launch.sh
grep -Fq -- '--block-size 2304' launch.sh
grep -Fq -- '--moe-backend marlin' launch.sh
grep -Fq -- '--gpu-memory-utilization 0.85' launch.sh
grep -Fq -- '--limit-mm-per-prompt '\''{"image":4,"video":0}'\''' launch.sh
grep -Fq -- '--restart no' launch.sh
grep -Fq -- '--network host --ipc host --shm-size 32g' launch.sh
grep -Fq -- '--master-addr "$HEAD" --master-port "$MPORT"' launch.sh
grep -Fq -- '--tensor-parallel-size 2 --distributed-executor-backend mp --nnodes 2' launch.sh
grep -Fq 'VLLM_PREFIX_CACHE_RETENTION_INTERVAL=0' launch.sh
grep -Fq 'VLLM_ENGINE_READY_TIMEOUT_S=3600' launch.sh
grep -Fq 'NCCL_IB_HCA=rocep1s0f0' launch.sh
grep -Fq 'NCCL_IB_GID_INDEX=3' launch.sh
grep -Fq 'NCCL_IB_ROCE_VERSION_NUM=2' launch.sh
grep -Fq 'NCCL_IB_ADDR_RANGE=10.0.7.0/30' launch.sh
grep -Fq 'NCCL_SOCKET_IFNAME=enp1s0f0np0' launch.sh
grep -Fq 'GLOO_SOCKET_IFNAME=enp1s0f0np0' launch.sh
grep -Fq 'TP_SOCKET_IFNAME=enp1s0f0np0' launch.sh
grep -Fq 'MN_IF_NAME=enp1s0f0np0' launch.sh
grep -Fq "$TARGET_OUTPUT_SHA" launch.sh
grep -Fq "$TARGET_INDEX_SHA" launch.sh
grep -Fq "$DRAFT_CONFIG_SHA" launch.sh
grep -Fq "$DRAFT_REV" README.md
grep -Fq "$DRAFT_LFS_SHA" README.md
grep -Fq "$DRAFT_HOST_DEFAULT" README.md
[[ $(grep -Ec '^ -v ' launch.sh) -eq 3 ]]
! grep -Eq -- '-v [^ ]*dist-packages|PATCH_HOST|MANAGER_HOST|COORDINATOR_HOST|SCHEDULER_HOST' launch.sh
! grep -Fq -- '--restart always' launch.sh
! grep -Fq -- '"method":"mtp"' launch.sh

echo "== Dockerfile and installer static gates =="
grep -Fq "FROM $BASE_DIGEST" Dockerfile
for asset in \
  0001-vllm-53388-native-mtp-block-drop.patch \
  0002-vllm-53906-coordinator-partial-hits.patch \
  0003-vllm-scheduler-lcm-mamba-block-align.patch \
  dflash2-pmu128-swa-fine-hits.patch \
  sparse_attn_indexer_kpool_sm121.py; do
  grep -Fq "patches/$asset" Dockerfile
done
grep -Fq 'VLLM_DIST=/usr/local/lib/python3.12/dist-packages' Dockerfile
grep -Fq -- '--verify-only' Dockerfile
grep -Fq 'org.opencontainers.image.base.digest' Dockerfile
grep -Fq "$OVERLAY_REV" Dockerfile
grep -Fq 'PATCH_SHA256' apply_runtime_patches.py
grep -Fq 'BASE_UNCHANGED' apply_runtime_patches.py
grep -Fq 'tree_is_final' apply_runtime_patches.py
grep -Fq 'os.replace(tmp, target)' apply_runtime_patches.py
grep -Fq '825ea2ad16b4db417606c9be2ca1b44af44402659b9285dfe0b2aa0a821a3561' apply_runtime_patches.py
grep -Fq 'cf75ab28813ceb95d083aa6bec1d13a810dedb087f482f433dd9ace31b94cdc2' apply_runtime_patches.py
grep -Fq '302ca0cbd7d889df928d1eca7986cc50230855b5660ae72bcc8a696690bc144c' apply_runtime_patches.py
grep -Fq 'RootFS.Layers' validate.sh

echo "== deterministic patch replay, idempotence, and tamper rejection =="
WORK=$(mktemp -d)
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT
tar -xJf patches/base-fixture.tar.xz -C "$WORK"
(cd "$WORK" && sha256sum --check --strict "$BASE_SUMS" >/dev/null)
PYTHONDONTWRITEBYTECODE=1 python3 "$APPLIER" --root "$WORK" >/dev/null
(cd "$WORK" && sha256sum --check --strict "$FINAL_SUMS" >/dev/null)
before_noop=$(find "$WORK/vllm" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
PYTHONDONTWRITEBYTECODE=1 python3 "$APPLIER" --root "$WORK" >/dev/null
after_noop=$(find "$WORK/vllm" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
[[ $before_noop == "$after_noop" ]] || { echo "idempotent replay changed final files"; exit 1; }
PYTHONDONTWRITEBYTECODE=1 python3 "$APPLIER" --root "$WORK" --verify-only >/dev/null
printf '\n# tampered\n' >>"$WORK/vllm/config/speculative.py"
if PYTHONDONTWRITEBYTECODE=1 python3 "$APPLIER" --root "$WORK" --verify-only >/dev/null 2>&1; then
  echo "tampered final tree unexpectedly verified"
  exit 1
fi
echo "exact final replay OK; second application is a no-op; tamper rejected"

echo "== all-input preflight atomicity =="
PREFLIGHT="$WORK/preflight"
mkdir -p "$PREFLIGHT"
tar -xJf patches/base-fixture.tar.xz -C "$PREFLIGHT"
printf '\n# late inherited tamper\n' >>"$PREFLIGHT/vllm/v1/worker/gpu/spec_decode/dflash2/speculator.py"
before_fail=$(find "$PREFLIGHT/vllm" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
if PYTHONDONTWRITEBYTECODE=1 python3 "$APPLIER" --root "$PREFLIGHT" >/dev/null 2>&1; then
  echo "tampered inherited input unexpectedly passed"
  exit 1
fi
after_fail=$(find "$PREFLIGHT/vllm" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
[[ $before_fail == "$after_fail" ]] || { echo "installer wrote before full preflight passed"; exit 1; }
echo "late inherited-file drift rejected before any write"

echo "== focused CPU regressions =="
tests/run.sh

if [[ -n $BASE_ROOT ]]; then
  echo "== caller-supplied base-tree byte binding (--base-root $BASE_ROOT) =="
  [[ -d $BASE_ROOT/vllm ]] || { echo "no vllm/ under --base-root"; exit 1; }
  (cd "$BASE_ROOT" && sha256sum --check --strict "$BASE_SUMS" >/dev/null)
  BASE_COPY="$WORK/base-root-copy"
  while read -r _ rel; do
    mkdir -p "$BASE_COPY/$(dirname -- "$rel")"
    cp -- "$BASE_ROOT/$rel" "$BASE_COPY/$rel"
  done <"$BASE_SUMS"
  PYTHONDONTWRITEBYTECODE=1 python3 "$APPLIER" --root "$BASE_COPY" >/dev/null
  (cd "$BASE_COPY" && sha256sum --check --strict "$FINAL_SUMS" >/dev/null)
  BASE_BOUND=1
  BASE_BINDING="caller-tree"
  echo "caller-supplied base-tree bytes match pinned before hashes and replay to exact final hashes; origin/ancestry is not asserted"
elif [[ $EXPLICIT_OFFLINE == 0 ]] && command -v docker >/dev/null 2>&1; then
  echo "== public base binding via Docker =="
  docker image inspect "$BASE_DIGEST" >/dev/null 2>&1 || docker pull "$BASE_DIGEST"
  docker run --rm --entrypoint sh -w /usr/local/lib/python3.12/dist-packages \
    -v "$BASE_SUMS:/tmp/base.SHA256SUMS:ro" \
    "$BASE_DIGEST" sha256sum --check --strict /tmp/base.SHA256SUMS >/dev/null
  BASE_BOUND=1
  BASE_BINDING="docker-digest"
  echo "digest-pinned public base and inherited DFlash2/cache-core bytes bound"
fi

if [[ $EXPLICIT_OFFLINE == 1 ]]; then
  echo "SKIP: public target/drafter/overlay network bindings (--offline-unit)"
else
  echo "== target AutoRound metadata and deterministic GPTQ adaptation =="
  META="$WORK/target-meta"
  mkdir -p "$META"
  TARGET_URL="https://huggingface.co/Intel/GLM-5.3-Flash-W4A16-AutoRound/resolve/$TARGET_REV"
  curl -fsSL -o "$META/config.json" "$TARGET_URL/config.json" || {
    echo "target config download failed; use --no-network only for offline unit validation"
    exit 1
  }
  curl -fsSL -o "$META/model.safetensors.index.json" "$TARGET_URL/model.safetensors.index.json" || {
    echo "target index download failed; use --no-network only for offline unit validation"
    exit 1
  }
  echo "$TARGET_CONFIG_SHA  $META/config.json" | sha256sum -c - >/dev/null
  echo "$TARGET_INDEX_SHA  $META/model.safetensors.index.json" | sha256sum -c - >/dev/null
  DST="$WORK/gptq-meta"
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$META" "$DST" --metadata-only >/dev/null
  [[ $(sha256sum "$DST/config.json" | awk '{print $1}') == "$TARGET_OUTPUT_SHA" ]]
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$META" "$DST" --metadata-only >/dev/null
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$META" "$DST" --metadata-only --check >/dev/null
  printf '\n' >>"$DST/config.json"
  if PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$META" "$DST" --metadata-only >/dev/null 2>&1; then
    echo "tampered adapted metadata unexpectedly accepted"
    exit 1
  fi

  echo "== adapter full-tree preservation and nested-root rejection =="
  FULL_SRC="$WORK/target-full-synthetic"
  mkdir -p "$FULL_SRC"
  cp "$META/config.json" "$META/model.safetensors.index.json" "$FULL_SRC/"
  PYTHONDONTWRITEBYTECODE=1 python3 - "$META/model.safetensors.index.json" "$FULL_SRC" <<'PY'
import json
import sys
from pathlib import Path

index, root = Path(sys.argv[1]), Path(sys.argv[2])
for name in sorted(set(json.loads(index.read_text())["weight_map"].values())):
    (root / name).write_bytes(b"synthetic-shard:" + name.encode())
(root / "tokenizer_config.json").write_text('{"tokenizer_class":"G"}\n')
(root / "generation_config.json").write_text('{"eos_token_id":1}\n')
PY
  FULL_DST="$WORK/target-full-adapted"
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$FULL_SRC" "$FULL_DST" >/dev/null
  cmp "$FULL_SRC/model.safetensors.index.json" "$FULL_DST/model.safetensors.index.json"
  cmp "$FULL_SRC/tokenizer_config.json" "$FULL_DST/tokenizer_config.json"
  cmp "$FULL_SRC/generation_config.json" "$FULL_DST/generation_config.json"
  [[ $(sha256sum "$FULL_DST/config.json" | awk '{print $1}') == "$TARGET_OUTPUT_SHA" ]]
  PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$FULL_SRC" "$FULL_DST" --check >/dev/null
  # The adapter deliberately hardlinks payloads when possible. Unlink first so
  # this exercises destination-only drift instead of mutating the source inode.
  rm -- "$FULL_DST/model-00001-of-00034.safetensors"
  printf 'tampered' >"$FULL_DST/model-00001-of-00034.safetensors"
  if PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$FULL_SRC" "$FULL_DST" >/dev/null 2>&1; then
    echo "tampered adapted shard unexpectedly accepted"
    exit 1
  fi
  NEST="$WORK/nested"
  mkdir -p "$NEST/src"
  cp "$META/config.json" "$META/model.safetensors.index.json" "$NEST/src/"
  if PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$NEST/src" "$NEST" >/dev/null 2>&1; then
    echo "destination ancestor of source unexpectedly accepted"
    exit 1
  fi
  if PYTHONDONTWRITEBYTECODE=1 python3 "$ADAPTER" "$META" "$META/nested" >/dev/null 2>&1; then
    echo "destination inside source unexpectedly accepted"
    exit 1
  fi

  echo "== exact DFlash2 revision, config, and LFS metadata =="
  DRAFT_META="$WORK/draft-meta"
  mkdir -p "$DRAFT_META"
  DRAFT_URL="https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2/resolve/$DRAFT_REV"
  DRAFT_WEIGHT_URL="$DRAFT_URL/model.safetensors"
  curl -fsSL -o "$DRAFT_META/config.json" "$DRAFT_URL/config.json" || {
    echo "drafter config download failed"
    exit 1
  }
  curl -fsSI -o "$DRAFT_META/model.headers" "$DRAFT_WEIGHT_URL" || {
    echo "drafter immutable weight HEAD failed"
    exit 1
  }
  echo "$DRAFT_CONFIG_SHA  $DRAFT_META/config.json" | sha256sum -c - >/dev/null
  PYTHONDONTWRITEBYTECODE=1 python3 - \
    "$DRAFT_META/model.headers" "$DRAFT_REV" "$DRAFT_LFS_SHA" "$DRAFT_LFS_SIZE" <<'PY'
import sys
from pathlib import Path

path, revision, expected_oid, expected_size = sys.argv[1:]
headers = {}
for line in Path(path).read_text(encoding="iso-8859-1").splitlines():
    if ":" not in line:
        continue
    name, value = line.split(":", 1)
    headers[name.strip().lower()] = value.strip()

commit = headers.get("x-repo-commit", "")
if commit != revision:
    raise SystemExit(f"drafter HEAD revision drift: {commit!r} != {revision}")

oid = headers.get("x-linked-etag", "").strip()
if oid.startswith("W/"):
    oid = oid[2:].strip()
oid = oid.strip('"').removeprefix("sha256:")
if oid != expected_oid:
    raise SystemExit(f"drafter HEAD LFS oid drift: {oid!r} != {expected_oid}")

size = headers.get("x-linked-size", "")
if not size.isdecimal() or int(size) != int(expected_size):
    raise SystemExit(f"drafter LFS size drift: {size!r} != {expected_size}")
print("drafter immutable revision/config/LFS HEAD bound without downloading weights")
PY
  MODEL_BOUND=1

  echo "== pinned public DFlash2 overlay provenance =="
  RAW_BASE="https://raw.githubusercontent.com/tonyd2wild/GLM-5.3-Flash-NVFP4-DFlash2-2x-DGX-Spark/$OVERLAY_REV/docker/dflash2-overlay"
  overlay_files=(qwen3_dflash2.py dflash2/__init__.py dflash2/speculator.py)
  overlay_hashes=(
    c141daa4b2059c0098224ac36471c2197b7052c100bef0a4dbc2ca79b627053f
    e3c55cbb0d7a8bd47df6f3378835644645f5d3bc89b45793b5d5a02d013e5c58
    66aa43b74abfdaa9aa09e00e6511fab273e7c8a1c5da6c0d06e1daa07216ffd5
  )
  for index in "${!overlay_files[@]}"; do
    destination="$WORK/overlay-$index"
    curl -fsSL -o "$destination" "$RAW_BASE/${overlay_files[$index]}" || {
      echo "public overlay download failed: ${overlay_files[$index]}"
      exit 1
    }
    echo "${overlay_hashes[$index]}  $destination" | sha256sum -c - >/dev/null
  done
  OVERLAY_BOUND=1
  echo "public commit content matches the exact inherited runtime bytes"
fi

if [[ -n $IMAGE_CHECK ]]; then
  echo "== built-image ancestry and final-byte binding (--image $IMAGE_CHECK) =="
  command -v docker >/dev/null || { echo "docker unavailable for --image"; exit 1; }
  docker image inspect "$BASE_DIGEST" >/dev/null 2>&1 || docker pull "$BASE_DIGEST"
  docker image inspect "$IMAGE_CHECK" >/dev/null
  base_layers=$(docker image inspect --format '{{json .RootFS.Layers}}' "$BASE_DIGEST")
  image_layers=$(docker image inspect --format '{{json .RootFS.Layers}}' "$IMAGE_CHECK")
  image_labels=$(docker image inspect --format '{{json .Config.Labels}}' "$IMAGE_CHECK")
  PYTHONDONTWRITEBYTECODE=1 python3 - \
    "$BASE_DIGEST_VALUE" "$base_layers" "$image_layers" "$image_labels" <<'PY'
import json
import sys

digest, base_raw, image_raw, labels_raw = sys.argv[1:]
base = list(json.loads(base_raw) or [])
image = list(json.loads(image_raw) or [])
labels = json.loads(labels_raw) or {}
if not base or not image:
    raise SystemExit("empty RootFS.Layers from docker inspect")
if len(image) <= len(base):
    raise SystemExit("built image adds no layer above the pinned base")
if image[: len(base)] != base:
    raise SystemExit("built image does not extend the exact base layer prefix")
if labels.get("org.opencontainers.image.base.digest") != digest:
    raise SystemExit("built image base-digest label mismatch")
print("rootfs layer-prefix ancestry and base-digest label bound")
PY
  docker run --rm --entrypoint python3 \
    -v "$PWD:/recipe:ro" "$IMAGE_CHECK" \
    /recipe/apply_runtime_patches.py \
    --root /usr/local/lib/python3.12/dist-packages --verify-only >/dev/null
  IMAGE_BOUND=1
  BASE_BOUND=1
  BASE_BINDING="image-prefix"
  echo "built image contains all exact final and unchanged inherited hashes"
fi

if [[ $EXPLICIT_OFFLINE == 1 ]]; then
  echo "OK: OFFLINE UNIT VALIDATION ONLY. This proves bundled self-consistency and CPU behavior; it is never a COMPLETE validation and does not bind remote model/overlay metadata or a runnable built image."
  exit 0
fi

if [[ $MODEL_BOUND == 1 && $OVERLAY_BOUND == 1 && $BASE_BOUND == 1 ]]; then
  if [[ $IMAGE_BOUND == 1 ]]; then
    echo "OK: COMPLETE validation passed for built image $IMAGE_CHECK (base ancestry, exact runtime bytes, target/drafter metadata, and public overlay provenance)."
  elif [[ $BASE_BINDING == "caller-tree" ]]; then
    echo "OK: COMPLETE byte-level reconstruction validation passed (caller-supplied --base-root bytes matched pinned before hashes and exact replay; no public-digest origin/ancestry claim; target/drafter metadata and public overlay provenance bound)."
  else
    echo "OK: COMPLETE validation passed (digest-pinned public base bound via Docker, exact replay, target/drafter metadata, and public overlay provenance)."
  fi
  exit 0
fi

echo "PARTIAL: network model/overlay checks and offline replay passed, but no base-tree byte binding completed. Do not treat this as COMPLETE; provide --base-root for caller-supplied byte reconstruction, use Docker default mode for public-digest binding, or validate a built image with --image."
exit 3
