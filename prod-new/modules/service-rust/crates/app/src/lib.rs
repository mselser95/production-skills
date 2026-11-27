//! App zone: use-cases over ports. Depends on `domain` only (Cargo enforces
//! it) and is `#![no_std]` + `alloc` too: ports are traits, the lock lives in
//! whatever store implements `EventStore`, so nothing here can do I/O.
#![no_std]
#![forbid(unsafe_code)]

extern crate alloc;

mod ledger;
mod ports;
pub mod telemetry;

pub use self::ledger::{Ledger, LedgerError, Receipt, Snapshot};
pub use self::ports::{
    Clock, EventStore, IdGenerator, MetricsSource, SpanId, StoreError, Telemetry,
};
pub use self::telemetry::{Counter, Gauge, SpanName};
