#!/usr/bin/env bash
# soak.sh — hold this service under sustained load and watch for a LEAK.
# Driven by `make soak`.
#
# The lanes that already exist answer "is it correct" and "how fast is it".
# Neither can see the failure this one is for: a service that is correct and
# fast and grows a few goroutines, descriptors or megabytes per minute, which
# is invisible for the length of a test run and fatal on the fourth day of a
# deploy. The only way to see it is to run for a while and watch the shape of
# the numbers.
#
# Three metrics, because they fail differently and a leak usually shows in only
# one: GOROUTINES (something is started per request and never returns),
# DESCRIPTORS (a connection, file or pipe is opened and never closed), and RSS
# (a map or slice grows without bound). The verdict is delegated to
# benchmarks/load/growth-check.sh, which can be run on a synthetic series --
# see its header for why a leak detector that can only be exercised by leaking
# is a leak detector nobody has checked.
#
# THE VACUOUS FORMS this script is written against:
#
#   * A SOAK WITH NO LOAD. Nothing grows in an idle process, so a soak whose
#     generator died in the first second passes with the cleanest numbers you
#     will ever see. The run therefore FAILS unless the load actually landed:
#     loadgen must report served responses, and a real fraction of the arrivals
#     it scheduled. This is the denominator, and it is checked, not assumed.
#
#   * A SOAK THAT DID NOT SOAK. Sampling twice is not a trend. growth-check.sh
#     enforces a floor on sample count and refuses to give a verdict below it.
#
#   * A TOLERANCE NOBODY CAN TRIP. GROWTH_TOLERANCE_PCT is stated here, printed
#     in the output, and applies to a warm-up-excluded window comparison rather
#     than to first-versus-last -- so it does not have to be widened to survive
#     the ordinary growth every process does in its first minutes.
#
#   * SAMPLING THE PROCESS'S OWN OPINION. Descriptors and RSS are read from the
#     OPERATING SYSTEM (/proc or ps), not from anything the service reports
#     about itself. A leak in the accounting is a leak the accounting cannot
#     report. Goroutines are the exception -- only the runtime knows -- and they
#     come from net/http/pprof, which is why this script sets PPROF_PORT.
#
# Knobs (env):
#   SOAK_MINUTES          how long to hold the load     (default 30)
#   SOAK_RATE             offered arrival rate          (default 200)
#   SOAK_SAMPLE_SECONDS   seconds between samples       (default 30)
#   GROWTH_TOLERANCE_PCT  growth that fails the run     (default 10)
#   HEALTH_PORT / PPROF_PORT                            (default 18081 / 18082)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
cd .. || exit 2

SOAK_MINUTES="${SOAK_MINUTES:-30}"
SOAK_RATE="${SOAK_RATE:-200}"
SOAK_SAMPLE_SECONDS="${SOAK_SAMPLE_SECONDS:-30}"
GROWTH_TOLERANCE_PCT="${GROWTH_TOLERANCE_PCT:-10}"
HEALTH_PORT="${HEALTH_PORT:-18081}"
PPROF_PORT="${PPROF_PORT:-18082}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"

