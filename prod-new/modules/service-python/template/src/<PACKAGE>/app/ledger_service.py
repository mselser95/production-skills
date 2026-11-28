"""The ledger use-cases: deposit and withdraw, journaled before the state advances."""

import threading
from dataclasses import dataclass

from <PACKAGE>.app.ports import (
    Clock,
    EventStore,
    IdGenerator,
    Recorder,
)
from <PACKAGE>.domain.errors import (
    AmountLimitExceeded,
    InsufficientFunds,
    InvalidAmount,
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
    Amount,
)


@dataclass(frozen=True, slots=True)
class Receipt:
    event_id: str
    outcome: Outcome
    balance: Amount


class LedgerService:
    """Single writer: one lock serialises the read-modify-write of the in-memory state."""

    def __init__(
        self, store: EventStore, clock: Clock, ids: IdGenerator, recorder: Recorder
    ) -> None:
        self._store = store
        self._clock = clock
        self._ids = ids
        self._recorder = recorder
        self._lock = threading.Lock()
        self._state: State = replay(store.load())

    def balance(self) -> Amount:
        with self._lock:
            return self._state.balance

    def verify(self) -> bool:
        """Check the conservation invariant of the live state against the log (O(n), on demand)."""
        with self._lock:
            return conserved(self._state, self._store.load())

    def deposit(self, amount: str, event_id: str | None = None) -> Receipt:
        with self._recorder.span("svc.deposit", event_type=EventType.DEPOSITED.value):
            return self._process(EventType.DEPOSITED, "deposit", amount, event_id)

    def withdraw(self, amount: str, event_id: str | None = None) -> Receipt:
        with self._recorder.span("svc.withdraw", event_type=EventType.WITHDRAWN.value):
            return self._process(EventType.WITHDRAWN, "withdraw", amount, event_id)

    def _process(self, kind: EventType, command: str, amount: str, event_id: str | None) -> Receipt:
        try:
            parsed = Amount.parse(amount)
            event = Event(event_id if event_id is not None else self._ids.new_id(), kind, parsed)
        except InvalidAmount:  # unparseable, over the bound or zero: the client's input
            self._recorder.counter("svc_commands_total", command=command, outcome="invalid_amount")
            raise
        with self._lock:
            try:
                decision = apply(self._state, event)
            except (InsufficientFunds, AmountLimitExceeded):
                self._recorder.counter("svc_commands_total", command=command, outcome="rejected")
                raise
            if decision.outcome is Outcome.APPLIED:
                # Journal first: if the store fails, the state has not advanced.
                self._store.append(event, self._clock.now())
                self._state = decision.state
            self._recorder.counter(
                "svc_commands_total", command=command, outcome=decision.outcome.value
            )
            self._recorder.gauge("svc_ledger_balance_minor", self._state.balance.minor)
            return Receipt(event.id, decision.outcome, self._state.balance)
