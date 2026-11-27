"""Invoice lines and their totals."""
from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from decimal import Decimal

from invoicing.money import to_cents


@dataclass(frozen=True)
class Line:
    sku: str
    qty: int
    unit_price: Decimal


def line_total(line: Line) -> Decimal:
    """Quantity times unit price, in whole cents."""
    if line.qty < 0:
        raise ValueError("quantity must not be negative")
    return to_cents(line.unit_price * line.qty)


def subtotal(lines: Iterable[Line]) -> Decimal:
    """Sum of the line totals."""
    return sum((line_total(line) for line in lines), Decimal(0))
