import asyncio
import unittest

from poller.probe import probe_once, wait_ready


class ProbeTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_true_check_is_ready(self) -> None:
        async def ok() -> bool:
            return True

        self.assertTrue(await probe_once(ok, 1))

    async def test_a_slow_check_times_out_as_false(self) -> None:
        async def slow() -> bool:
            await asyncio.sleep(5)
            return True

        self.assertFalse(await probe_once(slow, 0.05))

    async def test_wait_ready_retries_until_success(self) -> None:
        calls: list[int] = []

        async def flaky() -> bool:
            calls.append(1)
            return len(calls) == 3

        self.assertTrue(await wait_ready(flaky, interval=0.01, attempts=5, timeout=1))
        self.assertEqual(len(calls), 3)

    async def test_wait_ready_gives_up(self) -> None:
        async def down() -> bool:
            return False

        self.assertFalse(await wait_ready(down, interval=0.01, attempts=2, timeout=1))

    async def test_zero_attempts_is_refused(self) -> None:
        async def ok() -> bool:
            return True

        with self.assertRaises(ValueError):
            await wait_ready(ok, interval=0, attempts=0, timeout=1)


if __name__ == "__main__":
    unittest.main()
