"""Money as integer minor units. Decimal is built from strings only; floats never appear.

Rounding is explicit: ``Amount.parse`` takes the rounding mode as a parameter and the
default is named (``DEFAULT_ROUNDING``), never inherited from the ambient decimal context.
"""

import re
from dataclasses import dataclass
from decimal import (
    ROUND_CEILING,
    ROUND_DOWN,
    ROUND_FLOOR,
    ROUND_HALF_DOWN,
    ROUND_HALF_EVEN,
    ROUND_HALF_UP,
    ROUND_UP,
    Decimal,
    localcontext,
)

from <PACKAGE>.domain.errors import InsufficientFunds, InvalidAmount

EXPONENT = 2
"""Digits after the decimal point: 1 unit = 10**EXPONENT minor units."""

DEFAULT_ROUNDING = ROUND_HALF_EVEN
ROUNDING_MODES = frozenset(
    {
        ROUND_CEILING,
        ROUND_DOWN,
        ROUND_FLOOR,
        ROUND_HALF_DOWN,
        ROUND_HALF_EVEN,
        ROUND_HALF_UP,
        ROUND_UP,
    }
)

# ASCII digits only (never \d, which matches other scripts); the bounds keep the Decimal
# built from untrusted text small.
_AMOUNT = re.compile(r"(?P<whole>[0-9]{1,15})(?:\.(?P<fraction>[0-9]{1,18}))?")
_SCALE = 10**EXPONENT


@dataclass(frozen=True, slots=True, order=True)
class Amount:
    """A non-negative quantity in minor units."""

    minor: int

    def __post_init__(self) -> None:
        # type() is int, not isinstance: bool is an int subclass and must not pass.
        if type(self.minor) is not int or self.minor < 0:
            raise InvalidAmount("an amount is a non-negative integer of minor units")

    @classmethod
    def parse(cls, text: str, rounding: str = DEFAULT_ROUNDING) -> "Amount":
        """Parse a plain decimal string ("12", "12.34", "0.005"), rounding to EXPONENT places."""
        if rounding not in ROUNDING_MODES:
            raise InvalidAmount("unknown rounding mode")
        if not isinstance(text, str) or _AMOUNT.fullmatch(text) is None:
            raise InvalidAmount("an amount is a plain decimal string such as 12.34")
        with localcontext() as ctx:
            ctx.prec = 40
            quantized = Decimal(text).quantize(Decimal(1).scaleb(-EXPONENT), rounding=rounding)
            return cls(int(quantized.scaleb(EXPONENT)))

    def format(self) -> str:
        """Render as a decimal string with exactly EXPONENT fraction digits."""
        return f"{self.minor // _SCALE}.{self.minor % _SCALE:0{EXPONENT}d}"

    def plus(self, other: "Amount") -> "Amount":
        return Amount(self.minor + other.minor)

    def minus(self, other: "Amount") -> "Amount":
        """Subtract, or raise InsufficientFunds if the result would be negative."""
        if other.minor > self.minor:
            raise InsufficientFunds("the amount exceeds the balance")
        return Amount(self.minor - other.minor)
