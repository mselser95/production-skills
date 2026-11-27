from datetime import UTC, datetime, timedelta

import pytest

from <PACKAGE>.platform import config
from <PACKAGE>.platform.clock import ManualClock, SystemClock
from <PACKAGE>.platform.ids import SequenceIds, UuidIds
from <PACKAGE>.platform.observability import MetricsRecorder, NullRecorder

GOOD = {"SVC_API_TOKEN": "t" * 16}


# provenance: derived
# verifies: platform/config
def test_config_defaults_and_overrides() -> None:
    cfg = config.load(GOOD)
    assert (cfg.host, cfg.port, cfg.revision) == ("127.0.0.1", 8080, "unknown")
    cfg = config.load({**GOOD, "SVC_HOST": "0.0.0.0", "SVC_PORT": "0", "SVC_REVISION": "abc"})  # noqa: S104
    assert (cfg.host, cfg.port, cfg.revision) == ("0.0.0.0", 0, "abc")  # noqa: S104


# provenance: derived
# verifies: platform/config
def test_config_lists_every_problem_and_never_prints_the_token() -> None:
    with pytest.raises(config.ConfigError) as caught:
        config.load({"SVC_PORT": "70000", "SVC_API_TOKEN": "short"})
    assert "SVC_PORT" in str(caught.value)
    assert "SVC_API_TOKEN" in str(caught.value)
    assert "t" * 16 not in repr(config.load(GOOD))


# provenance: derived
# verifies: platform/config
@pytest.mark.parametrize("port", ["", "-1", "http", "1e3", "\N{ARABIC-INDIC DIGIT ONE}"])
def test_config_refuses_a_non_numeric_port(port: str) -> None:
    with pytest.raises(config.ConfigError):
        config.load({**GOOD, "SVC_PORT": port})


# provenance: derived
# verifies: platform/config
def test_config_reads_the_process_environment_by_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SVC_API_TOKEN", "e" * 16)
    assert config.load().api_token == "e" * 16
    monkeypatch.delenv("SVC_API_TOKEN")
    with pytest.raises(config.ConfigError):
        config.load()


# provenance: derived
# verifies: platform/clock_ids
def test_clocks_and_id_generators() -> None:
    assert SystemClock().now().tzinfo is not None
    clock = ManualClock(datetime(2026, 1, 1, tzinfo=UTC))
    clock.advance(timedelta(seconds=5))
    assert clock.now() == datetime(2026, 1, 1, 0, 0, 5, tzinfo=UTC)
    with pytest.raises(ValueError, match="timezone"):
        ManualClock(datetime(2026, 1, 1))  # noqa: DTZ001 - the point of the test
    ids = SequenceIds("x")
    assert [ids.new_id(), ids.new_id()] == ["x-1", "x-2"]
    generated = {UuidIds().new_id() for _ in range(5)}
    assert len(generated) == 5
    assert all(len(i) == 32 for i in generated)


# provenance: derived
# verifies: health_metrics_surface/metrics
def test_metrics_recorder_renders_sorted_escaped_prometheus_text() -> None:
    recorder = MetricsRecorder()
    recorder.counter("b_total", outcome='we"ird\\\n')
    recorder.counter("b_total", outcome='we"ird\\\n')
    recorder.gauge("a_gauge", 7)
    recorder.gauge("a_gauge", 9)
    assert recorder.render() == (
        "# TYPE a_gauge gauge\n"
        "a_gauge 9\n"
        "# TYPE b_total counter\n"
        'b_total{outcome="we\\"ird\\\\\\n"} 2\n'
    )
    with recorder.span("anything", k="v"):
        pass


# provenance: derived
# verifies: health_metrics_surface/metrics
def test_null_recorder_accepts_every_signal() -> None:
    recorder = NullRecorder()
    recorder.counter("c")
    recorder.gauge("g", 1)
    with recorder.span("s"):
        pass
