"""Dependency audit gate: `uv audit` over the locked set, with expiring waivers.

Fails closed: an unreachable advisory service, a malformed, duplicate, expired, too-distant or
STALE waiver, an exit code that disagrees with the findings, or any finding not waived is a
non-zero exit. Stdlib only; run as `uv run --locked python gates/audit.py`.

The findings are read from `uv audit --output-format json` (the decision never rests on the exit
code alone) and the waivers are applied HERE, by id or alias, so the gate knows which waiver
matched something: one that matched nothing is STALE (red), so dead waivers cannot accumulate.
"""

import datetime
import json
import pathlib
import re
import subprocess
import sys
from typing import Any

WAIVERS = pathlib.Path(__file__).with_name("audit-waivers.txt")
LINE = re.compile(r"^(?P<id>\S+)\s+(?P<expiry>\d{4}-\d{2}-\d{2})\s+(?P<owner>\S+)\s+(?P<why>\S.*)$")
# GHSA-xxxx-xxxx-xxxx, PYSEC-YYYY-N, CVE-YYYY-N, OSV-...; a leading `-` can never match.
ADVISORY_ID = re.compile(r"^[A-Z][A-Z0-9]*-[A-Za-z0-9-]+$")
MAX_DAYS_AHEAD = 180


def load_waivers(today: datetime.date) -> list[str]:
    """Return the ids of live waivers; raise ValueError on a malformed, duplicate, expired or
    too-distant entry."""
    ids: list[str] = []
    text_all = WAIVERS.read_text(encoding="utf-8-sig")  # a UTF-8 BOM is not part of the first id
    for number, raw in enumerate(text_all.splitlines(), start=1):
        text = raw.strip()
        if not text or text.startswith("#"):
            continue
        where = f"{WAIVERS.name}:{number}"
        match = LINE.match(text)
        if match is None:
            msg = f"{where}: malformed waiver (id expiry owner reason)"
            raise ValueError(msg)
        advisory = match["id"]
        if ADVISORY_ID.match(advisory) is None:
            msg = f"{where}: malformed advisory id {advisory!r} (like GHSA-xxxx-xxxx-xxxx)"
            raise ValueError(msg)
        if advisory in ids:
            msg = f"{where}: duplicate waiver for {advisory}"
            raise ValueError(msg)
        try:
            expiry = datetime.date.fromisoformat(match["expiry"])
        except ValueError as err:
            msg = f"{where}: bad expiry date {match['expiry']!r}"
            raise ValueError(msg) from err
        if expiry < today:
            msg = f"{where}: waiver for {advisory} expired {expiry}"
            raise ValueError(msg)
        if expiry > today + datetime.timedelta(days=MAX_DAYS_AHEAD):
            msg = f"{where}: {advisory} expires {expiry}, more than {MAX_DAYS_AHEAD} days ahead"
            raise ValueError(msg)
        ids.append(advisory)
    return ids


def finding_ids(finding: dict[str, Any]) -> set[str]:
    """Every name one finding is known by (its id, its display id and its aliases)."""
    names = {str(finding.get("id", "")), str(finding.get("display_id", ""))}
    names.update(str(alias) for alias in finding.get("aliases") or [])
    names.discard("")
    return names


def read_report(returncode: int, stdout: str) -> tuple[list[dict[str, Any]], str | None]:
    """Return (findings, problem): the findings of the JSON report, and why it cannot be trusted."""
    if returncode not in (0, 1):  # 2 = could not run (e.g. the advisory service is down)
        return [], f"uv audit exited {returncode}"
    try:
        findings = list(json.loads(stdout)["vulnerabilities"])
    except (ValueError, KeyError, TypeError) as err:
        return [], f"cannot read the uv audit report ({err.__class__.__name__}: {err})"
    if returncode == 0 and findings:
        return findings, f"uv audit exited 0 but its report holds {len(findings)} finding(s)"
    if returncode == 1 and not findings:
        return findings, "uv audit exited 1 but its report holds no finding"
    return findings, None


def judge(returncode: int, stdout: str, waived: list[str]) -> str | None:
    """Return why the audit is red, or None when it is clean. Findings come from the report."""
    findings, problem = read_report(returncode, stdout)
    if problem is not None:
        return problem
    seen: set[str] = set()
    open_findings = []
    for finding in findings:
        names = finding_ids(finding)
        seen |= names
        if not names & set(waived):
            open_findings.append(finding)
    for finding in open_findings:
        dep = finding.get("dependency") or {}
        print(  # noqa: T201
            f"audit: FINDING {finding.get('display_id') or finding.get('id')} in "
            f"{dep.get('name')} {dep.get('version')}",
            file=sys.stderr,
        )
    if open_findings:
        return f"{len(open_findings)} finding(s) not waived"
    stale = [advisory for advisory in waived if advisory not in seen]
    if stale:
        return f"STALE waiver(s), no such finding in this audit: {', '.join(stale)}"
    return None


def main() -> int:
    try:
        waived = load_waivers(datetime.datetime.now(tz=datetime.UTC).date())
    except (OSError, ValueError) as err:
        print(f"audit: FAIL {err}", file=sys.stderr)  # noqa: T201
        return 1
    command = [
        "uv", "audit", "--locked", "--output-format", "json",
        "--preview-features", "audit-command", "--preview-features", "json-output",
    ]  # fmt: skip
    try:
        done = subprocess.run(command, check=False, stdout=subprocess.PIPE, text=True)  # noqa: S603
    except OSError as err:
        print(f"audit: FAIL cannot run uv: {err}", file=sys.stderr)  # noqa: T201
        return 1
    problem = judge(done.returncode, done.stdout, waived)
    if problem is not None:
        print(f"audit: FAIL {problem}", file=sys.stderr)  # noqa: T201
        return 1
    print(f"audit: ok ({len(waived)} waiver(s) in force)")  # noqa: T201
    return 0


if __name__ == "__main__":
    sys.exit(main())
