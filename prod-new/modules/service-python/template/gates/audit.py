"""Dependency audit gate: `uv audit` over the locked set, with expiring waivers.

Fails closed: an unreachable advisory service, a malformed or expired waiver, or any finding
not waived is a non-zero exit. Stdlib only; run as `uv run --locked python gates/audit.py`.
"""

import datetime
import pathlib
import re
import subprocess
import sys

WAIVERS = pathlib.Path(__file__).with_name("audit-waivers.txt")
LINE = re.compile(r"^(?P<id>\S+)\s+(?P<expiry>\d{4}-\d{2}-\d{2})\s+(?P<owner>\S+)\s+(?P<why>\S.*)$")


def load_waivers(today: datetime.date) -> list[str]:
    """Return the ids of live waivers; raise ValueError on a malformed or expired entry."""
    ids: list[str] = []
    for number, raw in enumerate(WAIVERS.read_text(encoding="utf-8").splitlines(), start=1):
        text = raw.strip()
        if not text or text.startswith("#"):
            continue
        match = LINE.match(text)
        if match is None:
            msg = f"{WAIVERS.name}:{number}: malformed waiver (id expiry owner reason)"
            raise ValueError(msg)
        try:
            expiry = datetime.date.fromisoformat(match["expiry"])
        except ValueError as err:
            msg = f"{WAIVERS.name}:{number}: bad expiry date {match['expiry']!r}"
            raise ValueError(msg) from err
        if expiry < today:
            msg = f"{WAIVERS.name}:{number}: waiver for {match['id']} expired {expiry}"
            raise ValueError(msg)
        ids.append(match["id"])
    return ids


def main() -> int:
    try:
        waived = load_waivers(datetime.datetime.now(tz=datetime.UTC).date())
    except (OSError, ValueError) as err:
        print(f"audit: FAIL {err}", file=sys.stderr)  # noqa: T201
        return 1
    command = ["uv", "audit", "--locked", "--preview-features", "audit-command"]
    for advisory in waived:
        command += ["--ignore", advisory]
    try:
        done = subprocess.run(command, check=False)  # noqa: S603
    except OSError as err:
        print(f"audit: FAIL cannot run uv: {err}", file=sys.stderr)  # noqa: T201
        return 1
    if done.returncode != 0:
        print(f"audit: FAIL uv audit exited {done.returncode}", file=sys.stderr)  # noqa: T201
        return 1
    print(f"audit: ok ({len(waived)} waiver(s) in force)")  # noqa: T201
    return 0


if __name__ == "__main__":
    sys.exit(main())
