"""An in-memory, thread-safe event log. State lives for the process lifetime only."""

import threading
from datetime import datetime

from <PACKAGE>.domain.ledger import Event


class InMemoryEventStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._events: list[Event] = []
        self._recorded_at: list[datetime] = []

    def append(self, event: Event, recorded_at: datetime) -> None:
        with self._lock:
            self._events.append(event)
            self._recorded_at.append(recorded_at)

    def load(self) -> tuple[Event, ...]:
        with self._lock:
            return tuple(self._events)
