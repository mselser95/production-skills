package main

// These tests exist because a load generator is the one tool in a repo whose
// defects are invisible in its own output: a closed loop, a clock started at
// the wrong instant, or a tail sampled over successes only all produce a
// summary that looks exactly like a correct one, only better. Nothing about
// "loadgen ran and printed a p99" distinguishes the four vacuous forms named
// in loadgen.go's header from the real thing.
//
// So each test below pins ONE of those forms, and each is written so the
// obvious wrong implementation makes it RED rather than merely less precise.
// The mutations they are meant to catch are named in their comments.

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// flat returns n identical durations — a synthetic sorted sample.
func flat(n int, d time.Duration) []time.Duration {
	out := make([]time.Duration, n)
	for i := range out {
		out[i] = d
	}
	return out
}

// oneOutlier returns n durations of `base` with a single `spike` at the end:
// the isolated-hiccup shape, which must not condemn a run.
func oneOutlier(n int, base, spike time.Duration) []time.Duration {
	out := flat(n, base)
	out[n-1] = spike
	return out
}

// TestMeasure_TimesFromTheScheduledArrivalNotTheSend pins vacuous form 2.
//
// The scheduled instant is placed 500ms in the past, so an arrival whose
// request itself takes no measurable time still owes 500ms of waiting. A
// measure() that started its clock at the send (`sent := time.Now(); do();
// time.Since(sent)`) reports approximately zero here and the test goes red —
// which is exactly the substitution that, in production use, hides a stall
// behind a flat p99.
func TestMeasure_TimesFromTheScheduledArrivalNotTheSend(t *testing.T) {
	const backdate = 500 * time.Millisecond

	got := measure(time.Now().Add(-backdate), func() outcome { return served })

	if got.latency < backdate {
		t.Fatalf("latency %v is below the %v this arrival had already been waiting: "+
			"measure() is timing from the send, not from the scheduled arrival", got.latency, backdate)
	}
	// Upper bound so a constant-valued implementation cannot satisfy the
	// assertion above by returning something enormous.
	if got.latency > backdate+5*time.Second {
		t.Fatalf("latency %v is implausibly far above the %v backdate", got.latency, backdate)
	}
	if got.out != served {
		t.Fatalf("outcome = %v, want served (the sender's verdict must be carried through unchanged)", got.out)
	}
}

// TestRun_KeepsOfferingArrivalsWhileEveryResponseIsStalled pins vacuous form 1,
// and it is the load-bearing test of this file.
//
// Every response takes 100ms while arrivals are due every 10ms. An open loop
// issues all 20 arrivals inside the 200ms schedule and finishes about 100ms
// later; a closed loop — one that waits for each response before scheduling
// the next — takes 20 x 100ms = 2s and cannot issue more than 10 arrivals per
// second no matter what -rate says. The 1s bound sits far from both, so the
// test is decisive without being a stopwatch race: it cannot fail from
// ordinary scheduler jitter, and it cannot pass on a closed loop.
func TestRun_KeepsOfferingArrivalsWhileEveryResponseIsStalled(t *testing.T) {
	const (
		serviceTime = 100 * time.Millisecond
		duration    = 200 * time.Millisecond
		rate        = 100.0
	)

	var issued atomic.Int64
	stalled := func() outcome {
		issued.Add(1)
		time.Sleep(serviceTime)
		return served
	}

	start := time.Now()
	r := run(config{target: "stub", rate: rate, duration: duration}, stalled)
	elapsed := time.Since(start)

	if want := int(rate * duration.Seconds()); r.scheduled != want {
		t.Fatalf("scheduled = %d, want %d", r.scheduled, want)
	}
	if got := int(issued.Load()); got != r.scheduled {
		t.Fatalf("only %d of %d scheduled arrivals were issued: the loop stopped offering load",
			got, r.scheduled)
	}
	if elapsed > time.Second {
		t.Fatalf("run took %v for %d arrivals at %v each; an open loop overlaps them and finishes in "+
			"about %v. This is the closed-loop shape: arrivals waiting on responses",
			elapsed, r.scheduled, serviceTime, duration+serviceTime)
	}
	if r.answered() != r.scheduled {
		t.Fatalf("answered = %d, want %d (every issued arrival must produce a sample)", r.answered(), r.scheduled)
	}
	// Under an open loop each arrival waits only its own service time, so the
	// latencies cluster at serviceTime. Under a closed loop they would grow
	// without bound as the backlog builds.
	if p99 := percentile(r.latencies, 99); p99 > 10*serviceTime {
		t.Fatalf("p99 = %v against a service time of %v: arrivals are queueing behind each other", p99, serviceTime)
	}
}

