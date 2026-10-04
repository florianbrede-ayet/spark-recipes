#!/usr/bin/env bash
# Start one node of the live GLM-5.3-Flash NVFP4 service. Worker (rank 1)
# first, then head (rank 0). Run it on each node; it never uses SSH.
#
# It composes exactly three files:
#   <upstream>/compose.{head,worker}.yaml       pinned upstream, by commit+hash
#   <upstream>/compose.display-kv.override.yaml pinned upstream, by commit+hash
#   ./compose.phase1.override.yaml              this recipe
# with an explicit --env-file built by tools/envmerge.py.
#
# Dry run by default. The only mutating action it can take is `compose up -d`,
# behind both --apply and an interactive confirmation. Be precise about what
# that one command does: it pulls the pinned image if it is absent, and if a
# glm53 container already exists with a different configuration, Compose stops,
# removes and recreates it. On a live pair that means API downtime on rank 0, a
# model reload onto the GPUs, and in-flight requests lost - so treat --apply as
# a coordinated maintenance action: agree a window, and shut the pair down
# (worker and head) before relaunching a changed profile. It runs no other
# lifecycle command and never changes the host.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENVMERGE="$HERE/tools/envmerge.py"

ROLE=""
UPSTREAM=""
SITE_ENV="$HERE/config/site.env"
COMPOSE_SPEC="${COMPOSE_BIN:-}"
APPLY=0

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
note() { printf '  %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

usage() {
  cat <<'USAGE'
usage: bash launch.sh --role {head|worker} --upstream DIR [options]

  --role head|worker   head = rank 0 (serves the API), worker = rank 1
  --upstream DIR       git checkout of the pinned upstream repository
  --site-env FILE      site values (default: config/site.env)
  --compose-bin CMD    "docker compose", or a docker-compose path.
                       Also read from $COMPOSE_BIN. Autodetected otherwise.
  --apply              start this node (needs an interactive confirmation)
  -h, --help           this text

Without --apply it verifies the pin, renders the stack and prints the exact
command. It starts nothing. Host prerequisites are the operator's: see README.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)        [[ $# -ge 2 ]] || die "--role needs a value"
                   [[ -z "$ROLE" ]] || die "--role given twice"
                   ROLE="$2"; shift 2 ;;
    --upstream)    [[ $# -ge 2 ]] || die "--upstream needs a directory"
                   [[ -z "$UPSTREAM" ]] || die "--upstream given twice"
                   UPSTREAM="$2"; shift 2 ;;
    --site-env)    [[ $# -ge 2 ]] || die "--site-env needs a file"
                   SITE_ENV="$2"; shift 2 ;;
    --compose-bin) [[ $# -ge 2 ]] || die "--compose-bin needs a command"
                   COMPOSE_SPEC="$2"; shift 2 ;;
    --apply)       APPLY=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; die "unknown argument: $1" ;;
  esac
done

case "$ROLE" in
  head)   NODE_FILE="compose.head.yaml" ;;
  worker) NODE_FILE="compose.worker.yaml" ;;
  "")     usage >&2; die "--role is required" ;;
  *)      die "--role must be head or worker, not '$ROLE'" ;;
esac
[[ -n "$UPSTREAM" ]] || { usage >&2; die "--upstream is required"; }
[[ -d "$UPSTREAM" ]] || die "--upstream '$UPSTREAM' is not a directory"
[[ -f "$SITE_ENV" ]] || die "site file '$SITE_ENV' not found; copy config/site.env.example to config/site.env and fill it in"
command -v python3 >/dev/null || die "python3 is required (stdlib only)"
UPSTREAM="$(cd -- "$UPSTREAM" && pwd)"

# Fail closed on local drift before merging, rendering or starting anything:
# the profile constants and the overlay must match the published checksums. If
# you deliberately changed a recipe file, regenerate SHA256SUMS first.
section "recipe checksums"
(cd -- "$HERE" && sha256sum -c SHA256SUMS >/dev/null) \
  || die "this recipe does not match its published SHA256SUMS; refusing to run"
note "recipe files match SHA256SUMS"

WORK="$(mktemp -d)"
chmod 700 -- "$WORK"
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT
ENV_FILE="$WORK/merged.env"

section "pinned upstream source ($ROLE)"
python3 "$ENVMERGE" verify-source --upstream "$UPSTREAM" --role "$ROLE" \
  | tail -n +2

section "merged environment"
python3 "$ENVMERGE" merge --upstream "$UPSTREAM" --site "$SITE_ENV" \
  --role "$ROLE" --out "$ENV_FILE" --quiet
note "private temporary env file, removed on exit"
python3 "$ENVMERGE" delta --upstream "$UPSTREAM" --site "$SITE_ENV" \
  | tail -n 1 | sed 's/^# /  /'
note "to inspect or keep it: python3 tools/envmerge.py merge --upstream \\"
note "  $UPSTREAM --site $SITE_ENV --out config/merged.env  (git-ignored)"

