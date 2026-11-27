use std::fmt;

/// Largest capacity `Ring::new` accepts.
pub const MAX_CAPACITY: usize = 1 << 20;

#[derive(Debug, PartialEq, Eq)]
pub enum RingError {
    ZeroCapacity,
    TooLarge,
}

impl fmt::Display for RingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RingError::ZeroCapacity => write!(f, "capacity must be at least 1"),
            RingError::TooLarge => write!(f, "capacity exceeds {MAX_CAPACITY}"),
        }
    }
}

impl std::error::Error for RingError {}

/// `slots.len()` is the capacity; `len` items start at `head`, wrapping around.
pub struct Ring<T> {
    slots: Vec<Option<T>>,
    head: usize,
    len: usize,
    dropped: u64,
}

impl<T> Ring<T> {
    pub fn new(capacity: usize) -> Result<Self, RingError> {
        if capacity == 0 {
            return Err(RingError::ZeroCapacity);
        }
        if capacity > MAX_CAPACITY {
            return Err(RingError::TooLarge);
        }
        let mut slots = Vec::with_capacity(capacity);
        slots.resize_with(capacity, || None);
        Ok(Ring {
            slots,
            head: 0,
            len: 0,
            dropped: 0,
        })
    }

    /// The oldest item without removing it.
    pub fn peek_oldest(&self) -> Option<&T> {
        self.slots[self.head].as_ref()
    }

    pub fn capacity(&self) -> usize {
        self.slots.len()
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// How many items have been evicted to make room.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_ring_is_empty() {
        let r: Ring<u8> = Ring::new(4).unwrap();
        assert_eq!((r.capacity(), r.len(), r.dropped()), (4, 0, 0));
        assert!(r.is_empty());
        assert!(r.peek_oldest().is_none());
    }

    #[test]
    fn capacity_is_validated() {
        assert!(matches!(Ring::<u8>::new(0), Err(RingError::ZeroCapacity)));
        assert!(matches!(
            Ring::<u8>::new(MAX_CAPACITY + 1),
            Err(RingError::TooLarge)
        ));
    }
}
