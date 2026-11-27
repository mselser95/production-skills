//! Ports: the capabilities the use-cases need, named after the capability.
use alloc::string::String;
use core::error::Error;
use core::fmt;

use svc_domain::{Outcome, State};

use crate::ledger::{LedgerError, Snapshot};
use crate::telemetry::{Counter, Gauge, SpanName};

/// A store failure, already translated to text at the adapter boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoreError(pub String);

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "store: {}", self.0)
    }
}

impl Error for StoreError {}

/// Persistence of the ledger state.
pub trait EventStore: Send + Sync {
    /// Runs `change` on the ONE state, serialised against every other
    /// `update`, and returns its outcome with the resulting snapshot.
    ///
    /// Contract: `change` validates first and mutates last, so an `Err`
    /// leaves the state untouched; the store never clones the state to
    /// emulate that, and must not run two `change`s at once. A durable store
    /// makes `change`'s effect durable before returning `Ok`.
    fn update(
        &self,
        change: &mut dyn FnMut(&mut State) -> Result<Outcome, LedgerError>,
    ) -> Result<(Outcome, Snapshot), LedgerError>;

    /// Reads the current balance and version.
    fn read(&self) -> Result<Snapshot, StoreError>;
}

/// Wall clock, as whole seconds since the Unix epoch.
pub trait Clock: Send + Sync {
    /// Seconds since the Unix epoch.
    fn unix_seconds(&self) -> u64;
}

/// Source of fresh event ids for callers that do not bring their own.
pub trait IdGenerator: Send + Sync {
    /// A new id that satisfies `EventId::new`.
    fn next_id(&self) -> String;
}

/// Opaque handle of an open span.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpanId(pub u64);

/// Metrics and spans. Names and label keys come from `telemetry::{Counter,
/// Gauge, SpanName}` (one declaration); callers pass label VALUES in the
/// declared key order. A call whose value count differs from the declared key
/// count is dropped, never mislabelled.
pub trait Telemetry: Send + Sync {
    /// Adds one to a counter series.
    fn counter_inc(&self, counter: Counter, values: &[&str]);
    /// Sets a gauge series.
    fn gauge_set(&self, gauge: Gauge, value: i64, values: &[&str]);
    /// Opens a span.
    fn span_start(&self, span: SpanName, values: &[&str]) -> SpanId;
    /// Closes a span; `ok` false records an error.
    fn span_end(&self, id: SpanId, ok: bool);
}

/// Renders the metrics in the Prometheus text format.
pub trait MetricsSource: Send + Sync {
    /// The current scrape body.
    fn render(&self) -> String;
}
