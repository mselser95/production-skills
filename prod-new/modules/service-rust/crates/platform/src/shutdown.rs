//! SIGINT / SIGTERM to a flag the server loop watches.
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// Exit code when a SECOND signal arrives while the first is still draining:
/// the operator asked twice, so the process leaves at once and abandons
/// whatever was in flight.
pub const EXIT_FORCED: i32 = 4;

/// Sets `stop` on the first SIGINT/SIGTERM (graceful drain) and exits the
/// process with [`EXIT_FORCED`] on the second.
pub fn install(stop: Arc<AtomicBool>) -> Result<(), ctrlc::Error> {
    ctrlc::set_handler(move || {
        if stop.swap(true, Ordering::SeqCst) {
            std::process::exit(EXIT_FORCED);
        }
    })
}