// TestArrivalAt_ComputesAnAbsoluteScheduleThatDoesNotDrift pins the absolute
// schedule. The mutation this catches is `next = previous + interval`
// accumulated in a loop: with a rate whose interval is not representable
// exactly, accumulation drifts, and the drift is silent — the generator offers
// less than the requested rate while reporting the requested rate.
func TestArrivalAt_ComputesAnAbsoluteScheduleThatDoesNotDrift(t *testing.T) {
	start := time.Unix(0, 0)
	// 3 per second: an interval of 333.333...ms, deliberately not
	// representable exactly, which is the condition under which an
	// accumulating scheduler goes wrong. A variable, not a constant: the
	// truncation below is the point of the test, and Go refuses to write it as
	// a constant conversion precisely because the value is not exact.
	rate := 3.0

	// Expectations derived INDEPENDENTLY of the implementation's formula
	// (arrival 3k lands exactly on second k), not recomputed from it — a
	// table whose `want` restates the code under test asserts nothing.
	for _, tc := range []struct {
		i      int
		offset time.Duration
	}{
		{0, 0},
		{3, time.Second},
		{30, 10 * time.Second},
		{3000, 1000 * time.Second},
	} {
		if got := arrivalAt(start, tc.i, rate); !got.Equal(start.Add(tc.offset)) {
			t.Errorf("arrivalAt(start, %d, %v) = %v after start, want %v", tc.i, rate, got.Sub(start), tc.offset)
		}
	}

	// The contrast made concrete, so this test cannot be satisfied by an
	// accumulator that happens to agree: stepping `next = previous + interval`
	// 3000 times — the mutation this test exists to reject — lands a
	// measurable distance short of the thousandth second, because the interval
	// it steps by was truncated to whole nanoseconds once and that error is
	// then paid 3000 times.
	interval := time.Duration(float64(time.Second) / rate)
	accumulated := start
	for range 3000 {
		accumulated = accumulated.Add(interval)
	}
	if accumulated.Equal(arrivalAt(start, 3000, rate)) {
		t.Fatalf("an accumulating schedule agrees with the absolute one at rate %v, so this test would pass "+
			"on either implementation and proves nothing; pick a rate whose interval is not exact", rate)
	}
}

// TestSummarize_KeepsEveryAnsweredArrivalInTheLatencySet pins vacuous form 3.
//
// The refused arrival here is the slowest one in the run — the nine-second 503
// of the header comment, scaled down. A summarize() that filtered the latency
// set to successes would report a maximum of 10ms and lose the tail entirely.
func TestSummarize_KeepsEveryAnsweredArrivalInTheLatencySet(t *testing.T) {
	samples := []sample{
		{latency: 5 * time.Millisecond, out: served},
		{latency: 10 * time.Millisecond, out: served},
		{latency: 900 * time.Millisecond, out: refused},
		{latency: 5 * time.Second, out: failed},
	}

	r := summarize(config{rate: 10}, samples, 4, generatorStats{}, time.Second)

	if r.served != 2 || r.refused != 1 || r.failed != 1 {
		t.Fatalf("counts served=%d refused=%d failed=%d, want 2/1/1", r.served, r.refused, r.failed)
	}
	if len(r.latencies) != 4 {
		t.Fatalf("latency set has %d entries, want 4: a refused or failed arrival is still a wait a client paid",
			len(r.latencies))
	}
	if got := percentile(r.latencies, 100); got != 5*time.Second {
		t.Fatalf("max latency = %v, want 5s (the failed arrival is the tail, and dropping it is the defect)", got)
	}
	// Sorted ascending, which every percentile below depends on.
	for i := 1; i < len(r.latencies); i++ {
		if r.latencies[i-1] > r.latencies[i] {
			t.Fatalf("latency set is not sorted ascending: %v", r.latencies)
		}
	}
}

