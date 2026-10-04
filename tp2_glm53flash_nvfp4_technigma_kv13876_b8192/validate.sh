#!/usr/bin/env bash
# Offline validator.
#
#   ./validate.sh                  BASIC - recipe self-consistency only
#   ./validate.sh --upstream DIR   FULL  - adds the real Compose render
#   ./validate.sh --upstream DIR --compose-bin "docker compose"
#
# Neither mode needs a Docker daemon, a cluster, credentials or the network;
# neither downloads weights or starts anything. Read-only apart from a private
# temporary file.
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
    -h|--help)     sed -n '2,10p' "$0"; exit 0 ;;
    *)             echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -z "$UPSTREAM" || -d "$UPSTREAM" ]] \
  || { echo "--upstream '$UPSTREAM' is not a directory" >&2; exit 2; }
export PYTHONDONTWRITEBYTECODE=1

TESTLOG="$(mktemp)"
trap 'rm -f -- "$TESTLOG"' EXIT
# Summary on success, everything on failure.
run_tests() {
  if ./tests/run.sh "$@" >"$TESTLOG" 2>&1; then
    tail -n 4 "$TESTLOG"
  else
    cat "$TESTLOG"
    echo "FAIL: the test suite did not pass" >&2
    exit 1
  fi
}

FILES=(
  README.md SHA256SUMS launch.sh validate.sh .gitignore
  compose.phase1.override.yaml
  config/profile.env config/site.env.example
  tools/envmerge.py
  tests/run.sh tests/test_envmerge.py tests/test_source_pins.py
  tests/test_render_parity.py tests/test_launcher.py
)

echo "== files and modes =="
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { echo "missing $f"; exit 1; }
done
[[ -x validate.sh && -x tests/run.sh ]] || { echo "validate.sh and tests/run.sh must be executable"; exit 1; }
[[ ! -x launch.sh ]] || { echo "launch.sh must NOT be executable; it is run as 'bash launch.sh'"; exit 1; }
[[ ! -e config/site.env ]] || { echo "config/site.env must never be committed; it holds real site values"; exit 1; }
echo "  ${#FILES[@]} files present, modes as expected, no config/site.env"

echo "== syntax =="
bash -n launch.sh validate.sh tests/run.sh
python3 - "${FILES[@]}" <<'PY'
import ast, sys
for name in sys.argv[1:]:
    if name.endswith(".py"):
        with open(name, encoding="utf-8") as fh:
            ast.parse(fh.read(), filename=name)
print("  bash -n and python parse OK")
PY

echo "== checksums =="
sha256sum -c SHA256SUMS >/dev/null
python3 - "${FILES[@]}" <<'PY'
import sys
with open("SHA256SUMS", encoding="utf-8") as fh:
    listed = {ln.split(None, 1)[1].strip() for ln in fh if ln.strip()}
want = set(sys.argv[1:]) - {"SHA256SUMS"}   # a file cannot hash itself
missing, extra = sorted(want - listed), sorted(listed - want)
if missing or extra:
    raise SystemExit("SHA256SUMS mismatch: missing=%s unexpected=%s"
                     % (missing, extra))
print("  verified, and covers exactly the %d recipe files" % len(want))
PY

echo "== profile / site key guards and README delta =="
python3 - <<'PY'
import os, sys
sys.path.insert(0, "tools")
import envmerge

profile = envmerge.load_profile()          # raises on key-set or value problems
example, _ = envmerge.parse_env("config/site.env.example", "site.env.example")
if set(example) != set(envmerge.SITE_KEYS):
    raise SystemExit("site.env.example key set mismatch")
for key, value in sorted(example.items()):
    if not envmerge.PLACEHOLDER_RE.fullmatch(value):
        raise SystemExit("site.env.example: %s=%r is not a bare <PLACEHOLDER>"
                         % (key, value))
with open("README.md", encoding="utf-8") as fh:
    readme = fh.read()
undocumented = [k for k in envmerge.PROFILE_KEYS + envmerge.SITE_KEYS
                if k not in readme]
if undocumented:
    raise SystemExit("README does not document: %s" % ", ".join(undocumented))
unstated = [k for k, v in profile.items() if v and v not in readme]
if unstated:
    raise SystemExit("README does not state the value of: %s" % ", ".join(unstated))
for claim in ("18 changed values and one added key", envmerge.UPSTREAM_COMMIT):
    if claim not in readme:
        raise SystemExit("README is missing the claim: %r" % claim)
