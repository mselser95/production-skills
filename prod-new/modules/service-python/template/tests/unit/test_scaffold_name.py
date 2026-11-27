"""The scaffolded package name must be one a Python project can actually use.

The assembler checks the SHAPE of a slot (charset, length); it cannot know that ``class`` is
a keyword, that ``json`` would shadow the standard library, or that ``tests`` would collide
with this directory. These tests run in every scaffolded repo and know.
"""

import importlib
import keyword
import re
import sys
import tomllib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
IDENTIFIER = re.compile(r"[a-z_][a-z0-9_]*")
# The one package under src/: read from the tree, never typed in, and not imported here, so a
# name that cannot be imported (`class`, `json`) still fails on its reason, not at collection.
PACKAGES = sorted(p.name for p in (ROOT / "src").iterdir() if p.is_dir())
PACKAGE = PACKAGES[0] if len(PACKAGES) == 1 else ""


def problems(name: str) -> list[str]:
    """Every reason `name` is unusable as the package of this service (empty = usable)."""
    found = []
    if not IDENTIFIER.fullmatch(name):
        found.append("not a lowercase identifier ([a-z_][a-z0-9_]*)")
    if keyword.iskeyword(name) or keyword.issoftkeyword(name):
        found.append("a Python keyword or soft keyword")
    if name in sys.stdlib_module_names:
        found.append("shadows a standard-library module")
    if name == "tests":
        found.append("collides with this repository's tests package")
    return found


# provenance: derived
# verifies: package_name_usable
def test_the_installed_package_name_is_usable() -> None:
    assert PACKAGE, f"expected exactly one package under src/, found {PACKAGES}"
    assert problems(PACKAGE) == [], f"package {PACKAGE!r} cannot be used"


# provenance: derived
# verifies: package_name_usable
def test_the_package_under_src_is_the_one_that_imports() -> None:
    assert importlib.import_module(f"{PACKAGE}.__main__").__package__ == PACKAGE


# provenance: derived
# verifies: package_name_usable
@pytest.mark.parametrize(
    ("name", "expected"),
    [
        ("ledger_svc", []),
        ("_ledger", []),
        ("class", ["a Python keyword or soft keyword"]),
        ("match", ["a Python keyword or soft keyword"]),
        ("json", ["shadows a standard-library module"]),
        ("tests", ["collides with this repository's tests package"]),
        ("ledger-svc", ["not a lowercase identifier ([a-z_][a-z0-9_]*)"]),
        ("1ledger", ["not a lowercase identifier ([a-z_][a-z0-9_]*)"]),
        ("Ledger", ["not a lowercase identifier ([a-z_][a-z0-9_]*)"]),
    ],
)
def test_the_name_rules_refuse_what_they_claim_to_refuse(name: str, expected: list[str]) -> None:
    assert problems(name) == expected


# provenance: derived
# verifies: package_name_usable
def test_pyproject_agrees_with_the_package_name() -> None:
    project = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    distribution = project["project"]["name"]
    assert distribution == PACKAGE.replace("_", "-")
    assert project["tool"]["uv"]["build-backend"]["module-name"] == PACKAGE
    assert project["tool"]["ruff"]["lint"]["isort"]["known-first-party"] == [PACKAGE]
    scripts = project["project"]["scripts"]
    assert scripts == {distribution: f"{PACKAGE}.__main__:main"}
