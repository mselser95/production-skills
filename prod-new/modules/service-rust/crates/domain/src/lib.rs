//! Domain zone: the pure rules of the units ledger.
//!
//! `#![no_std]` is the purity rule, enforced by the compiler: without `std`
//! there is no file, socket, clock, environment or thread to reach. Only
//! `core` and `alloc` are available, and the crate has NO dependencies (see
//! `Cargo.toml`; `tests/architecture.rs` pins that list).
#![no_std]
#![forbid(unsafe_code)]

extern crate alloc;

mod ledger;

pub use self::ledger::{
    AppliedEvent, DomainError, Event, EventId, Kind, Outcome, State, MAX_ID_LEN,
};
