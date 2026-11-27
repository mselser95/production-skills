//! A queue of items that become due at a deadline, earliest first.

mod entry;
mod queue;

pub use queue::{DeadlineQueue, QueueError};
