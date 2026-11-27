"""Fitness functions: the zone dependency direction, enforced by reading the sources (ast).

domain    imports only an allowlist of pure standard-library modules and itself
app       never imports adapters or platform
adapters  inbound never imports outbound; outbound never imports app or inbound
platform  never imports app or adapters
config    only platform/config.py touches the process environment
money     no float anywhere in domain or app
"""

import ast
import sys
from dataclasses import dataclass
from pathlib import Path

PACKAGE = "<PACKAGE>"
SRC = Path(__file__).resolve().parents[2] / "src" / PACKAGE

# Everything the domain may import besides itself: pure computation, no I/O, no clock,
# no randomness, no concurrency.
DOMAIN_ALLOWED = frozenset(
    {"__future__", "abc", "collections", "dataclasses", "decimal", "enum", "fractions",
     "functools", "itertools", "math", "operator", "re", "typing"}
)  # fmt: skip
ENV_NAMES = frozenset({"environ", "environb", "getenv", "getenvb", "putenv", "unsetenv"})


@dataclass(frozen=True, slots=True)
class Finding:
    where: str
    what: str


def imported_modules(source: str, module: str, is_package: bool) -> list[tuple[int, str]]:
    """Every absolute module name a source imports (relative imports resolved), with line."""
    found: list[tuple[int, str]] = []
    base = module.split(".") if is_package else module.split(".")[:-1]
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Import):
            found.extend((node.lineno, alias.name) for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                anchor = base[: len(base) - (node.level - 1)]
                target = ".".join([*anchor, *([node.module] if node.module else [])])
            else:
                target = node.module or ""
            found.append((node.lineno, target))
            # `from pkg import sub` may import a submodule: report pkg.sub too.
            found.extend((node.lineno, f"{target}.{alias.name}") for alias in node.names)
        elif isinstance(node, ast.Call):
            func = node.func
            name = func.id if isinstance(func, ast.Name) else getattr(func, "attr", "")
            if name in {"__import__", "import_module"}:
                found.append((node.lineno, "<dynamic import>"))
    return found


def _is_under(name: str, prefix: str) -> bool:
    return name == prefix or name.startswith(prefix + ".")


def forbidden_imports(source: str, module: str, forbidden: tuple[str, ...]) -> list[Finding]:
    return [
        Finding(f"{module}:{line}", name)
        for line, name in imported_modules(source, module, False)
        if any(_is_under(name, f"{PACKAGE}.{zone}") for zone in forbidden)
    ]


def impure_domain_imports(source: str, module: str) -> list[Finding]:
    findings: list[Finding] = []
    for line, name in imported_modules(source, module, False):
        root = name.split(".")[0]
        if name == "<dynamic import>" or not (
            root in DOMAIN_ALLOWED or _is_under(name, f"{PACKAGE}.domain")
        ):
            findings.append(Finding(f"{module}:{line}", name))
    return findings


def float_uses(source: str, module: str) -> list[Finding]:
    findings = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Name) and node.id == "float":
            findings.append(Finding(f"{module}:{node.lineno}", "float"))
        elif isinstance(node, ast.Constant) and isinstance(node.value, float):
            findings.append(Finding(f"{module}:{node.lineno}", f"float literal {node.value}"))
    return findings


def environment_reads(source: str, module: str) -> list[Finding]:
    findings = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Attribute) and node.attr in ENV_NAMES:
            if isinstance(node.value, ast.Name) and node.value.id == "os":
                findings.append(Finding(f"{module}:{node.lineno}", f"os.{node.attr}"))
        elif isinstance(node, ast.ImportFrom) and node.module == "os":
            findings.extend(
                Finding(f"{module}:{node.lineno}", f"from os import {a.name}")
                for a in node.names
                if a.name in ENV_NAMES
            )
    return findings


def sources(zone: str) -> list[tuple[str, str]]:
    """(module name, source) for every .py under a zone; the empty zone is the whole package."""
    root = SRC / zone if zone else SRC
    out = []
    for path in sorted(root.rglob("*.py")):
        parts = path.relative_to(SRC.parent).with_suffix("").parts
        out.append((".".join(parts), path.read_text(encoding="utf-8")))
    return out


