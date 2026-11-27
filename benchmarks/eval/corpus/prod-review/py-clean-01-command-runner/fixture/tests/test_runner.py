import subprocess
import sys
import unittest

from cmdrun.errors import CommandError
from cmdrun.runner import run


class RunTest(unittest.TestCase):
    def test_returns_stdout(self) -> None:
        self.assertEqual(run([sys.executable, "-c", "print('hi')"], timeout=10), "hi\n")

    def test_non_zero_exit_raises_with_stderr(self) -> None:
        code = "import sys; sys.stderr.write('boom'); sys.exit(3)"
        with self.assertRaises(CommandError) as ctx:
            run([sys.executable, "-c", code], timeout=10)
        self.assertEqual(ctx.exception.returncode, 3)
        self.assertEqual(ctx.exception.stderr, "boom")

    def test_arguments_are_not_interpreted_by_a_shell(self) -> None:
        code = "import sys; print(sys.argv[1])"
        self.assertEqual(run([sys.executable, "-c", code, "$HOME; echo x"], timeout=10), "$HOME; echo x\n")

    def test_empty_argv_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            run([], timeout=1)

    def test_timeout_propagates(self) -> None:
        with self.assertRaises(subprocess.TimeoutExpired):
            run([sys.executable, "-c", "import time; time.sleep(30)"], timeout=0.2)


if __name__ == "__main__":
    unittest.main()
