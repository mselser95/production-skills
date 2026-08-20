#!/usr/bin/env bash
# kill-durability.sh — SIGKILL the real container and prove the outbox intents
# it had already fsynced are still there afterwards.
#
# WHY THIS EXISTS. internal/platform/outboxlog.Append fsyncs every record
# before returning, and NO IN-PROCESS TEST CAN GUARD THAT LINE: removing the
# Sync call stays GREEN under mutation, because a normally-exiting process
# flushes its writes anyway. Proving anything about it needs a killed
# CONTAINER, not a killed goroutine. This script is the closing evidence for
# registries/contract-debt.yaml's outbox-fsync-unproven-against-machine-kill.
#
# HONEST SCOPE, because the difference matters and is easy to overclaim: a
# container SIGKILL kills the PROCESS, not the machine. The kernel page cache
# survives it, so this proves the write reached the KERNEL and that the log is
# readable and replayable afterwards. It does NOT prove the bytes reached the
# platter -- that needs power loss or a fault-injecting filesystem, and no
# check in this repo claims it. production.yaml's units_notification capability
# records the residue under `assumed:`.
#
# WHAT IT ASSERTS, and each one is here because its absence would let the
# script pass having proven nothing:
#
#   * a REAL DENOMINATOR -- reading ZERO intents before the kill is a FAILURE.
#     If the copy fails (container gone, path moved, docker cp unavailable)
#     nothing can be "lost", and a scenario that reports success on an empty
#     baseline is the vacuous pass this standard keeps finding.
#   * EXIT CODE 137, or the run is rejected. `docker stop` sends SIGTERM, the
#     process shuts down gracefully, and every buffer is flushed on the way
#     out -- which would pass this scenario while testing nothing at all.
#   * IDENTITIES, not counts. The count can go UP across a restart, because
#     boot re-derives effects from the event log and journals the ones the
#     outbox does not know. So "pending is still 12" is the wrong assertion and
#     "pending is 43" would look like a regression. What must hold is that no
#     intent present before the kill is missing after it.
#
#   make kill-durability            build, run, kill, restart, verify
#   EVENTS=50 make kill-durability  seed more effects
#
# Requires docker. Leaves nothing behind: the container and image are removed
# on exit, including on failure.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

IMAGE="${IMAGE:-<SERVICE>-kill-durability:scenario}"
NAME="${NAME:-<SERVICE>-kill-durability}"
PORT="${PORT:-18099}"
EVENTS="${EVENTS:-12}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"

