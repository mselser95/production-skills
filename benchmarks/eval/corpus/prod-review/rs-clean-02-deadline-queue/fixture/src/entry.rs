use std::cmp::Ordering;

/// A queued item. Ordered by `(deadline_ms, seq)` only, and reversed so that
/// `BinaryHeap` (a max-heap) pops the earliest deadline first.
pub(crate) struct Entry<T> {
    pub deadline_ms: u64,
    pub seq: u64,
    pub item: T,
}

impl<T> PartialEq for Entry<T> {
    fn eq(&self, other: &Self) -> bool {
        (self.deadline_ms, self.seq) == (other.deadline_ms, other.seq)
    }
}

impl<T> Eq for Entry<T> {}

impl<T> PartialOrd for Entry<T> {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl<T> Ord for Entry<T> {
    fn cmp(&self, other: &Self) -> Ordering {
        (other.deadline_ms, other.seq).cmp(&(self.deadline_ms, self.seq))
    }
}
