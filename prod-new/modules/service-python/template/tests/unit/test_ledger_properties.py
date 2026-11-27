import pytest
from hypothesis import given
from hypothesis import strategies as st

from <PACKAGE>.domain.errors import (
    AmountLimitExceeded,
    InsufficientFunds,
    InvalidAmount,
    ZeroAmount,
)
from <PACKAGE>.domain.ledger import (
    Event,
    EventType,
    State,
    apply,
    conserved,
    replay,
)
from <PACKAGE>.domain.money import (
    MAX_MINOR,
    Amount,
)

pytestmark = pytest.mark.property

# Few ids so duplicates are common; small amounts so overdrafts are common.
events = st.builds(
    Event,
    id=st.sampled_from(["a", "b", "c", "d", "e", "f"]),
    type=st.sampled_from(list(EventType)),
    amount=st.builds(Amount, st.integers(min_value=1, max_value=1_000)),
)


def admitted(sequence: list[Event]) -> tuple[State, list[Event]]:
    """Fold a sequence, skipping what the domain refuses; return the state and what it admitted."""
    state, log = State(), []
    for event in sequence:
        try:
            decision = apply(state, event)
        except InsufficientFunds:
            continue
        if decision.state is not state:
            log.append(event)
        state = decision.state
    return state, log


# provenance: derived
# verifies: units_ledger/conservation
@given(st.lists(events, max_size=40))
def test_any_sequence_conserves_and_never_goes_negative(sequence: list[Event]) -> None:
    state, log = admitted(sequence)
    assert conserved(state, log)
    assert state.balance.minor >= 0
    assert state.version == len(log)


# provenance: derived
# verifies: units_ledger/idempotency
@given(st.lists(events, max_size=40))
def test_reapplying_an_admitted_event_changes_nothing(sequence: list[Event]) -> None:
    state, log = admitted(sequence)
    for event in log:
        assert apply(state, event).state == state


# provenance: derived
# verifies: units_ledger/recovery_rebuild_from_log
@given(st.lists(events, max_size=40))
def test_replaying_the_admitted_log_rebuilds_the_state(sequence: list[Event]) -> None:
    state, log = admitted(sequence)
    assert replay(log) == state


# provenance: derived
# verifies: units_ledger/amount_exactness
@given(st.integers(min_value=0, max_value=10**17 - 1))
def test_format_then_parse_is_the_identity(minor: int) -> None:
    assert Amount.parse(Amount(minor).format()).minor == minor


# provenance: derived
# verifies: units_ledger/amount_exactness
@given(st.text(max_size=60))
def test_parse_only_ever_fails_with_invalid_amount(text: str) -> None:
    try:
        parsed = Amount.parse(text)
    except InvalidAmount:
        return
    assert parsed.minor >= 0


amounts = st.integers(min_value=0, max_value=MAX_MINOR).map(Amount)


# provenance: derived
# verifies: units_ledger/amount_exactness
@given(amounts, amounts)
def test_plus_and_minus_never_exceed_the_bound_and_stay_parseable(a: Amount, b: Amount) -> None:
    try:
        total = a.plus(b)
    except AmountLimitExceeded:
        assert a.minor + b.minor > MAX_MINOR
    else:
        assert total.minor == a.minor + b.minor <= MAX_MINOR
        assert Amount.parse(total.format()) == total
    try:
        diff = a.minus(b)
    except InsufficientFunds:
        assert b.minor > a.minor
    else:
        assert 0 <= diff.minor <= MAX_MINOR


# provenance: derived
# verifies: units_ledger/amount_exactness
@given(st.lists(st.integers(min_value=1, max_value=MAX_MINOR), max_size=12))
def test_every_reachable_balance_round_trips_through_format_and_parse(minors: list[int]) -> None:
    state = State()
    for i, minor in enumerate(minors):
        try:
            state = apply(state, Event(f"e{i}", EventType.DEPOSITED, Amount(minor))).state
        except AmountLimitExceeded:
            continue
        assert state.balance.minor <= MAX_MINOR
        assert Amount.parse(state.balance.format()) == state.balance


# provenance: derived
# verifies: units_ledger/amount_exactness
@given(st.sampled_from(list(EventType)))
def test_a_zero_amount_is_never_an_event(kind: EventType) -> None:
    with pytest.raises(ZeroAmount):
        Event("z", kind, Amount(0))


# provenance: derived
# verifies: units_ledger/amount_exactness
@given(
    st.integers(min_value=0, max_value=10**15 - 1),
    st.text(alphabet="0123456789", min_size=3, max_size=18),
)
def test_more_fraction_digits_than_the_exponent_is_refused(whole: int, fraction: str) -> None:
    with pytest.raises(InvalidAmount):
        Amount.parse(f"{whole}.{fraction}")
