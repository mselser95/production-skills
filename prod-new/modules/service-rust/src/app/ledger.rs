//! The ledger use-cases: deposit, withdraw, snapshot.
use std::error::Error;
use std::fmt;
use std::sync::{Arc, Mutex, PoisonError};

use super::ports::{Clock, EventStore, StoreError, Telemetry};
use crate::domain::{DomainError, Event, EventId, Kind, Outcome};

/// Why a use-case failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LedgerError {
    /// The command was refused by a domain rule.
    Domain(DomainError),
    /// The store failed.
    Store(StoreError),
    /// The state broke `units_conserved`; nothing was saved.
    InvariantViolated,
}

impl fmt::Display for LedgerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Domain(e) => write!(f, "{e}"),
            Self::Store(e) => write!(f, "{e}"),
            Self::InvariantViolated => write!(f, "units_conserved violated"),
        }
    }
}

impl Error for LedgerError {}

impl From<DomainError> for LedgerError {
    fn from(e: DomainError) -> Self {
        Self::Domain(e)
    }
}

impl From<StoreError> for LedgerError {
    fn from(e: StoreError) -> Self {
        Self::Store(e)
    }
}

/// A read of the ledger.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Snapshot {
    /// Balance in minor units.
    pub balance: u64,
    /// Count of applied events.
    pub version: u64,
}

/// The ledger service. Commands are serialised by one lock (single writer).
pub struct Ledger {
    store: Arc<dyn EventStore>,
    telemetry: Arc<dyn Telemetry>,
    clock: Arc<dyn Clock>,
    gate: Mutex<()>,
}

impl Ledger {
    /// Wires the use-cases to their ports.
    pub fn new(
        store: Arc<dyn EventStore>,
        telemetry: Arc<dyn Telemetry>,
        clock: Arc<dyn Clock>,
    ) -> Self {
        Self {
            store,
            telemetry,
            clock,
            gate: Mutex::new(()),
        }
    }

    /// Deposits `units` under the idempotency key `id`.
    pub fn deposit(&self, id: &str, units: u64) -> Result<Outcome, LedgerError> {
        let span = self
            .telemetry
            .span_start("svc.deposit", &[("event_type", "deposit")]);
        let result = self.process(Kind::Deposit, id, units);
        self.telemetry.span_end(span, result.is_ok());
        result
    }

    /// Withdraws `units` under the idempotency key `id`.
    pub fn withdraw(&self, id: &str, units: u64) -> Result<Outcome, LedgerError> {
        let span = self
            .telemetry
            .span_start("svc.withdraw", &[("event_type", "withdraw")]);
        let result = self.process(Kind::Withdraw, id, units);
        self.telemetry.span_end(span, result.is_ok());
        result
    }

    /// Reads the current balance and version.
    pub fn snapshot(&self) -> Result<Snapshot, LedgerError> {
        let state = self.store.load()?;
        Ok(Snapshot {
            balance: state.balance(),
            version: state.version(),
        })
    }

    fn process(&self, kind: Kind, id: &str, units: u64) -> Result<Outcome, LedgerError> {
        let result = self.run(kind, id, units);
        let outcome = match &result {
            Ok(Outcome::Applied) => "applied",
            Ok(Outcome::Duplicate) => "duplicate",
            Err(_) => "rejected",
        };
        self.telemetry.counter_inc(
            "svc_events_total",
            &[("kind", kind.as_str()), ("outcome", outcome)],
        );
        result
    }