COMPOSE_CMD=()
if [[ -n "$COMPOSE_SPEC" ]]; then
  if [[ -x "$COMPOSE_SPEC" ]]; then
    COMPOSE_CMD=("$COMPOSE_SPEC")
  else
    read -r -a COMPOSE_CMD <<<"$COMPOSE_SPEC"
    command -v "${COMPOSE_CMD[0]}" >/dev/null \
      || die "compose binary '${COMPOSE_CMD[0]}' not found"
  fi
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  die "no Compose binary found; pass --compose-bin or set \$COMPOSE_BIN"
fi

COMPOSE_ARGS=(
  --env-file "$ENV_FILE"
  -f "$UPSTREAM/$NODE_FILE"
  -f "$UPSTREAM/compose.display-kv.override.yaml"
  -f "$HERE/compose.phase1.override.yaml"
)

# Compose lets the ambient shell environment win over --env-file, so an
# exported IMAGE or KV_CACHE_MEMORY_BYTES would silently replace a pin. Run it
# with an explicit environment; HOME is kept so the Docker CLI still finds its
# config and context.
SCRUB=(env -i "PATH=$PATH" "HOME=${HOME:-/}")

section "command"
printf '  '
printf '%q ' "${COMPOSE_CMD[@]}" "${COMPOSE_ARGS[@]}"
printf 'up -d\n'
note "the Compose project directory comes from the first -f file, so the"
note "upstream chat template resolves inside $UPSTREAM"

section "render (read-only, no daemon needed)"
"${SCRUB[@]}" "${COMPOSE_CMD[@]}" "${COMPOSE_ARGS[@]}" config --format json \
  >"$WORK/render.json"
python3 - "$WORK/render.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    service = json.load(fh)["services"]["glm53"]
env = service["environment"]
print("  image           %s" % service["image"])
print("  model           %s @ %s" % (env["MODEL_PATH"], env["MODEL_REVISION"]))
print("  rank / headless %s / %r" % (env["NODE_RANK"], env["HEADLESS"]))
print("  host ip         %s   rendezvous %s:%s"
      % (env["VLLM_HOST_IP"], env["MASTER_ADDR"], env["MASTER_PORT"]))
print("  KV / seqs / MNBT / split   %s / %s / %s / %s"
      % (env["KV_CACHE_MEMORY_BYTES"], env["MAX_NUM_SEQS"],
         env["MAX_NUM_BATCHED_TOKENS"], env["GLM53_SPLIT_TARGET_BLOCK_SIZE"]))
print("  spin limit      %s   display KV gid %s"
      % (env["B12X_ROCE_SPIN_LIMIT"], ",".join(service.get("group_add") or [])))
print("  API             %s"
      % ("none (headless rank)" if env["HEADLESS"]
         else "0.0.0.0:%s, unauthenticated" % env["PORT"]))
PY
note "render succeeded and changed nothing"

if [[ "$APPLY" == 0 ]]; then
  section "result"
  note "DRY RUN. Nothing was started."
  note "To start this node: add --apply (worker first, then head)."
  exit 0
fi

[[ -t 0 ]] || die "--apply needs an interactive terminal for the confirmation"
[[ -r /dev/tty ]] || die "--apply needs /dev/tty for the confirmation"

if [[ "$ROLE" == head ]]; then
  ORDER="Rank 1 (the worker) must ALREADY be running and listening; starting rank 0 first leaves both ranks waiting."
else
  ORDER="This is rank 1. It starts first; give it about 15 s before starting the head."
fi
cat <<CONFIRM

  About to run: ${COMPOSE_CMD[*]} ... up -d   (role $ROLE)
  $ORDER

  THIS CAN INTERRUPT A RUNNING SERVICE. Compose will pull the pinned image if
  it is absent, and if a glm53 container already exists here with a different
  configuration it will be stopped, removed and recreated: expect API downtime
  on rank 0, in-flight requests to fail, and the model to be reloaded onto the
  GPUs. An identical existing container is left running as is.
  Only proceed inside an agreed maintenance window. If you are replacing a
  running deployment, coordinate it and shut the pair down first.

  Rank 0 serves an unauthenticated API on 0.0.0.0 - protect it at the network
  boundary; nothing here configures a firewall.

CONFIRM
printf 'Type exactly "apply" to continue: '
IFS= read -r answer </dev/tty || die "could not read the confirmation"
[[ "$answer" == "apply" ]] || die "confirmation was '$answer', not 'apply'; nothing started"

section "starting"
"${SCRUB[@]}" "${COMPOSE_CMD[@]}" "${COMPOSE_ARGS[@]}" up -d
note "started. This launcher does not watch, restart or stop anything."
if [[ "$ROLE" == worker ]]; then
  note "Next: wait ~15 s, then run --role head --apply on the head node."
fi
