"""Every test says what it verifies, and what it says is declared in production.yaml.

Convention (the Go template's): each test carries, directly above it (above its decorators),

    # provenance: derived
    # verifies: <clause id>[ -- free prose]

and the clause id is declared in ``production.yaml``: a capability clause
``<capability id>/<key under verified>`` or a key under ``implemented``. The shipped tests are
all blocking-lane, so only ``derived`` and ``ratified`` are accepted; ``ratified`` must cite an
entry of ``invariants``, which is empty here, so none may appear. production.yaml is read with
a minimal line scan (no YAML dependency); the scan is exercised on a sample below.
"""

import ast
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "tests"
PROVENANCE = re.compile(r"# provenance: (derived|ratified)")
VERIFIES = re.compile(r"# verifies: ([A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)?)(?: -- .*)?")
NODE = re.compile(r"(tests/[\w/]+\.py)::(test_\w+)")


class Declared:
    """What production.yaml declares: invariants, and clause id -> test node id."""

    def __init__(self, text: str) -> None:
        self.invariants: list[str] = []
        self.clauses: dict[str, str] = {}
        top = capability = block = ""
        for raw in text.splitlines():
            line = raw.split(" #")[0].rstrip()
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            indent = len(line) - len(line.lstrip())
            body = line.strip()
            if indent == 0:
                top, capability, block = body.split(":")[0], "", ""
                if top == "invariants" and body != "invariants: []":
                    block = "invariants"
            elif top == "invariants" and body.startswith("- "):
                self.invariants.append(body[2:].strip())
            elif top == "implemented" and indent == 2 and ": " in body:
                key, value = body.split(": ", 1)
                self.clauses[key] = value.strip()
            elif top == "capabilities":
                if body.startswith("- id: "):
                    capability, block = body[6:].strip(), ""
                elif indent == 4 and body == "verified:":
                    block = "verified"
                elif indent == 4:
                    block = ""
                elif indent == 6 and block == "verified" and ": " in body:
                    key, value = body.split(": ", 1)
                    self.clauses[f"{capability}/{key}"] = value.strip()


DECLARED = Declared((ROOT / "production.yaml").read_text(encoding="utf-8"))


def headers() -> list[tuple[str, int, str, list[str]]]:
    """(file, line, test name, header comment lines) for every test function under tests/."""
    found = []
    for path in sorted(TESTS.rglob("test_*.py")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for node in ast.walk(ast.parse("\n".join(lines))):
            if isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef) and node.name.startswith(
                "test_"
            ):
                first = min([d.lineno for d in node.decorator_list] + [node.lineno])
                block: list[str] = []
                at = first - 2  # index of the line directly above the decorators/def
                while at >= 0 and lines[at].lstrip().startswith("#"):
                    block.insert(0, lines[at].strip())
                    at -= 1
                found.append((path.relative_to(ROOT).as_posix(), node.lineno, node.name, block))
    return found


HEADERS = headers()


def cited(block: list[str]) -> tuple[str, str] | None:
    """(class, clause id) when the block is a well-formed header, else None."""
    provenance = [m.group(1) for ln in block if (m := PROVENANCE.fullmatch(ln))]
    verifies = [m.group(1) for ln in block if (m := VERIFIES.fullmatch(ln))]
    if len(provenance) == 1 and len(verifies) == 1:
        return provenance[0], verifies[0]
    return None


# provenance: derived
# verifies: provenance_headers
def test_there_are_tests_to_check() -> None:
    assert len(HEADERS) > 100


# provenance: derived
# verifies: provenance_headers
@pytest.mark.parametrize(
    ("path", "line", "name", "block"), HEADERS, ids=[f"{h[0]}::{h[2]}" for h in HEADERS]
)
def test_every_test_carries_a_header_in_the_accepted_grammar(
    path: str, line: int, name: str, block: list[str]
) -> None:
    assert cited(block) is not None, f"{path}:{line} {name}: missing or malformed header"