say()  { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
good() { printf '  \033[32m%s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m%s\033[0m\n' "$*"; }

WORK="$(mktemp -d)"
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1
  docker image rm -f "$IMAGE" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || { bad "docker is not installed; this check cannot run"; exit 2; }
docker info >/dev/null 2>&1 || { bad "the docker daemon is not reachable; this check cannot run"; exit 2; }

# intent_ids prints the entry_id of every INTENT record in the container's
# outbox log, sorted and de-duplicated. Reading the file OUT of the container
# rather than asking the process is deliberate: the process is the thing under
# test, and after a SIGKILL there is nothing to ask.
intent_ids() {
  docker cp "$NAME":/tmp/data/outbox.jsonl - 2>/dev/null \
    | tar -xO 2>/dev/null \
    | sed -n 's/.*"entry_id":"\([^"]*\)","state":"intent".*/\1/p' \
    | sort -u
}

step "building the real image"
if ! docker build -q -t "$IMAGE" -f docker/Dockerfile . >"$WORK/build.log" 2>&1; then
  bad "docker build failed:"; tail -20 "$WORK/build.log"; exit 1
fi
say "built $IMAGE"

step "seeding $EVENTS events into a durable event log"
# The service exposes no write surface, so the effects it journals at boot are
# re-derived from the event log (cmd/<SERVICE>.rebuildOutboxFromLog). Seeding
# the log is therefore the honest way to make this service produce real
# intents through its real fsyncing path.
mkdir -p "$WORK/data"
: >"$WORK/data/eventlog.jsonl"
for ((i = 1; i <= EVENTS; i++)); do
  printf '{"schema_version":2,"kind":"event","id":"kill-%d","type":"deposited","amount":"1"}\n' "$i" \
    >>"$WORK/data/eventlog.jsonl"
done
# Mode, not ownership: the image runs as nonroot and `docker cp` does not
# preserve the host uid, so a 0644 file copied in can be unwritable by the
# process that has to open the log for append.
chmod 777 "$WORK/data"
chmod 666 "$WORK/data/eventlog.jsonl"

step "starting the container"
docker rm -f "$NAME" >/dev/null 2>&1
if ! docker create --name "$NAME" \
  -e EVENTLOG_PATH=/tmp/data/eventlog.jsonl \
  -e OUTBOX_LOG_PATH=/tmp/data/outbox.jsonl \
  -e CHECKPOINT_PATH=/tmp/data/checkpoints.json \
  -e HEALTH_PORT=8081 \
  -p "$PORT":8081 "$IMAGE" >/dev/null 2>&1; then
  bad "docker create failed"; exit 1
fi
docker cp "$WORK/data" "$NAME":/tmp/ >/dev/null || { bad "seeding the event log failed"; exit 1; }
docker start "$NAME" >/dev/null || { bad "docker start failed"; exit 1; }

waited=0
until curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; do
  sleep 1; waited=$((waited + 1))
  if ((waited > BOOT_TIMEOUT)); then
    bad "the service never became healthy in ${BOOT_TIMEOUT}s"; docker logs "$NAME" 2>&1 | tail -20; exit 1
  fi
done
say "healthy after ${waited}s"

step "capturing the durable intents before the kill"
before_file="$WORK/before.txt"
waited=0
while :; do
  intent_ids >"$before_file"
  before=$(wc -l <"$before_file" | tr -d ' ')
  ((before >= EVENTS)) && break
  sleep 1; waited=$((waited + 1))
  ((waited > BOOT_TIMEOUT)) && break
done
say "$before intent record(s) on disk"
# A REAL DENOMINATOR. Without this an empty baseline reports success having
# proven nothing at all -- there is no intent to lose, so none can go missing.
if ((before < 1)); then
  bad "read ZERO intents before the kill -- nothing could be lost, so a pass would mean nothing. Did the seeded event log reach the container?"
  docker logs "$NAME" 2>&1 | tail -20
  exit 1
fi

step "SIGKILL (docker kill, NOT stop -- a graceful stop would flush and prove nothing)"
docker kill --signal=SIGKILL "$NAME" >/dev/null 2>&1
code="$(docker inspect -f '{{.State.ExitCode}}' "$NAME" 2>/dev/null || echo '?')"
if [[ "$code" != "137" ]]; then
  bad "exit code $code, expected 137 -- the container was not SIGKILLed, so this run proves nothing"
  exit 1
fi
say "exit code 137, confirmed"

step "restarting"
docker start "$NAME" >/dev/null || { bad "docker start after the kill failed"; exit 1; }
waited=0
until curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; do
  sleep 1; waited=$((waited + 1))
  if ((waited > BOOT_TIMEOUT)); then
    bad "the service did not come back in ${BOOT_TIMEOUT}s after the kill"; docker logs "$NAME" 2>&1 | tail -20; exit 1
  fi
done
after_file="$WORK/after.txt"
intent_ids >"$after_file"
after=$(wc -l <"$after_file" | tr -d ' ')
lost=$(comm -23 "$before_file" "$after_file" | wc -l | tr -d ' ')
say "$after intent record(s) after the restart, $lost lost"

if [[ "$lost" != "0" ]]; then
  bad "$lost intent(s) fsynced before the kill are GONE -- an effect was committed to state and its delivery record did not survive"
  comm -23 "$before_file" "$after_file" | head -10
  exit 1
fi
good "every one of the $before intent(s) fsynced before a real SIGKILL survived it"
say "scope: this proves the write reached the KERNEL and the log replays; it does NOT prove the bytes reached the platter."
