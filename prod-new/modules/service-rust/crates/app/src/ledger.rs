//! The ledger use-cases: deposit, withdraw, snapshot.
use alloc::sync::Arc;
use core::error::Error;
use core::fmt;

use svc_domain::{DomainError, Event, EventId, Kind, Outcome, State};

use super::ports::{Clock, EventStore, StoreError, Telemetry};
use super::telemetry::{Counter, Gauge, SpanName};

/// Why a use-case failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LedgerError {
    /// The command was refused by a domain rule.
    Domain(DomainError),
    /// The store failed.
    Store(StoreError),
    /// The state broke `units_conserved` before the command; it was not applied.
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

/// What a command did and the state it left behind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Receipt {
    /// Applied, or a replay of an identical event.
    pub outcome: Outcome,
    /// Balance and version after the command.
    pub snapshot: Snapshot,
}

/// A read of the ledger.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Snapshot {
    /// Balance in minor units.
    pub balance: u64,
    /// Count of applied events.
    pub version: u64,
}

/// The ledger service. Commands are serialised by the store's `update`
/// (single writer); the use-case itself holds no lock.
pub struct Ledger {
    store: Arc<dyn EventStore>,
    telemetry: Arc<dyn Telemetry>,
    clock: Arc<dyn Clock>,
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
        }
    }

    /// Deposits `units` under the idempotency key `id`.
    pub fn deposit(&self, id: &str, units: u64) -> Result<Receipt, LedgerError> {
        self.traced(SpanName::Deposit, Kind::Deposit, id, units)
    }

    /// Withdraws `units` under the idempotency key `id`.
    pub fn withdraw(&self, id: &str, units: u64) -> Result<Receipt, LedgerError> {
        self.traced(SpanName::Withdraw, Kind::Withdraw, id, units)
    }

    /// Reads the current balance and version.
    pub fn snapshot(&self) -> Result<Snapshot, LedgerError> {
        Ok(self.store.read()?)
    }

    fn traced(
        &self,
        span: SpanName,
        kind: Kind,
        id: &str,
        units: u64,
    ) -> Result<Receipt, LedgerError> {
        let span = self.telemetry.span_start(span, &[kind.as_str()]);
        let result = self.process(kind, id, units);
        self.telemetry.span_end(span, result.is_ok());
        result
    }

    fn process(&self, kind: Kind, id: &str, units: u64) -> Result<Receipt, LedgerError> {
        let result = self.run(kind, id, units);
        let outcome = match &result {
            Ok(r) if r.outcome == Outcome::Applied => "applied",
            Ok(_) => "duplicate",
            Err(_) => "rejected",
        };
        self.telemetry
            .counter_inc(Counter::Events, &[kind.as_str(), outcome]);
        result
    }

    fn run(&self, kind: Kind, id: &str, units: u64) -> Result<Receipt, LedgerError> {
        let event = Event::new(EventId::new(id)?, kind, units)?;
        let telemetry = &self.telemetry;
        let (outcome, snapshot) = self.store.update(&mut |state: &mut State| {
            // Validate, then commit: a corrupt state is refused BEFORE the
            // event touches it, and `State::apply` checks every bound before
            // its first write, so an `Err` leaves the state as it was.
            if !state.conservation_holds() {
                telemetry.counter_inc(Counter::UnitsConservedViolations, &[]);
                return Err(LedgerError::InvariantViolated);
            }
            Ok(state.apply(&event)?)
        })?;
        if outcome == Outcome::Applied {
            let now = i64::try_from(self.clock.unix_seconds()).unwrap_or(i64::MAX);
            self.telemetry
                .gauge_set(Gauge::LastAppliedUnixSeconds, now, &[]);
        }
        let balance = i64::try_from(snapshot.balance).unwrap_or(i64::MAX);
        self.telemetry.gauge_set(Gauge::BalanceUnits, balance, &[]);
        Ok(Receipt { outcome, snapshot })
    }
}
