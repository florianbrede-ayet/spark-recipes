#!/usr/bin/env bash
# Offline check of this recipe (no cluster, network or credentials needed).
#   ./validate.sh                  checksums and secret scan
#   ./validate.sh --upstream DIR   also: DIR is a clean upstream clone at the pinned commit and the patch applies
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
BASE=33b50fde06fd7ea604cbc6a663880068ab1e2ee4
sha256sum -c --quiet SHA256SUMS && echo "checksums: ok"
if grep -n -i -E '(hf_[A-Za-z0-9]{10,}|_token=.|secret|passw|api_key)' env.example; then
  echo "FAIL: env.example looks like it contains a credential" >&2; exit 1
fi
echo "secret scan: ok"
if [[ "${1:-}" == --upstream ]]; then
  up="${2:?--upstream needs the clone directory}"
  head=$(git -C "$up" rev-parse HEAD)
  [[ "$head" == "$BASE" ]] || { echo "FAIL: $up is at $head, not $BASE" >&2; exit 1; }
  git -C "$up" apply --check "$PWD/recipe-v1.8-spill.patch" 2>/dev/null && echo "patch applies to $BASE: ok"
fi
