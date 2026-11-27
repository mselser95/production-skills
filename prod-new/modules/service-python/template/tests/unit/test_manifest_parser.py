import pytest

from tests.support.manifest import METRIC_FIELDS, ManifestError, parse

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
