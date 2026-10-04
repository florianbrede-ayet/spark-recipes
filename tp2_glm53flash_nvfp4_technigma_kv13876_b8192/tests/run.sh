#!/usr/bin/env bash
# Test runner for this recipe. Offline; starts nothing; pulls nothing.
#
#   tests/run.sh                                  unit suites only
#   tests/run.sh --upstream DIR [--compose-bin X] unit + render + launcher
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

UPSTREAM=""
COMPOSE_SPEC="${COMPOSE_BIN:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream)    [[ $# -ge 2 ]] || { echo "--upstream needs a directory" >&2; exit 2; }
                   UPSTREAM="$2"; shift 2 ;;
    --compose-bin) [[ $# -ge 2 ]] || { echo "--compose-bin needs a command" >&2; exit 2; }
                   COMPOSE_SPEC="$2"; shift 2 ;;
    -h|--help)     sed -n '2,6p' "$0"; exit 0 ;;
    *)             echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$UPSTREAM" ]]; then
  [[ -d "$UPSTREAM" ]] || { echo "--upstream '$UPSTREAM' is not a directory" >&2; exit 2; }
  export RECIPE_UPSTREAM="$(cd -- "$UPSTREAM" && pwd)"
  echo "== suites: envmerge, source pins, render parity, launcher =="
else
  echo "== suites: envmerge, source pins =="
  echo "   render parity and launcher need --upstream <pinned checkout>; they"
  echo "   will report as skipped below."
fi
[[ -n "$COMPOSE_SPEC" ]] && export RECIPE_COMPOSE_BIN="$COMPOSE_SPEC"

export PYTHONDONTWRITEBYTECODE=1
exec python3 -m unittest discover -s . -t . -p 'test_*.py' -v