say()  { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
good() { printf '  \033[32m%s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m%s\033[0m\n' "$*"; }

WORK="$(mktemp -d)"
SVC_PID=""
GEN_PID=""
cleanup() {
  [[ -n "$GEN_PID" ]] && kill "$GEN_PID" 2>/dev/null
  [[ -n "$SVC_PID" ]] && kill "$SVC_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

step "building loadgen and the service"
go build -o "$WORK/loadgen" ./benchmarks/load || { bad "building loadgen failed"; exit 1; }
svc_pkg="$(go list ./cmd/... | head -1)"
[[ -n "$svc_pkg" ]] || { bad "no package under ./cmd to soak"; exit 2; }
go build -o "$WORK/svc" "$svc_pkg" || { bad "building $svc_pkg failed"; exit 1; }

step "starting the service (health $HEALTH_PORT, pprof $PPROF_PORT)"
mkdir -p "$WORK/data"
EVENTLOG_PATH="$WORK/data/eventlog.jsonl" \
OUTBOX_LOG_PATH="$WORK/data/outbox.jsonl" \
CHECKPOINT_PATH="$WORK/data/checkpoints.json" \
HEALTH_PORT="$HEALTH_PORT" PPROF_PORT="$PPROF_PORT" \
  "$WORK/svc" >"$WORK/svc.log" 2>&1 &
SVC_PID=$!

target="http://127.0.0.1:$HEALTH_PORT/healthz"
waited=0
until curl -sf "$target" >/dev/null 2>&1; do
  if ! kill -0 "$SVC_PID" 2>/dev/null; then
    bad "the service exited during boot:"; tail -20 "$WORK/svc.log"; exit 1
  fi
  sleep 1; waited=$((waited + 1))
  ((waited > BOOT_TIMEOUT)) && { bad "never became healthy in ${BOOT_TIMEOUT}s"; tail -20 "$WORK/svc.log"; exit 1; }
done
say "healthy after ${waited}s, pid $SVC_PID"

# --- samplers --------------------------------------------------------------
# Each prints a number, or `-` when this host cannot answer. `-`, never 0: a
# metric reported as zero is a flat series and a green verdict, which is the
# unreadable-metric vacuous form. growth-check.sh names an all-`-` column
# UNAVAILABLE and fails the run if no column was readable at all.

goroutines() {
  curl -sf "http://127.0.0.1:$PPROF_PORT/debug/pprof/goroutine?debug=1" 2>/dev/null \
    | sed -n 's/^goroutine profile: total \([0-9]*\).*/\1/p' | head -1 | grep -E '^[0-9]+$' || echo -
}

fds() {
  if [[ -d "/proc/$SVC_PID/fd" ]]; then
    find "/proc/$SVC_PID/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
  elif command -v lsof >/dev/null 2>&1; then
    # -w silences warnings that would otherwise be counted as rows.
    lsof -w -p "$SVC_PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' '
  else
    echo -
  fi
}

rss_kb() {
  ps -o rss= -p "$SVC_PID" 2>/dev/null | tr -d ' ' | grep -E '^[0-9]+$' || echo -
}

# --- offer the load --------------------------------------------------------
duration_s=$((SOAK_MINUTES * 60))
step "offering ${SOAK_RATE}/s for ${SOAK_MINUTES} minute(s), sampling every ${SOAK_SAMPLE_SECONDS}s"
"$WORK/loadgen" -target "$target" -rate "$SOAK_RATE" -duration "${duration_s}s" \
  >"$WORK/loadgen.out" 2>"$WORK/loadgen.err" &
GEN_PID=$!

samples="$WORK/samples.tsv"
printf '#elapsed_s goroutines fds rss_kb\n' >"$samples"
elapsed=0
while kill -0 "$GEN_PID" 2>/dev/null; do
  printf '%s %s %s %s\n' "$elapsed" "$(goroutines)" "$(fds)" "$(rss_kb)" >>"$samples"
  sleep "$SOAK_SAMPLE_SECONDS"
  elapsed=$((elapsed + SOAK_SAMPLE_SECONDS))
  if ! kill -0 "$SVC_PID" 2>/dev/null; then
    bad "the service DIED ${elapsed}s into the soak:"; tail -20 "$WORK/svc.log"; exit 1
  fi
done
wait "$GEN_PID"; gen_code=$?
GEN_PID=""
# One last sample after the load stops, so the final window is not one short.
printf '%s %s %s %s\n' "$elapsed" "$(goroutines)" "$(fds)" "$(rss_kb)" >>"$samples"

# --- the denominator -------------------------------------------------------
# Everything below is only meaningful if load actually landed. An idle process
# leaks nothing.
step "confirming the load actually landed"
kv() { sed -n "s/^$1=//p" "$WORK/loadgen.out"; }
scheduled=$(kv arrivals_scheduled); served=$(kv responses_served)
if [[ -z "$served" || -z "$scheduled" ]]; then
  bad "loadgen produced no summary (exit $gen_code):"; cat "$WORK/loadgen.err"; exit 1
fi
say "$served of $scheduled arrivals served, p99 $(kv latency_p99_ms)ms"
if ((served == 0)); then
  bad "the service served NOTHING for the whole soak: nothing was exercised, so nothing could leak."
  exit 1
fi
if awk -v s="$served" -v n="$scheduled" 'BEGIN { exit !(s < 0.5 * n) }'; then
  bad "only $served of $scheduled arrivals were served — under half. This soak did not sustain its load,"
  say "so a flat resource curve says nothing about the service under real traffic."
  exit 1
fi
good "load sustained"

step "resource samples"
column -t "$samples" 2>/dev/null || cat "$samples"

step "growth verdict (tolerance ${GROWTH_TOLERANCE_PCT}%)"
grep -v '^#' "$samples" | GROWTH_TOLERANCE_PCT="$GROWTH_TOLERANCE_PCT" bash benchmarks/load/growth-check.sh
verdict=$?

case "$verdict" in
  0) good "no metric grew beyond ${GROWTH_TOLERANCE_PCT}% between the two measured windows" ;;
  1) bad  "a resource grew and did not level off — this is what a leak looks like" ;;
  *) bad  "the soak could not produce a verdict (see above); it did not pass, it failed to decide" ;;
esac
exit "$verdict"
