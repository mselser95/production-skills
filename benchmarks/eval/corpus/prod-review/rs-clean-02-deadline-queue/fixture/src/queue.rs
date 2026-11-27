use std::collections::BinaryHeap;
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Mutex;

use crate::entry::Entry;

#[derive(Debug, PartialEq, Eq)]
pub enum QueueError {
    DeadlineOverflow,
}

impl fmt::Display for QueueError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            QueueError::DeadlineOverflow => write!(f, "deadline does not fit in u64 milliseconds"),
        }
    }
}

impl std::error::Error for QueueError {}

/// Items wait here until their deadline. `wake` tells an idle consumer that
/// something new was queued. Time is passed in by the caller.
pub struct DeadlineQueue<T> {
    heap: Mutex<BinaryHeap<Entry<T>>>,
    next_seq: AtomicU64,
    wake: Sender<()>,
}

impl<T> DeadlineQueue<T> {
    pub fn new(wake: Sender<()>) -> Self {
        DeadlineQueue {
            heap: Mutex::new(BinaryHeap::new()),
            next_seq: AtomicU64::new(0),
            wake,
        }
    }

    /// Queue `item` to become due `ttl_ms` after `now_ms`; returns its deadline.
    pub fn push(&self, item: T, now_ms: u64, ttl_ms: u64) -> Result<u64, QueueError> {
        let deadline_ms = now_ms
            .checked_add(ttl_ms)
            .ok_or(QueueError::DeadlineOverflow)?;
        let seq = self.next_seq.fetch_add(1, Ordering::Relaxed);
        self.heap.lock().unwrap().push(Entry {
            deadline_ms,
            seq,
            item,
        });
        Ok(deadline_ms)
    }

    /// Remove the item with the earliest deadline, due or not.
    pub fn pop_next(&self) -> Option<T> {
        self.heap.lock().unwrap().pop().map(|e| e.item)
    }

    /// A handle producers can use to wake the consumer without owning the queue.
    pub fn wake_handle(&self) -> Sender<()> {
        self.wake.clone()
    }

    pub fn len(&self) -> usize {
        self.heap.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn new_queue_is_empty() {
        let (tx, _rx) = mpsc::channel();
        let q: DeadlineQueue<u8> = DeadlineQueue::new(tx);
        assert!(q.is_empty());
    }

    #[test]
    fn pop_next_follows_deadline_then_arrival() {
        let (tx, _rx) = mpsc::channel();
        let q = DeadlineQueue::new(tx);
        q.push("late", 0, 50).unwrap();
        q.push("b", 0, 10).unwrap();
        q.push("a", 0, 10).unwrap();
        assert_eq!(q.pop_next(), Some("b"));
        assert_eq!(q.pop_next(), Some("a"));
        assert_eq!(q.pop_next(), Some("late"));
        assert_eq!(q.pop_next(), None);
    }

    #[test]
    fn an_overflowing_deadline_is_refused() {
        let (tx, _rx) = mpsc::channel();
        let q = DeadlineQueue::new(tx);
        assert_eq!(q.push(1, u64::MAX, 1), Err(QueueError::DeadlineOverflow));
        assert!(q.is_empty());
    }
}