// TestAchievedRate_ExcludesRefusedResponses pins vacuous form 4: a service
// that answers every request with 503 has an achieved throughput of ZERO, not
// of the full offered rate. Counting refusals here would make a load shedder
// indistinguishable from a service with capacity to spare.
func TestAchievedRate_ExcludesRefusedResponses(t *testing.T) {
	allRefused := report{cfg: config{rate: 100}, refused: 100, wall: time.Second}
	if got := allRefused.achievedRate(); got != 0 {
		t.Fatalf("achievedRate = %.2f for a run where every response was a refusal, want 0", got)
	}
	if !allRefused.saturated() {
		t.Fatal("saturated = false for a run that served nothing at all")
	}

	half := report{cfg: config{rate: 100}, served: 50, refused: 50, wall: time.Second}
	if got := half.achievedRate(); got != 50 {
		t.Fatalf("achievedRate = %.2f, want 50 (only the served half is work done)", got)
	}
	if !half.saturated() {
		t.Fatal("saturated = false at half the offered rate")
	}

	clean := report{cfg: config{rate: 100}, served: 100, wall: time.Second}
	if clean.saturated() {
		t.Fatal("saturated = true for a run that served the full offered rate: the flag would be permanently on, which is the same as absent")
	}
}

// TestGeneratorSuspect_FiresWhenTheHarnessOwnsTheTailNotOnOneHiccup guards the
// harness's honesty about ITSELF, in BOTH directions — which is the point, and
// is why the "one isolated hiccup" case is asserted first.
//
// The flag's job is to say when the reported tail belongs to this process
// rather than to the service. Two earlier rules are recorded in
// generatorSuspect's own comment as the wrong ways to ask that question; the
// cases below are each of them, kept as tests so neither can come back:
//
//   - the isolated hiccup, which a maximum-based rule condemned and which must
//     pass, because a flag that is on for every run is the same as no flag;
//   - the genuinely contaminated run, which must fail even though the same
//     lag would be routine at a higher rate;
//   - the drop, which is unconditional whatever the tail looks like.
func TestGeneratorSuspect_FiresWhenTheHarnessOwnsTheTailNotOnOneHiccup(t *testing.T) {
	// One 200ms wake-up in a thousand arrivals against a 20ms tail. The
	// absolute schedule self-corrects, so exactly one sample carries the
	// delay and the p99 of the lags is still zero: nothing about the reported
	// tail is this process's.
	hiccup := report{cfg: config{rate: 100}, scheduled: 1000, served: 1000, wall: 10 * time.Second,
		latencies: flat(1000, 20*time.Millisecond),
		gen:       generatorStats{late: 1, lags: oneOutlier(1000, 0, 200*time.Millisecond)}}
	if hiccup.generatorSuspect() {
		t.Fatalf("generatorSuspect = true for ONE late arrival in 1000 (lag share %.4f): a flag that fires on "+
			"every real run is the same as no flag", hiccup.lagShareOfTail())
	}

	// A 15ms send lag under a 20ms tail: three quarters of what this run
	// reports as the service's latency is this process waiting to send.
	contaminated := report{cfg: config{rate: 100}, scheduled: 1000, served: 1000, wall: 10 * time.Second,
		latencies: flat(1000, 20*time.Millisecond),
		gen:       generatorStats{late: 500, lags: flat(1000, 15*time.Millisecond)}}
	if !contaminated.generatorSuspect() {
		t.Fatalf("generatorSuspect = false with a p99 send lag of 15ms under a p99 latency of 20ms "+
			"(share %.4f, ceiling %.2f): the numbers describe the generator, not the service",
			contaminated.lagShareOfTail(), maxLagShareOfTail)
	}

	// The SAME absolute lag under a tail large enough to swamp it. This is the
	// case the interval-based rule got wrong, and it must pass: 15ms of
	// scheduling under a 2s tail is not a contaminated measurement.
	swamped := report{cfg: config{rate: 100}, scheduled: 1000, served: 1000, wall: 10 * time.Second,
		latencies: flat(1000, 2*time.Second),
		gen:       generatorStats{late: 500, lags: flat(1000, 15*time.Millisecond)}}
	if swamped.generatorSuspect() {
		t.Fatalf("generatorSuspect = true for a 15ms send lag under a 2s tail (share %.4f): the rule is reading "+
			"the lag in absolute terms instead of against the tail it could spoil", swamped.lagShareOfTail())
	}

	// A drop is unconditional: offered load that never left this process.
	dropping := report{cfg: config{rate: 100}, scheduled: 1000, served: 999, wall: 10 * time.Second,
		latencies: flat(999, 20*time.Millisecond),
		gen:       generatorStats{dropped: 1, lags: flat(1000, 0)}}
	if !dropping.generatorSuspect() {
		t.Fatal("generatorSuspect = false for a run in which the generator dropped an arrival it never issued")
	}

	// A run in which nothing was answered has NO tail to contaminate, so this
	// flag must stay quiet and let verdict() report the real problem. Without
	// this, a service that was simply not running comes back as "your load
	// generator is broken", which sends the reader to the wrong file.
	nothing := report{cfg: config{rate: 100}, scheduled: 1000, failed: 1000,
		gen: generatorStats{lags: flat(1000, 3*time.Second)}}
	if nothing.generatorSuspect() {
		t.Fatalf("generatorSuspect = true for a run with no answered arrival at all (share %.4f): there is no "+
			"tail for the harness to have spoiled, and verdict() already says what went wrong",
			nothing.lagShareOfTail())
	}
	if code, _ := nothing.verdict(); code == 0 {
		t.Fatal("verdict = 0 for the same run: something must report it, and it is not the suspect flag")
	}
}

