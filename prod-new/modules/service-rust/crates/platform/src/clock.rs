//! The system clock behind the `Clock` port.
use std::time::{SystemTime, UNIX_EPOCH};

use svc_app::Clock;

/// Reads the operating system's wall clock.
#[derive(Debug, Default, Clone, Copy)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn unix_seconds(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_clock_is_past_2020() {
        assert!(SystemClock.unix_seconds() > 1_577_836_800);
    }
}
