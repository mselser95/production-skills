"""Fitness functions: the zone dependency direction, enforced by reading the sources (ast).

domain    imports only an allowlist of pure standard-library modules and itself
app       never imports adapters or platform
adapters  inbound never imports outbound; outbound never imports app or inbound
platform  never imports app or adapters
config    only platform/config.py touches the process environment
money     no float anywhere in domain or app
purity    domain and app: no I/O or reflection builtins, no true division, no float/clock/
          randomness/I-O members (aliases resolved), app imports no clock/random/I-O module
"""

import ast
import sys
from dataclasses import dataclass
from pathlib import Path

import pytest

PACKAGE = "<PACKAGE>"
SRC = Path(__file__).resolve().parents[2] / "src" / PACKAGE

# Everything the domain may import besides itself: pure computation, no I/O, no clock,
# no randomness, no concurrency. Deliberately absent: math (float functions), operator
# (truediv/pow/attrgetter reach what the AST rules ban), datetime, os, random.
DOMAIN_ALLOWED = frozenset(
    {"__future__", "abc", "collections", "dataclasses", "decimal", "enum", "fractions",
     "functools", "itertools", "re", "typing"}
)  # fmt: skip
ENV_NAMES = frozenset({"environ", "environb", "getenv", "getenvb", "putenv", "unsetenv"})
ENV_MODULES = frozenset({"os", "posix", "nt"})

# Builtins that do I/O, evaluate text, or reach any other name by string. No zone is exempt:
# today neither domain nor app needs one. If app ever must, add it to APP_ALLOWED_BUILTINS
# below with a comment saying why; never to domain.
BANNED_BUILTINS = frozenset(
    {"open", "print", "input", "eval", "exec", "compile", "__import__", "breakpoint", "globals",
     "locals", "vars", "getattr", "setattr", "delattr", "pow", "__builtins__", "builtins"}
)  # fmt: skip
APP_ALLOWED_BUILTINS: frozenset[str] = frozenset()
BANNED_ATTRIBUTES = frozenset(
    {"__builtins__", "__globals__", "__subclasses__", "__import__", "__loader__", "__code__",
     "__truediv__", "__rtruediv__", "__itruediv__", "__pow__", "__rpow__", "__ipow__"}
)  # fmt: skip
# Canonical dotted names (import aliases resolved) that produce floats, clocks, randomness,
# I/O, ambient numeric context or a getattr in disguise.
BANNED_MEMBERS = frozenset(
    {"operator.truediv", "operator.itruediv", "operator.pow", "operator.ipow",
     "operator.attrgetter", "operator.methodcaller",
     "fractions.Fraction.from_float", "fractions.Fraction.from_decimal",
     "decimal.Decimal.from_float", "decimal.getcontext", "decimal.setcontext",
     "decimal.DefaultContext", "decimal.BasicContext", "decimal.ExtendedContext",
     "datetime.datetime.now", "datetime.datetime.utcnow", "datetime.datetime.today",
     "datetime.date.today", "datetime.datetime.fromtimestamp",
     "functools.reduce"}
)  # fmt: skip
# The app may use datetime only as a TYPE (the Clock port); it imports none of these.
APP_FORBIDDEN_MODULES = frozenset(
    {"math", "cmath", "random", "secrets", "time", "os", "posix", "nt", "sys", "io", "pathlib",
     "socket", "subprocess", "builtins", "importlib", "ctypes", "pickle", "tempfile", "shutil",
     "urllib", "http", "logging", "uuid", "operator"}
)  # fmt: skip


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


def import_aliases(tree: ast.AST) -> dict[str, str]:
    """Local name -> canonical dotted name, for every import in the tree."""
    aliases: dict[str, str] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                if a.asname:
                    aliases[a.asname] = a.name
                else:
                    root = a.name.split(".")[0]
                    aliases[root] = root
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            for a in node.names:
                aliases[a.asname or a.name] = f"{node.module}.{a.name}"
    return aliases


def canonical(node: ast.AST, aliases: dict[str, str]) -> str | None:
    """The dotted name a Name/Attribute chain refers to, with its root alias resolved."""
    parts: list[str] = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if not isinstance(node, ast.Name) or node.id not in aliases:
        return None
    return ".".join([aliases[node.id], *reversed(parts)])