    fn run(&self, kind: Kind, id: &str, units: u64) -> Result<Outcome, LedgerError> {
        let event = Event::new(EventId::new(id)?, kind, units)?;
        let _writer = self.gate.lock().unwrap_or_else(PoisonError::into_inner);
        let mut state = self.store.load()?;
        let outcome = state.apply(&event)?;
        if !state.conservation_holds() {
            self.telemetry
                .counter_inc("svc_units_conserved_violations_total", &[]);
            return Err(LedgerError::InvariantViolated);
        }
        if outcome == Outcome::Applied {
            self.store.save(&state)?;
            let now = i64::try_from(self.clock.unix_seconds()).unwrap_or(i64::MAX);
            self.telemetry
                .gauge_set("svc_last_applied_unix_seconds", now, &[]);
        }
        let balance = i64::try_from(state.balance()).unwrap_or(i64::MAX);
        self.telemetry.gauge_set("svc_balance_units", balance, &[]);
        Ok(outcome)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::ports::SpanId;
    use crate::domain::State;
    use std::collections::BTreeSet;

    struct FixedClock;
    impl Clock for FixedClock {
        fn unix_seconds(&self) -> u64 {
            1_000
        }
    }

    #[derive(Default)]
    struct Seen {
        counters: Mutex<Vec<String>>,
        spans: Mutex<Vec<(String, bool)>>,
    }
    impl Telemetry for Seen {
        fn counter_inc(&self, name: &'static str, _labels: &[(&'static str, &str)]) {
            self.counters.lock().unwrap().push(name.to_owned());
        }
        fn gauge_set(&self, _n: &'static str, _v: i64, _l: &[(&'static str, &str)]) {}
        fn span_start(&self, name: &'static str, _a: &[(&'static str, &str)]) -> SpanId {
            let mut spans = self.spans.lock().unwrap();
            spans.push((name.to_owned(), false));
            SpanId(u64::try_from(spans.len()).unwrap_or(0))
        }
        fn span_end(&self, id: SpanId, ok: bool) {
            let mut spans = self.spans.lock().unwrap();
            if let Some(s) = usize::try_from(id.0.saturating_sub(1))
                .ok()
                .and_then(|i| spans.get_mut(i))
            {
                s.1 = ok;
            }
        }
    }

    struct FixedStore(Mutex<State>, bool);
    impl EventStore for FixedStore {
        fn load(&self) -> Result<State, StoreError> {
            Ok(self.0.lock().unwrap().clone())
        }
        fn save(&self, s: &State) -> Result<(), StoreError> {
            if self.1 {
                return Err(StoreError("disk full".into()));
            }
            *self.0.lock().unwrap() = s.clone();
            Ok(())
        }
    }

    fn ledger(state: State, failing_save: bool) -> (Ledger, Arc<Seen>) {
        let seen = Arc::new(Seen::default());
        let l = Ledger::new(
            Arc::new(FixedStore(Mutex::new(state), failing_save)),
            seen.clone(),
            Arc::new(FixedClock),
        );
        (l, seen)
    }

    #[test]
    fn deposit_applies_and_closes_its_span_ok() {
        let (l, seen) = ledger(State::new(), false);
        assert_eq!(l.deposit("a", 10), Ok(Outcome::Applied));
        assert_eq!(
            l.snapshot(),
            Ok(Snapshot {
                balance: 10,
                version: 1
            })
        );
        assert_eq!(
            *seen.spans.lock().unwrap(),
            vec![("svc.deposit".to_owned(), true)]
        );
    }

    #[test]
    fn a_refused_command_closes_its_span_as_error() {
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
            vec![("svc.withdraw".to_owned(), false)]
        );
    }

    #[test]
    fn a_store_failure_is_surfaced_not_swallowed() {
        let (l, _) = ledger(State::new(), true);
        assert!(matches!(l.deposit("a", 1), Err(LedgerError::Store(_))));
    }

    #[test]
    fn a_corrupt_store_fires_the_violation_counter_and_saves_nothing() {
        let corrupt = State::restore(7, 5, 0, 0, BTreeSet::new());
        let (l, seen) = ledger(corrupt, false);
        assert_eq!(l.deposit("a", 1), Err(LedgerError::InvariantViolated));
        let counters = seen.counters.lock().unwrap();
        assert!(counters
            .iter()
            .any(|c| c == "svc_units_conserved_violations_total"));
    }
}
