// Command loadgen is an OPEN-LOOP load generator: arrivals are scheduled off
// the wall clock at a fixed rate, and the next arrival is NEVER made to wait
// for the previous response.
//
// WHY THE SHAPE OF THE LOOP IS THE WHOLE TOOL. The obvious way to write a load
// generator is a worker pool where each worker sends a request, waits for the
// reply, and sends the next one. That loop is CLOSED, and it has a property
// nobody intends: when the system under test slows down, the generator slows
// down with it. Offered load becomes a function of the system's own pace, so
// the system can never be pushed past the point it is already at. The measured
// throughput is then not the system's capacity, it is the system's current
// speed restated; and the latency percentiles omit exactly the requests that
// would have been slow, because those requests were never issued. Gil Tene
// named this coordinated omission ("How NOT to Measure Latency", 2015): the
// measurement and the thing measured coordinate, and the tail vanishes.
//
// The numbers a closed loop produces are not merely imprecise, they are
// confidently wrong in the safe direction — a server that stalls for a full
// second reports a p99 of a few milliseconds, because during that second one
// request was outstanding instead of the thousand that should have arrived.
// This tool exists so that a service born from this template cannot acquire a
// load baseline of that kind.
//
// THE FOUR VACUOUS FORMS this file is written against. Each is a way to ship a
// load harness that runs, prints percentiles, and measures nothing:
//
//  1. NEXT-REQUEST-AFTER-RESPONSE. The closed loop above. Ruled out
//     structurally: run() computes every arrival instant from `start` before
//     any response exists (arrivalAt), sleeps until that instant, and hands the
//     request to its own goroutine. No branch anywhere consults a completion.
//
//  2. LATENCY FROM THE SEND TIME. Timing from the moment the request left this
//     process discards the queueing that happened before it left. Under a
//     stall — a full connection pool, a generator that woke late, a service
//     that stopped reading — the backlog of arrivals that are DUE but not yet
//     sent is precisely the damage, and starting the clock at the send erases
//     it. measure() times from the SCHEDULED instant, which is the instant a
//     real client would have started waiting.
//
//  3. PERCENTILES OVER SUCCESSES ONLY. A request that returns 503 after nine
//     seconds is nine seconds of a user's life; dropping it from the sample
//     because it was not a 2xx makes an overloaded system look healthy at the
//     tail. Every arrival that got an ANSWER of any kind — served, refused, or
//     failed after a timeout — contributes its latency.
//
//  4. COUNTING REFUSALS AS THROUGHPUT. A service that sheds load answers very
//     fast and does no work. Counting those answers as achieved rate makes
//     shedding indistinguishable from capacity, which inverts the one signal
//     this tool exists to produce. achievedRate() counts SERVED (2xx) only,
//     and the refused/failed counts are reported beside it so a run that held
//     its rate by refusing everything reads as exactly that.
//
// WHAT THE OUTPUT IS FOR. The gap between offered rate and achieved rate IS the
// saturation signal: while the system keeps up they are equal, and the rate at
// which they part company is the capacity number that belongs in
// benchmarks/load/baseline.md. A single run does not find that point — a sweep
// of runs at rising rates does, which is what `make load` drives.
//
// Standard library only, deliberately: this binary is built by every repo
// generated from the template, and a load tool is not a reason to put a
// third-party dependency into a service's go.mod.
package main

