//! In-memory `EventStore`. State is lost on restart: a scaffold choice.
use std::sync::{Mutex, PoisonError};

use crate::app::{EventStore, StoreError};
use crate::domain::State;

/// The ledger state behind a lock.
#[derive(Default)]
pub struct MemoryStore {
    state: Mutex<State>,
}

impl MemoryStore {
    /// An empty store.
    pub fn new() -> Self {
        Self::default()
    }
}

impl EventStore for MemoryStore {
    fn load(&self) -> Result<State, StoreError> {
        Ok(self
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone())
    }

    fn save(&self, state: &State) -> Result<(), StoreError> {
        *self.state.lock().unwrap_or_else(PoisonError::into_inner) = state.clone();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{Event, EventId, Kind};

    #[test]
    fn save_then_load_round_trips() {
        let store = MemoryStore::new();
        let mut s = State::new();
        s.apply(&Event::new(EventId::new("a").unwrap(), Kind::Deposit, 3).unwrap())
            .unwrap();
        store.save(&s).unwrap();
        assert_eq!(store.load().unwrap(), s);
    }
}
