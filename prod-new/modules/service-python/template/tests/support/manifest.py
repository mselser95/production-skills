"""A strict parser for the observability manifests (a small YAML subset, no dependency).

Accepted: full-line comments, blank lines, a list of entries starting with ``- name: value``,
plain (unquoted) scalar fields ``key: value``, flow lists ``[a, b]`` / ``[]`` of bare words,
and a folded scalar ``key: >`` whose lines are indented four spaces. LF line endings only.
Anything else raises ManifestError naming the line: a typo in a manifest must fail loudly,
not be skipped, and every file this accepts must load to the same data under a real YAML
parser (``tests/unit/test_manifest_equivalence.py`` proves it when PyYAML is present).

Refused on purpose, each with its line: quoted scalars, inline comments, null/bool/number
scalars, a value containing ``: `` or ending in ``:``, a scalar where a list is required and
the reverse, flow lists with an empty item (trailing comma), nested brackets or quotes,
anchors/aliases/tags and other YAML indicators at the start of a value, tabs, CR (CRLF
files are refused, not normalised: a checked-in manifest is LF), a BOM, non-printable
characters, trailing whitespace, document markers, duplicate keys and duplicate names.

Names follow the grammar the contract test's scrape already uses for series and label
names (``\\w+``); a span name is dotted words (``svc.deposit``).
"""

import re
from dataclasses import dataclass
from pathlib import Path

_START = re.compile(r"- (?P<key>[a-z_]+): (?P<value>\S.*)")
_FIELD = re.compile(r"  (?P<key>[a-z_]+):(?: (?P<value>\S.*))?")
_FOLDED_LINE = re.compile(r"    \S.*")
_WORD = re.compile(r"\w+")  # same grammar as the contract test's /metrics scrape
_SPAN_NAME = re.compile(r"\w+(?:\.\w+)*")
_NUMBER = re.compile(r"[-+]?(?:\.?\d[\d_.]*(?:[eE][-+]?\d+)?|0[xob][0-9a-fA-F_]+|\.inf|\.nan)")
_NON_STRINGS = {"null", "~", "true", "false", "yes", "no", "on", "off", "y", "n"}
_INDICATORS = set("'\"&*!|>%@`[]{},#?")

METRIC_FIELDS = {"name", "type", "labels", "note"}
SPAN_FIELDS = {"name", "emitted_by", "attrs", "note"}
LIST_FIELDS = {"labels", "attrs"}
METRIC_TYPES = {"counter", "gauge"}  # the types the contract test's scrape recognises


class ManifestError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class Entry:
    name: str
    fields: dict[str, str | tuple[str, ...]]


def _plain_scalar(raw: str, where: str) -> str:
    if raw[0] in _INDICATORS or (raw[0] in "-:" and raw[1:2] in {" ", ""}):
        raise ManifestError(f"{where}: {raw[0]!r} at the start of a value is outside the subset")
    if raw.lower() in _NON_STRINGS or _NUMBER.fullmatch(raw):
        raise ManifestError(f"{where}: {raw!r} is not a string in YAML (null/bool/number)")
    if ": " in raw or raw.endswith(":"):
        raise ManifestError(f"{where}: {raw!r} contains a mapping indicator ': '")
    if " #" in raw:
        raise ManifestError(f"{where}: inline comment in {raw!r}")
    return raw


def _flow_list(raw: str, where: str) -> tuple[str, ...]:
    if not (raw.startswith("[") and raw.endswith("]")):
        raise ManifestError(f"{where}: a list is required here, got the scalar {raw!r}")
    inner = raw[1:-1].strip()
    if not inner:
        return ()
    items = tuple(i.strip() for i in inner.split(","))
    for item in items:
        if _WORD.fullmatch(item) is None:
            raise ManifestError(f"{where}: list item {item!r} is not a bare word")
    return items


def _name(raw: str, allowed: set[str], where: str) -> str:
    pattern = _SPAN_NAME if "emitted_by" in allowed else _WORD
    value = _plain_scalar(raw, where)
    if pattern.fullmatch(value) is None:
        raise ManifestError(f"{where}: {value!r} is not a valid signal name")
    return value


