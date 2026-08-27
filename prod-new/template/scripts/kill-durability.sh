#!/usr/bin/env bash
# kill-durability.sh — SIGKILL the real container and prove two things about
# what comes back: the outbox intents it had already fsynced are still there,
# and the LEDGER STATE it reconstructs is the state it had before the kill.
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
# THE SECOND RATIONALE, added beside the first rather than replacing it:
# CRASH-ONLY DISCIPLINE. Candea and Fox, "Crash-Only Software" (HotOS IX,
# 2003), make the argument this scenario exists to test: a component should
# have exactly ONE way to stop -- crashing -- and exactly one way to start --
# recovering -- because a graceful-shutdown path that differs from the
# recovery path is code that only ever runs when things are going well, while
# the path that runs during an outage is the one nobody exercised. Their
# corollary is the sharp one: if crashing is the only stop, then recovery is
# on the common path and gets tested continuously; if it is not, recovery is
# the least-tested code in the system and it runs at the worst moment.
#
# This scaffold already takes that side by construction. The durable event log
# is the source of truth, boot replays it (eventlog.Recover), and there is no
# state flush on the way out that a SIGKILL could skip. But "recovery IS the
# start path" is a claim, and the only way to falsify it is to compare the
# state before a crash against the state after one. That comparison is what
# the LEDGER STATE assertion below performs, and it is a genuinely different
# question from the outbox one above: the outbox check asks whether a DURABLE
# RECORD survived; this one asks whether REPLAYING those records reconstructs
# the same thing. A boot that read every byte back and then rebuilt the
# balance wrong would pass the first check and fail the second, which is
# precisely why one does not stand in for the other.
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
#   * IDENTICAL LEDGER STATE across the kill: the balance, the size of the
#     applied-event set, and the digest over that set, all read from /healthz
#     before the SIGKILL and again after the restart. EQUALITY is the right
#     relation here, unlike the intents above, and for a reason worth stating
#     rather than assuming: the applied set is a function of the event log
#     alone, and the kill adds no events to it, so a replay that reconstructs
#     anything else has lost or invented history.
#   * A REAL DENOMINATOR ON THAT TOO, and it is a different denominator from
#     the intents one. Two captures both reading `known=false` -- a /healthz
#     that never learned about the ledger, a curl that failed, a field that
#     got renamed -- are trivially identical, and comparing them would report
#     crash-only recovery proven having observed nothing at all. So a capture
#     must say known=true and must carry a non-empty applied set before its
#     equality means anything.
#
#   make kill-durability            build, run, kill, restart, verify
#   EVENTS=50 make kill-durability  seed more effects
#
# Requires docker. Leaves nothing behind: the container and image are removed
# on exit, including on failure.
#
# SOURCEABLE AS A LIBRARY. `KILL_DURABILITY_LIB=1 source scripts/kill-
# durability.sh` defines the helpers and returns before touching docker, so
# scripts/tests/kill-durability-state-selftest.sh can drive the REAL state
# comparison against crafted fixture captures on a machine with no docker
# daemon. That matters more than it sounds: this script cannot run in a
# developer's inner loop or on a runner without docker, so without the
# sourceable seam its newest assertion would be the kind of code that is only
# ever executed by the environment least able to debug it.
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

# ---------------------------------------------------------------------------
# LEDGER STATE: capture and compare.
#
# These three live above the docker preflight so the library seam below can
# expose them to the selftest. Nothing here shells out to docker; the state is
# read over HTTP from the health endpoint, which is the only vantage that can
# answer "what did this process reconstruct" as opposed to "what is on disk".
# The intents check deliberately reads the FILE instead, because after a
# SIGKILL there is no process left to ask -- these two checks look at the two
# different halves on purpose.
# ---------------------------------------------------------------------------

