"""Recorders: a Prometheus-text metrics recorder and a no-op.

Spans are accepted and not exported: exporter wiring (OpenTelemetry) is a later step; the
call sites and the manifest (observability/spans.yaml) are already contract-checked.
"""

import threading
from collections.abc import Mapping
from contextlib import AbstractContextManager, nullcontext

_LabelKey = tuple[tuple[str, str], ...]


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _series(name: str, key: _LabelKey) -> str:
    if not key:
        return name
    return name + "{" + ",".join(f'{k}="{_escape(v)}"' for k, v in key) + "}"


class NullRecorder:
    def counter(self, name: str, /, **labels: str) -> None:
        pass

    def gauge(self, name: str, value: int, /, **labels: str) -> None:
        pass

    def span(self, _name: str, /, **_attrs: str) -> AbstractContextManager[None]:
        return nullcontext()


class MetricsRecorder(NullRecorder):
    """Thread-safe in-process counters and gauges, rendered in the Prometheus text format."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._counters: dict[str, dict[_LabelKey, int]] = {}
        self._gauges: dict[str, dict[_LabelKey, int]] = {}

    def counter(self, name: str, /, **labels: str) -> None:
        key = tuple(sorted(labels.items()))
        with self._lock:
            series = self._counters.setdefault(name, {})
            series[key] = series.get(key, 0) + 1

    def gauge(self, name: str, value: int, /, **labels: str) -> None:
        key = tuple(sorted(labels.items()))
        with self._lock:
            self._gauges.setdefault(name, {})[key] = value

    def render(self) -> str:
        with self._lock:
            families: list[tuple[str, str, Mapping[_LabelKey, int]]] = [
                *((n, "counter", s) for n, s in self._counters.items()),
                *((n, "gauge", s) for n, s in self._gauges.items()),
            ]
            lines: list[str] = []
            for name, kind, series in sorted(families, key=lambda f: f[0]):
                lines.append(f"# TYPE {name} {kind}")
                lines.extend(
                    f"{_series(name, key)} {value}" for key, value in sorted(series.items())
                )
        return "\n".join(lines) + "\n"
