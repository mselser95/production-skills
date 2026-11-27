"""Money as integer minor units. No Decimal, no float, no division: parsing is integer-only.

There is one upper bound, ``MAX_MINOR``. The ``Amount`` constructor enforces it and so does
every arithmetic result, so every reachable amount (and balance, which is an ``Amount``)
formats to at most ``_MAX_WHOLE_DIGITS`` whole digits and parses back to itself.

Client-supplied text is never rounded: more fraction digits than ``EXPONENT`` is refused.
"""

import re
from dataclasses import dataclass

from <PACKAGE>.domain.errors import (
    AmountLimitExceeded,
    InsufficientFunds,
    InvalidAmount,
)

EXPONENT = 2
"""Digits after the decimal point: 1 unit = 10**EXPONENT minor units."""

_SCALE = 100
"""10**EXPONENT as a literal: the architecture rule forbids a computed power in the domain."""

_MAX_WHOLE_DIGITS = 15
MAX_MINOR = 10**17 - 1
"""The upper bound of any amount and any balance: 999999999999999.99 at EXPONENT 2."""

# ASCII digits only (never \d, which matches other scripts); the bounds keep the input small.
_AMOUNT = re.compile(
    rf"(?P<whole>[0-9]{{1,{_MAX_WHOLE_DIGITS}}})(?:\.(?P<fraction>[0-9]{{1,{EXPONENT}}}))?"
)


@dataclass(frozen=True, slots=True, order=True)
class Amount:
    """A quantity in minor units, 0 <= minor <= MAX_MINOR."""

    minor: int

    def __post_init__(self) -> None:
        # type() is int, not isinstance: bool is an int subclass and must not pass.
        if type(self.minor) is not int or self.minor < 0:
            raise InvalidAmount("an amount is a non-negative integer of minor units")
        if self.minor > MAX_MINOR:
            raise AmountLimitExceeded("the amount exceeds the upper bound")

    @classmethod
    def parse(cls, text: str) -> "Amount":
        """Parse a plain decimal string ("12", "12.34"). More than EXPONENT fraction digits is
        refused, never rounded."""
        match = _AMOUNT.fullmatch(text) if isinstance(text, str) else None
        if match is None:
            raise InvalidAmount("an amount is a plain decimal string such as 12.34")
        fraction = (match["fraction"] or "").ljust(EXPONENT, "0")
        return cls(int(match["whole"]) * _SCALE + int(fraction))

    def format(self) -> str:
        """Render as a decimal string with exactly EXPONENT fraction digits."""
        whole, fraction = divmod(self.minor, _SCALE)
        return f"{whole}.{fraction:0{EXPONENT}d}"

    def plus(self, other: "Amount") -> "Amount":
        """Add, or raise AmountLimitExceeded if the result would pass MAX_MINOR."""
        total = self.minor + other.minor
        if total > MAX_MINOR:
            raise AmountLimitExceeded("the result exceeds the upper bound")
        return Amount(total)

    def minus(self, other: "Amount") -> "Amount":
        """Subtract, or raise InsufficientFunds if the result would be negative."""
        if other.minor > self.minor:
            raise InsufficientFunds("the amount exceeds the balance")
        return Amount(self.minor - other.minor)
