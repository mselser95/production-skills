"""A strict parser for the observability manifests (a small YAML subset, no dependency).

Accepted: comments, blank lines, a list of entries starting with ``- name: value``, scalar
fields ``key: value``, flow lists ``[a, b]`` / ``[]``, and a folded scalar ``key: >`` whose
lines are indented deeper than the key. Anything else raises ManifestError: a typo in a
manifest must fail loudly, not be skipped.
"""

import re
from dataclasses import dataclass
from pathlib import Path

_START = re.compile(r"- (?P<key>[a-z_]+): (?P<value>\S.*)")
_FIELD = re.compile(r"  (?P<key>[a-z_]+):(?: (?P<value>\S.*))?")
_LIST = re.compile(r"\[(?P<items>[a-z_, ]*)\]")
_FOLDED_LINE = re.compile(r"    \S.*")

METRIC_FIELDS = {"name", "type", "labels", "note"}
SPAN_FIELDS = {"name", "emitted_by", "attrs", "note"}


class ManifestError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class Entry:
    name: str
    fields: dict[str, str | tuple[str, ...]]


def _parse_value(raw: str, lineno: int) -> str | tuple[str, ...]:
    if raw.startswith("["):
        match = _LIST.fullmatch(raw)
        if match is None:
            raise ManifestError(f"line {lineno}: malformed list {raw!r}")
        return tuple(i.strip() for i in match["items"].split(",") if i.strip())
    return raw


def parse(text: str, allowed: set[str]) -> list[Entry]:  # noqa: PLR0912 - a line-by-line state machine
    entries: list[dict[str, str | tuple[str, ...]]] = []
    folded: str | None = None
    folded_parts: list[str] = []

    def close_folded() -> None:
        nonlocal folded, folded_parts
        if folded is not None:
            entries[-1][folded] = " ".join(folded_parts)
            folded, folded_parts = None, []

    for lineno, line in enumerate(text.splitlines(), start=1):
        if "\t" in line:
            raise ManifestError(f"line {lineno}: tab character")
        if folded is not None and _FOLDED_LINE.fullmatch(line):
            folded_parts.append(line.strip())
            continue
        close_folded()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        start, field = _START.fullmatch(line), _FIELD.fullmatch(line)
        if start is not None:
            if start["key"] != "name":
                raise ManifestError(f"line {lineno}: an entry starts with name:")
            entries.append({"name": start["value"].strip()})
        elif field is not None and entries:
            key, value = field["key"], field["value"]
            if key not in allowed:
                raise ManifestError(f"line {lineno}: unknown field {key!r}")
            if key in entries[-1]:
                raise ManifestError(f"line {lineno}: duplicate field {key!r}")
            if value == ">":
                folded = key
            elif value is None:
                raise ManifestError(f"line {lineno}: empty value for {key!r}")
            else:
                entries[-1][key] = _parse_value(value.strip(), lineno)
        else:
            raise ManifestError(f"line {lineno}: not in the accepted subset: {line!r}")
    close_folded()
    names: set[str] = set()
    for entry in entries:
        name = entry["name"]
        if not isinstance(name, str) or name in names:
            raise ManifestError(f"duplicate or invalid name {name!r}")
        names.add(name)
        missing = allowed - set(entry)
        if missing:
            raise ManifestError(f"{name}: missing field(s) {sorted(missing)}")
    return [Entry(str(e["name"]), e) for e in entries]


def load(path: Path, allowed: set[str]) -> list[Entry]:
    return parse(path.read_text(encoding="utf-8"), allowed)
