//! Build identity.

/// The service name, substituted at scaffold time.
pub const SERVICE_NAME: &str = "<SERVICE>";

/// The git revision baked in at build time (`SVC_REVISION`), else `dev`.
/// The read itself lives in `config.rs`, the only file that touches the
/// environment (`tests/architecture.rs` pins that).
pub fn revision() -> &'static str {
    crate::config::REVISION
}