# state_field <json-fragment> <key> -- pull one value out of the flat `state`
# object. Hand-rolled rather than jq, matching intent_ids below and the rest
# of this repo: jq is not in the image, not in the Makefile, and not a
# dependency this scenario should acquire to read four scalars.
state_field() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([^,\"}]*\)\"\{0,1\}.*/\1/p" | head -1
}

# ledger_state prints a NORMALISED capture of the state this pod reconstructed:
# one `key=value` line per field, in a fixed order, so two captures can be
# compared with a plain diff and the diff names the field that moved.
#
# Fixed order and one field per line, rather than the raw JSON body: the body
# also carries pod_id, revision and the config identity, and a capture that
# included those would differ across a restart for reasons that have nothing
# to do with recovery -- an assertion that fires when nothing is wrong, which
# trains people to widen it until it is gone.
ledger_state() {
  local body frag
  body="$(curl -sf "http://127.0.0.1:$PORT/healthz" 2>/dev/null)" || return 1
  # the nested `state` object, from its opening brace to its first closing one
  frag="${body#*\"state\":\{}"
  [[ "$frag" == "$body" ]] && return 1   # no `state` key at all: field renamed or removed
  frag="${frag%%\}*}"
  printf 'known=%s\n'          "$(state_field "$frag" known)"
  printf 'balance=%s\n'        "$(state_field "$frag" balance)"
  printf 'applied_count=%s\n'  "$(state_field "$frag" applied_count)"
  printf 'applied_digest=%s\n' "$(state_field "$frag" applied_digest)"
}

# assert_state_identical <before-file> <after-file> -- 0 if the two captures
# describe the same reconstructed state AND that state is real enough for the
# comparison to mean something; 1 otherwise, with the reason named.
#
# LIFTED INTO A FUNCTION so the selftest can drive THIS, rather than a second
# copy of the same logic living in a test file. A selftest that reimplements
# the comparison tests the copy, and the two drift in exactly the direction
# where the real one stops asserting.
assert_state_identical() {
  local before="$1" after="$2" known count

  # The denominator, checked on the BEFORE capture, and checked before
  # equality rather than after it. Two unknown captures are equal, and an
  # equality test that passes on them reports crash-only recovery proven from
  # two readings of nothing.
  known="$(sed -n 's/^known=//p' "$before")"
  if [[ "$known" != "true" ]]; then
    bad "the pre-kill state capture reads known=${known:-<empty>} -- /healthz did not report a reconstructed ledger, so there is no state to lose and a pass would mean nothing"
    return 1
  fi
  count="$(sed -n 's/^applied_count=//p' "$before")"
  if [[ ! "$count" =~ ^[0-9]+$ ]] || ((count < 1)); then
    bad "the pre-kill applied set is ${count:-<empty>} -- an empty set is reconstructed identically by a boot that replays nothing, which is the vacuous pass this check exists to refuse"
    return 1
  fi

  if ! diff -u "$before" "$after" >/dev/null 2>&1; then
    bad "the state after the restart is NOT the state before the kill -- replay did not reconstruct what the log already contained:"
    diff -u "$before" "$after" | sed -n '4,20p'
    return 1
  fi
  return 0
}

# THE LIBRARY SEAM. Everything above is definitions; everything below builds an
# image and talks to a docker daemon. Sourcing with KILL_DURABILITY_LIB=1 stops
# here, which is what lets the state comparison be exercised on a machine that
# cannot run the scenario at all.
if [[ -n "${KILL_DURABILITY_LIB:-}" ]]; then
  # The marker exists because REMOVING THIS BLOCK IS SILENT. Measured
  # 2026-08-27: with the seam deleted, sourcing ran the entire docker scenario,
  # it passed, and the selftest then carried on and reported 9 ok / 0 failed --
  # so the mutation that turns the library seam off was undetectable by the one
  # thing that depends on it. The selftest asserts this marker, which turns
  # "the seam is gone" into a red instead of a slow green.
  #
  # shellcheck disable=SC2034  # read by the SOURCING script, never by this one
  KILL_DURABILITY_LIB_LOADED=1
  return 0 2>/dev/null || exit 0
fi

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

step "capturing the reconstructed LEDGER STATE before the kill"
# Read LAST, immediately before the SIGKILL, and not at boot: the point of
# comparison is the state the process was actually holding at the instant it
# died, and anything captured earlier compares the restart against a moment
# the crash did not interrupt.
state_before="$WORK/state-before.txt"
if ! ledger_state >"$state_before"; then
  bad "could not read the ledger state off /healthz before the kill -- with no capture there is nothing to compare the restart against"
  docker logs "$NAME" 2>&1 | tail -20
  exit 1
fi
say "state before: $(tr '\n' ' ' <"$state_before")"

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

step "asserting the restarted process reconstructed the SAME LEDGER STATE"
# Additive, and the existing check above is untouched: surviving records and a
# correct replay OF those records are two claims, and this repo has only ever
# made the first one. A boot that read every byte back and rebuilt the balance
# wrong passes everything above this line.
state_after="$WORK/state-after.txt"
if ! ledger_state >"$state_after"; then
  bad "could not read the ledger state off /healthz after the restart"
  docker logs "$NAME" 2>&1 | tail -20
  exit 1
fi
say "state after:  $(tr '\n' ' ' <"$state_after")"
if ! assert_state_identical "$state_before" "$state_after"; then
  docker logs "$NAME" 2>&1 | tail -20
  exit 1
fi
good "recovery IS the start path: balance, applied-set size and applied-set digest are identical across the SIGKILL (crash-only, Candea & Fox HotOS IX 2003)"

say "scope: this proves the write reached the KERNEL and the log replays; it does NOT prove the bytes reached the platter."
say "scope: the state assertion covers what /healthz exposes -- balance, applied-set size and its digest. State the service holds but does not surface is outside it."