// TestRun_ReportsItsOwnLatenessAtARateItCannotSustain drives the harness past
// what any process can schedule — one arrival every 100 nanoseconds — and
// asserts it SAYS SO.
//
// This is the case the whole generator-honesty apparatus exists for, and
// without a test that forces it the lag-recording branch runs only when the
// operating system happens to be late, which made this package's own coverage
// swing by two points between runs. A flag that is only ever exercised by luck
// is a flag nobody has checked.
//
// Note what is NOT asserted: any latency number. At this rate the latencies
// ARE this process's own scheduling, which is exactly why the run is marked
// unusable rather than interpreted.
func TestRun_ReportsItsOwnLatenessAtARateItCannotSustain(t *testing.T) {
	r := run(config{target: "stub", rate: 10_000_000, duration: 200 * time.Microsecond},
		func() outcome { return served })

	if r.scheduled != 2000 {
		t.Fatalf("scheduled = %d, want 2000", r.scheduled)
	}
	if r.gen.late == 0 {
		t.Fatal("late = 0 at one arrival every 100ns: no process schedules a goroutine that fast, " +
			"so the loop was behind and did not notice")
	}
	// EVERY arrival's lag is sampled, not only the late ones. A percentile
	// taken over just the late subset is a percentile of the worst tail of the
	// data, which would read as catastrophic on a run with three bad wake-ups.
	if len(r.gen.lags) != r.scheduled {
		t.Fatalf("recorded %d send lags for %d scheduled arrivals: the percentile behind the verdict "+
			"would be taken over a biased subset", len(r.gen.lags), r.scheduled)
	}
	if percentile(r.gen.lags, 100) == 0 {
		t.Fatal("every send lag is zero while arrivals were recorded late: lateness is counted but never measured")
	}
	if !r.generatorSuspect() {
		t.Fatalf("generatorSuspect = false with a p99 send lag of %v under a p99 latency of %v (share %.4f): "+
			"recording this as a baseline would attribute the harness's delay to the service",
			percentile(r.gen.lags, 99), percentile(r.latencies, 99), r.lagShareOfTail())
	}
}

