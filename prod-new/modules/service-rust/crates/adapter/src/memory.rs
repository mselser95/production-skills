//! In-memory `EventStore`. State is lost on restart: a scaffold choice.
//!
//! One lock, one state, no clone: `update` hands the stored state to the
//! use-case by `&mut`, and the use-case validates before it mutates, so an
//! `Err` leaves the state as it was without a copy (O(log n) per command, not
//! O(n)).
//!
//! RETENTION IS UNBOUNDED: the applied-id map (`svc_domain::State`) keeps
//! every id ever applied, so memory grows with the number of distinct events.
//! A real store keeps ids for a bounded idempotency window or in a unique
//! index, persists them with the state in one transaction, and decides what a
//! replay older than the window means.
use std::sync::{Mutex, PoisonError};

use svc_app::{EventStore, LedgerError, Snapshot, StoreError};
use svc_domain::{Outcome, State};

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

fn snapshot(state: &State) -> Snapshot {
    Snapshot {
        balance: state.balance(),
        version: state.version(),
    }
}

impl EventStore for MemoryStore {
    fn update(
        &self,
        change: &mut dyn FnMut(&mut State) -> Result<Outcome, LedgerError>,
    ) -> Result<(Outcome, Snapshot), LedgerError> {
        // A poisoned lock is recovered: `State::apply` writes only after every
        // check, so a panic elsewhere cannot leave it half-written.
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let outcome = change(&mut state)?;
        Ok((outcome, snapshot(&state)))
    }

    fn read(&self) -> Result<Snapshot, StoreError> {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        Ok(snapshot(&state))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use svc_domain::{DomainError, Event, EventId, Kind};

    fn ev(id: &str, kind: Kind, units: u64) -> Event {
        Event::new(EventId::new(id).unwrap(), kind, units).unwrap()
    }

    #[test]
    fn update_mutates_in_place_and_read_sees_it() {
        let store = MemoryStore::new();
        let (o, snap) = store
            .update(&mut |s| Ok(s.apply(&ev("a", Kind::Deposit, 3))?))
            .unwrap();
        assert_eq!(o, Outcome::Applied);
        assert_eq!(
            snap,
            Snapshot {
                balance: 3,
                version: 1
            }
        );
        assert_eq!(store.read().unwrap(), snap);
    }

    #[test]
    fn a_failed_change_leaves_the_state_untouched() {
        let store = MemoryStore::new();
        store
            .update(&mut |s| Ok(s.apply(&ev("a", Kind::Deposit, 3))?))
            .unwrap();
        let err = store
            .update(&mut |s| Ok(s.apply(&ev("b", Kind::Withdraw, 9))?))
            .unwrap_err();
        assert!(matches!(
            err,
            LedgerError::Domain(DomainError::InsufficientFunds { .. })
        ));
        assert_eq!(
            store.read().unwrap(),
            Snapshot {
                balance: 3,
                version: 1
            }
        );
    }
}