def assert_clean(findings: list[Finding], rule: str) -> None:
    assert not findings, f"{rule}: " + "; ".join(f"{f.where} -> {f.what}" for f in findings)


# provenance: derived
# verifies: zones/domain_is_pure
def test_domain_imports_only_pure_standard_library_and_itself() -> None:
    files = sources("domain")
    assert len(files) >= 4  # not vacuous: the zone really was scanned
    assert_clean([f for m, s in files for f in impure_domain_imports(s, m)], "domain purity")


# provenance: derived
# verifies: zones/direction
def test_the_dependency_direction_holds() -> None:
    rules = {
        "app": ("adapters", "platform"),
        "adapters.inbound": ("adapters.outbound",),
        "adapters.outbound": ("app", "adapters.inbound"),
        "platform": ("app", "adapters"),
    }
    for zone, forbidden in rules.items():
        files = sources(zone.replace(".", "/"))
        assert files, f"zone {zone} has no sources"
        findings = [f for m, s in files for f in forbidden_imports(s, m, forbidden)]
        assert_clean(findings, f"{zone} must not import {forbidden}")


# provenance: derived
# verifies: zones/no_float_money
def test_no_float_in_domain_or_app() -> None:
    files = sources("domain") + sources("app")
    assert_clean([f for m, s in files for f in float_uses(s, m)], "no float")


# provenance: derived
# verifies: zones/config_in_one_place
def test_only_platform_config_reads_the_environment() -> None:
    files = sources("")
    assert len(files) >= 15
    findings = [
        f for m, s in files if m != f"{PACKAGE}.platform.config" for f in environment_reads(s, m)
    ]
    assert_clean(findings, "environment read outside platform/config.py")


# provenance: derived
# verifies: zones/domain_is_pure
def test_the_checkers_catch_what_they_guard() -> None:
    module = f"{PACKAGE}.domain.x"
    assert impure_domain_imports("import os", module)
    assert impure_domain_imports("import datetime", module)
    assert impure_domain_imports("import random", module)
    assert impure_domain_imports("import asyncio", module)
    assert impure_domain_imports(f"from {PACKAGE}.adapters import inbound", module)
    assert impure_domain_imports(f"from {PACKAGE}.platform.clock import SystemClock", module)
    assert impure_domain_imports("from .. import app", module)
    assert impure_domain_imports("from ..app import x", module)
    assert impure_domain_imports("__import__('os')", module)
    assert impure_domain_imports("import importlib; importlib.import_module('os')", module)
    assert not impure_domain_imports("import re\nfrom decimal import Decimal", module)
    assert not impure_domain_imports("from . import money", module)
    assert not impure_domain_imports(f"from {PACKAGE}.domain.money import Amount", module)


# provenance: derived
# verifies: zones/direction
def test_the_direction_checker_resolves_relative_and_from_imports() -> None:
    module = f"{PACKAGE}.app.x"
    assert forbidden_imports(f"import {PACKAGE}.adapters.outbound", module, ("adapters",))
    assert forbidden_imports(f"from {PACKAGE} import platform", module, ("platform",))
    assert forbidden_imports("from ..platform import clock", module, ("platform",))
    assert not forbidden_imports("from ..domain import ledger", module, ("platform",))


# provenance: derived
# verifies: zones/no_float_money
def test_the_float_and_environment_checkers_catch_what_they_guard() -> None:
    assert float_uses("x: float = 1", "m")
    assert float_uses("x = 1.5", "m")
    assert not float_uses("x = 15", "m")
    assert environment_reads("import os\nos.environ['A']", "m")
    assert environment_reads("import os\nos.getenv('A')", "m")
    assert environment_reads("from os import environ", "m")
    assert not environment_reads("import os\nos.path.join('a')", "m")


# provenance: derived
# verifies: zones/domain_is_pure
def test_the_stdlib_allowlist_names_real_stdlib_modules() -> None:
    assert set(sys.stdlib_module_names) >= DOMAIN_ALLOWED