// TestRender_WarnsLoudlyOnASuspectRun asserts the warning text itself, because
// the warning is the only thing standing between an unusable run and a
// recorded baseline. A `generator_suspect=true` line buried among twenty other
// key=value lines is easy to paste past; the instruction not to record it is
// not.
func TestRender_WarnsLoudlyOnASuspectRun(t *testing.T) {
	suspect := summarize(config{target: "http://stub/healthz", rate: 100, duration: time.Second},
		[]sample{{latency: time.Millisecond, out: served}}, 100,
		generatorStats{late: 50, dropped: 3, lags: flat(100, time.Second)}, time.Second)

	var buf strings.Builder
	suspect.render(&buf)
	out := buf.String()

	for _, want := range []string{"WARNING", "Do not record this run as a baseline", "generator_suspect=true"} {
		if !strings.Contains(out, want) {
			t.Errorf("a suspect run's summary does not contain %q\n---\n%s", want, out)
		}
	}

	// And the converse, or the warning is unconditional and says nothing.
	clean := summarize(config{target: "http://stub/healthz", rate: 100, duration: time.Second},
		[]sample{{latency: time.Millisecond, out: served}}, 100,
		generatorStats{lags: flat(100, 0)}, time.Second)
	var cleanBuf strings.Builder
	clean.render(&cleanBuf)
	if strings.Contains(cleanBuf.String(), "WARNING") {
		t.Errorf("a clean run's summary carries the WARNING banner\n---\n%s", cleanBuf.String())
	}
}

// TestVerdict_ExitsNonZeroWhenNothingWasServed pins the real-denominator exit,
// and specifically the CORRECTION recorded in verdict()'s comment.
//
// The `deadPort` case is the whole reason this test exists: the first version
// of the guard asked whether anything ANSWERED, and a connection to a port
// with nothing on it answers — with ECONNREFUSED, counted as a failed arrival.
// So the check meant to catch "you pointed this at nothing" exited 0 in
// precisely that case. That is the vacuous form, and it is caught here rather
// than described.
func TestVerdict_ExitsNonZeroWhenNothingWasServed(t *testing.T) {
	deadPort := report{cfg: config{target: "http://127.0.0.1:1/healthz", rate: 100}, scheduled: 100, failed: 100}
	if code, why := deadPort.verdict(); code == 0 {
		t.Fatal("exit 0 for a run where every arrival failed at the transport: nothing was listening and nothing was measured")
	} else if !strings.Contains(why, "listening") {
		t.Errorf("the message for a dead target does not name the likely cause: %q", why)
	}

	allRefused := report{cfg: config{target: "http://svc/healthz", rate: 100}, scheduled: 100, refused: 100}
	if code, _ := allRefused.verdict(); code == 0 {
		t.Fatal("exit 0 for a run where every response was a refusal: a refusal rate is not a capacity measurement")
	}

	allDropped := report{cfg: config{target: "http://svc/healthz", rate: 100}, scheduled: 100,
		gen: generatorStats{dropped: 100}}
	if code, why := allDropped.verdict(); code == 0 {
		t.Fatal("exit 0 for a run whose every arrival was dropped by this process's own ceiling")
	} else if !strings.Contains(why, "ceiling") {
		t.Errorf("the message for a self-inflicted drop does not name the ceiling: %q", why)
	}

	// And the other direction, without which every one of the assertions above
	// is satisfied by `return 1` unconditionally.
	good := report{cfg: config{target: "http://svc/healthz", rate: 100}, scheduled: 100, served: 100, wall: time.Second}
	if code, why := good.verdict(); code != 0 {
		t.Fatalf("exit %d (%q) for a run that served every arrival", code, why)
	}
}

