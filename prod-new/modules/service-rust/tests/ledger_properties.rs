//! Property-style tests over the domain with a small deterministic generator
//! (xorshift64*, fixed seeds): no dependency, fully reproducible.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
use svc::domain::{DomainError, Event, EventId, Kind, Outcome, State};

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
}

fn random_event(rng: &mut Rng) -> Event {
    let id = format!("e{}", rng.below(40)); // small id space forces duplicates
    let kind = if rng.below(2) == 0 {
        Kind::Deposit
    } else {
        Kind::Withdraw
    };
    let units = match rng.below(10) {
        0 => u64::MAX, // overflow / overdraw pressure
        1 => u64::MAX / 2,
        _ => 1 + rng.below(1_000),
    };
    Event::new(EventId::new(&id).unwrap(), kind, units).unwrap()
}

#[test]
fn conservation_holds_over_generated_event_sequences() {
    for seed in 1..=200u64 {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        let mut state = State::new();
        for _ in 0..200 {
            let before = state.clone();
            let ev = random_event(&mut rng);
            match state.apply(&ev) {
                Ok(Outcome::Applied) => assert_eq!(state.version(), before.version() + 1),
                Ok(Outcome::Duplicate) => assert_eq!(state, before, "seed {seed}"),
                Err(_) => assert_eq!(state, before, "a refusal must change nothing (seed {seed})"),
            }
            assert!(
                state.conservation_holds(),
                "units_conserved broken (seed {seed})"
            );
        }
    }
}

#[test]
fn replaying_the_same_events_reaches_the_same_state() {
    for seed in 1..=100u64 {
        let mut rng = Rng(seed.wrapping_mul(0xD1B5_4A32_D192_ED03) | 1);
        let events: Vec<Event> = (0..150).map(|_| random_event(&mut rng)).collect();
        let (mut a, mut b) = (State::new(), State::new());
        for e in &events {
            let _ = a.apply(e);
        }
        for e in &events {
            let _ = b.apply(e);
        }
        assert_eq!(a, b, "seed {seed}");
    }
}

#[test]
fn a_duplicate_submission_has_exactly_one_effect() {
    for seed in 1..=100u64 {
        let mut rng = Rng(seed | 1);
        let mut state = State::new();
        let first = random_event(&mut rng);
        let r1 = state.apply(&first);
        let after_first = state.clone();
        let r2 = state.apply(&first);
        if r1 == Ok(Outcome::Applied) {
            assert_eq!(r2, Ok(Outcome::Duplicate));
        }
        assert_eq!(state, after_first, "seed {seed}");
    }
}

#[test]
fn balance_equals_the_signed_sum_of_applied_events() {
    for seed in 1..=100u64 {
        let mut rng = Rng(seed.wrapping_mul(0xA24B_AED4_963E_E407) | 1);
        let mut state = State::new();
        let (mut model, mut count) = (0i128, 0u64);
        for _ in 0..150 {
            let ev = random_event(&mut rng);
            if state.apply(&ev) == Ok(Outcome::Applied) {
                count += 1;
                let units = i128::from(ev.units());
                model += if ev.kind() == Kind::Deposit {
                    units
                } else {
                    -units
                };
            }
        }
        assert_eq!(model, i128::from(state.balance()), "seed {seed}");
        assert_eq!(count, state.version(), "seed {seed}");
    }
}

#[test]
fn overdraw_is_always_refused_with_the_true_balance() {
    let mut s = State::new();
    s.apply(&Event::new(EventId::new("a").unwrap(), Kind::Deposit, 10).unwrap())
        .unwrap();
    let e = Event::new(EventId::new("b").unwrap(), Kind::Withdraw, 11).unwrap();
    assert_eq!(
        s.apply(&e),
        Err(DomainError::InsufficientFunds {
            balance: 10,
            requested: 11
        })
    );
}
