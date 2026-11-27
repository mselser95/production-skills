//! The units ledger: one balance, an applied-map, a version counter.
//!
//! Money is an integer count of minor units (`u64`). Every operation that can
//! overflow or underflow is checked; a failed `apply` leaves the state
//! untouched (validate everything, then commit). Event application is
//! idempotent by event id: the same id with the same content is a replay, the
//! same id with different content is a conflict.
use alloc::collections::BTreeMap;
use alloc::string::{String, ToString};
use core::error::Error;
use core::fmt;

/// Longest accepted event id, in bytes.
pub const MAX_ID_LEN: usize = 64;

/// Why a command was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DomainError {
    /// The id is empty, too long, or has characters outside `[A-Za-z0-9_-]`.
    InvalidId,
    /// A command must move at least one unit.
    ZeroUnits,
    /// A counter would exceed `u64::MAX`.
    Overflow,
    /// The id was already applied with a different kind or amount.
    IdConflict,
    /// A withdrawal larger than the balance.
    InsufficientFunds {
        /// Balance at the time of the refusal.
        balance: u64,
        /// Units the command asked for.
        requested: u64,
    },
}

impl fmt::Display for DomainError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidId => write!(f, "invalid event id"),
            Self::ZeroUnits => write!(f, "units must be greater than zero"),
            Self::Overflow => write!(f, "counter overflow"),
            Self::IdConflict => write!(f, "event id reused with different content"),
            Self::InsufficientFunds { balance, requested } => {
                write!(
                    f,
                    "insufficient funds: balance {balance}, requested {requested}"
                )
            }
        }
    }
}

impl Error for DomainError {}

/// A validated event identifier (the idempotency key).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct EventId(String);

impl EventId {
    /// Validates `raw`: 1..=`MAX_ID_LEN` bytes of `[A-Za-z0-9_-]`.
    pub fn new(raw: &str) -> Result<Self, DomainError> {
        let ok = !raw.is_empty()
            && raw.len() <= MAX_ID_LEN
            && raw
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
        if ok {
            Ok(Self(raw.to_string()))
        } else {
            Err(DomainError::InvalidId)
        }
    }

    /// The id as text.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Direction of a movement.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// Units come in.
    Deposit,
    /// Units go out.
    Withdraw,
}

impl Kind {
    /// Stable lowercase name, used as a metric label.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Deposit => "deposit",
            Self::Withdraw => "withdraw",
        }
    }
}

/// One movement of units.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    id: EventId,
    kind: Kind,
    units: u64,
}

impl Event {
    /// Builds an event; refuses a zero amount.
    pub fn new(id: EventId, kind: Kind, units: u64) -> Result<Self, DomainError> {
        if units == 0 {
            return Err(DomainError::ZeroUnits);
        }
        Ok(Self { id, kind, units })
    }

    /// The event's id.
    pub fn id(&self) -> &EventId {
        &self.id
    }

    /// The event's direction.
    pub fn kind(&self) -> Kind {
        self.kind
    }

    /// The amount moved, in minor units.
    pub fn units(&self) -> u64 {
        self.units
    }
}

/// What `apply` did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// The event changed the state.
    Applied,
    /// The id was already applied; nothing changed.
    Duplicate,
}

/// What the ledger remembers about an applied event: enough to tell a true
/// replay from an id reused with different content.
pub type AppliedEvent = (Kind, u64);

/// The ledger state.
///
/// The applied-id map grows with every distinct event and is never pruned:
/// retention is unbounded in this in-memory example. A real store keeps ids
/// for a bounded idempotency window (or in a unique index) and says what a
/// replay older than the window means.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct State {
    balance: u64,
    total_in: u64,
    total_out: u64,
    version: u64,
    applied: BTreeMap<EventId, AppliedEvent>,
}

impl State {
    /// An empty ledger.
    pub fn new() -> Self {
        Self::default()
    }

    /// Rebuilds a state from persisted parts WITHOUT checking consistency:
    /// a corrupt store must be detectable by [`State::conservation_holds`],
    /// not silently repaired here.
    pub fn restore(
        balance: u64,
        total_in: u64,
        total_out: u64,
        version: u64,
        applied: BTreeMap<EventId, AppliedEvent>,
    ) -> Self {
        Self {
            balance,
            total_in,
            total_out,
            version,
            applied,
        }
    }

    /// Current balance in minor units.
    pub fn balance(&self) -> u64 {
        self.balance
    }

    /// Number of applied events.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// Total ever deposited.
    pub fn total_in(&self) -> u64 {
        self.total_in
    }

    /// Total ever withdrawn.
    pub fn total_out(&self) -> u64 {
        self.total_out
    }

    /// Ids already applied, with their kind and amount.
    pub fn applied(&self) -> &BTreeMap<EventId, AppliedEvent> {
        &self.applied
    }

