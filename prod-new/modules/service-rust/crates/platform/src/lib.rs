//! Platform zone: clock, ids, config, observability recorder, signals.
//! Depends on `app` (it implements ports) and never on `adapter` or `domain`
//! (Cargo enforces it).
#![forbid(unsafe_code)]

pub mod buildinfo;
pub mod clock;
pub mod config;
pub mod ids;
pub mod shutdown;
pub mod telemetry;
