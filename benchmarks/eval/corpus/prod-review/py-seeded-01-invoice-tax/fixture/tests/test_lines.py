import unittest
from decimal import Decimal

from invoicing.lines import Line, line_total, subtotal


class LineTotalTest(unittest.TestCase):
    def test_multiplies_and_rounds(self) -> None:
        self.assertEqual(line_total(Line("a", 3, Decimal("0.335"))), Decimal("1.01"))

    def test_zero_quantity_is_zero(self) -> None:
        self.assertEqual(line_total(Line("a", 0, Decimal("9.99"))), Decimal("0.00"))

    def test_negative_quantity_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            line_total(Line("a", -1, Decimal("1.00")))


class SubtotalTest(unittest.TestCase):
    def test_sums_line_totals(self) -> None:
        lines = [Line("a", 2, Decimal("1.10")), Line("b", 1, Decimal("0.80"))]
        self.assertEqual(subtotal(lines), Decimal("3.00"))

    def test_empty_is_zero(self) -> None:
        self.assertEqual(subtotal([]), Decimal(0))


if __name__ == "__main__":
    unittest.main()
