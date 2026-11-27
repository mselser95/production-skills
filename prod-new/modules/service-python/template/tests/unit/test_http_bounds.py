"""Resource bounds of the inbound HTTP adapter: deadlines, connection caps, health under flood."""

import http.client
import logging
import select
import socket
import sys
import threading
import time
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from datetime import UTC, datetime

import pytest

from <PACKAGE>.adapters.inbound.http_api import (
    Api,
    Response,
)
from <PACKAGE>.adapters.inbound.http_server import (
    BoundedServer,
    make_server,
)
from <PACKAGE>.adapters.outbound.memory_store import (
    InMemoryEventStore,
)
from <PACKAGE>.app.ledger_service import (
    LedgerService,
)
from <PACKAGE>.platform.clock import (
    ManualClock,
)
from <PACKAGE>.platform.ids import (
    SequenceIds,
)
from <PACKAGE>.platform.observability import (
    MetricsRecorder,
)

TOKEN = "b" * 40
HEAD, TOTAL = 0.3, 0.6
POST_HEAD = (
    b"POST /v1/deposits HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n"
    b"Authorization: Bearer " + TOKEN.encode() + b"\r\n\r\n"
)


class BlockingApi(Api):
    """``GET /v1/balance`` blocks until the test releases it (a slow but valid request)."""

    def __init__(self, inner: Api) -> None:
        self.entered = threading.Semaphore(0)
        self.release = threading.Event()
        self._inner = inner

    def handle(self, method: str, path: str, headers: Mapping[str, str], body: bytes) -> Response:
        if path == "/v1/balance":
            self.entered.release()
            self.release.wait(timeout=10)
        return self._inner.handle(method, path, headers, body)


def make_api() -> BlockingApi:
    recorder = MetricsRecorder()
    clock = ManualClock(datetime(2026, 1, 1, tzinfo=UTC))
    service = LedgerService(InMemoryEventStore(), clock, SequenceIds(), recorder)
    return BlockingApi(Api(service, recorder.render, TOKEN))


@contextmanager
def serving(api: BlockingApi, **limits: float) -> Iterator[tuple[BoundedServer, int]]:
    server = make_server(api, "127.0.0.1", 0, **limits)  # type: ignore[arg-type]
    thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.02), daemon=True)
    thread.start()
    try:
        yield server, int(server.server_address[1])
    finally:
        api.release.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def connect(port: int) -> socket.socket:
    return socket.create_connection(("127.0.0.1", port), timeout=5)


def read_until_closed(sock: socket.socket, limit: float) -> tuple[bytes, float]:
    """Read to EOF; returns (bytes, seconds taken); stops at ``limit`` seconds."""
    start, data = time.monotonic(), b""
    while time.monotonic() - start < limit:
        ready, _, _ = select.select([sock], [], [], 0.05)
        if ready:
            try:
                chunk = sock.recv(4096)
            except ConnectionResetError:
                break
            if not chunk:
                break
            data += chunk
    return data, time.monotonic() - start


def healthz(port: int) -> tuple[int, float]:
    start = time.monotonic()
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        conn.request("GET", "/healthz")
        return conn.getresponse().status, time.monotonic() - start
    finally:
        conn.close()


def trickle(sock: socket.socket, payload: bytes, gap: float, limit: float) -> tuple[bytes, float]:
    """Send one byte per ``gap`` seconds until the server answers or closes; time it."""
    start, data, sent = time.monotonic(), b"", 0
    while time.monotonic() - start < limit:
        if sent < len(payload):
            try:
                sock.send(payload[sent : sent + 1])
            except OSError:
                break
            sent += 1
        ready, _, _ = select.select([sock], [], [], gap)
        if ready:
            try:
                data = sock.recv(4096)
            except ConnectionResetError:
                data = b""
            break
    return data, time.monotonic() - start


def no_traceback(caplog: pytest.LogCaptureFixture) -> None:
    assert "Traceback" not in caplog.text
    assert all(record.exc_info is None for record in caplog.records)
    assert not [r for r in caplog.records if r.levelno >= logging.ERROR]


