//! Use-case tests over in-test fakes of the ports (std lives here, not in
//! the `no_std` crate).
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use svc_app::{
    Clock, Counter, EventStore, Gauge, Ledger, LedgerError, Receipt, Snapshot, SpanId, SpanName,
    StoreError, Telemetry,
};
use svc_domain::{DomainError, Outcome, State};

struct FixedClock;
impl Clock for FixedClock {
    fn unix_seconds(&self) -> u64 {
        1_000
    }
}

#[derive(Default)]
struct Seen {
    counters: Mutex<Vec<(Counter, Vec<String>)>>,
    gauges: Mutex<Vec<(Gauge, i64)>>,
    spans: Mutex<Vec<(SpanName, Vec<String>, bool)>>,
}
impl Telemetry for Seen {
    fn counter_inc(&self, c: Counter, values: &[&str]) {
        let v = values.iter().map(|s| (*s).to_owned()).collect();
        self.counters.lock().unwrap().push((c, v));
    }
    fn gauge_set(&self, g: Gauge, value: i64, _v: &[&str]) {
        self.gauges.lock().unwrap().push((g, value));
    }
    fn span_start(&self, s: SpanName, values: &[&str]) -> SpanId {
        let mut spans = self.spans.lock().unwrap();
        spans.push((s, values.iter().map(|x| (*x).to_owned()).collect(), false));
        SpanId(u64::try_from(spans.len()).unwrap())
    }
    fn span_end(&self, id: SpanId, ok: bool) {
        let i = usize::try_from(id.0 - 1).unwrap();
        self.spans.lock().unwrap()[i].2 = ok;
    }
}

struct FakeStore {
    state: Mutex<State>,
    fail: bool,
}
impl EventStore for FakeStore {
    fn update(
        &self,
        change: &mut dyn FnMut(&mut State) -> Result<Outcome, LedgerError>,
    ) -> Result<(Outcome, Snapshot), LedgerError> {
        if self.fail {
            return Err(StoreError("disk full".into()).into());
        }
        let mut g = self.state.lock().unwrap();
        let outcome = change(&mut g)?;
        Ok((
            outcome,
            Snapshot {
                balance: g.balance(),
                version: g.version(),
            },
        ))
    }
    fn read(&self) -> Result<Snapshot, StoreError> {
        let g = self.state.lock().unwrap();
        Ok(Snapshot {
            balance: g.balance(),
            version: g.version(),
        })
    }
}

fn ledger(state: State, fail: bool) -> (Ledger, Arc<Seen>) {
    let seen = Arc::new(Seen::default());
    let l = Ledger::new(
        Arc::new(FakeStore {
            state: Mutex::new(state),
            fail,
        }),
        seen.clone(),
        Arc::new(FixedClock),
    );
    (l, seen)
}

#[test]
fn deposit_applies_and_closes_its_span_ok() {
    let (l, seen) = ledger(State::new(), false);
    let r = l.deposit("a", 10).unwrap();
    assert_eq!(
        r,
        Receipt {
            outcome: Outcome::Applied,
            snapshot: Snapshot {
                balance: 10,
                version: 1
            }
        }
    );
    assert_eq!(
        *seen.spans.lock().unwrap(),
        vec![(SpanName::Deposit, vec!["deposit".to_owned()], true)]
    );
    assert_eq!(
        *seen.counters.lock().unwrap(),
        vec![(
            Counter::Events,
            vec!["deposit".to_owned(), "applied".to_owned()]
        )]
    );
}

#[test]
fn a_refused_command_closes_its_span_as_error_and_counts_rejected() {
    let (l, seen) = ledger(State::new(), false);
    assert_eq!(
        l.withdraw("a", 1),
        Err(LedgerError::Domain(DomainError::InsufficientFunds {
            balance: 0,
            requested: 1
        }))
    );
    assert_eq!(
        *seen.spans.lock().unwrap(),
        vec![(SpanName::Withdraw, vec!["withdraw".to_owned()], false)]
    );
    assert_eq!(
        seen.counters.lock().unwrap()[0].1,
        vec!["withdraw".to_owned(), "rejected".to_owned()]
    );
}

#[test]
fn a_replay_is_idempotent_and_a_changed_replay_is_a_conflict() {
    let (l, _) = ledger(State::new(), false);
    l.deposit("a", 10).unwrap();
    assert_eq!(l.deposit("a", 10).unwrap().outcome, Outcome::Duplicate);
    assert_eq!(
        l.deposit("a", 11),
        Err(LedgerError::Domain(DomainError::IdConflict))
    );
    assert_eq!(
        l.snapshot(),
        Ok(Snapshot {
            balance: 10,
            version: 1
        })
    );
}

#[test]
fn a_store_failure_is_surfaced_not_swallowed() {
    let (l, _) = ledger(State::new(), true);
    assert!(matches!(l.deposit("a", 1), Err(LedgerError::Store(_))));
}

#[test]
fn a_corrupt_store_fires_the_violation_counter_and_applies_nothing() {
    let corrupt = State::restore(7, 5, 0, 0, BTreeMap::new());
    let (l, seen) = ledger(corrupt, false);
    assert_eq!(l.deposit("a", 1), Err(LedgerError::InvariantViolated));
    assert!(seen
        .counters
        .lock()
        .unwrap()
        .iter()
        .any(|(c, _)| *c == Counter::UnitsConservedViolations));
    assert_eq!(l.snapshot().unwrap().version, 0);
}

#[test]
fn a_refused_command_leaves_the_state_exactly_as_it_was() {
    let (l, _) = ledger(State::new(), false);
    l.deposit("a", 5).unwrap();
    let before = l.snapshot().unwrap();
    assert!(l.withdraw("b", 6).is_err());
    assert!(l.deposit("bad id", 1).is_err());
    assert_eq!(l.snapshot().unwrap(), before);
}

#[test]
fn last_applied_moves_only_when_something_was_applied() {
    let (l, seen) = ledger(State::new(), false);
    l.deposit("a", 5).unwrap();
    l.deposit("a", 5).unwrap();
    let last = seen
        .gauges
        .lock()
        .unwrap()
        .iter()
        .filter(|(g, _)| *g == Gauge::LastAppliedUnixSeconds)
        .count();
    assert_eq!(last, 1);
}
