import threading
from datetime import UTC, datetime

import pytest

from <PACKAGE>.adapters.outbound.memory_store import (
    InMemoryEventStore,
)
from <PACKAGE>.app.ledger_service import (
    LedgerService,
)
from <PACKAGE>.app.ports import (
    EventStore,
)
from <PACKAGE>.domain.errors import (
    AmountLimitExceeded,
    InsufficientFunds,
    InvalidAmount,
    ZeroAmount,
)
from <PACKAGE>.domain.ledger import (
    Event,
    Outcome,
)
from <PACKAGE>.domain.money import (
    Amount,
)
from <PACKAGE>.platform.clock import (
    ManualClock,
)
from <PACKAGE>.platform.ids import (
    SequenceIds,
)

from tests.support.recorders import SpyRecorder

START = datetime(2026, 1, 1, tzinfo=UTC)


def make(store: EventStore | None = None) -> tuple[LedgerService, EventStore, SpyRecorder]:
    store = store if store is not None else InMemoryEventStore()
    spy = SpyRecorder()
    return LedgerService(store, ManualClock(START), SequenceIds(), spy), store, spy


# provenance: derived
# verifies: units_ledger/conservation
def test_deposit_and_withdraw_move_the_balance_and_verify() -> None:
    service, _, _ = make()
    service.deposit("10.00")
    receipt = service.withdraw("2.50")
    assert receipt.balance == Amount(750)
    assert service.balance().format() == "7.50"
    assert service.verify()


# provenance: derived
# verifies: units_ledger/idempotency
def test_a_repeated_event_id_is_journaled_and_counted_once() -> None:
    service, store, spy = make()
    first = service.deposit("5.00", event_id="k1")
    again = service.deposit("5.00", event_id="k1")
    assert (first.outcome, again.outcome) == (Outcome.APPLIED, Outcome.DUPLICATE)
    assert service.balance() == Amount(500)
    assert len(store.load()) == 1
    assert [labels["outcome"] for _, labels in spy.counters] == ["applied", "duplicate"]


# provenance: derived
# verifies: units_ledger/no_overdraft
def test_an_overdraft_is_refused_counted_and_not_journaled() -> None:
    service, store, spy = make()
    with pytest.raises(InsufficientFunds):
        service.withdraw("1.00")
    assert store.load() == ()
    assert spy.counters == [("svc_commands_total", {"command": "withdraw", "outcome": "rejected"})]


# provenance: derived
# verifies: units_ledger/amount_exactness
def test_an_invalid_amount_is_refused_and_counted() -> None:
    service, store, spy = make()
    with pytest.raises(InvalidAmount):
        service.deposit("1e3")
    assert store.load() == ()
    assert spy.counters == [
        ("svc_commands_total", {"command": "deposit", "outcome": "invalid_amount"})
    ]


# provenance: derived
# verifies: units_ledger/recovery_rebuild_from_log
def test_a_new_service_over_the_same_log_rebuilds_the_state() -> None:
    first, store, _ = make()
    first.deposit("3.00")
    first.deposit("4.00")
    second, _, _ = make(store)
    assert second.balance() == Amount(700)
    assert second.verify()


class BrokenStore:
    def append(self, _event: Event, _recorded_at: datetime) -> None:
        raise OSError("disk full")

    def load(self) -> tuple[Event, ...]:
        return ()


# provenance: derived
# verifies: units_ledger/journal_before_state
def test_a_failing_journal_leaves_the_state_unchanged() -> None:
    service, _, _ = make(BrokenStore())
    with pytest.raises(OSError, match="disk full"):
        service.deposit("1.00")
    assert service.balance() == Amount(0)


# provenance: derived
# verifies: units_ledger/journal_before_state
def test_the_journal_records_the_clock_time() -> None:
    class Spy(InMemoryEventStore):
        times: list[datetime]

        def append(self, event: Event, recorded_at: datetime) -> None:
            self.times = [*getattr(self, "times", []), recorded_at]
            super().append(event, recorded_at)

    store = Spy()
    service, _, _ = make(store)
    service.deposit("1.00")
    assert store.times == [START]


# provenance: derived
# verifies: units_ledger/single_writer
def test_concurrent_deposits_are_all_counted() -> None:
    service, _, _ = make()
    workers = [
        threading.Thread(target=lambda: [service.deposit("1.00") for _ in range(50)])
        for _ in range(8)
    ]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join()
    assert service.balance() == Amount(40_000)
    assert service.verify()


# provenance: derived
# verifies: health_metrics_surface/spans
def test_each_command_runs_inside_its_span_and_sets_the_balance_gauge() -> None:
    service, _, spy = make()
    service.deposit("1.00")
    service.withdraw("1.00")
    assert spy.spans == [
        ("svc.deposit", {"event_type": "deposited"}),
        ("svc.withdraw", {"event_type": "withdrawn"}),
    ]
    assert spy.gauges == [
        ("svc_ledger_balance_minor", 100, {}),
        ("svc_ledger_balance_minor", 0, {}),
    ]


# provenance: derived
# verifies: units_ledger/amount_exactness
@pytest.mark.parametrize("text", ["0", "0.00"])
def test_a_zero_amount_is_refused_counted_and_not_journaled(text: str) -> None:
    service, store, spy = make()
    with pytest.raises(ZeroAmount):
        service.deposit(text)
    assert store.load() == ()
    assert spy.counters == [
        ("svc_commands_total", {"command": "deposit", "outcome": "invalid_amount"})
    ]


# provenance: derived
# verifies: units_ledger/amount_exactness
def test_an_amount_with_extra_fraction_digits_is_refused_not_rounded() -> None:
    service, store, _ = make()
    with pytest.raises(InvalidAmount):
        service.deposit("0.005")
    assert store.load() == ()
    assert service.balance() == Amount(0)


# provenance: derived
# verifies: units_ledger/amount_exactness
def test_two_maximum_deposits_are_refused_and_the_balance_stays_parseable() -> None:
    service, store, spy = make()
    service.deposit("999999999999999.99")
    with pytest.raises(AmountLimitExceeded):
        service.deposit("0.01")
    assert len(store.load()) == 1
    assert Amount.parse(service.balance().format()) == service.balance()
    assert spy.counters[-1] == (
        "svc_commands_total",
        {"command": "deposit", "outcome": "rejected"},
    )
    assert service.verify()


# provenance: derived
# verifies: units_ledger/amount_exactness
def test_an_amount_over_the_bound_is_refused_as_invalid() -> None:
    service, store, _ = make()
    with pytest.raises(InvalidAmount):
        service.deposit("1000000000000000.00")
    assert store.load() == ()