# provenance: derived
# verifies: units_ledger/http_surface
def test_a_body_trickle_is_cut_at_the_request_deadline(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    with serving(make_api(), head_deadline=HEAD, request_deadline=TOTAL) as (_, port):
        sock = connect(port)
        sock.sendall(
            POST_HEAD
        )  # a complete head, then one body byte every 0.2 s (< any recv timeout)
        data, elapsed = trickle(sock, b"x" * 100, 0.2, limit=3)
        sock.close()
    assert data.startswith(b"HTTP/1.0 408 ")
    assert TOTAL - 0.05 <= elapsed <= TOTAL + 0.5
    no_traceback(caplog)


# provenance: derived
# verifies: units_ledger/http_surface
def test_a_header_trickle_is_cut_at_the_head_deadline(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    with serving(make_api(), head_deadline=HEAD, request_deadline=TOTAL) as (_, port):
        sock = connect(port)
        data, elapsed = trickle(sock, b"GET /healthz HTTP/1.1\r\nX-A: " + b"a" * 100, 0.1, limit=3)
        sock.close()
    assert data.startswith(b"HTTP/1.0 408 ")
    assert HEAD - 0.05 <= elapsed <= HEAD + 0.25  # well below the request deadline
    no_traceback(caplog)


# provenance: derived
# verifies: units_ledger/http_surface
def test_health_survives_stalled_connections_and_threads_stay_bounded(
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.DEBUG)
    cap, active = 12, 4
    with serving(
        make_api(),
        max_connections=cap,
        max_requests=active,
        head_deadline=HEAD,
        request_deadline=TOTAL,
    ) as (_, port):
        base = threading.active_count()
        t0 = time.monotonic()
        stalled = [connect(port) for _ in range(active + 3)]
        for sock in stalled:
            sock.sendall(b"G")
        status, latency = healthz(port)
        peak, until = 0, time.monotonic() + HEAD
        while time.monotonic() < until:
            peak = max(peak, threading.active_count())
            time.sleep(0.05)
        closed = []
        for sock in stalled:
            read_until_closed(sock, HEAD + 0.5)
            closed.append(time.monotonic() - t0)
        for sock in stalled:
            sock.close()
        sys.stdout.write(
            f"flood: {len(stalled)} stalled, healthz {status} in {latency:.3f}s, "
            f"peak threads {peak} (base {base}), last close {max(closed):.2f}s\n"
        )
    assert (status, latency < 1) == (200, True)
    assert peak <= base + cap
    assert HEAD - 0.05 <= max(closed) <= HEAD + 0.25
    no_traceback(caplog)


# provenance: derived
# verifies: units_ledger/http_surface
def test_a_flood_beyond_the_connection_cap_is_shed_and_health_returns_after_the_head_deadline(
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.DEBUG)
    cap = 12
    with serving(
        make_api(),
        max_connections=cap,
        max_requests=4,
        head_deadline=HEAD,
        request_deadline=TOTAL,
    ) as (_, port):
        base = threading.active_count()
        stalled = [connect(port) for _ in range(cap + 3)]
        for sock in stalled:
            sock.sendall(b"G")
        peak = 0
        for _ in range(4):
            peak = max(peak, threading.active_count())
            time.sleep(0.05)
        replies = [read_until_closed(sock, HEAD + 0.5)[0] for sock in stalled]
        status, _ = healthz(port)
        for sock in stalled:
            sock.close()
    assert sum(r.startswith(b"HTTP/1.0 503 ") and b"Retry-After: 1" in r for r in replies) == 3
    assert peak <= base + cap
    assert status == 200
    no_traceback(caplog)


# provenance: derived
# verifies: units_ledger/http_surface
def test_over_the_connection_cap_is_a_503_with_retry_after_and_no_new_thread(
    caplog: pytest.LogCaptureFixture, monkeypatch: pytest.MonkeyPatch
) -> None:
    caplog.set_level(logging.DEBUG)
    api = make_api()
    with serving(
        api, max_connections=2, max_requests=1, head_deadline=HEAD, request_deadline=5
    ) as (
        _,
        port,
    ):
        slow = connect(port)
        slow.sendall(b"GET /v1/balance HTTP/1.1\r\nHost: x\r\n\r\n")
        assert api.entered.acquire(timeout=3)  # a long slot and a connection slot are held
        waiting = connect(port)  # the second connection slot: stalled in its head phase
        waiting.sendall(b"G")
        time.sleep(0.1)
        before = threading.active_count()
        starts: list[str] = []
        original_start = threading.Thread.start

        def counting_start(thread: threading.Thread) -> None:
            starts.append(thread.name)
            original_start(thread)

        monkeypatch.setattr(threading.Thread, "start", counting_start)
        extra = connect(port)
        extra.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
        reply, _ = read_until_closed(extra, 2)
        after = threading.active_count()
        monkeypatch.undo()
        extra.close()
        waiting.close()
        slow.close()
    assert reply.startswith(b"HTTP/1.0 503 ")
    assert b"Retry-After: 1" in reply
    assert starts == []  # not one thread was started for the 503
    assert after <= before
    no_traceback(caplog)


# provenance: derived
# verifies: units_ledger/http_surface
def test_requests_over_the_request_cap_get_503_while_health_is_served(
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.DEBUG)
    api = make_api()
    with serving(
        api, max_connections=4, max_requests=1, head_deadline=HEAD, request_deadline=5
    ) as (
        _,
        port,
    ):
        slow = connect(port)
        slow.sendall(b"GET /v1/balance HTTP/1.1\r\nHost: x\r\n\r\n")
        assert api.entered.acquire(timeout=3)
        second = connect(port)
        second.sendall(b"GET /v1/balance HTTP/1.1\r\nHost: x\r\n\r\n")
        reply, _ = read_until_closed(second, 2)
        status, _ = healthz(port)
        second.close()
        slow.close()
    assert reply.startswith(b"HTTP/1.0 503 ")
    assert b"Retry-After: 1" in reply
    assert status == 200
    no_traceback(caplog)


# provenance: derived
# verifies: units_ledger/http_surface
def test_a_client_reset_mid_request_logs_no_exception(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    with serving(make_api(), head_deadline=HEAD, request_deadline=TOTAL) as (_, port):
        sock = connect(port)
        sock.sendall(POST_HEAD)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
        sock.close()  # an RST while the server waits for the body
        time.sleep(0.2)
        assert healthz(port)[0] == 200
    no_traceback(caplog)


# provenance: derived
# verifies: units_ledger/http_surface
@pytest.mark.parametrize(
    "limits",
    [
        {"max_connections": 2, "max_requests": 2},
        {"max_connections": 2, "max_requests": 0},
        {"head_deadline": 2, "request_deadline": 1},
        {"head_deadline": 0},
    ],
)
def test_nonsensical_limits_are_refused_at_construction(limits: dict[str, float]) -> None:
    with pytest.raises(ValueError, match="need"):
        make_server(make_api(), "127.0.0.1", 0, **limits)  # type: ignore[arg-type]
