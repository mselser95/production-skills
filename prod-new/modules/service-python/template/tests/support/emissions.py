"""Find every observability signal emitted in the source tree, by reading it (ast)."""

import ast
from dataclasses import dataclass
from pathlib import Path

KINDS = {"counter": "metric", "gauge": "metric", "span": "span"}


@dataclass(frozen=True, slots=True)
class Emission:
    method: str  # counter | gauge | span
    name: str | None  # None when the first argument is not a string literal
    keys: frozenset[str]  # label / attribute keys passed as keywords
    where: str


def scan_source(source: str, where: str) -> list[Emission]:
    found: list[Emission] = []
    for node in ast.walk(ast.parse(source)):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)):
            continue
        if node.func.attr not in KINDS:
            continue
        first = node.args[0] if node.args else None
        name = (
            first.value
            if isinstance(first, ast.Constant) and isinstance(first.value, str)
            else None
        )
        keys = frozenset(k.arg for k in node.keywords if k.arg is not None)
        if any(k.arg is None for k in node.keywords):
            keys |= {"**"}  # label forwarding cannot be checked statically
        found.append(Emission(node.func.attr, name, keys, f"{where}:{node.lineno}"))
    return found


def scan_tree(root: Path) -> list[Emission]:
    emissions: list[Emission] = []
    for path in sorted(root.rglob("*.py")):
        emissions.extend(scan_source(path.read_text(encoding="utf-8"), str(path.relative_to(root))))
    return emissions
