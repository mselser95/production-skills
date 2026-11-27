"""Money helpers: amounts are Decimals rounded half-up to the cent."""
from __future__ import annotations

from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

CENT = Decimal("0.01")


def to_cents(value: Decimal) -> Decimal:
    """Round to whole cents, halves away from zero, as the invoice rules require."""
    return value.quantize(CENT, rounding=ROUND_HALF_UP)


def parse_amount(text: str) -> Decimal:
    """Parse a decimal string such as "12.50"; NaN and infinities are refused."""
    try:
        value = Decimal(text.strip())
    except InvalidOperation as exc:
        raise ValueError(f"not an amount: {text!r}") from exc
    if not value.is_finite():
        raise ValueError(f"not an amount: {text!r}")
    return value