def _value(key: str, raw: str, allowed: set[str], where: str) -> str | tuple[str, ...]:
    if key in LIST_FIELDS:
        return _flow_list(raw, where)
    if raw.startswith("["):
        raise ManifestError(f"{where}: a scalar is required for {key!r}, got a list")
    if key == "name":
        return _name(raw, allowed, where)
    value = _plain_scalar(raw, where)
    if key == "type" and value not in METRIC_TYPES:
        raise ManifestError(f"{where}: type {value!r} is not one of {sorted(METRIC_TYPES)}")
    return value


def _check_line(line: str, lineno: int) -> None:
    if "\t" in line:
        raise ManifestError(f"line {lineno}: tab character")
    if "\r" in line:
        raise ManifestError(f"line {lineno}: CR in the line ending (CRLF is refused; use LF)")
    if not line.isprintable():
        raise ManifestError(f"line {lineno}: non-printable character")
    if line != line.rstrip():
        raise ManifestError(f"line {lineno}: trailing whitespace")
    if line in {"---", "..."} or line.startswith(("--- ", "... ")):
        raise ManifestError(f"line {lineno}: document marker")


def parse(text: str, allowed: set[str]) -> list[Entry]:  # noqa: PLR0912, PLR0915 - a line-by-line state machine
    if text.startswith("﻿"):
        raise ManifestError("line 1: UTF-8 BOM")
    entries: list[dict[str, str | tuple[str, ...]]] = []
    starts: list[int] = []
    folded: tuple[str, int] | None = None
    folded_parts: list[str] = []

    def close_folded() -> None:
        nonlocal folded, folded_parts
        if folded is not None:
            if not folded_parts:
                raise ManifestError(f"line {folded[1]}: empty folded scalar for {folded[0]!r}")
            entries[-1][folded[0]] = " ".join(folded_parts)
            folded, folded_parts = None, []

    for lineno, line in enumerate(text.split("\n"), start=1):
        _check_line(line, lineno)
        if folded is not None and _FOLDED_LINE.fullmatch(line):
            folded_parts.append(line.strip())
            continue
        close_folded()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        where = f"line {lineno}"
        start, field = _START.fullmatch(line), _FIELD.fullmatch(line)
        if start is not None:
            if start["key"] != "name":
                raise ManifestError(f"{where}: an entry starts with name:")
            entries.append({"name": _value("name", start["value"], allowed, where)})
            starts.append(lineno)
        elif field is not None and entries:
            key, value = field["key"], field["value"]
            if key not in allowed:
                raise ManifestError(f"{where}: unknown field {key!r}")
            if key in entries[-1]:
                raise ManifestError(f"{where}: duplicate field {key!r}")
            if value is None:
                raise ManifestError(f"{where}: empty value for {key!r}")
            if value == ">":
                if key in LIST_FIELDS:
                    raise ManifestError(f"{where}: a list is required for {key!r}")
                folded = (key, lineno)
                entries[-1][key] = ""  # reserve the key now: a later duplicate is refused
            else:
                entries[-1][key] = _value(key, value, allowed, where)
        else:
            raise ManifestError(f"{where}: not in the accepted subset: {line!r}")
    close_folded()
    seen: dict[str, int] = {}
    for entry, lineno in zip(entries, starts, strict=True):
        name = str(entry["name"])
        if name in seen:
            raise ManifestError(f"line {lineno}: duplicate entry name {name!r} (line {seen[name]})")
        seen[name] = lineno
        missing = allowed - set(entry)
        if missing:
            raise ManifestError(f"line {lineno}: {name}: missing field(s) {sorted(missing)}")
    return [Entry(str(e["name"]), e) for e in entries]


def load(path: Path, allowed: set[str]) -> list[Entry]:
    try:
        return parse(path.read_text(encoding="utf-8"), allowed)
    except ManifestError as exc:
        raise ManifestError(f"{path}: {exc}") from exc
