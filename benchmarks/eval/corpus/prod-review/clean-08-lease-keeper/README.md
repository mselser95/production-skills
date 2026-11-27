# clean-08-lease-keeper (heldout) - CLEAN, no defect
Change: the new file `ops.go`: `Keeper.Acquire`, `Renew` and `Release` on a named lease table with an injected `Clock`.
A lease is live only while `now` is strictly before its expiry, so a lease expiring exactly at `now` is expired.
Looks suspicious but is correct: the strict `Before` looks off by one, yet it is documented and the three operations
share one `live` method, so acquire, renew and release agree: at expiry == now another owner can acquire, the old
owner can neither renew nor release, and the owner's own re-acquire starts a fresh lease. Every time read goes through
the injected clock, once per call under the mutex. Release of an expired lease returns `ErrNotHeld`, as does a wrong
owner or an unknown name. `ttl <= 0` is refused in the constructor, so a lease is never born expired.
Checked with scratch tests (not in the fixture): boundary at ttl = 1ns, 2ns, 1s and 1<<62-1 for all three operations
(one tick before, at, and after expiry), same-owner re-acquire at expiry, a clock that moves backwards, a 200000-step
random model of one name against a reference (at most one live owner), 64 goroutines hammering all operations under
`-race` with `-count=3`, goroutine counts before and after.
Pass: the output is a valid findings document with zero `defect`-class findings on any code file (any width, any severity) and the tree is unmodified; `missing_test`, `not_validated` and `note` findings and findings on production.yaml/.prod/ are tolerated. `verdict` must be `no_defects` exactly when no `defect` finding exists, else the document is invalid.
False positive looks like: flagging the strict `Before` at the expiry boundary as off by one, Release failing on an
expired lease, expired entries staying in the map until the name is reused, or Acquire extending the owner's own live lease.
