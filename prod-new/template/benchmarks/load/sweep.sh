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
#   GENERATOR_CEILING  a rate the GENERATOR has been shown to sustain against
#                      a faster service. At or below it, a spoiled row is
#                      attributed to the SERVICE rather than dismissed --
#                      because the harness has already been proven capable
#                      there. Requires GENERATOR_CEILING_EVIDENCE.
#   GENERATOR_CEILING_EVIDENCE
#                      how that ceiling was established. Recorded in the
#                      baseline; without it the ceiling is refused, because an
#                      undocumented one is just a switch that turns the
#                      spoiled-row guard off.
#   REPS               repetitions per rate, median reported (default 1).
#                      Set it to 5 on a machine that also runs anything else:
#                      this measurement is bimodal, and one bad draw in a
#                      single-shot sweep invents a saturation point.
#   TARGET_RPS         DECLARED peak; no default  (margin is not computed without it)
#   LATENCY_BUDGET_MS  declared p99 budget; no default
#   MARGIN_TARGET      headroom multiple          (default 2, from tier-policy.yaml)
#   HEALTH_PORT        loopback port for the service under test (default 18081)
#   TARGET_PATH        which endpoint to drive (default /healthz).
#
#                      THIS CHOICE DECIDES WHETHER THE NUMBER MEANS ANYTHING.
#                      /healthz returns a couple of hundred bytes and does
#                      almost no work, so on a fast machine the SERVICE never
#                      becomes the bottleneck -- the generator does, and the
#                      sweep correctly refuses to call that a saturation point.
#                      Point this at an endpoint that does representative work
#                      (/metrics renders the full exposition) and the service
#                      saturates within a band the generator can actually
#                      drive.
#   SVC_GOMAXPROCS     cores the SERVICE may use; unset = all of them. Set it
#                      when the generator is the bottleneck (see below), and
#                      record it beside the number -- capacity without a stated
#                      resource allocation is not a figure, it is a rumour.
#   OUT                where to write             (default benchmarks/load/baseline.md)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
cd .. || exit 2

RATES="${RATES:-100 250 500 1000 2000 4000}"
DURATION="${DURATION:-10s}"
REPS="${REPS:-1}"
GENERATOR_CEILING="${GENERATOR_CEILING:-}"
GENERATOR_CEILING_EVIDENCE="${GENERATOR_CEILING_EVIDENCE:-}"

TARGET_RPS="${TARGET_RPS:-}"
LATENCY_BUDGET_MS="${LATENCY_BUDGET_MS:-}"
MARGIN_TARGET="${MARGIN_TARGET:-2}"
HEALTH_PORT="${HEALTH_PORT:-18081}"
TARGET_PATH="${TARGET_PATH:-/healthz}"
SVC_GOMAXPROCS="${SVC_GOMAXPROCS:-}"
OUT="${OUT:-benchmarks/load/baseline.md}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"

