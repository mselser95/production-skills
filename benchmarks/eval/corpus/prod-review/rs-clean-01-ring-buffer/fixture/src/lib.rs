//! Fixed-capacity ring buffer that evicts its oldest item when full.

mod ring;

pub use ring::{Ring, RingError, MAX_CAPACITY};
