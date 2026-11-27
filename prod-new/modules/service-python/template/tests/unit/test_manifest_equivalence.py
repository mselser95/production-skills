from pathlib import Path

import pytest

from tests.support.manifest import METRIC_FIELDS, SPAN_FIELDS, load

ROOT = Path(__file__).resolve().parents[2]


# provenance: derived
# verifies: health_metrics_surface/manifest_parser
@pytest.mark.parametrize(
    ("file", "allowed"),
    [("emitted-metrics.yaml", METRIC_FIELDS), ("spans.yaml", SPAN_FIELDS)],
)
def test_the_parser_equals_pyyaml_on_the_real_manifests(file: str, allowed: set[str]) -> None:
    yaml = pytest.importorskip("yaml", reason="PyYAML not installed: equivalence not checked")
    path = ROOT / "observability" / file
    expected = yaml.safe_load(path.read_text(encoding="utf-8"))
    entries = load(path, allowed)
    assert len(entries) == len(expected) > 0
    for entry, want in zip(entries, expected, strict=True):
        assert set(entry.fields) == set(want)
        for key, value in want.items():
            # a YAML folded scalar (clip chomping) ends in one newline; the parser's does not
            norm = list(value) if isinstance(value, list) else value.rstrip("\n")
            got = entry.fields[key]
            assert (list(got) if isinstance(got, tuple) else got) == norm, f"{entry.name}.{key}"
