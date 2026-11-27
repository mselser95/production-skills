//! Platform zone: clock, ids, config, observability, signals.
//! Imports `app` (it implements ports) and nothing from `adapter`.
pub mod buildinfo;
pub mod clock;
pub mod config;
pub mod ids;
pub mod shutdown;
pub mod telemetry;
