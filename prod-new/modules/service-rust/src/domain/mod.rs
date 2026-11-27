//! Domain zone: pure rules of the units ledger.
mod ledger;

pub use self::ledger::{DomainError, Event, EventId, Kind, Outcome, State, MAX_ID_LEN};
