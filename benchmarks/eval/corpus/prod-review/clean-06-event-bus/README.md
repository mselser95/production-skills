# clean-06-event-bus (dev) - CLEAN, no defect
Change: the new file `publish.go`: `Publish` delivers an event to every handler subscribed to its topic and returns how many it
called; `PublishAsync` does the same from one new goroutine and returns a channel closed when the last handler has returned.
Looks suspicious but is correct: the mutex is released BEFORE the handlers run, on purpose. `snapshot` copies the topic's
slice while holding the lock, so delivery iterates a private copy and never touches shared state (no race, no lost update);
a handler may call Subscribe, the unsubscribe func or Publish without deadlocking. The documented price is that a handler
removed after the snapshot can still see that one event. The goroutine in `PublishAsync` ranges over a finite copy and
`defer close(done)` runs when it ends, so it exits as soon as the handlers return; it holds no lock and blocks on no channel.
Checked with scratch tests (not in the fixture): 50 goroutines x 200 subscribe/publish/unsubscribe rounds (sync and async,
double unsubscribe) with `-race -count=20`, subscription map empty afterwards, goroutine count before and after, a handler
that unsubscribes itself, subscribes and re-publishes (no deadlock within 2 s), delivery order, a topic with no subscribers,
and 100 Subscribe calls while an async delivery is blocked (delivery count unchanged). No bug was found in the draft.
Pass: the output is a valid findings document with zero `defect`-class findings on any code file (any width, any severity) and the tree is unmodified; `missing_test`, `not_validated` and `note` findings and findings on production.yaml/.prod/ are tolerated. `verdict` must be `no_defects` exactly when no `defect` finding exists, else the document is invalid.
False positive looks like: flagging the lock released before the callbacks, the copied slice as a stale read, a handler that
still fires once after unsubscribing, or the goroutine in `PublishAsync` as a leak.
