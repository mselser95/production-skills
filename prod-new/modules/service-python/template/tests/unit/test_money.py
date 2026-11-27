import pytest

from <PACKAGE>.domain.errors import (
    AmountLimitExceeded,
    InsufficientFunds,
    InvalidAmount,
)
from <PACKAGE>.domain.money import (
    EXPONENT,
    MAX_MINOR,
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
@pytest.mark.parametrize("text", ["0.005", "0.015", "1.004", "1.006", "0.001", "12.340", "1.000"])
def test_parse_refuses_more_fraction_digits_than_the_exponent_and_never_rounds(text: str) -> None:
    with pytest.raises(InvalidAmount):
        Amount.parse(text)


# provenance: derived
# verifies: units_ledger/amount_exactness
def test_parse_takes_no_rounding_parameter() -> None:
    with pytest.raises(TypeError):
        Amount.parse("1.00", "ROUND_HALF_UP")  # type: ignore[call-arg]


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
        "1000000000000000.00",
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


# provenance: derived
# verifies: units_ledger/amount_exactness
def test_the_bound_is_the_largest_text_parse_accepts() -> None:
    assert MAX_MINOR == 10**17 - 1
    assert Amount.parse("999999999999999.99").minor == MAX_MINOR
    assert Amount(MAX_MINOR).format() == "999999999999999.99"
    with pytest.raises(AmountLimitExceeded):
        Amount(MAX_MINOR + 1)
    with pytest.raises(InvalidAmount):  # 16 whole digits: refused by the grammar, same bound
        Amount.parse("1000000000000000")
    assert len(str(MAX_MINOR // 10**EXPONENT)) == 15
    assert 10**EXPONENT == 100  # the literal scale in money.py


# provenance: derived
# verifies: units_ledger/amount_exactness
def test_plus_past_the_bound_raises_the_limit_error() -> None:
    assert Amount(MAX_MINOR - 1).plus(Amount(1)) == Amount(MAX_MINOR)
    with pytest.raises(AmountLimitExceeded):
        Amount(MAX_MINOR).plus(Amount(1))
    with pytest.raises(AmountLimitExceeded):
        Amount(MAX_MINOR).plus(Amount(MAX_MINOR))


# provenance: derived
# verifies: units_ledger/amount_exactness
def test_the_limit_error_is_an_invalid_amount() -> None:
    assert issubclass(AmountLimitExceeded, InvalidAmount)