say()  { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
good() { printf '  \033[32m%s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m%s\033[0m\n' "$*"; }
# A ceiling with no evidence is a bypass, not a measurement.
#
# This flag suppresses the guard that stops a spoiled row setting the
# saturation point -- the single most load-bearing refusal in this script. It
# is legitimate ONLY when the generator has been independently shown to drive
# that rate, and the way to keep it legitimate is to make the claim a required
# input that lands in the artifact where a reader can judge it.
if [[ -n "$GENERATOR_CEILING" && -z "$GENERATOR_CEILING_EVIDENCE" ]]; then
  bad "GENERATOR_CEILING is set with no GENERATOR_CEILING_EVIDENCE."
  say "The ceiling suppresses the spoiled-row guard, so it needs the measurement"
  say "that justifies it -- e.g. 'same rate 5/5 clean at SVC_GOMAXPROCS=2'."
  exit 2
fi

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
# # SVC_GOMAXPROCS: give the service a DEFINED share of the machine
#
# Without it the service and the load generator compete for every core, and on
# a developer's laptop the generator loses first: it cannot schedule sends fast
# enough, its own lag dominates the reported tail, and the sweep correctly
# refuses to call that a saturation point. Measured here on 16 cores -- 80,000/s
# clean, and at 88,000/s nearly a third of the reported p99 was the harness's
# own delay. The service's real limit was never reached.
#
# Pinning the service to fewer cores makes IT the bottleneck again, which is
# the only configuration in which the number means anything. It also makes the
# number honest in a way an unconstrained run is not: "this service saturates
# at N req/s" is meaningless without saying on how much machine. A capacity
# figure is a pair.
#
# Unset by default, so an unconstrained run behaves exactly as before.
# Built as an array and launched through `env`, NOT as a bare
# `${VAR:+NAME=value}` prefix: that expansion lands in COMMAND position, so
# bash tried to execute a program literally named "GOMAXPROCS=2".
svc_env=(
  EVENTLOG_PATH="$WORK/data/eventlog.jsonl"
  OUTBOX_LOG_PATH="$WORK/data/outbox.jsonl"
  CHECKPOINT_PATH="$WORK/data/checkpoints.json"
  HEALTH_PORT="$HEALTH_PORT"
)
[[ -n "$SVC_GOMAXPROCS" ]] && svc_env+=(GOMAXPROCS="$SVC_GOMAXPROCS")
env "${svc_env[@]}" "$WORK/svc" >"$WORK/svc.log" 2>&1 &
SVC_PID=$!

target="http://127.0.0.1:$HEALTH_PORT${TARGET_PATH}"
# Readiness is polled on /healthz regardless of what is being DRIVEN: the
# target may be an endpoint that is only meaningful once the process is warm,
# and waiting on it would conflate "not up yet" with "not working".
boot_probe="http://127.0.0.1:$HEALTH_PORT/healthz"
waited=0
until curl -sf "$boot_probe" >/dev/null 2>&1; do
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

# median <numbers...> -> the middle value, for an ODD count.
#
# The median and not the mean, deliberately. The failure mode this exists to
# survive is a single catastrophic outlier -- one repetition in five collapsing
# to 1% of offered load -- and a mean would let that one run drag the reported
# figure down by 20%, inventing a degradation the service never had.
median() {
  printf '%s\n' "$@" | sort -g | awk '{ v[NR]=$0 } END { print v[int((NR+1)/2)] }'
}

for rate in $RATES; do
  if (( REPS > 1 )); then
    step "offering ${rate}/s for $DURATION, x${REPS} (median reported)"
  else
    step "offering ${rate}/s for $DURATION"
  fi

  # # REPETITION, because this measurement is BIMODAL on a busy host
  #
  # Measured on a 16-core laptop at a fixed 56,000/s: four runs of five came
  # back clean at ~56,000/s with p99 4-8ms, and the fifth collapsed to 557/s
  # with a 12-second tail. Same rate, same binary, same machine, 100x apart.
  #
  # A single-shot sweep therefore INVENTS cliffs. Walk the rates once and the
  # first rate to catch the bad draw looks like the saturation point, and the
  # next run puts it somewhere else entirely -- which is exactly the shape of
  # the contradictory results that made this capacity figure unreportable.
  #
  # Repeating and taking the median makes the number reproducible. It does not
  # make the outlier disappear: the spread is printed, and a rate whose
  # repetitions disagree wildly is visible rather than averaged away.
  rep_ratios=(); rep_p99s=(); rep_achieved=(); rep_p999s=()
  rep_refused=(); rep_failed=(); rep_suspect=0; rep_lag=""
  worst_ratio=""; best_ratio=""

  for (( rep = 1; rep <= REPS; rep++ )); do
    out="$WORK/run-$rate-$rep.txt"
    "$WORK/loadgen" -target "$target" -rate "$rate" -duration "$DURATION" >"$out" 2>"$WORK/run-$rate-$rep.err"
    code=$?

    a=$(kv achieved_rate_rps "$out")
    if [[ -z "$a" ]]; then
      bad "loadgen produced no summary at ${rate}/s rep ${rep} (exit $code):"
      cat "$WORK/run-$rate-$rep.err"; exit 1
    fi
    rep_achieved+=("$a")
    rep_ratios+=("$(kv achieved_over_offered "$out")")
    rep_p99s+=("$(kv latency_p99_ms "$out")")
    rep_p999s+=("$(kv latency_p999_ms "$out")")
    rep_refused+=("$(kv responses_refused "$out")")
    rep_failed+=("$(kv responses_failed "$out")")
    if [[ "$(kv generator_suspect "$out")" == "true" ]]; then
      rep_suspect=$((rep_suspect + 1))
      rep_lag=$(kv lag_share_of_tail "$out")
    fi
  done

  achieved=$(median "${rep_achieved[@]}")
  ratio=$(median "${rep_ratios[@]}")
  p99=$(median "${rep_p99s[@]}")
  p999=$(median "${rep_p999s[@]}")
  refused=$(median "${rep_refused[@]}")
  failed=$(median "${rep_failed[@]}")
  lag_share="$rep_lag"

  # A rate is spoiled only when a MAJORITY of its repetitions were spoiled.
  # One bad draw in five is the outlier this repetition exists to absorb;
  # three in five is the generator genuinely at its limit.
  suspect="false"
  if (( REPS > 1 )); then
    if (( rep_suspect * 2 > REPS )); then suspect="true"; fi
  elif (( rep_suspect > 0 )); then
    suspect="true"
  fi

  if (( REPS > 1 )); then
    worst_ratio=$(printf '%s\n' "${rep_ratios[@]}" | sort -g | head -1)
    best_ratio=$(printf '%s\n' "${rep_ratios[@]}" | sort -g | tail -1)
    say "median of ${REPS}: ratio $ratio (spread ${worst_ratio}..${best_ratio}), ${rep_suspect} spoiled rep(s)"
  fi

  note="ok"
  # # ATTRIBUTION: a spoiled row below a PROVEN generator ceiling is the service
  #
  # generator_suspect measures how much of the reported tail is the harness's
  # own send lag. It cannot distinguish "the generator is too slow" from "the
  # generator's sends are queueing behind a SATURATED SERVICE" -- both look
  # like lag. Dismissing every such row means a service that genuinely
  # saturates can never have a saturation point recorded.
  #
  # The discriminator is a control: run the SAME rate against a faster service.
  # If the generator drives it cleanly there, it is capable of that rate, and
  # lag at that rate against a slower service belongs to the service.
  #
  # GENERATOR_CEILING carries that finding in, and the evidence is required and
  # printed, so the claim is auditable rather than asserted.
  attributed=""
  if [[ "$suspect" == "true" && -n "$GENERATOR_CEILING" ]] \
     && awk -v r="$rate" -v c="$GENERATOR_CEILING" 'BEGIN { exit !(r <= c) }'; then
    suspect="false"
    attributed=" (lag attributed to the SERVICE: ${rate}/s is at or below the declared generator ceiling of ${GENERATOR_CEILING}/s)"
    say "attributing the lag at ${rate}/s to the service -- the generator is proven at this rate"
  fi
  if [[ "$suspect" == "true" ]]; then
    note="UNUSABLE — ${lag_share} of this tail is the generator's own send lag"
    suspect_rows=$((suspect_rows + 1))
    bad "generator_suspect at ${rate}/s: ${lag_share} of the reported p99 is this harness's own delay"
  else
    note="ok${attributed}"
    measured_rows=$((measured_rows + 1))
    # The highest rate the generator did NOT spoil. This is the only number in
    # the sweep that can honestly be called observed capacity, and the markdown
    # verdict below needs it to avoid claiming the service kept up at rates
    # nobody measured.
    highest_measured="$rate"
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
highest_measured="${highest_measured:-}"

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
  # The target is recorded WITH a warning when it is the near-empty one,
  # because a capacity figure read off /healthz is a figure about the network
  # stack rather than about this service.
  if [[ "$TARGET_PATH" == "/healthz" ]]; then
    printf -- '- **Target:** `%s` — a NEAR-EMPTY endpoint. The service is unlikely to be the bottleneck here; see TARGET_PATH\n' "$target"
  else
    printf -- '- **Target:** `%s` (TARGET_PATH)\n' "$target"
  fi
  printf -- '- **Per-rate duration:** %s\n' "$DURATION"
  printf -- '- **Repetitions per rate:** %s%s\n' "$REPS" "$( ((REPS>1)) && printf ' (median reported)' || printf ' — single shot; see REPS' )"
  if [[ -n "$GENERATOR_CEILING" ]]; then
    printf -- '- **Declared generator ceiling:** %s/s — %s\n' \
      "$GENERATOR_CEILING" "$GENERATOR_CEILING_EVIDENCE"
  fi
  # The allocation is recorded BESIDE the number, always. A capacity figure
  # without the machine it was measured on is a rumour.
  if [[ -n "$SVC_GOMAXPROCS" ]]; then
    printf -- '- **Service CPU allocation:** GOMAXPROCS=%s (the generator had the rest)\n\n' "$SVC_GOMAXPROCS"
  else
    printf -- '- **Service CPU allocation:** unconstrained — service and generator shared every core\n\n'
  fi

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
  # NOTE on the field NAME below, which is load-bearing.
#
  # verify-standard.sh's load-baseline row reads this file with
  # `load_field 'saturation[_ -]?point'` -- it greps for a key matching
  # "saturation point". This generator wrote "**Saturation:**", which does not
  # match, so a sweep that HAD determined a saturation point still failed the row
  # with "<no such field>" -- the same message a baseline with no number at all
  # produces.
#
  # That is the second time the generator and the probe have disagreed about a
  # field's spelling (see load_field's own comment about the bold/colon styles).
  # The key must stay "Saturation point".
  if [[ -n "$saturation" ]]; then
    printf -- '- **Saturation point:** %s/s — %s\n' "$saturation" "$saturation_reason"
  elif ((measured_rows == 0)); then
    printf -- '- **Saturation point: UNKNOWN.** EVERY row was spoiled by the generator; nothing\n'
    printf -- '  about the service was measured. Re-run on a quiet host.\n'
  elif ((suspect_rows > 0)); then
    # NOT-MEASURED IS NOT KEPT-UP -- and this file, not the terminal, is what
    # anyone reads a week later.
    #
    # The terminal verdict has distinguished these two cases since 2026-08-29;
    # this markdown branch did not, and printed "the service kept up at every
    # rate offered, up to 192000/s" directly above a table whose 192000 row
    # showed a collapse to 0.001 of offered load. The artifact contradicted
    # both the table it sat under and the terminal that produced it, and it
    # resolved the ambiguity in the service's favour -- which is the one
    # direction a capacity claim must never drift.
    printf -- '- **Saturation point: INDETERMINATE.** %d of the offered rates were spoiled by the\n' "$suspect_rows"
    printf -- '  generator competing with the service for the same CPUs. A spoiled row says\n'
    printf -- '  NOTHING about the service -- it is not evidence that the service kept up.\n'
    printf -- '- **Highest rate actually MEASURED: %s/s.** Everything above it is unknown.\n' "${highest_measured:-none}"
    printf -- '  Re-run from a host that is not also running the service before reading any\n'
    printf -- '  capacity figure out of this file.\n'
  else
    printf -- '- **Saturation point: NOT REACHED.** The service kept up at every rate offered, up to %s/s,\n' "$highest"
    printf -- '  and every row was usable.\n'
    printf -- '  The real saturation point is somewhere above that and this run did not find it.\n'
    printf -- '  Raise `RATES` and re-run; do not read the top row as a capacity figure.\n'
  fi
  # The key is "Margin", not "Capacity margin", and that is not a style choice.
  #
  # verify-standard.sh reads this with `load_field 'margin|headroom'`, whose
  # regex anchors the KEY: `\**(margin|headroom)\**[[:space:]]*:`. A key of
  # "Capacity margin" does not match, so the row reported "declares no
  # parseable margin: <no such field>" over a margin sitting right there.
  #
  # THIRD time the generator and the probe have disagreed about a field's
  # spelling in this file -- after the bold/colon styles and "Saturation" vs
  # "Saturation point". They are written in different repos and nothing tests
  # them together, which is what makes this class keep recurring.
  printf -- '- **Margin:** %s — %s\n' "$margin" "$margin_note"
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