import (
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// outcome classifies what came back for one arrival. The three-way split is
// load-bearing rather than cosmetic: under overload a system moves work
// between these buckets without changing its response rate at all, and a
// harness that only knows "ok / not ok" cannot see it happen. `refused`
// climbing while `served` falls at a constant answer rate is a load shedder
// doing its job; `failed` climbing instead is the same overload with no
// shedder, and the two call for opposite remedies.
type outcome int

const (
	// served: a 2xx. The service accepted the request and did the work.
	served outcome = iota
	// refused: a response arrived and it was not a 2xx — 429, 503, a 5xx from
	// a dependency. Work was NOT done, so this never counts toward achieved
	// throughput, but the request did get an answer, so its latency counts.
	refused
	// failed: no usable response at all — the per-request timeout expired, the
	// connection was refused, the peer reset. Its latency is the time until
	// that verdict, which is a real wait a real client would have paid.
	failed
)

// sender issues ONE request and reports what came back. It is injected rather
// than hard-wired to net/http so this file's timing rules can be tested
// without a socket: loadgen_test.go substitutes a stub that stalls on command,
// which is the only way to prove that a stall actually shows up in the numbers
// rather than being absorbed by the harness.
type sender func() outcome

// sample is one arrival's result. latency is measured from the arrival's
// SCHEDULED instant — see measure().
type sample struct {
	latency time.Duration
	out     outcome
}

type config struct {
	target      string
	rate        float64
	duration    time.Duration
	timeout     time.Duration
	maxInflight int
}

// arrivalAt returns the ABSOLUTE instant arrival i is due, computed from the
// run's start rather than accumulated from the previous arrival.
//
// Absolute, not incremental, because incremental scheduling (`next = last +
// interval`, or worse `next = now + interval`) accumulates every scheduling
// delay permanently: one late wake-up shifts the entire remaining run, the
// generator quietly offers less than the requested rate, and the report says
// it offered the full rate. With an absolute schedule a late wake-up is
// visible in the send lag for that arrival alone and the schedule self-corrects
// on the next one.
func arrivalAt(start time.Time, i int, rate float64) time.Time {
	return start.Add(time.Duration(float64(i) / rate * float64(time.Second)))
}

// measure issues one arrival and times it from `scheduled` — the instant the
// request was DUE — rather than from the instant it was actually sent.
//
// This is vacuous form 2 above, and it is one line, which is why it is worth
// stating loudly: swapping `scheduled` for a `time.Now()` taken just before
// `do()` leaves a harness that still compiles, still runs, still prints a
// plausible histogram, and reports a flat p99 through a stall it cannot see.
// TestMeasure_TimesFromTheScheduledArrivalNotTheSend is the guard.
func measure(scheduled time.Time, do sender) sample {
	out := do()
	return sample{latency: time.Since(scheduled), out: out}
}

// generatorStats is what the scheduling loop observed about ITSELF. It is
// carried separately from the response counts and reported separately, because
// mixing the two is how a harness comes to blame the service for its own
// delays.
type generatorStats struct {
	// dropped is arrivals the GENERATOR never issued because maxInflight was
	// already reached. This is the harness admitting it was the bottleneck. It
	// is never folded into `failed`: a request the service never saw says
	// nothing about the service.
	dropped int
	// late is arrivals the loop got to more than one full arrival interval
	// after they were due: a schedule-fidelity DIAGNOSTIC, reported and never
	// read by the verdict. It answers "how often did this process miss its own
	// deadline", which is a fair question and a poor gate -- the yardstick
	// shrinks with the rate, so at 4000/s it degenerates into "did a timer miss
	// by 250us", which every host does routinely. generatorSuspect reads the
	// lags below against the tail they could spoil instead.
	late int
	// lags is EVERY arrival's send lag: the gap between when it was due and
	// when the scheduling loop actually got to it, floored at zero. Sorted
	// ascending by summarize, and kept in full rather than summarised to a
	// maximum, because the verdict below needs a percentile of it and a
	// maximum cannot be compared with one.
	lags []time.Duration
}

// report is everything one run measured. It carries the counts and the raw
// latency set; percentiles are derived at render time.
type report struct {
	cfg config
	// scheduled is how many arrivals the schedule called for — the DENOMINATOR.
	// Reported because every other count is only meaningful against it: a run
	// that answered 40 requests is a triumph or a disaster depending on whether
	// 40 or 40,000 were due.
	scheduled int
	gen       generatorStats
	served    int
	refused   int
	failed    int
	latencies []time.Duration // sorted ascending, one per ANSWERED arrival
	// wall is the window the achieved rate is computed over: the offered
	// duration, or the elapsed time to the last completion when responses were
	// still outstanding after the schedule ran out. See run().
	wall time.Duration
}

// answered is every arrival that got a verdict of any kind. It is the sample
// size behind every percentile below (vacuous form 3).
func (r report) answered() int { return r.served + r.refused + r.failed }

// achievedRate is SERVED responses per second of wall time. Refusals are
// excluded on purpose (vacuous form 4) — a shed request is answered, not done.
func (r report) achievedRate() float64 {
	if r.wall <= 0 {
		return 0
	}
	return float64(r.served) / r.wall.Seconds()
}

// saturated reports whether this run found the system's limit. Any of three
// things means yes, and they are genuinely different failures: the service did
// not keep up (achieved below offered), it answered without serving (refused),
// or it did not answer at all (failed).
//
// The 0.99 floor is slack for measurement noise only — scheduling jitter over
// a short run moves the achieved rate by a fraction of a percent. It is not a
// tolerance for real shortfall: at 1% the run is already over the line.
func (r report) saturated() bool {
	return r.refused > 0 || r.failed > 0 || r.achievedRate() < r.cfg.rate*0.99
}

// maxLagShareOfTail is the fraction of the reported tail that may be this
// process's own delay before the run stops being a measurement of the service.
const maxLagShareOfTail = 0.25

// generatorSuspect reports whether THIS PROCESS, rather than the service under
// test, is the thing the numbers describe. A run that trips this is not a
// measurement of the service and must not be recorded as one: re-run it at a
// lower rate, or from a host that is not also running the service.
//
// THE RULE COMPARES LIKE WITH LIKE: p99 of the generator's own send lag against
// p99 of the latency it is reporting. If a quarter of the tail is delay this
// process caused, the tail is not the service's.
//
// It took two wrong rules to get here, and both are worth recording because
// both looked reasonable:
//
//   - The MAXIMUM send lag over one arrival interval. Fired on every run of any
//     length — one 4.4ms wake-up in 1000 arrivals at a 2ms interval, on an idle
//     machine. A flag that is always on is the same as no flag.
//
//   - More than 1% of arrivals late by more than one arrival INTERVAL. Better,
//     and still wrong, because the yardstick shrinks with the rate: at 4000/s
//     the interval is 250µs, so the rule degenerates into "did any timer miss
//     by a quarter of a millisecond", which every host does routinely and which
//     says nothing about whether the reported numbers are contaminated. A 300µs
//     lag on a request whose latency is 28ms is noise; the rule called it a
//     spoiled run. Measured against the scaffold's own service on an idle host:
//     1.1% late at 200/s, 6.1% at 1000/s, 2.8% at 4000/s — every rate condemned,
//     no rate actually contaminated.
//
// The share-of-tail rule has neither problem: it is scale-free, it compares two
// numbers of the same kind, and it says in one sentence what it is protecting.
//
// Dropped arrivals remain unconditional. An arrival the generator never issued
// is offered load that never existed, and no fraction of that is acceptable in
// a number recorded as capacity.
func (r report) generatorSuspect() bool {
	if r.gen.dropped > 0 {
		return true
	}
	tail := percentile(r.latencies, 99)
	if tail <= 0 {
		// Nothing was answered, so there is no tail to contaminate. The run has
		// other problems (verdict() names them); this flag is not one of them.
		return false
	}
	return float64(percentile(r.gen.lags, 99)) > maxLagShareOfTail*float64(tail)
}

// lagShareOfTail is the ratio the verdict above reads, rendered so a reader can
// see how close a run came to the line rather than only which side it fell on.
func (r report) lagShareOfTail() float64 {
	tail := percentile(r.latencies, 99)
	if tail <= 0 {
		return 0
	}
	return float64(percentile(r.gen.lags, 99)) / float64(tail)
}

// run drives the open loop. Every arrival instant is computed up front from
// `start`; nothing in this function reads a completion before deciding when to
// issue the next request. That is the structural form of vacuous form 1.
func run(cfg config, do sender) report {
	total := int(cfg.rate * cfg.duration.Seconds())

	var (
		mu       sync.Mutex
		samples  = make([]sample, 0, total)
		inflight atomic.Int64
		wg       sync.WaitGroup
		gen      generatorStats
	)
	interval := time.Duration(float64(time.Second) / cfg.rate)

	start := time.Now()
	for i := range total {
		due := arrivalAt(start, i, cfg.rate)

		// A plain sleep to the absolute due instant, and that is a decision
		// with a measurement behind it rather than the obvious default.
		//
		// A sleep-plus-busy-spin scheduler (sleep to `due - 250µs`, then spin)
		// was written and REMOVED, because the numbers did not support it. On
		// an idle host at 2000 arrivals/s over 5s, plain sleeping was late for
		// 90 / 128 / 234 arrivals of 10000 across three runs; the spinning
		// version, same host, same load, was late for 78 / 115 / 158. The
		// distributions overlap, both straddle the one-percent line this tool
		// uses to condemn a run, and the spin costs up to a core. What DOES
		// move the number is contention: on a host busy with a build, plain
		// sleeping was late for 5.2% of arrivals at 500/s, and the spin
		// recovered none of it, because time.Sleep was overshooting by 5-15ms
		// and a 250µs spin window cannot catch an overshoot larger than itself.
		//
		// So the schedule is as accurate as the host allows and no mechanism
		// here changes that. What matters is that the harness SAYS when the
		// host did not allow it, which is what the lag accounting below and
		// generatorSuspect are for. Adding the spin would have bought a slower,
		// more complicated generator and the same verdicts.
		if wait := time.Until(due); wait > 0 {
			time.Sleep(wait)
		}
		// Read the lag AFTER the sleep and before dispatch: this is how late
		// this loop actually is, which is the only part of the delay that
		// belongs to the generator. Written only here, on the single
		// scheduling goroutine, so it needs no lock.
		lag := time.Since(due)
		if lag < 0 {
			lag = 0
		}
		gen.lags = append(gen.lags, lag)
		if lag > interval {
			gen.late++
		}

		// maxInflight is a safety valve on THIS process's memory and file
		// descriptors, not a concurrency limit on the load. Reaching it is
		// recorded as a generator drop and reported, never as a slow request
		// and never by delaying the arrival: delaying it would silently
		// reintroduce the closed loop this whole file exists to avoid.
		if cfg.maxInflight > 0 && inflight.Load() >= int64(cfg.maxInflight) {
			gen.dropped++
			continue
		}

		inflight.Add(1)
		wg.Add(1)
		go func(due time.Time) {
			defer wg.Done()
			defer inflight.Add(-1)
			s := measure(due, do)
			mu.Lock()
			samples = append(samples, s)
			mu.Unlock()
		}(due)
	}
	wg.Wait()

	// THE WINDOW THROUGHPUT IS DIVIDED BY, and it is not simply the elapsed
	// time. The schedule places arrival i at i/rate, so the last of N arrivals
	// is due at (N-1)/rate — one interval SHORT of the offered duration. A run
	// that keeps up therefore finishes fractionally before its own window
	// closes, and dividing by that shorter elapsed time reports an achieved
	// rate ABOVE the offered one: the first real run of this tool printed
	// achieved_over_offered=1.0008, which is not a system exceeding its offered
	// load, it is a denominator that was 0.08% too small. Load was offered for
	// `duration`, so `duration` is the floor of the window it is measured over.
	//
	// The max() is what keeps this from being a fudge in the other direction:
	// when the system stalls and responses are still outstanding after the
	// schedule runs out, elapsed exceeds duration and the larger number wins —
	// which is precisely the saturation signal this tool exists to produce.
	wall := max(cfg.duration, time.Since(start))

	return summarize(cfg, samples, total, gen, wall)
}

// summarize folds the raw samples into a report. Split out of run() so the
// counting and sorting rules are testable without spending wall-clock time.
func summarize(cfg config, samples []sample, scheduled int, gen generatorStats, wall time.Duration) report {
	r := report{cfg: cfg, scheduled: scheduled, gen: gen, wall: wall}
	r.latencies = make([]time.Duration, 0, len(samples))
	for _, s := range samples {
		switch s.out {
		case served:
			r.served++
		case refused:
			r.refused++
		case failed:
			r.failed++
		}
		// EVERY answered arrival, whatever its verdict — vacuous form 3.
		r.latencies = append(r.latencies, s.latency)
	}
	sort.Slice(r.latencies, func(i, j int) bool { return r.latencies[i] < r.latencies[j] })
	sort.Slice(r.gen.lags, func(i, j int) bool { return r.gen.lags[i] < r.gen.lags[j] })
	return r
}

// percentile returns the nearest-rank p-th percentile of an ascending slice.
//
// Nearest-rank rather than interpolated, because interpolation invents a
// latency no request experienced, and at p99.9 over a few thousand samples the
// invented value can sit between two very different real ones. The rank is
// clamped into range so p999 over a short run returns the real maximum instead
// of panicking or silently reporting zero.
func percentile(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	rank := int(math.Ceil(p / 100 * float64(len(sorted))))
	if rank < 1 {
		rank = 1
	}
	if rank > len(sorted) {
		rank = len(sorted)
	}
	return sorted[rank-1]
}

// histogramBounds are the upper edges, in milliseconds, of the rendered
// buckets; the final bucket is everything above the last edge.
//
// Roughly log-spaced because a linear histogram over a latency distribution is
// one tall bar and a lot of empty ones. The point of rendering it at all,
// given the percentiles are printed right above, is SHAPE: a bimodal
// distribution — one mode at the fast path and a second three decades out — is
// the fingerprint of a queue that sometimes fills, and p50/p99 alone show it
// as a single number moving.
var histogramBounds = []float64{0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000}

// histogram counts an ascending latency slice into histogramBounds.
func histogram(sorted []time.Duration) []int {
	counts := make([]int, len(histogramBounds)+1)
	for _, d := range sorted {
		ms := float64(d) / float64(time.Millisecond)
		idx := len(histogramBounds)
		for i, edge := range histogramBounds {
			if ms < edge {
				idx = i
				break
			}
		}
		counts[idx]++
	}
	return counts
}

// render writes the run's summary. The format is deliberately dull and
// line-oriented: one `key=value` per line, keys stable across versions, so
// `make load` and CI can grep a number out without a parser and a diff of two
// runs is readable. The histogram block that follows is prefixed `hist_` on
// every line for the same reason.
func (r report) render(w io.Writer) {
	ms := func(d time.Duration) float64 { return float64(d) / float64(time.Millisecond) }

	_, _ = fmt.Fprintf(w, "target=%s\n", r.cfg.target)
	_, _ = fmt.Fprintf(w, "duration=%s\n", r.cfg.duration)
	_, _ = fmt.Fprintf(w, "request_timeout=%s\n", r.cfg.timeout)
	_, _ = fmt.Fprintf(w, "arrivals_scheduled=%d\n", r.scheduled)
	_, _ = fmt.Fprintf(w, "arrivals_answered=%d\n", r.answered())
	_, _ = fmt.Fprintf(w, "responses_served=%d\n", r.served)
	_, _ = fmt.Fprintf(w, "responses_refused=%d\n", r.refused)
	_, _ = fmt.Fprintf(w, "responses_failed=%d\n", r.failed)
	_, _ = fmt.Fprintf(w, "generator_dropped=%d\n", r.gen.dropped)
	_, _ = fmt.Fprintf(w, "generator_late_arrivals=%d\n", r.gen.late)
	_, _ = fmt.Fprintf(w, "wall_seconds=%.3f\n", r.wall.Seconds())
	_, _ = fmt.Fprintf(w, "offered_rate_rps=%.2f\n", r.cfg.rate)
	_, _ = fmt.Fprintf(w, "achieved_rate_rps=%.2f\n", r.achievedRate())
	// The ratio is printed rather than left to the reader because it is THE
	// number: 1.00 means the system kept up, and the first rate at which it
	// falls below 1.00 is the saturation point recorded in the baseline.
	ratio := 0.0
	if r.cfg.rate > 0 {
		ratio = r.achievedRate() / r.cfg.rate
	}
	_, _ = fmt.Fprintf(w, "achieved_over_offered=%.4f\n", ratio)
	_, _ = fmt.Fprintf(w, "latency_p50_ms=%.3f\n", ms(percentile(r.latencies, 50)))
	_, _ = fmt.Fprintf(w, "latency_p90_ms=%.3f\n", ms(percentile(r.latencies, 90)))
	_, _ = fmt.Fprintf(w, "latency_p99_ms=%.3f\n", ms(percentile(r.latencies, 99)))
	_, _ = fmt.Fprintf(w, "latency_p999_ms=%.3f\n", ms(percentile(r.latencies, 99.9)))
	_, _ = fmt.Fprintf(w, "latency_max_ms=%.3f\n", ms(percentile(r.latencies, 100)))
	_, _ = fmt.Fprintf(w, "send_lag_p99_ms=%.3f\n", ms(percentile(r.gen.lags, 99)))
	_, _ = fmt.Fprintf(w, "max_send_lag_ms=%.3f\n", ms(percentile(r.gen.lags, 100)))
	_, _ = fmt.Fprintf(w, "lag_share_of_tail=%.4f\n", r.lagShareOfTail())
	_, _ = fmt.Fprintf(w, "saturated=%t\n", r.saturated())
	_, _ = fmt.Fprintf(w, "generator_suspect=%t\n", r.generatorSuspect())

	counts := histogram(r.latencies)
	widest := 0
	for _, c := range counts {
		if c > widest {
			widest = c
		}
	}
	for i, c := range counts {
		label := fmt.Sprintf("lt_%gms", histogramBounds[min(i, len(histogramBounds)-1)])
		if i == len(histogramBounds) {
			label = fmt.Sprintf("ge_%gms", histogramBounds[len(histogramBounds)-1])
		}
		bar := ""
		if widest > 0 {
			bar = fmt.Sprintf(" %s", barOf(c, widest, 40))
		}
		_, _ = fmt.Fprintf(w, "hist_%s=%d%s\n", label, c, bar)
	}

	if r.generatorSuspect() {
		_, _ = fmt.Fprintf(w, "# WARNING: %.1f%% of the reported p99 is delay THIS PROCESS caused "+
			"(ceiling %.0f%%), or it dropped arrivals it never issued (%d).\n",
			100*r.lagShareOfTail(), 100*maxLagShareOfTail, r.gen.dropped)
		_, _ = fmt.Fprintf(w, "# Part of the latency reported here was produced by THIS PROCESS, and part of\n")
		_, _ = fmt.Fprintf(w, "# the offered load never left it. Do not record this run as a baseline:\n")
		_, _ = fmt.Fprintf(w, "# re-run at a lower rate, or from a host that can sustain this one.\n")
	}
}

// verdict returns this run's process exit code and, when it is non-zero, the
// line explaining why. A run that produced NO evidence about the service's
// capacity must not exit 0 looking like a clean result — the same
// real-denominator discipline scripts/kill-durability.sh applies to its intent
// count.
//
// "No evidence" is `served == 0`, and getting that predicate right took a
// correction worth recording, because the first version of it was VACUOUS.
// It read `answered() == 0`, meaning "nothing came back at all" — and over
// HTTP nothing ever satisfies that. A connection to a dead port does not
// vanish, it returns ECONNREFUSED, which this harness correctly counts as a
// `failed` arrival, which counts as answered. So the guard against "you
// pointed this at a port with no service on it" was structurally incapable of
// firing in exactly that case. Pointing loadgen at an unused port exited 0.
//
// The honest predicate is about SERVED responses: a run in which nothing was
// served measured no capacity, whether because nobody was listening or because
// the service refused every request. Both are non-zero exits and the message
// distinguishes them, because the operator's next action is different.
func (r report) verdict() (int, string) {
	if r.served > 0 {
		return 0, ""
	}
	switch {
	case r.failed == r.answered() && r.failed > 0:
		return 1, fmt.Sprintf("loadgen: none of %d arrivals to %s got a response (all %d failed at the transport). "+
			"Is a service listening there?", r.scheduled, r.cfg.target, r.failed)
	case r.answered() == 0:
		return 1, fmt.Sprintf("loadgen: ZERO of %d scheduled arrivals were issued — %d were dropped by this "+
			"process's own in-flight ceiling. Nothing was measured.", r.scheduled, r.gen.dropped)
	default:
		return 1, fmt.Sprintf("loadgen: %s served NONE of %d arrivals (%d refused, %d failed). "+
			"No capacity was measured, only a refusal rate.", r.cfg.target, r.scheduled, r.refused, r.failed)
	}
}

// barOf renders a proportional bar, never wider than width.
func barOf(count, widest, width int) string {
	if widest <= 0 || count <= 0 {
		return ""
	}
	n := count * width / widest
	if n < 1 {
		n = 1
	}
	b := make([]byte, n)
	for i := range b {
		b[i] = '#'
	}
	return string(b)
}

// httpSender is the real sender: one GET per arrival against target.
//
// The client is built once and shared, with idle connections pooled generously.
// net/http's DefaultMaxIdleConnsPerHost is 2, which means that above two
// concurrent arrivals nearly every request pays a fresh TCP handshake — and
// that handshake is charged to the SERVICE in this tool's latency numbers,
// because the clock started at the scheduled arrival. Pooling here is not a
// performance nicety; it is the difference between measuring the service and
// measuring the loopback interface.
func httpSender(cfg config) sender {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	pool := cfg.maxInflight
	if pool <= 0 {
		pool = 1000
	}
	transport.MaxIdleConns = pool
	transport.MaxIdleConnsPerHost = pool
	client := &http.Client{Transport: transport, Timeout: cfg.timeout}

	return func() outcome {
		resp, err := client.Get(cfg.target)
		if err != nil {
			return failed
		}
		// Drain and close, or the connection is not returned to the pool and
		// the pooling above buys nothing.
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return served
		}
		return refused
	}
}