print("  profile.env declares exactly %d keys (%d blanked); site.env.example "
      "declares exactly %d, all placeholders"
      % (len(envmerge.PROFILE_KEYS), len(envmerge.DISCARDED_KEYS),
         len(envmerge.SITE_KEYS)))
print("  README documents every delta key and every non-empty profile value")
PY

echo "== secret and site-identity scan =="
python3 - "${FILES[@]}" <<'PY'
import ipaddress, re, sys

PATTERNS = (
    (re.compile(r"hf_[A-Za-z0-9]{20,}"), "a Hugging Face token"),
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"), "a GitHub token"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "an AWS access key"),
    # The PEM delimiters, not the bare phrase: rejection fixtures in tests/
    # contain the phrase, a real leaked key always has the dashes.
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "a private key"),
    (re.compile(r"(?i)\b(password|passwd|api_key|secret)\s*[=:]\s*\S"), "a secret"),
    (re.compile(r"(?i)/home/[a-z0-9._-]+"), "a home directory path"),
    (re.compile(r"(?i)\byour-user\b"), "an upstream example login"),
    # RFC 2606 reserved names are fine; anything else looks like a real host.
    (re.compile(r"[A-Za-z0-9._-]+@(?!(?:[A-Za-z0-9.-]+\.)?"
                r"(?:invalid|example|test|localhost)\b)"
                r"[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "a user@host"),
    (re.compile(r"(?i)\b[a-z0-9-]+\.(?:local|lan|internal)\b"), "a site hostname"),
)
ALLOWED = [ipaddress.IPv4Network(n) for n in
           ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",
            "0.0.0.0/32", "127.0.0.0/8")]
IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")

problems = []
for name in sys.argv[1:]:
    with open(name, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            for rx, what in PATTERNS:
                hit = rx.search(line)
                if hit:
                    problems.append("%s:%d looks like %s: %r"
                                    % (name, lineno, what, hit.group(0)))
            for literal in IPV4.findall(line):
                try:
                    addr = ipaddress.IPv4Address(literal)
                except ipaddress.AddressValueError:
                    continue
                if not any(addr in net for net in ALLOWED):
                    problems.append("%s:%d has the non-documentation address %s"
                                    % (name, lineno, literal))
if problems:
    raise SystemExit("\n".join("  " + p for p in problems))
print("  no secrets, no site hostnames, logins or home paths; every IPv4 "
      "literal is a documentation, wildcard or loopback address")
PY

echo "== launcher safety markers =="
grep -Fq 'set -euo pipefail' launch.sh
grep -Fq 'SCRUB=(env -i "PATH=$PATH"' launch.sh
grep -Fq 'read -r answer </dev/tty' launch.sh
grep -Fq '[[ "$answer" == "apply" ]]' launch.sh
[[ "$(grep -c '^"${SCRUB\[@\]}" "${COMPOSE_CMD\[@\]}" "${COMPOSE_ARGS\[@\]}" up -d$' launch.sh)" == 1 ]]
echo "  dry-run default, env scrub, single gated 'up -d' (ordering checked by the suite)"

if [[ -n "$UPSTREAM" ]]; then
  echo
  echo "== FULL: pinned upstream source =="
  python3 tools/envmerge.py verify-source --upstream "$UPSTREAM" --role both \
    | tail -n +2
  echo
  echo "== test suites (env-merge, source pins, render parity, launcher) =="
  ARGS=(--upstream "$UPSTREAM")
  if [[ -n "$COMPOSE_SPEC" ]]; then ARGS+=(--compose-bin "$COMPOSE_SPEC"); fi
  run_tests "${ARGS[@]}"
  echo
  echo "OK: FULL validation passed. The three-file stack renders offline from the"
  echo "pinned upstream source, differs from the upstream baseline by exactly the"
  echo "documented delta, and produces the live serve argv on both roles. NOT"
  echo "proven here: that the image digest is pullable, that the weights are"
  echo "cached, that the fabric works, or that the service starts."
  exit 0
fi

echo
echo "== test suites (env-merge, source pins) =="
run_tests
echo
echo "BASIC OFFLINE VALIDATION ONLY: the recipe is internally consistent and the"
echo "env-merge and source-pin rejection paths are proven, but no Compose render"
echo "was performed, so parity with the live service was NOT checked here."
echo "For that: ./validate.sh --upstream <pinned checkout> [--compose-bin X]"
