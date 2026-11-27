import http.client
import os
import signal
import threading

import pytest

from <PACKAGE> import __main__ as root
from <PACKAGE>.platform.config import Config


def cfg(port: int = 0) -> Config:
    return Config("127.0.0.1", port, "t" * 16, "rev-1")


# provenance: derived
# verifies: composition_root/wiring
def test_build_wires_the_service_and_emits_build_info() -> None:
    runtime = root.build(cfg())
    response = runtime.api.handle("GET", "/metrics", {}, b"")
    assert 'svc_build_info{revision="rev-1"} 1' in response.body.decode()


# provenance: derived
# verifies: composition_root/clean_shutdown
def test_run_serves_until_stopped_then_releases_the_port() -> None:
    stop, ready = threading.Event(), threading.Event()
    ports: list[int] = []
    result: list[int] = []

    def on_ready(port: int) -> None:
        ports.append(port)
        ready.set()

    thread = threading.Thread(target=lambda: result.append(root.run(cfg(), stop, on_ready)))
    thread.start()
    assert ready.wait(timeout=5)
    connection = http.client.HTTPConnection("127.0.0.1", ports[0], timeout=5)
    connection.request("GET", "/healthz")
    assert connection.getresponse().status == 200
    connection.close()
    stop.set()
    thread.join(timeout=10)
    assert not thread.is_alive()
    assert result == [0]
    with pytest.raises(OSError):  # noqa: PT011 - any refusal proves the socket is closed
        http.client.HTTPConnection("127.0.0.1", ports[0], timeout=2).request("GET", "/healthz")


# provenance: derived
# verifies: composition_root/refuses_bad_config
def test_main_exits_2_without_a_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("SVC_API_TOKEN", raising=False)
    assert root.main() == 2


# provenance: derived
# verifies: composition_root/clean_shutdown
def test_main_shuts_down_cleanly_on_sigterm(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SVC_API_TOKEN", "t" * 16)
    monkeypatch.setenv("SVC_PORT", "0")
    saved = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGTERM)}
    timer = threading.Timer(0.3, os.kill, args=(os.getpid(), signal.SIGTERM))
    timer.start()
    try:
        assert root.main() == 0
    finally:
        timer.cancel()
        for signum, handler in saved.items():
            signal.signal(signum, handler if handler is not None else signal.SIG_DFL)
