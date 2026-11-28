"""The observability contract: manifests == emitted signals, in both directions.

Static half: every counter/gauge/span call in src/ (read with ast) against the manifests.
Runtime half: a real /metrics scrape of the wired service against the metrics manifest.
"""

import json
import re
from pathlib import Path

import pytest

from <PACKAGE>.__main__ import (
    build,
)
from <PACKAGE>.domain.errors import (
    InsufficientFunds,
)
from <PACKAGE>.platform.config import (
    Config,
)

from tests.support import emissions, manifest

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "src" / "<PACKAGE>"
METRICS = manifest.load(ROOT / "observability" / "emitted-metrics.yaml", manifest.METRIC_FIELDS)
SPANS = manifest.load(ROOT / "observability" / "spans.yaml", manifest.SPAN_FIELDS)
EMITTED = emissions.scan_tree(SRC)
EMITTED_METRICS = [e for e in EMITTED if e.method in {"counter", "gauge"}]
EMITTED_SPANS = [e for e in EMITTED if e.method == "span"]


def diff(declared: set[str], emitted: set[str], what: str) -> str:
    return (
        f"{what}: emitted but undeclared {sorted(emitted - declared)}; "
        f"declared but never emitted {sorted(declared - emitted)}"
    )


# provenance: derived
# verifies: health_metrics_surface/observability_contract_checked
def test_signal_names_are_string_literals_at_every_call_site() -> None:
    assert EMITTED, "no emission found: the scan is vacuous"
    dynamic = [e.where for e in EMITTED if e.name is None]
    assert not dynamic, f"signal name is not a string literal at {dynamic}"
    forwarded = [e.where for e in EMITTED if "**" in e.keys]
    assert not forwarded, f"labels forwarded with ** at {forwarded}"


# provenance: derived
# verifies: health_metrics_surface/observability_contract_checked
def test_emitted_metrics_equal_the_metrics_manifest() -> None:
    declared = {m.name for m in METRICS}
    emitted = {e.name for e in EMITTED_METRICS if e.name is not None}
    assert declared == emitted, diff(declared, emitted, "metrics")


# provenance: derived
# verifies: health_metrics_surface/observability_contract_checked
def test_each_metric_is_emitted_with_its_declared_type_and_label_set() -> None:
    declared = {m.name: m for m in METRICS}
    for e in EMITTED_METRICS:
        entry = declared[e.name or ""]
        assert e.method == entry.fields["type"], f"{e.where}: {e.name} is a {entry.fields['type']}"
        assert e.keys == set(entry.fields["labels"]), f"{e.where}: label set {sorted(e.keys)}"


# provenance: derived
# verifies: health_metrics_surface/observability_contract_checked
def test_emitted_spans_equal_the_spans_manifest() -> None:
    declared = {s.name for s in SPANS}
    emitted = {e.name for e in EMITTED_SPANS if e.name is not None}
    assert declared == emitted, diff(declared, emitted, "spans")
    by_name = {s.name: s for s in SPANS}
    for e in EMITTED_SPANS:
        assert e.keys == set(by_name[e.name or ""].fields["attrs"]), (
            f"{e.where}: attrs {sorted(e.keys)}"
        )


# provenance: derived
# verifies: health_metrics_surface/observability_contract_checked
def test_every_span_names_the_file_that_emits_it() -> None:
    for span in SPANS:
        emitted_by = span.fields["emitted_by"]
        assert isinstance(emitted_by, str)
        relative = emitted_by.split(" ")[0]
        path = ROOT / relative
        assert path.is_file(), f"{span.name}: emitted_by {relative} does not exist"
        assert f'"{span.name}"' in path.read_text(encoding="utf-8"), (
            f"{span.name} not in {relative}"
        )


# provenance: derived
# verifies: health_metrics_surface/observability_contract_checked
def test_a_real_scrape_matches_the_metrics_manifest_both_ways() -> None:
    runtime = build(Config("127.0.0.1", 0, "t" * 16, "rev"))
    runtime.service.deposit("5.00")
    runtime.service.withdraw("1.00")
    with pytest.raises(InsufficientFunds):
        runtime.service.withdraw("100.00")
    text = runtime.api.handle("GET", "/metrics", {}, b"").body.decode()
    scraped = set(re.findall(r"^# TYPE (\S+) (counter|gauge)$", text, re.MULTILINE))
    declared = {(m.name, str(m.fields["type"])) for m in METRICS}
    assert scraped == declared, (
        diff({n for n, _ in declared}, {n for n, _ in scraped}, "scrape")
        + f" (types: {sorted(scraped ^ declared)})"
    )
    for line in text.splitlines():
        if line.startswith("#"):
            continue
        series = re.fullmatch(r"(\w+)(?:\{(.*)\})? -?\d+", line)
        assert series is not None, f"unparseable series line {line!r}"
        entry = next(m for m in METRICS if m.name == series[1])
        keys = set(re.findall(r'(\w+)="', series[2] or ""))
        assert keys == set(entry.fields["labels"]), f"{series[1]} labels {sorted(keys)}"
    assert json.loads(runtime.api.handle("GET", "/healthz", {}, b"").body)["status"] == "ok"
