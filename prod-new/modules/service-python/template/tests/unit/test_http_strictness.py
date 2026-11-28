"""Second-review hardening of the inbound HTTP adapter, over real sockets where it matters.

Duplicate singleton headers, a bare CR in the head, strictly-UTF-8 JSON bodies, the depth
guard, the request-slot release on every status, and what the transport logs.
"""

import http.client
import json
import logging
import socket
import threading
import time
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from datetime import UTC, datetime

import pytest

from <PACKAGE>.adapters.inbound.http_api import (
    MAX_JSON_DEPTH,
    Api,
    Response,
    _parse,
)
from <PACKAGE>.adapters.inbound.http_server import (
    make_server,
    respond,
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

TOKEN = "k" * 40
WRONG = "w" * 40
GOOD_BODY = b'{"amount": "1.00", "event_id": "e-1"}'


class FaultyApi(Api):
    """``POST /v1/withdrawals`` raises: the barrier must still free the request slot."""

    def handle(self, method: str, path: str, headers: Mapping[str, str], body: bytes) -> Response:
        if path == "/v1/withdrawals":
            raise RuntimeError("boom")
        return super().handle(method, path, headers, body)


def make_api(api_type: type[Api] = Api) -> Api:
    recorder = MetricsRecorder()
    clock = ManualClock(datetime(2026, 1, 1, tzinfo=UTC))
    service = LedgerService(InMemoryEventStore(), clock, SequenceIds(), recorder)
    return api_type(service, recorder.render, TOKEN)


@contextmanager
def serving(api: Api, **limits: float) -> Iterator[int]:
    server = make_server(api, "127.0.0.1", 0, **limits)  # type: ignore[arg-type]
    thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.02), daemon=True)
    thread.start()
    try:
        yield int(server.server_address[1])
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def exchange(port: int, data: bytes) -> bytes:
    """Send bytes, read to EOF; return everything the server answered."""
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.sendall(data)
        chunks = []
        while chunk := sock.recv(4096):
            chunks.append(chunk)
    return b"".join(chunks)


def raw(port: int, data: bytes) -> tuple[int, bytes]:
    """(status, body) of the one response."""
    head, _, body = exchange(port, data).partition(b"\r\n\r\n")
    return int(head.split(b" ", 2)[1]), body


def post(auth: list[str], body: bytes = GOOD_BODY, path: str = "/v1/deposits") -> bytes:
    lines = [f"POST {path} HTTP/1.1", "Host: x", f"Content-Length: {len(body)}"]
    lines += [f"Authorization: {value}" for value in auth]
    return ("\r\n".join(lines) + "\r\n\r\n").encode() + body


def error_code(body: bytes) -> str:
    return str(json.loads(body)["error"])


# ---- duplicate singleton headers ---------------------------------------------------------


# provenance: derived
# verifies: units_ledger/http_surface
def test_a_second_authorization_header_is_a_400_even_when_the_last_one_is_right() -> None:
    with serving(make_api()) as port:
        assert raw(port, post([f"Bearer {TOKEN}"]))[0] == 200  # control: one header works
        for auth in ([f"Bearer {WRONG}", f"Bearer {TOKEN}"], [f"Bearer {TOKEN}", "x"]):
            status, body = raw(port, post(auth))
            assert (status, error_code(body)) == (400, "duplicate_header"), auth


# provenance: derived
# verifies: units_ledger/http_surface
@pytest.mark.parametrize("name", ["Host", "host", "Authorization"])
def test_duplicate_host_and_authorization_are_refused_before_auth_or_body(name: str) -> None:
    def no_read(_: int) -> bytes:
        raise AssertionError("the body must not be read")

    headers = [(name, "a"), (name.swapcase(), "b"), ("Content-Length", "5")]
    status, body, _ = respond(make_api(), "POST", "/v1/deposits", headers, no_read)
    assert (status, error_code(body)) == (400, "duplicate_header")


# provenance: derived
# verifies: units_ledger/http_surface
def test_duplicate_content_length_over_a_socket_is_still_a_400() -> None:
    lines = b"POST /v1/deposits HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n"
    data = lines + b"Content-Length: 2\r\n\r\n{}"
    with serving(make_api()) as port:
        assert raw(port, data)[0] == 400


# ---- a bare CR in the head ---------------------------------------------------------------