    /// Proposed (not yet ratified) invariant `units_conserved`: deposits minus withdrawals is
    /// the balance, and the version counts the applied ids.
    pub fn conservation_holds(&self) -> bool {
        self.total_in.checked_sub(self.total_out) == Some(self.balance)
            && u64::try_from(self.applied.len()).is_ok_and(|n| n == self.version)
    }

    /// Applies `event`. Idempotent by id; atomic (an `Err` changes nothing:
    /// every check runs before the first write).
    pub fn apply(&mut self, event: &Event) -> Result<Outcome, DomainError> {
        if let Some(&(kind, units)) = self.applied.get(&event.id) {
            return if kind == event.kind && units == event.units {
                Ok(Outcome::Duplicate)
            } else {
                Err(DomainError::IdConflict)
            };
        }
        let version = self.version.checked_add(1).ok_or(DomainError::Overflow)?;
        let units = event.units;
        let (balance, total_in, total_out) = match event.kind {
            Kind::Deposit => (
                self.balance
                    .checked_add(units)
                    .ok_or(DomainError::Overflow)?,
                self.total_in
                    .checked_add(units)
                    .ok_or(DomainError::Overflow)?,
                self.total_out,
            ),
            Kind::Withdraw => (
                self.balance
                    .checked_sub(units)
                    .ok_or(DomainError::InsufficientFunds {
                        balance: self.balance,
                        requested: units,
                    })?,
                self.total_in,
                self.total_out
                    .checked_add(units)
                    .ok_or(DomainError::Overflow)?,
            ),
        };
        self.applied
            .insert(event.id.clone(), (event.kind, event.units));
        self.balance = balance;
        self.total_in = total_in;
        self.total_out = total_out;
        self.version = version;
        Ok(Outcome::Applied)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(id: &str, kind: Kind, units: u64) -> Event {
        Event::new(EventId::new(id).unwrap(), kind, units).unwrap()
    }

    #[test]
    fn deposit_then_withdraw_moves_the_balance() {
        let mut s = State::new();
        assert_eq!(s.apply(&ev("a", Kind::Deposit, 100)), Ok(Outcome::Applied));
        assert_eq!(s.apply(&ev("b", Kind::Withdraw, 40)), Ok(Outcome::Applied));
        assert_eq!((s.balance(), s.version()), (60, 2));
        assert!(s.conservation_holds());
    }

    #[test]
    fn a_duplicate_id_has_no_second_effect() {
        let mut s = State::new();
        s.apply(&ev("a", Kind::Deposit, 5)).unwrap();
        assert_eq!(s.apply(&ev("a", Kind::Deposit, 5)), Ok(Outcome::Duplicate));
        assert_eq!((s.balance(), s.version()), (5, 1));
    }

    #[test]
    fn an_id_reused_with_different_content_is_a_conflict_and_changes_nothing() {
        let mut s = State::new();
        s.apply(&ev("a", Kind::Deposit, 5)).unwrap();
        let before = s.clone();
        assert_eq!(
            s.apply(&ev("a", Kind::Deposit, 6)),
            Err(DomainError::IdConflict)
        );
        assert_eq!(
            s.apply(&ev("a", Kind::Withdraw, 5)),
            Err(DomainError::IdConflict)
        );
        assert_eq!(s, before);
    }

    #[test]
    fn overdraw_is_refused_and_changes_nothing() {
        let mut s = State::new();
        s.apply(&ev("a", Kind::Deposit, 5)).unwrap();
        let before = s.clone();
        let err = s.apply(&ev("b", Kind::Withdraw, 6)).unwrap_err();
        assert_eq!(
            err,
            DomainError::InsufficientFunds {
                balance: 5,
                requested: 6
            }
        );
        assert_eq!(s, before);
    }

    #[test]
    fn overflow_is_refused_and_changes_nothing() {
        let mut s = State::new();
        s.apply(&ev("a", Kind::Deposit, u64::MAX)).unwrap();
        let before = s.clone();
        assert_eq!(
            s.apply(&ev("b", Kind::Deposit, 1)),
            Err(DomainError::Overflow)
        );
        assert_eq!(s, before);
    }

    #[test]
    fn zero_units_and_bad_ids_are_refused() {
        let id = EventId::new("x").unwrap();
        assert_eq!(
            Event::new(id, Kind::Deposit, 0),
            Err(DomainError::ZeroUnits)
        );
        for bad in ["", "has space", "ünï", &"x".repeat(MAX_ID_LEN + 1)] {
            assert_eq!(EventId::new(bad), Err(DomainError::InvalidId), "{bad:?}");
        }
        assert!(EventId::new(&"x".repeat(MAX_ID_LEN)).is_ok());
    }

    #[test]
    fn a_corrupt_restore_is_detected_not_repaired() {
        let s = State::restore(7, 5, 0, 0, BTreeMap::new());
        assert!(!s.conservation_holds());
    }
}
