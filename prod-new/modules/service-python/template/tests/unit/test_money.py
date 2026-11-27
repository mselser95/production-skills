from decimal import ROUND_DOWN, ROUND_HALF_UP

import pytest

from <PACKAGE>.domain.errors import InsufficientFunds, InvalidAmount
from <PACKAGE>.domain.money import (
    DEFAULT_ROUNDING,
    Amount,
)


# provenance: derived
# verifies: units_ledger/amount_exactness
@pytest.mark.parametrize(
    ("text", "minor"),
    [
        ("0", 0),
        ("12", 1200),
        ("12.3", 1230),
        ("12.34", 1234),
        ("0.01", 1),
        ("999999999999999.99", 99999999999999999),
    ],
)
def test_parse_is_exact_for_representable_amounts(text: str, minor: int) -> None:
    assert Amount.parse(text).minor == minor


# provenance: derived
# verifies: units_ledger/amount_exactness
@pytest.mark.parametrize(
    ("text", "minor"),
    [("0.005", 0), ("0.015", 2), ("0.025", 2), ("0.035", 4), ("1.004", 100), ("1.006", 101)],
)
def test_default_rounding_is_half_even(text: str, minor: int) -> None:
    assert DEFAULT_ROUNDING == "ROUND_HALF_EVEN"
    assert Amount.parse(text).minor == minor


# provenance: derived
# verifies: units_ledger/amount_exactness
def test_rounding_mode_is_an_explicit_parameter() -> None:
    assert Amount.parse("0.005", ROUND_HALF_UP).minor == 1
    assert Amount.parse("0.019", ROUND_DOWN).minor == 1
    with pytest.raises(InvalidAmount):
        Amount.parse("1", "ROUND_SIDEWAYS")


# provenance: derived
# verifies: units_ledger/amount_exactness
@pytest.mark.parametrize(
    "text",
    [
        "",
        " 1",
        "1 ",
        "-1",
        "+1",
        "1e3",
        "NaN",
        "Infinity",
        "1,5",
        "1.",
        ".5",
        "0x10",
        "\N{ARABIC-INDIC DIGIT ONE}\N{ARABIC-INDIC DIGIT TWO}",
        "9" * 16,
        "0." + "1" * 19,
    ],
)
def test_parse_refuses_anything_but_a_plain_bounded_decimal(text: str) -> None:
    with pytest.raises(InvalidAmount):
        Amount.parse(text)


# provenance: derived
# verifies: units_ledger/amount_exactness
@pytest.mark.parametrize("bad", [-1, 1.5, True, "5", None])
def test_amount_refuses_non_integer_or_negative_minor_units(bad: object) -> None:
    with pytest.raises(InvalidAmount):
        Amount(bad)  # type: ignore[arg-type]


# provenance: derived
# verifies: units_ledger/amount_exactness
def test_format_always_shows_two_fraction_digits() -> None:
    assert [Amount(m).format() for m in (0, 5, 100, 1234)] == ["0.00", "0.05", "1.00", "12.34"]


# provenance: derived
# verifies: units_ledger/no_overdraft
def test_minus_below_zero_raises_insufficient_funds() -> None:
    assert Amount(500).minus(Amount(500)) == Amount(0)
    with pytest.raises(InsufficientFunds):
        Amount(499).minus(Amount(500))
