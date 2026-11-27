"""A recording Recorder for tests."""

from collections.abc import Iterator
from contextlib import AbstractContextManager, contextmanager


class SpyRecorder:
    def __init__(self) -> None:
        self.counters: list[tuple[str, dict[str, str]]] = []
        self.gauges: list[tuple[str, int, dict[str, str]]] = []
        self.spans: list[tuple[str, dict[str, str]]] = []

    def counter(self, name: str, /, **labels: str) -> None:
        self.counters.append((name, labels))

    def gauge(self, name: str, value: int, /, **labels: str) -> None:
        self.gauges.append((name, value, labels))

    def span(self, name: str, /, **attrs: str) -> AbstractContextManager[None]:
        return self._span(name, attrs)

    @contextmanager
    def _span(self, name: str, attrs: dict[str, str]) -> Iterator[None]:
        self.spans.append((name, attrs))
        yield
