"""Ports, declared where they are consumed and satisfied structurally by adapters and platform."""

from collections.abc import Sequence
from contextlib import AbstractContextManager
from datetime import datetime
from typing import Protocol

from <PACKAGE>.domain.ledger import Event


class Clock(Protocol):
    def now(self) -> datetime:
        """The current time, timezone-aware."""
        ...


class IdGenerator(Protocol):
    def new_id(self) -> str:
        """A fresh unique event id."""
        ...


class EventStore(Protocol):
    """Append-only event log."""

    def append(self, event: Event, recorded_at: datetime, /) -> None: ...

    def load(self) -> Sequence[Event]:
        """Every appended event, in order."""
        ...


class Recorder(Protocol):
    """Where observability signals go. Every name must be declared in observability/*.yaml.

    Signal names and label keys must be string literals at the call site: the contract test
    reads the source to compare them with the manifests.
    """

    def counter(self, name: str, /, **labels: str) -> None: ...

    def gauge(self, name: str, value: int, /, **labels: str) -> None: ...

    def span(self, name: str, /, **attrs: str) -> AbstractContextManager[None]: ...
