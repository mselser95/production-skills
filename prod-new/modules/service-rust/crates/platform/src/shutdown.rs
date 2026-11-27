//! SIGINT / SIGTERM to a flag the server loop watches.
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// Sets `stop` when the process is asked to terminate.
pub fn install(stop: Arc<AtomicBool>) -> Result<(), ctrlc::Error> {
    ctrlc::set_handler(move || stop.store(true, Ordering::SeqCst))
}
