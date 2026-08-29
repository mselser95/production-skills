#!/usr/bin/env bash
# sweep.sh — find this service's SATURATION POINT and write
# benchmarks/load/baseline.md. Driven by `make load`.
#
# One run of loadgen at one rate answers "did it keep up at 500/s". That is not
# a capacity number, and a baseline built from one of them is a number with no
# meaning: a service that keeps up at every rate you tried has only told you
# that you did not try hard enough. Capacity is where achieved load stops
# tracking offered load, so this script SWEEPS rising rates against a real
# process and records the first one that parts company.
#
# It starts the service itself, on a loopback port with a throwaway data
# directory, so `make load` on a laptop and the nightly job in CI measure the
# same thing rather than whatever happened to be running.
#
# WHAT IT REFUSES TO RECORD, because each of these is a baseline that reads as
# a measurement and is not one:
#
#   * A SWEEP THAT NEVER SATURATED. If the service survives the top rate, the
#     saturation point is UNKNOWN and greater than that rate. The baseline says
#     so in those words and this script exits non-zero, because "we never found
#     the limit" is a sweep that needs extending, not a capacity result.
#
#   * A RUN THE GENERATOR SPOILED. loadgen reports `generator_suspect=true`
#     when more than a quarter of the tail it is reporting is its own send lag,
#     or when it dropped arrivals it never issued. A saturation point taken
#     from such a run is this laptop's limit wearing the service's name.
#     Suspect rows are marked UNUSABLE and cannot set the saturation point.
#
#     Expect this on a developer machine, especially at low rates where the
#     tail is small enough for a few milliseconds of scheduling to dominate it.
#     That is the harness working, not failing: the row is genuinely not a
#     measurement of the service. A baseline worth committing comes from a
#     quiet host, ideally with the generator not sharing it with the service.
#
#   * A MARGIN AGAINST NOTHING. tier-policy.yaml requires 2x headroom over
#     declared peak (`capacity: { margin_target: 2x, measured: required }`).
#     With no declared peak the ratio has no denominator, and a capacity gate
#     with no denominator passes every service forever. TARGET_RPS is
#     therefore not defaulted: unset, the baseline records the margin as NOT
#     COMPUTABLE and names the missing input, rather than printing a number.
#
#   * A NUMBER WITH NO ENVIRONMENT. A saturation rate from an unnamed host and
#     an unnamed toolchain cannot be compared with next quarter's, which is the
#     only thing a baseline is for. The header records both.
#
# Knobs (env):
#   RATES              rates to sweep, ascending  (default "100 250 500 1000 2000 4000")
#   DURATION           per-rate run length        (default 10s)
#   TARGET_RPS         DECLARED peak; no default  (margin is not computed without it)
#   LATENCY_BUDGET_MS  declared p99 budget; no default
#   MARGIN_TARGET      headroom multiple          (default 2, from tier-policy.yaml)
#   HEALTH_PORT        loopback port for the service under test (default 18081)
#   OUT                where to write             (default benchmarks/load/baseline.md)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
cd .. || exit 2

RATES="${RATES:-100 250 500 1000 2000 4000}"
DURATION="${DURATION:-10s}"
TARGET_RPS="${TARGET_RPS:-}"
LATENCY_BUDGET_MS="${LATENCY_BUDGET_MS:-}"
MARGIN_TARGET="${MARGIN_TARGET:-2}"
HEALTH_PORT="${HEALTH_PORT:-18081}"
OUT="${OUT:-benchmarks/load/baseline.md}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"

