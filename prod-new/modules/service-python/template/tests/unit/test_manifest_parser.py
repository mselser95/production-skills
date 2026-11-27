from pathlib import Path

import pytest

from tests.support.manifest import METRIC_FIELDS, SPAN_FIELDS, ManifestError, load, parse

GOOD = """\
# comment
- name: m_total
  type: counter
  labels: [a, b]
  note: >
    folded text
    continues
"""


# provenance: derived
# verifies: health_metrics_surface/manifest_parser
def test_the_accepted_subset_parses() -> None:
    (entry,) = parse(GOOD, METRIC_FIELDS)
    assert entry.name == "m_total"
    assert entry.fields["labels"] == ("a", "b")
    assert entry.fields["note"] == "folded text continues"
    assert parse(GOOD.replace("[a, b]", "[]"), METRIC_FIELDS)[0].fields["labels"] == ()


# provenance: derived
# verifies: health_metrics_surface/manifest_parser
@pytest.mark.parametrize(
    "broken",
    [
        GOOD.replace("type:", "kind:"),
        GOOD.replace("  labels: [a, b]\n", ""),
        GOOD.replace("  type: counter", "\ttype: counter"),
        GOOD.replace("[a, b]", "[a, b"),
        GOOD + "  type: gauge\n",
        GOOD + "stray line\n",
        GOOD + GOOD,
        "- type: counter\n",
        GOOD.replace("type: counter", "type:"),
        GOOD.replace("note: >\n    folded text\n    continues\n", "note: >\n\n    folded text\n"),
    ],
)
def test_anything_outside_the_subset_is_refused(broken: str) -> None:
    with pytest.raises(ManifestError):
        parse(broken, METRIC_FIELDS)


ROOT = Path(__file__).resolve().parents[2]


# provenance: derived
# verifies: health_metrics_surface/manifest_parser
def test_the_real_manifests_parse() -> None:
    assert load(ROOT / "observability" / "emitted-metrics.yaml", METRIC_FIELDS)
    assert load(ROOT / "observability" / "spans.yaml", SPAN_FIELDS)


REFUSED = {
    "double quotes": ("name: m_total", 'name: "m_total"'),
    "single quotes": ("name: m_total", "name: 'm_total'"),
    "inline comment": ("type: counter", "type: counter # c"),
    "null name": ("name: m_total", "name: null"),
    "tilde name": ("name: m_total", "name: ~"),
    "bool name": ("name: m_total", "name: True"),
    "yes type": ("type: counter", "type: yes"),
    "number name": ("name: m_total", "name: 12"),
    "float note": ("note: >\n    folded text\n    continues\n", "note: 1.5\n"),
    "double quoted note": ("note: >\n    folded text\n    continues\n", 'note: "x"\n'),
    "single quoted note": ("note: >\n    folded text\n    continues\n", "note: 'x'\n"),
    "inline comment in note": ("note: >\n    folded text\n    continues\n", "note: x # c\n"),
    "colon space in note": ("note: >\n    folded text\n    continues\n", "note: a: b\n"),
    "null note": ("note: >\n    folded text\n    continues\n", "note: null\n"),
    "empty type": ("type: counter", "type:"),
    "scalar labels": ("labels: [a, b]", "labels: ab"),
    "list type": ("type: counter", "type: [counter]"),
    "trailing comma": ("[a, b]", "[a, b,]"),
    "empty item": ("[a, b]", "[a, , b]"),
    "nested brackets": ("[a, b]", "[a, [b]]"),
    "quoted item": ("[a, b]", '[a, "b"]'),
    "colon space in value": ("type: counter", "type: a: b"),
    "trailing colon": ("type: counter", "type: counter:"),
    "tab": ("  type: counter", "\ttype: counter"),
    "duplicate key": ("  type: counter\n", "  type: counter\n  type: gauge\n"),
    "anchor": ("name: m_total", "name: &x m_total"),
    "alias": ("name: m_total", "name: *x"),
    "tag": ("type: counter", "type: !!str counter"),
    "document marker": ("# comment", "---"),
    "bom": ("# comment", "\ufeff# comment"),
    "crlf": ("type: counter\n", "type: counter\r\n"),
    "bad type": ("type: counter", "type: histogram"),
    "bad name": ("name: m_total", "name: m-total"),
    "dotted metric name": ("name: m_total", "name: m.total"),
    "trailing space": ("type: counter", "type: counter "),
}


# provenance: derived
# verifies: health_metrics_surface/manifest_parser
@pytest.mark.parametrize("case", sorted(REFUSED))
def test_each_yaml_divergence_is_refused_naming_the_line(case: str) -> None:
    old, new = REFUSED[case]
    assert old in GOOD
    broken = GOOD.replace(old, new)
    with pytest.raises(ManifestError, match=r"line \d+"):
        parse(broken, METRIC_FIELDS)


# provenance: derived
# verifies: health_metrics_surface/manifest_parser
def test_a_duplicate_entry_name_is_refused_naming_both_lines() -> None:
    with pytest.raises(ManifestError, match=r"line 8: duplicate entry name .*line 2"):
        parse(GOOD + GOOD.split("\n", 1)[1], METRIC_FIELDS)