// TestRun_DividesThroughputByTheFullOfferedWindow pins the denominator.
//
// Arrival i is due at i/rate, so the last of N arrivals is due one interval
// BEFORE the offered duration elapses. A run that keeps up therefore finishes
// just inside its own window, and dividing served responses by that elapsed
// time reports an achieved rate ABOVE the offered one — which reads as a
// system exceeding the load it was given, and is really a denominator that is
// one arrival interval too small. Load was offered for `duration`; `duration`
// is the floor of the window it is measured over.
func TestRun_DividesThroughputByTheFullOfferedWindow(t *testing.T) {
	const (
		duration = 200 * time.Millisecond
		rate     = 100.0
	)

	r := run(config{target: "stub", rate: rate, duration: duration}, func() outcome { return served })

	if r.served != r.scheduled {
		t.Fatalf("served = %d of %d scheduled against an instantaneous stub", r.served, r.scheduled)
	}
	if r.wall < duration {
		t.Fatalf("wall = %v, below the %v of load that was offered", r.wall, duration)
	}
	if got := r.achievedRate(); got > rate {
		t.Fatalf("achievedRate = %.2f against an offered %.2f: nothing can be served faster than it was offered, "+
			"so the window it was divided by is too short", got, rate)
	}
	if r.saturated() {
		t.Fatalf("saturated = true (achieved %.2f of %.2f offered) against a stub that answers instantly",
			r.achievedRate(), rate)
	}

	// EVERY arrival's send lag is sampled, including the on-time ones, and this
	// is asserted HERE — at a rate the harness comfortably sustains — for a
	// reason worth stating, because the obvious place for it does not work.
	//
	// The same assertion in TestRun_ReportsItsOwnLatenessAtARateItCannotSustain
	// is VACUOUS: at one arrival every 100ns essentially every arrival is late,
	// so `len(lags) == scheduled` holds even under an implementation that
	// records a lag only when the arrival was late. (Verified by mutation: that
	// substitution left the impossible-rate test green.) Only a run whose
	// arrivals are mostly ON TIME can tell the two apart.
	//
	// It matters because generatorSuspect reads a PERCENTILE of these lags. Over
	// the late subset alone, p99 is a percentile of the worst tail of the data,
	// and a run with three bad wake-ups in ten thousand would read as
	// catastrophically contaminated.
	if len(r.gen.lags) != r.scheduled {
		t.Fatalf("recorded %d send lags for %d scheduled arrivals at a rate this harness sustains: "+
			"on-time arrivals are being left out of the sample the suspect verdict is a percentile of",
			len(r.gen.lags), r.scheduled)
	}
}

// TestPercentile_UsesNearestRankAndClampsTheEnds fixes the percentile
// convention. p999 over a handful of samples must return the real maximum: the
// alternative implementations return zero (rank 0) or panic (rank == len).
func TestPercentile_UsesNearestRankAndClampsTheEnds(t *testing.T) {
	sorted := make([]time.Duration, 100)
	for i := range sorted {
		sorted[i] = time.Duration(i+1) * time.Millisecond // 1ms .. 100ms
	}

	for _, tc := range []struct {
		p    float64
		want time.Duration
	}{
		{0, 1 * time.Millisecond},   // clamped up to rank 1
		{50, 50 * time.Millisecond}, // nearest-rank, not interpolated
		{90, 90 * time.Millisecond},
		{99, 99 * time.Millisecond},
		{99.9, 100 * time.Millisecond}, // clamped down to the last rank
		{100, 100 * time.Millisecond},
	} {
		if got := percentile(sorted, tc.p); got != tc.want {
			t.Errorf("percentile(p%v) = %v, want %v", tc.p, got, tc.want)
		}
	}

	if got := percentile(nil, 99); got != 0 {
		t.Errorf("percentile over an empty sample = %v, want 0", got)
	}
}

