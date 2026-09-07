#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

select_python() {
  local candidate resolved version
  local -a candidates
  if [[ -n ${PYTHON_BIN:-} ]]; then
    candidates=("$PYTHON_BIN")
  else
    candidates=(python3.12 /usr/bin/python3.12 python3)
  fi
  for candidate in "${candidates[@]}"; do
    resolved=$(command -v -- "$candidate" 2>/dev/null) || continue
    [[ -x $resolved ]] || continue
    version=$("$resolved" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    if [[ $version == 3.12 ]]; then
      PYTHON_BIN=$(readlink -f -- "$resolved")
      return
    fi
  done
  printf 'ERROR: focused regressions require Python 3.12\n' >&2
  exit 1
}

select_python
WORK=$(mktemp -d)
cleanup() {
  [[ -n ${WORK:-} && -d $WORK ]] && rm -rf -- "$WORK"
}
trap cleanup EXIT

tar -xJf "$ROOT/patches/base-fixture.tar.xz" -C "$WORK"
PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" \
  "$ROOT/apply_runtime_patches.py" --root "$WORK" >/dev/null

OUTPUT=$(
  DFLASH2_RUNTIME_ROOT="$WORK" \
  PYTHONHASHSEED=0 \
  PYTHONPYCACHEPREFIX="$WORK/pycache" \
  PYTHONDONTWRITEBYTECODE=1 \
  "$PYTHON_BIN" -m unittest discover \
    -s "$ROOT/tests" -p 'test_*.py' -v 2>&1
)
printf '%s\n' "$OUTPUT"
grep -Fq 'Ran 15 tests' <<<"$OUTPUT" || {
  printf 'ERROR: expected exactly 15 focused regressions\n' >&2
  exit 1
}
grep -Fq 'OK' <<<"$OUTPUT" || {
  printf 'ERROR: focused regressions did not report OK\n' >&2
  exit 1
}
