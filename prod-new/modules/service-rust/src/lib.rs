//! A units ledger service, organised in four zones with one allowed
//! dependency direction (enforced by `tests/architecture.rs`):
//!
//! ```text
//! adapter -> app -> domain        platform -> app -> domain
//! ```
//!
//! * `domain`: pure rules. No I/O, no clock, no randomness, no async.
//! * `app`: use-cases over ports (traits). Orchestration only.
//! * `adapter`: things on the far side of a port (HTTP in, memory store out).
//! * `platform`: clock, ids, config, observability, signals.
//!
//! The composition root is `main.rs`: the only place that sees every zone.
#![forbid(unsafe_code)]

pub mod adapter;
pub mod app;
pub mod domain;
pub mod platform;