// TestHistogram_SeparatesTheModesOfABimodalRun is why the histogram is
// rendered at all. Two clusters three decades apart — the fingerprint of a
// queue that sometimes fills — must appear as two populated buckets with empty
// ones between them, which p50 and p99 alone cannot show.
func TestHistogram_SeparatesTheModesOfABimodalRun(t *testing.T) {
	var sorted []time.Duration
	for range 90 {
		sorted = append(sorted, 1*time.Millisecond)
	}
	for range 10 {
		sorted = append(sorted, 900*time.Millisecond)
	}

	counts := histogram(sorted)
	if len(counts) != len(histogramBounds)+1 {
		t.Fatalf("histogram returned %d buckets, want %d", len(counts), len(histogramBounds)+1)
	}
	total := 0
	populated := 0
	for _, c := range counts {
		total += c
		if c > 0 {
			populated++
		}
	}
	if total != len(sorted) {
		t.Fatalf("histogram counted %d of %d samples: a sample fell outside every bucket", total, len(sorted))
	}
	if populated != 2 {
		t.Fatalf("%d populated buckets, want 2 — the two modes must not be merged into one", populated)
	}
}

// TestRender_EmitsTheStableKeysCiEnvGrepsFor pins the output contract. The
// Makefile's `load` target and any CI job reading a baseline grep these keys;
// renaming one silently breaks every reader, and nothing else in the repo
// would notice.
func TestRender_EmitsTheStableKeysCiEnvGrepsFor(t *testing.T) {
	r := summarize(config{target: "http://stub/healthz", rate: 100, duration: time.Second, timeout: 5 * time.Second},
		[]sample{
			{latency: 2 * time.Millisecond, out: served},
			{latency: 3 * time.Millisecond, out: served},
		}, 2, generatorStats{lags: flat(2, time.Millisecond)}, time.Second)

	var buf strings.Builder
	r.render(&buf)
	out := buf.String()

	for _, key := range []string{
		"target=", "duration=", "arrivals_scheduled=", "arrivals_answered=",
		"responses_served=", "responses_refused=", "responses_failed=",
		"generator_dropped=", "generator_late_arrivals=", "offered_rate_rps=", "achieved_rate_rps=",
		"achieved_over_offered=", "latency_p50_ms=", "latency_p90_ms=",
		"latency_p99_ms=", "latency_p999_ms=", "latency_max_ms=",
		"send_lag_p99_ms=", "max_send_lag_ms=", "lag_share_of_tail=", "saturated=", "generator_suspect=", "hist_",
	} {
		if !strings.Contains(out, key) {
			t.Errorf("rendered summary is missing the key %q\n---\n%s", key, out)
		}
	}
}

