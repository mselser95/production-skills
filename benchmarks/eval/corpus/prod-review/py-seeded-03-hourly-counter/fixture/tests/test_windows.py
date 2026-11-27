import unittest
from datetime import datetime, timedelta, timezone

from windows.counter import HourlyCounter
from windows.labels import as_utc, hour_label

UTC = timezone.utc


class LabelTest(unittest.TestCase):
    def test_aware_timestamps_are_converted_to_utc(self) -> None:
        plus_two = timezone(timedelta(hours=2))
        ts = datetime(2024, 3, 10, 9, 30, tzinfo=plus_two)
        self.assertEqual(hour_label(ts), "2024-03-10T07:00Z")

    def test_naive_timestamps_are_taken_as_utc(self) -> None:
        self.assertEqual(as_utc(datetime(2024, 1, 1, 5)), datetime(2024, 1, 1, 5, tzinfo=UTC))

    def test_the_hour_boundary_belongs_to_the_new_hour(self) -> None:
        self.assertEqual(hour_label(datetime(2024, 1, 1, 5, 59, 59, tzinfo=UTC)), "2024-01-01T05:00Z")
        self.assertEqual(hour_label(datetime(2024, 1, 1, 6, 0, 0, tzinfo=UTC)), "2024-01-01T06:00Z")


class CounterTest(unittest.TestCase):
    def test_counts_per_hour(self) -> None:
        c = HourlyCounter()
        c.record(datetime(2024, 1, 1, 5, 1, tzinfo=UTC))
        c.record(datetime(2024, 1, 1, 5, 50, tzinfo=UTC), 2)
        c.record(datetime(2024, 1, 1, 6, 0, tzinfo=UTC))
        self.assertEqual(c.count("2024-01-01T05:00Z"), 3)
        self.assertEqual(list(c.snapshot()), ["2024-01-01T05:00Z", "2024-01-01T06:00Z"])

    def test_non_positive_increment_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            HourlyCounter().record(datetime(2024, 1, 1, tzinfo=UTC), 0)


if __name__ == "__main__":
    unittest.main()
