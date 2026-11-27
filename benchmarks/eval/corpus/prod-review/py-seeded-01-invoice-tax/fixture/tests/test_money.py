import unittest
from decimal import Decimal

from invoicing.money import parse_amount, to_cents


class ToCentsTest(unittest.TestCase):
    def test_rounds_half_up(self) -> None:
        self.assertEqual(to_cents(Decimal("1.005")), Decimal("1.01"))
        self.assertEqual(to_cents(Decimal("1.004")), Decimal("1.00"))

    def test_halves_go_away_from_zero(self) -> None:
        self.assertEqual(to_cents(Decimal("-1.005")), Decimal("-1.01"))


class ParseAmountTest(unittest.TestCase):
    def test_parses_a_decimal_string(self) -> None:
        self.assertEqual(parse_amount(" 12.50 "), Decimal("12.50"))

    def test_refuses_garbage_and_non_finite(self) -> None:
        for text in ("abc", "", "NaN", "Infinity"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_amount(text)


if __name__ == "__main__":
    unittest.main()