# provenance: derived
# verifies: units_ledger/http_surface
@pytest.mark.parametrize(
    "head",
    [
        b"X: a\rTransfer-Encoding: chunked\r\n",
        b"X: a\rContent-Length: 0\r\n",
        b"Authorization: Bearer " + TOKEN.encode() + b"\r\r\nX-Later: 1\r\n",
    ],
)
def test_a_bare_cr_in_the_head_is_a_400(head: bytes) -> None:
    data = b"GET /healthz HTTP/1.1\r\nHost: x\r\n" + head + b"\r\n"
    with serving(make_api()) as port:
        assert raw(port, b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")[0] == 200  # control
        status, body = raw(port, data)
        assert (status, error_code(body)) == (400, "invalid_framing"), head


# provenance: derived
# verifies: units_ledger/http_surface
def test_a_bare_cr_in_the_request_line_is_a_400() -> None:
    with serving(make_api()) as port:
        assert raw(port, b"GET /healthz?a=b\rc HTTP/1.1\r\nHost: x\r\n\r\n")[0] == 400


# ---- strictly UTF-8 JSON -----------------------------------------------------------------


# provenance: derived
# verifies: units_ledger/http_surface
@pytest.mark.parametrize(
    "body",
    [
        GOOD_BODY.decode().encode("utf-16"),
        GOOD_BODY.decode().encode("utf-16-le"),
        GOOD_BODY.decode().encode("utf-16-be"),
        GOOD_BODY.decode().encode("utf-32"),
        b"\xef\xbb\xbf" + GOOD_BODY,  # a UTF-8 BOM
        b'{"amount": "1.00", "event_id": "\xed\xa0\x80"}',  # a lone surrogate, UTF-8 encoded
        b'{"amount": "1.00", "event_id": "\xff"}',
        '{"event_id": [[[[[["x"]]]]]], "amount": "1"}'.encode("utf-16"),  # depth hidden in UTF-16
    ],
)
def test_a_body_that_is_not_strict_utf_8_is_a_400(body: bytes) -> None:
    response = make_api().handle("POST", "/v1/deposits", {"authorization": f"Bearer {TOKEN}"}, body)
    assert (response.status, error_code(response.body)) == (400, "invalid_json")
    ok = make_api().handle("POST", "/v1/deposits", {"authorization": f"Bearer {TOKEN}"}, GOOD_BODY)
    assert ok.status == 200  # control: the same JSON as UTF-8 passes


# provenance: derived
# verifies: units_ledger/http_surface
def test_the_depth_guard_refuses_just_over_the_limit_and_accepts_the_limit() -> None:
    at_limit = "[" * MAX_JSON_DEPTH + "]" * MAX_JSON_DEPTH
    over = "[" * (MAX_JSON_DEPTH + 1) + "]" * (MAX_JSON_DEPTH + 1)
    assert _parse(at_limit.encode()) == [[[[]]]]
    with pytest.raises(ValueError, match="too deep"):
        _parse(over.encode())
    with pytest.raises(ValueError, match="too deep"):
        _parse(('{"a":' * (MAX_JSON_DEPTH + 1) + "1" + "}" * (MAX_JSON_DEPTH + 1)).encode())
    # brackets inside strings do not count
    assert _parse(b'["[[[[[[[[", "\\"[[[[[["]') == ["[[[[[[[[", '"[[[[[[']


# ---- the request slot is released on every status ----------------------------------------


# provenance: derived
# verifies: units_ledger/http_surface
def test_request_slots_are_released_after_error_and_success_statuses_alike() -> None:
    slots = 2
    with serving(make_api(FaultyApi), max_connections=8, max_requests=slots) as port:
        cases = [
            (post([f"Bearer {WRONG}"]), 401),  # error: unauthorized
            (post([f"Bearer {TOKEN}"], b"{"), 400),  # error: invalid JSON
            (post([f"Bearer {TOKEN}"], b"{}", "/v1/withdrawals"), 500),  # error: the barrier
            (post([f"Bearer {TOKEN}"]), 200),  # success
        ]
        for round_number in range(3):  # 12 requests through 2 slots, one after the other
            for data, expected in cases:
                status, _ = raw(port, data)
                assert status == expected, (round_number, expected)
        # capacity is fully available again: `slots` requests held at once are both served
        assert raw(port, post([f"Bearer {TOKEN}"], b'{"amount": "2.00"}'))[0] == 200
        assert raw(port, b"GET /v1/balance HTTP/1.1\r\nHost: x\r\n\r\n")[0] == 200
        assert raw(port, b"GET /v1/balance HTTP/1.1\r\nHost: x\r\n\r\n")[0] == 200


# ---- what the transport logs -------------------------------------------------------------


# provenance: derived
# verifies: units_ledger/http_surface
def test_an_unknown_method_is_logged_as_a_fixed_token(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.INFO)
    with serving(make_api()) as port:
        assert raw(port, b"BREW /healthz HTTP/1.1\r\nHost: x\r\n\r\n")[0] == 501
        assert raw(port, b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")[0] == 200
        time.sleep(0.05)
    assert "BREW" not in caplog.text
    assert "OTHER /" in caplog.text
    assert "GET /healthz -> 200" in caplog.text


# provenance: derived
# verifies: units_ledger/http_surface
def test_a_malformed_request_line_never_reaches_the_log(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    marker = "MARKER-7f3a"
    with serving(make_api()) as port:
        # "Bad request syntax (<the whole request line>)" is the stdlib message that echoes it
        assert raw(port, f"GET /{marker} x HTTP/1.1\r\n\r\n".encode())[0] == 400
        # no status line is sent for an unparsable (HTTP/0.9-shaped) head; the log is the probe
        assert b"400" in exchange(port, f"GET /{marker} x y\r\n\r\n".encode())
        assert b"505" in exchange(port, f"GET /x?token={marker} HTTP/9.9\r\n\r\n".encode())
        time.sleep(0.05)
    assert "protocol error" in caplog.text  # the test means something: it did log
    assert marker not in caplog.text


# provenance: derived
# verifies: units_ledger/http_surface
def test_http_client_still_reads_a_normal_response() -> None:
    with serving(make_api()) as port:
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.request("GET", "/healthz")
        assert connection.getresponse().status == 200
        connection.close()
