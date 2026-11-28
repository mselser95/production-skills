//! Event ids for callers that bring none: `<boot-seconds>-<counter>`.
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use svc_app::{Clock, IdGenerator};

/// A process-local sequence. Ids are unique per process lifetime only, so a
/// request without its own id is NOT idempotent across a retry.
pub struct Sequence {
    boot: u64,
    next: AtomicU64,
}

impl Sequence {
    /// Starts a sequence stamped with the clock's current second.
    pub fn new(clock: &Arc<dyn Clock>) -> Self {
        Self {
            boot: clock.unix_seconds(),
            next: AtomicU64::new(1),
        }
    }
}

impl IdGenerator for Sequence {
    fn next_id(&self) -> String {
        format!(
            "gen-{}-{}",
            self.boot,
            self.next.fetch_add(1, Ordering::Relaxed)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixed;
    impl Clock for Fixed {
        fn unix_seconds(&self) -> u64 {
            42
        }
    }

    #[test]
    fn ids_are_distinct_and_valid() {
        let clock: Arc<dyn Clock> = Arc::new(Fixed);
        let seq = Sequence::new(&clock);
        let (a, b) = (seq.next_id(), seq.next_id());
        assert_ne!(a, b);
        assert!(a.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-'));
    }
}
