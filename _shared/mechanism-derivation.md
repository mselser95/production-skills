# Mechanism derivation — which machinery this service actually needs

Read with `dimensions.md`. That file says what every service must ANSWER; this
one says which MECHANISMS are warranted to answer it here. The two are not the
same thing, and conflating them is the failure this file exists to prevent.

## Why this exists

`prod-new` used to ship every mechanism unconditionally and record absence as a
per-dimension decline. That was fine when the list was short. It is not any
more: a team scaffolding a request/response CRUD service inherits an event log,
an inbox, an outbox, a delivery watermark, snapshots, compaction and a replay
corpus — and most of it is ceremony for that shape. Every write then pays
journal + replay for a history nobody reads, and the unused mechanisms rot,
because an outbox nobody exercises is an outbox nobody tests properly.

The deeper cost is pedagogical. **A scaffold that ships an event log to a CRUD
service teaches that event logs are the standard.** They are not. The standard
is that you know whether you need one, and can say why.

## The rule that resolves the tension

RULE BORN-COMPLETE says the scaffold ships the whole machine and absence is a
ratified decline. That rule stands, with one distinction it did not previously
draw:

> **The MECHANISM is derived. The DIMENSION is not.**

Declining the event log does not decline `bounded_boot`. Every service still
owes an answer to "does recovery time scale with total history" — a service
with no event log answers it differently ("boot loads nothing; state lives in
Postgres and is queried on demand"), and that answer is still recorded and
still probed. The dimension is the question; the mechanism is one possible
answer to it.

So: a mechanism derived NOT WARRANTED is **left out of the scaffold**, with the
deriving property recorded in `production.yaml`'s `out_of_scope`. It is not
shipped-but-unused, and it is not silently missing. The dimension it would have
served still gets its row, its answer, and its probe.

## Contract

- **Input:** what the human already gives at Phase 1 — the purpose line, what
  the service OWNS, and the declared capability classes. Plus the tier, which
  modifies thresholds and never the mechanism set.
- **Output:** per mechanism, one of `warranted` / `not warranted` /
  `needs one more question`, **each naming the property that decided it**.
- **Status:** every verdict is a PROPOSAL. See "The human overturns you".

**This is not a fifth question.** Phase 1 is four questions with proposals
pre-filled, and RULE FOUR-QUESTIONS forbids asking what you can derive. This
file is machinery for deriving MORE from the same four answers. The only
verdict that may reach the human is `needs one more question`, and it rides
along inside the existing batched message — never as a new round trip.

## Every verdict names its property

A verdict without the property that produced it is an opinion, and opinions are
not auditable six months later when someone asks why this repo has no outbox.

```
✗  outbox: not warranted
✓  outbox: not warranted — this service causes no effect outside its own
   store; every declared capability is source_of_truth or external_read,
   and neither writes anywhere a crash could lose.
```

The second form survives review, survives the author leaving, and — critically
— **fails visibly when it stops being true.** A new `external_effect`
capability contradicts that sentence on sight. "No outbox" contradicts nothing.

## The human overturns you

The preamble is firm that semantics belong to the human, and a derivation that
silently decided for them would violate it. So:

- present each verdict WITH its property, inside the Phase-1 batched message;
- an override is recorded in `out_of_scope` (or in the capability entry) with
  the human's reason, not yours;
- **frequent overrides are data about the derivation, not about the human.** If
  three services in a row overturn the same verdict, the property that produced
  it is wrong. Fix the property here; do not add a special case at the call
  site.

---

# The derivations

## 1. Event log (event sourcing)

**Property:** is the owned state a FOLD over an ordered stream of inputs, or
the result of arbitrary writes?

Durable state is NOT the test — a CRUD service has durable state and wants no
event log. Four questions decide it; two or more yes-es and the log earns its
cost:

- state is a function of an ORDERED STREAM, not of "whatever the last writer
  said";
- the history has value of its own — audit, replay, reconstruction — rather
  than only the latest value mattering;
- an external source ALREADY owns the ordering (an upstream feed with monotonic
  ids, a broker's partition offsets), so the service does not have to invent an
  order to have one;
- some declared obligation requires reproducing a PAST decision — an incident
  replay, a dispute, a regulator.

**Not warranted ⇒** no `internal/platform/eventlog`, no `Rebuild` at boot. The
`bounded_boot` dimension is still owed and is answered by whatever the state
actually lives in.

**Always, either way: the replay corpus.** `regressions/` is fixtures driven
through the real decode→core→serve path asserting invariants at every
transition. That is valuable whether or not the fixtures came from a durable
log. A repo that declines event sourcing still owes its corpus, and the probe
must not let one excuse the other.

## 2. Inbox / consumption dedup

**Property:** does this service consume from a source that can REDELIVER — and
if so, is a dedup key provided, or must one be invented?

Only reachable when a declared capability is `event_consumer` or `connection`.
A request/response service has no inbox: an HTTP retry is the caller's
idempotency problem, handled at the API boundary, and calling that an inbox
confuses two different guarantees.

The second half of the property decides the COST, and it is the half people
skip:

- **a provided monotonic sequence is O(1).** "Have I seen this?" collapses to
  `seq <= cursor`, one integer, exact, and it cannot drift. If the upstream
  gives you one, take it.
- **an invented key is usually an unbounded set.** A hash of contents, a UUID
  from the payload — now you keep a set of seen keys, and that set grows for
  the life of the process unless something prunes it. That pruning is a design
  problem, not a detail: it needs a bound and a story for what happens past it.

**Derived consequence:** if the key is invented, `bounded_storage` acquires a
new obligation the provided-sequence case never has.

## 3. Outbox

**Property:** does this service cause effects OUTSIDE itself that must not be
lost?

Warranted when any declared capability is `external_effect` or
`event_producer`. Not warranted when every capability is `source_of_truth`,
`external_read`, or `signer` reading only — nothing leaves, so there is nothing
a crash can lose in flight.

**The trap:** "we write to our own database" is not an external effect. The
outbox exists for the window between "we decided" and "the far side confirmed",
and a local transactional write has no such window.

**Derived consequence, and it is the sharpest one in this file.** The outbox's
DURABILITY STRATEGY depends on whether an event log exists:

- **outbox WITH an event log** ⇒ the effects are derivable, because the core is
  pure and deterministic. The outbox can be a PROJECTION of the log plus a
  delivery watermark: one durable write on the hot path, and boot re-derives
  what was never delivered. No atomicity window.
- **outbox WITHOUT an event log** ⇒ nothing can re-derive the intent, so the
  outbox record IS the only evidence it ever existed. It must be durable in its
  own right, and it must be written ATOMICALLY with the state change it
  accompanies — which in practice means both live in the same transactional
  store. Two files with two fsyncs and no transaction between them is not an
  outbox; it is the shape of one with the property removed.

Derive the strategy, not just the mechanism, and record which one applies.

## 4. Snapshots + compaction

**Property:** does the owned state grow with usage without a natural ceiling,
AND does recovery replay it?

Both halves are required. A tiny bounded state that replays in milliseconds
needs no snapshot. A large state that is never replayed (because it lives in a
database) needs no snapshot either — it needs a retention policy instead.

Effectively: warranted when the event log is warranted and the workload is not
naturally bounded. Not warranted whenever the event log is not warranted, since
there is nothing to snapshot.

**`bounded_boot` and `bounded_storage` are still owed either way.** A service
whose state lives in Postgres answers them with its query patterns and its
retention policy. It answers them; it just does not answer them with snapshots.

## 5. Reconciliation

**Property:** is there a PAIR of stores that can disagree — this service's
durable state and something outside it?

Warranted when a `source_of_truth` capability coexists with an
`external_effect`, or when two systems hold views of the same fact. Not
warranted for a single store with no external counterpart: there is nothing to
reconcile it against, and a reconciliation job comparing a thing to itself is
the emptiest kind of green.

Note the batch-job shape: no durable state of its own, but it reads A and
writes B, so "did B actually receive what A said" is a real reconciliation and
warranted despite the service owning almost nothing.

## 6. Partition key

**Property:** does the workload have a natural partition, or is it genuinely
one serial stream?

Always ASKED, never assumed absent — this is the scalability dimension's
declaration and the standing rule is that horizontal scale is required by
default. The verdict is the key itself (symbol, tenant, account, shard) or a
ratified decline explaining why the workload is genuinely single-writer.

**Watch for "single-writer so far".** State can be partitionable long before it
is partitioned, and the coupling that prevents it later is cheap to avoid now
and expensive to remove. If the state is per-key independent but a shared
monotonic cursor forces serialization, say that — it is the difference between
"cannot be partitioned" and "is not partitioned yet".

## 7. Durability trade

**Property:** what is the acceptable loss window on a crash?

This one is never "not warranted" — every service sits somewhere on it and the
only failure is not saying where. The verdict is one of a closed set:

- `fsync_per_event` — zero loss window, paid for in tail latency;
- `group_commit` — a bounded loss window, paid for in complexity;
- `no_durable_writes` — everything is reconstructible from elsewhere.

Derive the PROPOSAL from the purpose line (money and orders lean fsync; metrics
and derived views lean group commit), and let the human confirm. A hot path
that fsyncs under a mutex has chosen; it should say so rather than discover it
in a latency graph.

---

# Worked examples

Three services of genuinely different shape. If a derivation returns
`warranted` for everything in example B, it is not a derivation — it is a
preamble with extra steps.

## A. Market engine over an upstream order feed

*Owns: a derived order book per symbol, the feed cursor, the trade stream.
Classes: `event_consumer`, `external_effect`, `event_producer`,
`source_of_truth`.*

| mechanism | verdict | property |
|---|---|---|
| event log | **warranted** | state is a fold over an ordered stream; the upstream feed already owns the ordering via monotonic ids |
| inbox/dedup | **warranted, O(1)** | consumes a redelivering source AND the key is provided — `seq <= cursor`, no set to bound |
| outbox | **warranted, as projection** | submits orders upstream and publishes derived events; the event log exists, so effects are re-derivable and the watermark suffices |
| snapshots | **warranted** | books grow with usage and boot replays the log |
| reconciliation | **warranted** | its own book vs what the venue actually holds |
| partition key | **symbol** | books are independent per symbol; the shared cursor is the coupling to watch |
| durability trade | **fsync_per_event** | folded trades must not be lost; the tail cost is accepted deliberately |

Nearly everything warranted — which is what makes this the *unrepresentative*
case, and why the template built around it needs the other two.

## B. CRUD service over Postgres, no external effects

*Owns: the rows its API writes. Classes: `source_of_truth`.*

| mechanism | verdict | property |
|---|---|---|
| event log | **not warranted** | state is arbitrary writes, not a fold; only the latest value matters; no external source owns an ordering; no obligation to reproduce a past decision |
| inbox/dedup | **not warranted** | nothing redelivers to it — it is request/response; caller retries are API idempotency, a different guarantee at a different boundary |
| outbox | **not warranted** | causes no effect outside its own store; the one write is local and transactional, so there is no in-flight window |
| snapshots | **not warranted** | no log to snapshot — but `bounded_storage` is still owed, and here it is answered by the retention policy on the tables, not by compaction |
| reconciliation | **not warranted** | one store, no external counterpart to disagree with it |
| partition key | **tenant id** | rows are naturally per-tenant |
| durability trade | **fsync_per_event** | delegated to Postgres' own commit |

**Six of seven fall away.** What does NOT fall away: `bounded_boot` (does
startup scale with table size?), `bounded_storage` (does any table grow
forever, and what prunes it?), `egress_backpressure` (still owed the moment it
calls anything), the replay corpus, invariant counters, the observability
contract, and every gate. The dimensions survive intact; only the machinery
shrinks.

## C. Periodic batch job: read system A, write system B

*Owns: a checkpoint. Classes: `external_read` (A), `external_effect` (B).*

| mechanism | verdict | property |
|---|---|---|
| event log | **not warranted** | owns no state to fold — the checkpoint is a position, not an aggregate |
| inbox/dedup | **needs one more question** | re-reading a window re-sees rows, so dedup is needed — but is there a natural key IN A's rows, or must one be invented? The answer decides whether `bounded_storage` gains an obligation |
| outbox | **warranted, and durable in its own right** | writes to B must not be lost, and there is NO event log to re-derive them from — so the outbox record is the only evidence the intent existed, and must be atomic with the checkpoint advance |
| snapshots | **not warranted** | nothing to snapshot; the checkpoint is already the compaction |
| reconciliation | **warranted** | did B actually receive what A said? the whole job is a claim about two systems agreeing |
| partition key | **the batch window / shard** | windows share no state, so two runners on disjoint windows need no coordination |
| durability trade | **group_commit** | a re-run recovers a lost batch; per-row fsync buys nothing |

This is the profile the template handles WORST: an outbox with no event log
behind it, where the reconstruct-from-log strategy is unavailable and the
atomicity requirement is therefore strictest. It is also the shape most likely
to be scaffolded by someone who reads the template and assumes the event log is
mandatory.

---

# Using this in the skills

**`prod-new`** runs the derivation between Phase 1 and Phase 2: the four
answers arrive, the derivation produces the mechanism set, and Phase 2 scaffolds
that set rather than the full one. Verdicts and their properties go into
`production.yaml` — warranted ones as capability entries, not-warranted ones as
`out_of_scope` with the deriving property as the reason.

**`prod-bootstrap`** runs it in Phase 1b, against the INVENTORY rather than a
purpose line: the code already shows which mechanisms exist. The derivation
then produces two lists worth more than either alone — mechanisms present but
not warranted (ceremony to consider removing, always a proposal and never an
automatic task), and mechanisms warranted but absent (real gaps, which become
gap-report rows and plan tasks).

**Both:** a derivation that ran and produced verdicts is itself evidence.
Record it, so the next reader sees the reasoning rather than re-deriving it or,
worse, assuming the absent mechanism was an oversight.
