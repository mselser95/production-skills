//! Build identity.

/// The service name, substituted at scaffold time.
pub const SERVICE_NAME: &str = "<SERVICE>";

/// The git revision baked in at build time (`SVC_REVISION`), else `dev`.
pub fn revision() -> &'static str {
    option_env!("SVC_REVISION").unwrap_or("dev")
}
