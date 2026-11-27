import unittest

from webhooks.signing import header, sign


class SignTest(unittest.TestCase):
    def test_known_vector(self) -> None:
        self.assertEqual(
            sign(b"key", 1700000000, b'{"a":1}'),
            "a438e398bfafc57e4396bb7fc2304422f0f768e965d073ca313cb52e22e6ad03",
        )

    def test_depends_on_every_input(self) -> None:
        base = sign(b"key", 10, b"x")
        self.assertNotEqual(base, sign(b"other", 10, b"x"))
        self.assertNotEqual(base, sign(b"key", 11, b"x"))
        self.assertNotEqual(base, sign(b"key", 10, b"y"))

    def test_header_format(self) -> None:
        self.assertEqual(header(b"key", 10, b"x"), f"t=10,v1={sign(b'key', 10, b'x')}")

    def test_negative_timestamp_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            sign(b"key", -1, b"x")


if __name__ == "__main__":
    unittest.main()
