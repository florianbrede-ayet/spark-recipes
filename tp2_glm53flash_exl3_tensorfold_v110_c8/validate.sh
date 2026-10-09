#!/usr/bin/env bash
# Offline check of this recipe (no cluster, network or credentials needed).
#   ./validate.sh                  checksums and secret scan
#   ./validate.sh --upstream DIR   also: DIR is an unmodified upstream clone at the pinned commit
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
PIN=7d42f905388a8d7fa91e2dc9458e0a4a68001540
sha256sum -c --quiet SHA256SUMS && echo "checksums: ok"
if grep -n -i -E '(hf_[A-Za-z0-9]{10,}|_token=.|secret|passw|api_key)' env.example; then
  echo "FAIL: env.example looks like it contains a credential" >&2; exit 1
fi
echo "secret scan: ok"
if [[ "${1:-}" == --upstream ]]; then
  up="${2:?--upstream needs the clone directory}"
  head=$(git -C "$up" rev-parse HEAD)
  [[ "$head" == "$PIN" ]] || { echo "FAIL: $up is at $head, not $PIN" >&2; exit 1; }
  [[ -z "$(git -C "$up" status --porcelain --untracked-files=no)" ]] || { echo "FAIL: $up has modified tracked files" >&2; exit 1; }
  echo "upstream clone at $PIN, unmodified: ok"
fi
