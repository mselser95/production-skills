# clean-03-token-bucket (dev) - CLEAN, no defect
Change: `refill` credits tokens to the nanosecond, carrying the unearned fraction of a token in `rem` (billionths);
`New` precomputes `fill` and bounds capacity and rate so the integer math cannot overflow.
Looks suspicious but is correct: `int64(elapsed)*perSec` is only computed when `elapsed < fill`, which keeps it
below `capacity*1e9`; `New` refuses capacity at or above MaxInt64/1e9 and rate above 1e9, so the sum with `rem`
fits an int64; `fill` is rounded up so a bucket idle that long is exactly full; a clock that goes backwards earns
nothing and is not rewound; the lock covers the whole read-refill-spend sequence.
Checked with scratch tests (not in the fixture): 3000 random schedules against an exact big-integer reference
(never over-mints, never above capacity), exact grant counts at rates from 1 to 1e9 per second, maximum
capacity and rate with durations up to MaxInt64, a backwards clock, and 32 goroutines under `-race`.
Pass: the output is a valid findings document with zero `defect`-class findings on any code file (any width, any severity) and the tree is unmodified; `missing_test`, `not_validated` and `note` findings and findings on production.yaml/.prod/ are tolerated. `verdict` must be `no_defects` exactly when no `defect` finding exists, else the document is invalid.
False positive looks like: flagging the integer division as truncation, the `rem` carry as drift, the capacity
bound as arbitrary, or the missing handling of a backwards clock.
