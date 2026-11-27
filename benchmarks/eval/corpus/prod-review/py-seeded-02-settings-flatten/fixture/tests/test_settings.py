import unittest

from settings.sources import from_environ, resolve
from settings.merge import DEFAULTS, merge


class MergeTest(unittest.TestCase):
    def test_later_layers_win(self) -> None:
        self.assertEqual(merge({"a": "1", "b": "2"}, {"b": "3"}), {"a": "1", "b": "3"})

    def test_inputs_are_not_modified(self) -> None:
        first = {"a": "1"}
        merge(first, {"a": "2"})
        self.assertEqual(first, {"a": "1"})


class EnvTest(unittest.TestCase):
    def test_prefixed_names_become_dotted_keys(self) -> None:
        env = {"APP_DB_HOST": "db1", "HOME": "/root", "APP_": "x"}
        self.assertEqual(from_environ(env), {"db.host": "db1"})

    def test_resolve_overrides_defaults_only_where_set(self) -> None:
        got = resolve({"APP_LOG_LEVEL": "debug"})
        self.assertEqual(got["log.level"], "debug")
        self.assertEqual(got["db.port"], DEFAULTS["db.port"])


if __name__ == "__main__":
    unittest.main()