// TestRun_AgainstARealServerServesTheFullOfferedRate is the end-to-end smoke:
// a real listener, a real net/http client, real sockets. It is the only test
// here that would catch httpSender misreading a status code or leaking
// connections until the pool starves.
//
// The rate is low and the assertions are one-sided (nothing asserts a latency
// UPPER bound) so a loaded CI runner cannot make it flake — an under-performing
// host is a slow pass here, never a red.
func TestRun_AgainstARealServerServesTheFullOfferedRate(t *testing.T) {
	var hits atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		_, _ = fmt.Fprintln(w, `{"status":"ok"}`)
	}))
	defer srv.Close()

	cfg := config{target: srv.URL + "/healthz", rate: 200, duration: 250 * time.Millisecond, timeout: 5 * time.Second, maxInflight: 1000}
	r := run(cfg, httpSender(cfg))

	if r.scheduled != 50 {
		t.Fatalf("scheduled = %d, want 50", r.scheduled)
	}
	if r.served != r.scheduled {
		t.Fatalf("served = %d of %d scheduled (refused=%d failed=%d): the stub answers 200 to everything",
			r.served, r.scheduled, r.refused, r.failed)
	}
	if got := int(hits.Load()); got != r.scheduled {
		t.Fatalf("the server saw %d requests, the harness scheduled %d", got, r.scheduled)
	}
	if r.gen.dropped != 0 {
		t.Fatalf("dropped = %d at 200 rps against a loopback stub", r.gen.dropped)
	}
}

// TestRun_AgainstARefusingServerCountsRefusalsAndServesNothing is the other
// half: httpSender must classify a non-2xx as `refused`, not as `served` and
// not as `failed`. Treating a 503 as a success is how an overloaded service
// gets a clean load baseline.
func TestRun_AgainstARefusingServerCountsRefusalsAndServesNothing(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "shedding", http.StatusServiceUnavailable)
	}))
	defer srv.Close()

	// maxInflight 0 = unbounded, the other side of the safety valve, so
	// httpSender's pooling fallback is exercised by a real socket too.
	cfg := config{target: srv.URL + "/readyz", rate: 100, duration: 200 * time.Millisecond, timeout: 5 * time.Second}
	r := run(cfg, httpSender(cfg))

	if r.served != 0 {
		t.Fatalf("served = %d against a server that answers 503 to everything", r.served)
	}
	if r.refused != r.scheduled {
		t.Fatalf("refused = %d of %d scheduled (failed=%d): a 503 is an answer, so it is refused, never failed",
			r.refused, r.scheduled, r.failed)
	}
	if r.achievedRate() != 0 {
		t.Fatalf("achievedRate = %.2f while nothing was served", r.achievedRate())
	}
	if !r.saturated() {
		t.Fatal("saturated = false for a run in which every single response was a refusal")
	}
}

// TestRun_DropsRatherThanDelaysArrivalsAtTheInflightCeiling guards the safety
// valve's SHAPE. The tempting implementation blocks the scheduling loop until a
// slot frees, which is the closed loop reintroduced through the back door: the
// generator would then offer load at the system's pace and report the
// requested rate. The drop must be recorded and the schedule must not slip.
func TestRun_DropsRatherThanDelaysArrivalsAtTheInflightCeiling(t *testing.T) {
	const (
		serviceTime = 150 * time.Millisecond
		duration    = 200 * time.Millisecond
		rate        = 100.0
	)

	stalled := func() outcome {
		time.Sleep(serviceTime)
		return served
	}

	start := time.Now()
	// A ceiling of 1 against 20 arrivals that each take longer than the whole
	// schedule: all but the first must be dropped.
	r := run(config{target: "stub", rate: rate, duration: duration, maxInflight: 1}, stalled)
	elapsed := time.Since(start)

	if r.gen.dropped == 0 {
		t.Fatal("dropped = 0 with a ceiling of 1 in-flight and 20 arrivals due inside 200ms")
	}
	if r.gen.dropped+r.answered() != r.scheduled {
		t.Fatalf("dropped(%d) + answered(%d) != scheduled(%d): an arrival went unaccounted for",
			r.gen.dropped, r.answered(), r.scheduled)
	}
	if elapsed > duration+serviceTime+500*time.Millisecond {
		t.Fatalf("run took %v: the ceiling DELAYED arrivals instead of dropping them, which is the closed loop again", elapsed)
	}
	if !r.generatorSuspect() {
		t.Fatal("generatorSuspect = false for a run whose own ceiling swallowed most of the offered load")
	}
}