# provenance: derived
# verifies: provenance_headers
def test_every_cited_clause_is_declared_in_production_yaml() -> None:
    unknown = []
    for path, line, name, block in HEADERS:
        header = cited(block)
        if header and header[1] not in DECLARED.clauses:
            unknown.append(f"{path}:{line} {name} cites {header[1]!r}")
    assert unknown == []


# provenance: derived
# verifies: provenance_headers
def test_no_test_is_ratified_while_no_invariant_is_ratified() -> None:
    ratified = [f"{p}:{n}" for p, _, n, b in HEADERS if (h := cited(b)) and h[0] == "ratified"]
    cites_invariant = [
        f"{p}:{n}" for p, _, n, b in HEADERS if (h := cited(b)) and h[1] in DECLARED.invariants
    ]
    if DECLARED.invariants:
        assert all(x in cites_invariant for x in ratified)
    else:
        assert ratified == [] == cites_invariant


# provenance: derived
# verifies: provenance_headers
@pytest.mark.parametrize(("clause", "node"), sorted(DECLARED.clauses.items()))
def test_every_declared_clause_names_a_test_that_exists_and_cites_it(
    clause: str, node: str
) -> None:
    match = NODE.fullmatch(node)
    assert match, f"{clause}: {node!r} is not a tests/...py::test_name node id"
    path, name = match.groups()
    found = [b for p, _, n, b in HEADERS if p == path and n == name]
    assert len(found) == 1, f"{clause}: no test {node}"
    header = cited(found[0])
    assert header is not None
    assert header[1] == clause, f"{node} cites {header[1]!r}, not {clause!r}"


# provenance: derived
# verifies: provenance_headers
def test_the_scan_reads_a_sample_the_way_the_file_is_laid_out() -> None:
    sample = Declared(
        "invariants:\n  - conserved\ncapabilities:\n  - id: cap\n    class: x\n"
        "    verified:\n      one: tests/a.py::test_a  # note\n      two: tests/b.py::test_b\n"
        "    semantics:\n      three: not-a-clause\n"
        "implemented:\n  # c\n  four: tests/c.py::test_c\n"
    )
    assert sample.invariants == ["conserved"]
    assert sample.clauses == {
        "cap/one": "tests/a.py::test_a",
        "cap/two": "tests/b.py::test_b",
        "four": "tests/c.py::test_c",
    }
    assert Declared("invariants: []\n").invariants == []


def gate_targets() -> list[str]:
    """The make targets production.yaml's `gates:` block names (`  cheap: "make check-fast"`)."""
    text = (ROOT / "production.yaml").read_text(encoding="utf-8")
    block = text.split("\ngates:\n", 1)[1].split("\n\n", 1)[0] if "\ngates:\n" in text else ""
    lines = [line.split(" #")[0].rstrip() for line in block.splitlines()]
    matches = [re.fullmatch(r'  [a-z_]+: "make ([a-z][a-z-]*)"', line) for line in lines]
    return [m.group(1) for m in matches if m]


# provenance: derived
# verifies: gates_exist
def test_every_gate_production_yaml_names_is_a_real_make_target_with_a_recipe() -> None:
    targets = gate_targets()
    assert sorted(targets) == ["check-fast", "verify"]
    rules: dict[str, list[str]] = {}
    phony: set[str] = set()
    current = ""
    for line in (ROOT / "Makefile").read_text(encoding="utf-8").splitlines():
        if line.startswith(".PHONY:"):
            phony |= set(line.split(":", 1)[1].split())
        elif m := re.fullmatch(r"([a-z][a-z-]*):(.*)", line):
            current = m.group(1)
            rules[current] = [p for p in m.group(2).split() if p]
        elif line.startswith("\t") and line.strip() and current:
            rules[current].append(line.strip())
        elif line.strip() and not line.startswith("#"):
            current = ""
    for target in targets:
        assert target in phony, f"{target} is not .PHONY"
        assert rules.get(target), f"{target} has no recipe and no prerequisite"
    assert any("uv run pytest" in part for part in rules["check-fast"])
    assert "check-fast" in rules["verify"]