say()  { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
good() { printf '  \033[32m%s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m%s\033[0m\n' "$*"; }

WORK="$(mktemp -d)"
SVC_PID=""
cleanup() {
  [[ -n "$SVC_PID" ]] && kill "$SVC_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

step "building loadgen and the service"
go build -o "$WORK/loadgen" ./benchmarks/load || { bad "building loadgen failed"; exit 1; }
svc_pkg="$(go list ./cmd/... | head -1)"
[[ -n "$svc_pkg" ]] || { bad "no package under ./cmd to load-test"; exit 2; }
go build -o "$WORK/svc" "$svc_pkg" || { bad "building $svc_pkg failed"; exit 1; }
say "built $svc_pkg"

step "starting the service on 127.0.0.1:$HEALTH_PORT"
mkdir -p "$WORK/data"
EVENTLOG_PATH="$WORK/data/eventlog.jsonl" \
OUTBOX_LOG_PATH="$WORK/data/outbox.jsonl" \
CHECKPOINT_PATH="$WORK/data/checkpoints.json" \
HEALTH_PORT="$HEALTH_PORT" \
  "$WORK/svc" >"$WORK/svc.log" 2>&1 &
SVC_PID=$!

target="http://127.0.0.1:$HEALTH_PORT/healthz"
waited=0
until curl -sf "$target" >/dev/null 2>&1; do
  if ! kill -0 "$SVC_PID" 2>/dev/null; then
    bad "the service exited during boot:"; tail -20 "$WORK/svc.log"; exit 1
  fi
  sleep 1; waited=$((waited + 1))
  if ((waited > BOOT_TIMEOUT)); then
    bad "the service never became healthy in ${BOOT_TIMEOUT}s"; tail -20 "$WORK/svc.log"; exit 1
  fi
done
say "healthy after ${waited}s"

# A warm-up run whose numbers are DISCARDED. The first requests a process ever
# serves pay for lazily-built connection pools, cold caches and first-touch
# page faults; charging those to the lowest rate in the sweep makes the bottom
# of the curve look worse than the middle, which reads as a system that gets
# faster under load.
step "warm-up (discarded)"
"$WORK/loadgen" -target "$target" -rate 50 -duration 2s >/dev/null 2>&1
say "done"

kv() { sed -n "s/^$1=//p" "$2"; }

rows=""
saturation=""
saturation_reason=""
suspect_rows=0
measured_rows=0

for rate in $RATES; do
  step "offering ${rate}/s for $DURATION"
  out="$WORK/run-$rate.txt"
  "$WORK/loadgen" -target "$target" -rate "$rate" -duration "$DURATION" >"$out" 2>"$WORK/run-$rate.err"
  code=$?

  achieved=$(kv achieved_rate_rps "$out")
  ratio=$(kv achieved_over_offered "$out")
  p99=$(kv latency_p99_ms "$out")
  p999=$(kv latency_p999_ms "$out")
  refused=$(kv responses_refused "$out")
  failed=$(kv responses_failed "$out")
  suspect=$(kv generator_suspect "$out")
  lag_share=$(kv lag_share_of_tail "$out")

  if [[ -z "$achieved" ]]; then
    bad "loadgen produced no summary at ${rate}/s (exit $code):"; cat "$WORK/run-$rate.err"; exit 1
  fi

  note="ok"
  if [[ "$suspect" == "true" ]]; then
    note="UNUSABLE — ${lag_share} of this tail is the generator's own send lag"
    suspect_rows=$((suspect_rows + 1))
    bad "generator_suspect at ${rate}/s: ${lag_share} of the reported p99 is this harness's own delay"
  else
    measured_rows=$((measured_rows + 1))
  fi

  rows+="| $rate | $achieved | $ratio | $p99 | $p999 | $refused | $failed | $note |"$'\n'
  say "achieved ${achieved}/s (ratio $ratio), p99 ${p99}ms, refused $refused, failed $failed"

  # The saturation point is the LOWEST rate at which either half of the
  # definition trips, and only a row the generator did not spoil may set it.
  if [[ -z "$saturation" && "$suspect" != "true" ]]; then
    if awk -v r="$ratio" 'BEGIN { exit !(r < 0.99) }'; then
      saturation="$rate"
      saturation_reason="achieved/offered fell to $ratio"
    elif [[ -n "$LATENCY_BUDGET_MS" ]] && awk -v p="$p99" -v b="$LATENCY_BUDGET_MS" 'BEGIN { exit !(p > b) }'; then
      saturation="$rate"
      saturation_reason="p99 ${p99}ms breached the declared budget of ${LATENCY_BUDGET_MS}ms"
    fi
  fi
done

highest="${RATES##* }"

# --- verdict ---------------------------------------------------------------
verdict=0
if ((measured_rows == 0)); then
  bad "every row in the sweep was spoiled by the generator; nothing about the service was measured."
  say "This is normal on a busy developer machine. Run it on a quiet host, or raise DURATION so the"
  say "tail is measured over more samples, before reading anything into these numbers."
  verdict=2
elif [[ -z "$saturation" && $suspect_rows -gt 0 ]]; then
  # NOT-MEASURED IS NOT KEPT-UP. A spoiled row is correctly barred from setting
  # the saturation point -- if the generator was the bottleneck, the numbers say
  # nothing about the service -- but the old message then reported that silence
  # as a result: "the service kept up at every rate up to ${highest}/s."
  #
  # Measured 2026-08-29 on this scaffold at RATES="4000 8000 16000 32000 64000":
  #
  #   16000 -> ratio 0.9999, p99   5.972ms,     0 failed   ok
  #   32000 -> ratio 0.0203, p99 7622.885ms, 18269 failed   UNUSABLE (35% generator lag)
  #   64000 -> ratio 0.0084, p99 8008.479ms, 18511 failed   UNUSABLE (21% generator lag)
  #
  # and it printed "the service kept up at every rate up to 64000/s" over a
  # table showing a collapse to 2% of offered load. Whether that collapse was
  # the service or the harness is genuinely unknown -- which is the point. The
  # honest verdict names the unknown instead of resolving it in the service's
  # favour, because a capacity story built on this would claim headroom that was
  # never observed.
  bad "the sweep could NOT determine a saturation point: ${suspect_rows} of the offered rates were spoiled by the generator's own send lag."
  say "This says nothing about the service -- not that it kept up. The highest rate that"
  say "was actually MEASURED is the last row marked ok in the table above; everything past"
  say "it is unknown. Re-run on a quieter host, or with a generator that is not competing"
  say "with the service for the same CPUs, before reading capacity into these numbers."
  verdict=1
elif [[ -z "$saturation" ]]; then
  # Every row was usable and none tripped: this one really is a lower bound.
  bad "the sweep never saturated: the service kept up at every rate up to ${highest}/s, and every row was usable."
  say "That is a LOWER BOUND, not a capacity number. Raise RATES and run again."
  verdict=1
fi

margin="NOT COMPUTABLE"
margin_note="no declared peak: set TARGET_RPS to the rate this service must sustain. tier-policy.yaml requires ${MARGIN_TARGET}x headroom over it, and a ratio with no denominator is a gate that passes every service forever."
if [[ -n "$TARGET_RPS" && -n "$saturation" ]]; then
  margin="$(awk -v s="$saturation" -v t="$TARGET_RPS" 'BEGIN { printf "%.2fx", s / t }')"
  if awk -v s="$saturation" -v t="$TARGET_RPS" -v m="$MARGIN_TARGET" 'BEGIN { exit !(s / t < m) }'; then
    margin_note="BELOW the ${MARGIN_TARGET}x required by tier-policy.yaml (capacity.margin_target) against a declared peak of ${TARGET_RPS}/s."
    bad "capacity margin $margin is below the required ${MARGIN_TARGET}x"
    verdict=1
  else
    margin_note="meets the ${MARGIN_TARGET}x required by tier-policy.yaml (capacity.margin_target) against a declared peak of ${TARGET_RPS}/s."
  fi
fi

step "writing $OUT"
{
  printf '# Load baseline\n\n'
  printf '**Generated by `make load`** (`benchmarks/load/sweep.sh`) on %s.\n\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')"
  printf 'Measured by `benchmarks/load/loadgen.go`, an OPEN-LOOP generator: arrivals\n'
  printf 'are scheduled off the wall clock and latency is timed from the SCHEDULED\n'
  printf 'arrival, so a stall shows up in the tail instead of throttling the offered\n'
  printf 'load. See that file for why a closed-loop driver cannot produce this table.\n\n'

  printf '## Environment\n\n'
  printf 'A measurement without its environment is not comparable with the next one.\n\n'
  # MACHINE-READABLE MEASUREMENT DATE. The prose line above ("Generated by
  # `make load` ... on 2026-08-29 06:35:09Z") is for humans, and the probe
  # cannot parse it: verify-standard.sh's load_field() looks for a `key: value`
  # line and wants `measured:` (or measured_at / measurement_date / date).
  # Without this field the load-baseline row FAILS with "carries no parseable
  # measurement date" -- on a baseline this very script had just written.
  #
  # Measured 2026-08-29 in a freshly instantiated template: `make load` ran the
  # full sweep, wrote baseline.md, and the row still failed. Following the
  # documented Phase 3 procedure exactly could not turn this dimension green in
  # ANY repo the skill scaffolds. Neither side was individually wrong, which is
  # why it survived unnoticed: the writer's timestamp is real, and the reader's
  # requirement is well-founded (mtime is explicitly NOT a fallback, because a
  # clone stamps it with the checkout time and would report any baseline as
  # fresh). They simply never agreed on a format, and nobody had run the
  # producer and the consumer back to back.
  # The colon goes OUTSIDE the bold: `- **measured**: DATE`, not
  # `- **measured:** DATE`. Neighbouring lines here use the second style
  # (`- **Toolchain:** ...`) and copying it is the natural mistake -- it was
  # mine, first try. load_field() then strips everything up to the first colon
  # and hands back `** 2026-08-29`, which fails the YYYY-MM-DD anchor with the
  # same "no parseable measurement date" message as having no field at all.
  # (The probe now also tolerates the other style; this stays canonical.)
  printf -- '- **measured**: %s\n' "$(date -u '+%Y-%m-%d')"
  printf -- '- **Toolchain:** `%s`\n' "$(go version)"
  printf -- '- **Host:** %s %s, %s CPU(s)\n' "$(uname -s)" "$(uname -m)" "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?')"
  printf -- '- **Target:** `%s` (the scaffold health endpoint; a real service repoints this at the surface whose budget it declared)\n' "$target"
  printf -- '- **Per-rate duration:** %s\n\n' "$DURATION"

  printf '## Sweep\n\n'
  printf '| offered rps | achieved rps | achieved/offered | p99 ms | p99.9 ms | refused | failed | note |\n'
  printf '| ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n'
  printf '%s' "$rows"
  printf '\n'

  printf '## Saturation point\n\n'
  printf 'The lowest offered rate at which achieved load stopped tracking it '
  if [[ -n "$LATENCY_BUDGET_MS" ]]; then
    printf '(ratio < 0.99) or p99 breached the declared budget of %sms.\n\n' "$LATENCY_BUDGET_MS"
  else
    printf '(ratio < 0.99).\n\n'
    printf '_No `LATENCY_BUDGET_MS` was declared, so the p99 half of that definition\n'
    printf 'was NOT evaluated: this saturation point is a throughput cliff only, and a\n'
    printf 'service can breach its latency budget well below it._\n\n'
  fi
  if [[ -n "$saturation" ]]; then
    printf -- '- **Saturation:** %s/s — %s\n' "$saturation" "$saturation_reason"
  else
    printf -- '- **Saturation: NOT REACHED.** The service kept up at every rate offered, up to %s/s.\n' "$highest"
    printf -- '  The real saturation point is somewhere above that and this run did not find it.\n'
    printf -- '  Raise `RATES` and re-run; do not read the top row as a capacity figure.\n'
  fi
  printf -- '- **Capacity margin:** %s — %s\n' "$margin" "$margin_note"
  if ((suspect_rows > 0)); then
    printf -- '- **%d row(s) UNUSABLE:** more than a quarter of the tail those rows report is\n' "$suspect_rows"
    printf -- '  the generator\047s own send lag, or it dropped arrivals it never issued. Those\n'
    printf -- '  rates were NOT measured; re-run them from a host that is not also running the\n'
    printf -- '  service.\n'
  fi
  printf '\n'

  printf '## Reproducing\n\n'
  printf '```sh\n'
  printf 'make load                       # this sweep, with these defaults\n'
  printf 'RATES="500 1000 2000 4000 8000" TARGET_RPS=800 LATENCY_BUDGET_MS=50 make load\n'
  printf '```\n'
} >"$OUT"

good "wrote $OUT"
if ((verdict != 0)); then
  bad "sweep incomplete — see $OUT"
fi
exit "$verdict"