func main() {
	cfg := config{}
	// The default target is this template's own health endpoint, on the port
	// internal/platform/config defaults HEALTH_PORT to. It is the only HTTP
	// surface the scaffold exposes, so it is the only thing a generated repo
	// can load-test before it has written a real handler — and a harness that
	// shipped pointing at a URL that does not exist would be verified by
	// nobody. A real service repoints this at the endpoint whose budget it
	// declared in production.yaml.
	flag.StringVar(&cfg.target, "target", "http://127.0.0.1:8081/healthz", "URL to request once per arrival")
	flag.Float64Var(&cfg.rate, "rate", 50, "offered arrival rate, requests per second (fixed; NOT adjusted to the system's pace)")
	flag.DurationVar(&cfg.duration, "duration", 10*time.Second, "how long to keep offering arrivals")
	flag.DurationVar(&cfg.timeout, "timeout", 5*time.Second, "per-request timeout; an arrival that exceeds it is counted failed with its full latency")
	flag.IntVar(&cfg.maxInflight, "max-inflight", 20000, "safety valve on concurrent in-flight requests in THIS process; arrivals above it are dropped and reported, never delayed (0 = unbounded)")
	flag.Parse()

	if cfg.rate <= 0 || cfg.duration <= 0 {
		_, _ = fmt.Fprintln(os.Stderr, "loadgen: -rate and -duration must both be positive")
		os.Exit(2)
	}

	r := run(cfg, httpSender(cfg))
	r.render(os.Stdout)

	if code, why := r.verdict(); code != 0 {
		_, _ = fmt.Fprintln(os.Stderr, why)
		os.Exit(code)
	}
}