def banned_names(source: str, module: str, allowed: frozenset[str] = frozenset()) -> list[Finding]:
    """Banned builtins and reflective attributes, by bare name or attribute, wherever they sit."""
    findings = []
    banned = BANNED_BUILTINS - allowed
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Name) and node.id in banned:
            findings.append(Finding(f"{module}:{node.lineno}", node.id))
        elif isinstance(node, ast.Attribute) and (
            node.attr in BANNED_ATTRIBUTES or node.attr in {"__builtins__", "builtins"}
        ):
            findings.append(Finding(f"{module}:{node.lineno}", f".{node.attr}"))
        elif isinstance(node, ast.alias) and node.name.split(".")[0] in {"builtins"}:
            findings.append(Finding(module, f"import {node.name}"))
        elif isinstance(node, ast.ImportFrom) and any(a.name == "*" for a in node.names):
            findings.append(Finding(f"{module}:{node.lineno}", "star import"))
        elif isinstance(node, ast.ImportFrom) and any(a.name in banned for a in node.names):
            findings.append(Finding(f"{module}:{node.lineno}", "import of a banned builtin"))
    return findings


def banned_arithmetic(source: str, module: str) -> list[Finding]:
    """True division anywhere, and ** unless the exponent is a literal non-negative int."""
    findings = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Div):
            findings.append(Finding(module, "true division '/' (use // or divmod)"))
        if isinstance(node, ast.BinOp | ast.AugAssign) and isinstance(node.op, ast.Pow):
            exponent = node.right if isinstance(node, ast.BinOp) else node.value
            literal = (
                isinstance(exponent, ast.Constant)
                and type(exponent.value) is int
                and exponent.value >= 0
            )
            if not literal:
                where = f"{module}:{node.lineno}"
                findings.append(Finding(where, "** with a non-literal exponent"))
    return findings


def banned_members(source: str, module: str) -> list[Finding]:
    """Banned dotted members reached through any alias, plus `from m import banned`."""
    tree = ast.parse(source)
    aliases = import_aliases(tree)
    findings = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute | ast.Name):
            name = canonical(node, aliases)
            if name in BANNED_MEMBERS:
                findings.append(Finding(f"{module}:{node.lineno}", name))
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            findings.extend(
                Finding(f"{module}:{node.lineno}", f"{node.module}.{a.name}")
                for a in node.names
                if f"{node.module}.{a.name}" in BANNED_MEMBERS
            )
    return findings


def app_forbidden_modules(source: str, module: str) -> list[Finding]:
    return [
        Finding(f"{module}:{line}", name)
        for line, name in imported_modules(source, module, False)
        if name == "<dynamic import>" or name.split(".")[0] in APP_FORBIDDEN_MODULES
    ]


def purity_findings(source: str, module: str, zone: str) -> list[Finding]:
    """Every purity rule for one domain or app source."""
    allowed = APP_ALLOWED_BUILTINS if zone == "app" else frozenset()
    return [
        *banned_names(source, module, allowed),
        *banned_arithmetic(source, module),
        *banned_members(source, module),
        *float_uses(source, module),
    ]


