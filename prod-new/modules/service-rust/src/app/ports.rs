//! Ports: the capabilities the use-cases need, named after the capability.
use std::error::Error;
use std::fmt;

use crate::domain::State;

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
    /// Reads the current state.
    fn load(&self) -> Result<State, StoreError>;
    /// Replaces the current state.
    fn save(&self, state: &State) -> Result<(), StoreError>;
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

/// Metrics and spans. Every name passed here must be declared in
/// `observability/{emitted-metrics,spans}.yaml` (`tests/observability_contract.rs`).
pub trait Telemetry: Send + Sync {
    /// Adds one to a counter series.
    fn counter_inc(&self, name: &'static str, labels: &[(&'static str, &str)]);
    /// Sets a gauge series.
    fn gauge_set(&self, name: &'static str, value: i64, labels: &[(&'static str, &str)]);
    /// Opens a span.
    fn span_start(&self, name: &'static str, attrs: &[(&'static str, &str)]) -> SpanId;
    /// Closes a span; `ok` false records an error.
    fn span_end(&self, id: SpanId, ok: bool);
}

/// Renders the metrics in the Prometheus text format.
pub trait MetricsSource: Send + Sync {
    /// The current scrape body.
    fn render(&self) -> String;
}
