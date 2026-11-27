"""The ledger decision function: apply(state, event) -> decision.

Idempotent by event id: applying the same id twice has the economic effect once. The state
is immutable; ``version`` counts events actually admitted (a duplicate does not bump it).
Limitation, deliberate and shared with the reference template: a duplicate is recognised by
id alone, a repeated id carrying a different amount is treated as the same event.
"""

from collections.abc import Iterable
from dataclasses import dataclass, field
from enum import Enum

from <PACKAGE>.domain.errors import InvalidEvent
from <PACKAGE>.domain.money import Amount

MAX_EVENT_ID_LENGTH = 128


class EventType(Enum):
    DEPOSITED = "deposited"
    WITHDRAWN = "withdrawn"


class Outcome(Enum):
    APPLIED = "applied"
    DUPLICATE = "duplicate"


@dataclass(frozen=True, slots=True)
class Event:
    id: str
    type: EventType
    amount: Amount

    def __post_init__(self) -> None:
        if not isinstance(self.id, str) or not 0 < len(self.id) <= MAX_EVENT_ID_LENGTH:
            raise InvalidEvent("an event id is 1 to 128 characters")


@dataclass(frozen=True, slots=True)
class State:
    balance: Amount = field(default_factory=lambda: Amount(0))
    applied: frozenset[str] = frozenset()
    version: int = 0


@dataclass(frozen=True, slots=True)
class Decision:
    state: State
    outcome: Outcome


def apply(state: State, event: Event) -> Decision:
    """Fold one event into the state. Raises InsufficientFunds on an uncovered withdrawal."""
    if event.id in state.applied:
        return Decision(state, Outcome.DUPLICATE)
    if event.type is EventType.DEPOSITED:
        balance = state.balance.plus(event.amount)
    else:
        balance = state.balance.minus(event.amount)
    admitted = State(balance, state.applied | {event.id}, state.version + 1)
    return Decision(admitted, Outcome.APPLIED)


def replay(events: Iterable[Event]) -> State:
    """Rebuild the state from an event log."""
    state = State()
    for event in events:
        state = apply(state, event).state
    return state


def conserved(state: State, events: Iterable[Event]) -> bool:
    """Invariant: the balance equals deposits minus withdrawals of the distinct admitted events."""
    seen: set[str] = set()
    total = 0
    for event in events:
        if event.id in seen:
            continue
        seen.add(event.id)
        total += event.amount.minor if event.type is EventType.DEPOSITED else -event.amount.minor
    return state.balance.minor == total and seen == state.applied