def environment_reads(source: str, module: str) -> list[Finding]:
    """Reads or writes of the process environment, through any import alias."""
    tree = ast.parse(source)
    aliases = import_aliases(tree)
    findings = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute | ast.Name):
            name = canonical(node, aliases)
            if name is not None:
                root, _, rest = name.partition(".")
                if root in ENV_MODULES and rest.split(".")[0] in ENV_NAMES:
                    findings.append(Finding(f"{module}:{node.lineno}", name))
        elif isinstance(node, ast.ImportFrom) and node.module in ENV_MODULES:
            findings.extend(
                Finding(f"{module}:{node.lineno}", f"from {node.module} import {a.name}")
                for a in node.names
                if a.name in ENV_NAMES or a.name == "*"
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
# verifies: domain_is_pure
def test_domain_imports_only_pure_standard_library_and_itself() -> None:
    files = sources("domain")
    assert len(files) >= 4  # not vacuous: the zone really was scanned
    assert_clean([f for m, s in files for f in impure_domain_imports(s, m)], "domain purity")


# provenance: derived
# verifies: zones_enforced
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
# verifies: no_float_money
def test_no_float_in_domain_or_app() -> None:
    files = sources("domain") + sources("app")
    assert_clean([f for m, s in files for f in float_uses(s, m)], "no float")


# provenance: derived
# verifies: config_in_one_place
def test_only_platform_config_reads_the_environment() -> None:
    files = sources("")
    assert len(files) >= 15
    findings = [
        f for m, s in files if m != f"{PACKAGE}.platform.config" for f in environment_reads(s, m)
    ]
    assert_clean(findings, "environment read outside platform/config.py")


# provenance: derived
# verifies: domain_is_pure
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
# verifies: zones_enforced
def test_the_direction_checker_resolves_relative_and_from_imports() -> None:
    module = f"{PACKAGE}.app.x"
    assert forbidden_imports(f"import {PACKAGE}.adapters.outbound", module, ("adapters",))
    assert forbidden_imports(f"from {PACKAGE} import platform", module, ("platform",))
    assert forbidden_imports("from ..platform import clock", module, ("platform",))
    assert not forbidden_imports("from ..domain import ledger", module, ("platform",))


# provenance: derived
# verifies: no_float_money
def test_the_float_and_environment_checkers_catch_what_they_guard() -> None:
    assert float_uses("x: float = 1", "m")
    assert float_uses("x = 1.5", "m")
    assert not float_uses("x = 15", "m")
    assert environment_reads("import os\nos.environ['A']", "m")
    assert environment_reads("import os\nos.getenv('A')", "m")
    assert environment_reads("from os import environ", "m")
    assert not environment_reads("import os\nos.path.join('a')", "m")


# provenance: derived
# verifies: domain_is_pure
def test_the_stdlib_allowlist_names_real_stdlib_modules() -> None:
    assert set(sys.stdlib_module_names) >= DOMAIN_ALLOWED


# provenance: derived
# verifies: domain_is_pure
def test_domain_and_app_obey_the_purity_rules() -> None:
    for zone in ("domain", "app"):
        files = sources(zone)
        assert len(files) >= 3  # not vacuous
        assert_clean([f for m, s in files for f in purity_findings(s, m, zone)], f"{zone} purity")
    files = sources("app")
    assert_clean([f for m, s in files for f in app_forbidden_modules(s, m)], "app imports")


DOMAIN_MODULE = f"{PACKAGE}.domain.x"
APP_MODULE = f"{PACKAGE}.app.x"


# provenance: derived
# verifies: domain_is_pure
@pytest.mark.parametrize(
    "source",
    [
        "open('/dev/null')",
        "print(1)",
        "input()",
        "eval('1')",
        "exec('x=1')",
        "compile('1', 'f', 'eval')",
        "__import__('os')",
        "breakpoint()",
        "globals()",
        "locals()",
        "vars(object)",
        "getattr(__builtins__, 'open')",
        "getattr(x, 'y')",
        "setattr(x, 'y', 1)",
        "delattr(x, 'y')",
        "x = __builtins__",
        "x = y.__builtins__",
        "x = f.__globals__",
        "x = ().__class__.__bases__[0].__subclasses__()",
        "o = open",
        "import builtins",
        "from builtins import open",
        "from x import *",
        "pow(2, 3)",
        "x.__truediv__(2)",
    ],
)
def test_the_name_checker_catches_each_evasion(source: str) -> None:
    assert banned_names(source, DOMAIN_MODULE), source
    assert purity_findings(source, DOMAIN_MODULE, "domain"), source
    assert purity_findings(source, APP_MODULE, "app"), source


# provenance: derived
# verifies: domain_is_pure
def test_the_name_checker_lets_ordinary_code_through() -> None:
    ok = "q, r = divmod(a, b)\nx = a // b + r + 2**8 + 10**17"
    assert not purity_findings(ok, DOMAIN_MODULE, "domain")
    assert not purity_findings("self._clock.now()", APP_MODULE, "app")
    assert not purity_findings("x.open_account()", DOMAIN_MODULE, "domain")
    # An explicit per-zone allowance is honoured for app only.
    assert not banned_names("print(1)", APP_MODULE, frozenset({"print"}))
    assert banned_names("print(1)", DOMAIN_MODULE)


# provenance: derived
# verifies: no_float_money
@pytest.mark.parametrize(
    "source",
    [
        "x = self.minor / 2",
        "x /= 2",
        "x = a / b",
        "x = 2 ** -1",
        "x = 2 ** n",
        "x = 2 ** 0.5",
        "x = 2 ** True",
        "x **= n",
        "x = 10 ** EXPONENT",
    ],
)
def test_the_arithmetic_checker_catches_float_producing_operators(source: str) -> None:
    assert banned_arithmetic(source, DOMAIN_MODULE), source
    assert purity_findings(source, APP_MODULE, "app"), source


# provenance: derived
# verifies: no_float_money
def test_the_arithmetic_checker_allows_integer_money_arithmetic() -> None:
    assert not banned_arithmetic("a // b\ndivmod(a, b)\n2 ** 3\n10 ** 17 - 1\nx **= 2", "m")


# provenance: derived
# verifies: domain_is_pure
@pytest.mark.parametrize(
    "source",
    [
        "import math",
        "import math as m",
        "from math import sqrt",
        "import operator",
        "import datetime",
        "from datetime import datetime",
        "import random",
        "import os",
    ],
)
def test_the_allowlist_refuses_float_clock_random_and_io_modules(source: str) -> None:
    assert impure_domain_imports(source, DOMAIN_MODULE), source


# provenance: derived
# verifies: domain_is_pure
def test_the_allowlist_has_no_math_operator_or_datetime() -> None:
    assert not DOMAIN_ALLOWED & {"math", "cmath", "operator", "datetime", "time", "os", "random"}


# provenance: derived
# verifies: domain_is_pure
@pytest.mark.parametrize(
    "source",
    [
        "import operator\noperator.truediv(1, 2)",
        "import operator as op\nop.truediv(1, 2)",
        "from operator import truediv",
        "from operator import truediv as t\nt(1, 2)",
        "import operator\noperator.attrgetter('x')",
        "from decimal import Decimal\nDecimal.from_float(0.5)",
        "import decimal as d\nd.getcontext().prec = 5",
        "from fractions import Fraction\nFraction.from_float(1)",
        "from datetime import datetime\ndatetime.now()",
        "import datetime as dt\ndt.datetime.utcnow()",
        "import datetime\ndatetime.date.today()",
        "import functools\nfunctools.reduce(f, xs)",
    ],
)
def test_the_member_checker_catches_banned_members_through_aliases(source: str) -> None:
    assert banned_members(source, DOMAIN_MODULE), source


# provenance: derived
# verifies: domain_is_pure
def test_the_member_checker_ignores_lookalikes() -> None:
    assert not banned_members("clock.now()\nself._clock.now()\ndatetime.now()", "m")
    assert not banned_members("import operator\noperator.add(1, 2)", "m")


# provenance: derived
# verifies: domain_is_pure
@pytest.mark.parametrize(
    "source",
    [
        "import math",
        "import time\ntime.time()",
        "import random",
        "import os.path",
        "import logging",
        "import importlib\nimportlib.import_module('os')",
        "__import__('os')",
        "from sys import argv",
    ],
)
def test_the_app_checker_refuses_clock_random_and_io_modules(source: str) -> None:
    assert app_forbidden_modules(source, APP_MODULE), source


# provenance: derived
# verifies: domain_is_pure
def test_the_app_checker_allows_datetime_as_a_type_and_threading() -> None:
    assert not app_forbidden_modules("from datetime import datetime\nimport threading", "m")


# provenance: derived
# verifies: config_in_one_place
@pytest.mark.parametrize(
    "source",
    [
        "import os as o\no.getenv('A')",
        "import os as o\no.environ['A']",
        "import os as o\no.environb[b'A']",
        "import os\nos.environb",
        "import os\nos.putenv('A', 'b')",
        "import os\nos.unsetenv('A')",
        "from os import environ as e\ne['A']",
        "from os import getenv",
        "from os import getenv as g\ng('A')",
        "from os import *",
        "import posix\nposix.environ",
        "import os.path\nos.environ",
        "from os import environb",
    ],
)
def test_the_environment_checker_resolves_aliases(source: str) -> None:
    assert environment_reads(source, "m"), source


# provenance: derived
# verifies: config_in_one_place
def test_the_environment_checker_ignores_lookalikes() -> None:
    assert not environment_reads("import os\nos.path.join('a')\nconfig.environ", "m")
    assert not environment_reads("from os import path as p\np.join('a')", "m")
    assert not environment_reads("environ = {}\nenviron['A']", "m")
