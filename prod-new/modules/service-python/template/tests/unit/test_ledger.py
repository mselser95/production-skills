import pytest

from <PACKAGE>.domain.errors import (
    AmountLimitExceeded,
    InsufficientFunds,
    InvalidEvent,
    ZeroAmount,
)
from <PACKAGE>.domain.ledger import (
    Event,
    EventType,
    Outcome,
    State,
    apply,
    conserved,
    replay,
)
from <PACKAGE>.domain.money import (
    MAX_MINOR,
    Amount,
)


def deposit(event_id: str, minor: int) -> Event:
    return Event(event_id, EventType.DEPOSITED, Amount(minor))


def withdraw(event_id: str, minor: int) -> Event:
    return Event(event_id, EventType.WITHDRAWN, Amount(minor))


# provenance: derived
# verifies: units_ledger/conservation
def test_deposit_then_withdraw_moves_the_balance_and_conserves() -> None:
    events = [deposit("a", 1000), withdraw("b", 250)]
    state = replay(events)
    assert state.balance == Amount(750)
    assert state.version == 2
    assert conserved(state, events)


# provenance: derived
# verifies: units_ledger/idempotency
def test_a_duplicate_event_id_has_its_effect_once() -> None:
    first = apply(State(), deposit("a", 1000))
    again = apply(first.state, deposit("a", 1000))
    assert first.outcome is Outcome.APPLIED
    assert again.outcome is Outcome.DUPLICATE
    assert again.state == first.state


# provenance: derived
# verifies: units_ledger/no_overdraft
def test_an_uncovered_withdrawal_raises_and_leaves_the_state_alone() -> None:
    state = apply(State(), deposit("a", 100)).state
    with pytest.raises(InsufficientFunds):
        apply(state, withdraw("b", 101))
    assert state.balance == Amount(100)
    assert "b" not in state.applied


# provenance: derived
# verifies: units_ledger/no_overdraft
def test_withdrawing_the_whole_balance_is_allowed() -> None:
    state = replay([deposit("a", 100), withdraw("b", 100)])
    assert state.balance == Amount(0)


# provenance: derived
# verifies: units_ledger/conservation
def test_conserved_detects_a_state_that_disagrees_with_its_log() -> None:
    events = [deposit("a", 100)]
    forged = State(Amount(999), frozenset({"a"}), 1)
    assert not conserved(forged, events)
    assert not conserved(State(Amount(100), frozenset(), 0), events)


# provenance: derived
# verifies: units_ledger/event_validity
@pytest.mark.parametrize("bad_id", ["", "x" * 129])
def test_an_event_needs_a_bounded_non_empty_id(bad_id: str) -> None:
    with pytest.raises(InvalidEvent):
        deposit(bad_id, 1)


# provenance: derived
# verifies: units_ledger/conservation
def test_a_zero_amount_event_is_refused_for_both_kinds() -> None:
    with pytest.raises(ZeroAmount):
        deposit("a", 0)
    with pytest.raises(ZeroAmount):
        withdraw("a", 0)


# provenance: derived
# verifies: units_ledger/conservation
def test_a_deposit_past_the_bound_is_refused_and_leaves_the_state_alone() -> None:
    state = replay([deposit("a", MAX_MINOR)])
    with pytest.raises(AmountLimitExceeded):
        apply(state, deposit("b", 1))
    assert state.balance == Amount(MAX_MINOR)
    assert state.version == 1
