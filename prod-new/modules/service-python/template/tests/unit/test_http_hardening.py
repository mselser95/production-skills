"""Input hardening of the inbound HTTP adapter: framing, barrier, token, logging, JSON, fuzz."""

import ast
import hmac
import http.client
import inspect
import json
import logging
import textwrap
import threading
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from datetime import UTC, datetime

import pytest
from hypothesis import given
from hypothesis import strategies as st

from <PACKAGE>.adapters.inbound.http_api import (
    MAX_BODY_BYTES,
    Api,
)
from <PACKAGE>.adapters.inbound.http_server import (
    LOGGED_PATH_LIMIT,
    frame,
    log_path,
    make_server,
    printable,
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

TOKEN = "s3cret-" + "t" * 32
AUTH = {"authorization": f"Bearer {TOKEN}"}
ALLOWED_STATUSES = {200, 400, 401, 404, 405, 409, 413, 500}


def make_api() -> Api:
    recorder = MetricsRecorder()
    clock = ManualClock(datetime(2026, 1, 1, tzinfo=UTC))
    service = LedgerService(InMemoryEventStore(), clock, SequenceIds(), recorder)
    return Api(service, recorder.render, TOKEN)


def no_read(_: int) -> bytes:
    raise AssertionError("the body must not be read")


@contextmanager
def serving(api: Api) -> Iterator[int]:
    server = make_server(api, "127.0.0.1", 0)
    thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.05), daemon=True)
    thread.start()
    try:
        yield int(server.server_address[1])
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def call(port: int, method: str, path: str, headers: dict[str, str]) -> tuple[int, bytes]:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request(method, path, headers=headers)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


# ---- B1: framing ---------------------------------------------------------------------------


# provenance: derived
# verifies: units_ledger/http_surface
@pytest.mark.parametrize(
    "value",
    ["9" * 5000, "9" * 11, "-1", "+1", " 1", "1 ", "1\n", "0x10", "1e3", chr(0x661), "", "1_0"],
)
def test_a_malformed_content_length_is_a_400_never_an_exception(value: str) -> None:
    status, body, _ = respond(
        make_api(), "POST", "/v1/deposits", [("Content-Length", value)], no_read
    )
    assert (status, json.loads(body)) == (400, {"error": "invalid_length"})


# provenance: derived
# verifies: units_ledger/http_surface
def test_duplicate_content_length_is_a_400_even_when_the_values_agree() -> None:
    headers = [("Content-Length", "2"), ("content-length", "2")]
    assert respond(make_api(), "POST", "/v1/deposits", headers, no_read)[0] == 400


# provenance: derived
# verifies: units_ledger/http_surface
@pytest.mark.parametrize("value", ["chunked", "identity", ""])
def test_any_transfer_encoding_is_a_400(value: str) -> None:
    headers = [("transfer-encoding", value)]
    assert respond(make_api(), "POST", "/v1/deposits", headers, no_read)[0] == 400
    assert respond(make_api(), "GET", "/healthz", headers, no_read)[0] == 400


# provenance: derived
# verifies: units_ledger/http_surface
@pytest.mark.parametrize("method", ["GET", "HEAD"])
def test_a_body_on_get_or_head_is_a_400(method: str) -> None:
    assert respond(make_api(), method, "/healthz", [("Content-Length", "2")], no_read)[0] == 400
    assert respond(make_api(), method, "/healthz", [("Content-Length", "0")], no_read)[0] != 400


# provenance: derived
# verifies: units_ledger/http_surface
def test_a_declared_length_above_the_cap_is_a_413_and_the_body_is_never_read() -> None:
    headers = [("Content-Length", str(MAX_BODY_BYTES + 1))]
    status, body, _ = respond(make_api(), "POST", "/v1/deposits", headers, no_read)
    assert (status, json.loads(body)) == (413, {"error": "body_too_large"})
    assert frame("POST", [("Content-Length", str(MAX_BODY_BYTES))]) == MAX_BODY_BYTES


# provenance: derived
# verifies: units_ledger/http_surface
def test_a_5000_digit_content_length_over_a_real_socket_is_a_400_before_auth() -> None:
    with serving(make_api()) as port:
        status, _ = call(port, "GET", "/healthz", {"Content-Length": "9" * 5000})
        assert status == 400
        assert call(port, "GET", "/healthz", {})[0] == 200  # the server is still alive


# ---- B1: the exception barrier ------------------------------------------------------------


# provenance: derived
# verifies: units_ledger/http_surface
def test_an_exception_in_handle_is_a_generic_500_with_one_type_only_log_line(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    def boom(*_: object) -> None:
        raise RuntimeError(f"leaks {TOKEN}")

    monkeypatch.setattr(Api, "handle", boom)
    caplog.set_level(logging.DEBUG)
    with serving(make_api()) as port:
        status, body = call(port, "GET", "/healthz?x=1", {"Authorization": f"Bearer {TOKEN}"})
    assert (status, json.loads(body)) == (500, {"error": "internal_error"})
    errors = [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert [r.getMessage() for r in errors] == ["request failed: RuntimeError"]
    assert errors[0].exc_info is None
    assert TOKEN not in caplog.text


# provenance: derived
# verifies: units_ledger/http_surface
def test_a_failing_body_read_is_a_500_not_an_exception() -> None:
    def broken(_: int) -> bytes:
        raise TimeoutError("socket")

    reply = respond(make_api(), "POST", "/v1/deposits", [("Content-Length", "3")], broken)
    assert reply[0] == 500


# ---- W1: the token --------------------------------------------------------------------------


# provenance: derived
# verifies: units_ledger/write_authn
@pytest.mark.parametrize(
    "header",
    [
        f"Bearer  {TOKEN}",
        f"Bearer {TOKEN} ",
        f" Bearer {TOKEN}",
        f"bearer {TOKEN}",
        f"Bearer\t{TOKEN}",
        f"Bearer {TOKEN}\n",
        f"Bearer {TOKEN}, Bearer {TOKEN}",
        f"Bearer {TOKEN}é",
        "Bearer ",
        "Bearer",
    ],
)
def test_the_authorization_header_is_parsed_strictly(header: str) -> None:
    api = make_api()
    assert (
        api.handle("POST", "/v1/deposits", {"authorization": header}, b'{"amount": "1"}').status
        == 401
    )
    assert api.handle("POST", "/v1/deposits", AUTH, b'{"amount": "1"}').status == 200


# provenance: derived
# verifies: units_ledger/write_authn
def test_the_comparison_goes_through_the_constant_time_helper(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[tuple[bytes, bytes]] = []
    real = hmac.compare_digest

    def recording(a: bytes, b: bytes) -> bool:
        calls.append((a, b))
        return real(a, b)

    monkeypatch.setattr(hmac, "compare_digest", recording)
    api = make_api()
    api.handle("POST", "/v1/deposits", AUTH, b'{"amount": "1"}')
    api.handle("POST", "/v1/deposits", {"authorization": "Bearer wrong"}, b"{}")
    assert calls == [(TOKEN.encode(), TOKEN.encode()), (b"wrong", TOKEN.encode())]


# provenance: derived
# verifies: units_ledger/write_authn
def test_authorized_has_no_equality_comparison() -> None:
    source = textwrap.dedent(inspect.getsource(Api._authorized))
    comparisons = [n for n in ast.walk(ast.parse(source)) if isinstance(n, ast.Compare)]
    equalities = [
        c for c in comparisons if any(isinstance(op, (ast.Eq, ast.NotEq)) for op in c.ops)
    ]
    assert equalities == []
    assert "compare_digest" in source


# ---- W2: logging ----------------------------------------------------------------------------


# provenance: derived
# verifies: units_ledger/write_authn
@pytest.mark.parametrize("name", ["token", "access_token", "TOKEN", "Access_Token", "to%6Ben"])
def test_a_token_query_parameter_is_a_400(name: str) -> None:
    api = make_api()
    for path in (f"/healthz?{name}=x", f"/v1/balance?a=1&{name}=x", f"/healthz?a=1;{name}=x"):
        assert api.handle("GET", path, {}, b"").status == 400
    assert api.handle("GET", "/healthz?other=1", {}, b"").status == 200


# provenance: derived
# verifies: units_ledger/write_authn
def test_secrets_never_reach_the_log(caplog: pytest.LogCaptureFixture) -> None:
    secret = "hunter2-" + "z" * 24
    caplog.set_level(logging.DEBUG)
    with serving(make_api()) as port:
        assert call(port, "GET", f"/healthz?token={secret}", {})[0] == 400
        assert call(port, "GET", f"/v1/balance?x=1&access_token={secret}", {})[0] == 400
        assert call(port, "GET", f"/v1/{secret}/x", {})[0] == 404
        assert call(port, "GET", "/healthz", {"Authorization": f"Bearer {secret}"})[0] == 200
        assert call(port, "GET", "/healthz", {"X-Api-Key": secret})[0] == 200
        assert call(port, "GET", f"/healthz%00?a={secret}", {"X-Y": secret})[0] == 404
    assert caplog.records, "the transport must log something for this test to mean anything"
    assert secret not in caplog.text
    assert "?" not in caplog.text
    assert "GET /healthz -> 200" in caplog.text


# provenance: derived
# verifies: units_ledger/http_surface
def test_the_logged_path_is_truncated_and_control_characters_are_escaped() -> None:
    assert printable("a\x00b\r\né") == "a\\u0000b\\u000d\\u000a\\u00e9"
    assert len(printable("x" * 1000)) == LOGGED_PATH_LIMIT
    assert log_path("/v1/balance?token=abc") == "/v1/balance"
    assert log_path("/not/a/route?token=abc") == "-"


# ---- W5: JSON bodies ------------------------------------------------------------------------


def post_raw(body: bytes, path: str = "/v1/deposits") -> int:
    return make_api().handle("POST", path, AUTH, body).status


# provenance: derived
# verifies: units_ledger/http_surface
@pytest.mark.parametrize(
    "body",
    [
        b'{"amount": "1", "amount": "2"}',
        b'{"amount": "1", "event_id": "a", "event_id": "b"}',
        b'["1"]',
        b'"1"',
        b"1",
        b"null",
        b'{"amount": "1", "extra": "x"}',
        b'{"amount": NaN}',
        b'{"amount": "1", "event_id": Infinity}',
        b'{"amount": -Infinity}',
        b"[" * 2000,
        b'{"a":' * 500,
        b'{"amount": "1", "event_id": ' + b"[" * 900 + b"]" * 900 + b"}",
        b'{"amount": "' + b"9" * 4000,
        b"\xff\xfe",
        b"",
    ],
)
def test_strict_json_bodies_are_a_400(body: bytes) -> None:
    assert post_raw(body) == 400


# provenance: derived
# verifies: units_ledger/http_surface
def test_a_huge_document_is_refused_and_a_valid_one_still_passes() -> None:
    assert post_raw(b'{"amount": "' + b"9" * MAX_BODY_BYTES + b'"}') == 413
    assert post_raw(b'{"amount": "1.50", "event_id": "br{ace]s\\"[["}') == 200


# ---- fuzz -----------------------------------------------------------------------------------

text = st.text(max_size=40)
headers_st = st.lists(st.tuples(text, text), max_size=5) | st.lists(
    st.tuples(
        st.sampled_from(["Content-Length", "content-length", "Transfer-Encoding", "Authorization"]),
        st.sampled_from(["0", "5", "99999999999", "chunked", f"Bearer {TOKEN}", "Bearer ", "x"]),
    ),
    max_size=4,
)
methods = st.sampled_from(["GET", "POST", "HEAD", "PUT", "DELETE", ""]) | text
paths = (
    st.sampled_from(["/healthz", "/v1/deposits", "/v1/balance", "/metrics"]).flatmap(
        lambda p: st.sampled_from([p, p + "?token=1", p + "?a=%zz", p + "\x00"])
    )
    | text
)


def reader(data: bytes) -> Callable[[int], bytes]:
    return lambda n: data[:n]


# provenance: derived
# verifies: units_ledger/http_surface
@pytest.mark.property
@given(
    method=methods,
    path=paths,
    headers=headers_st,
    body=st.binary(max_size=64) | st.sampled_from([b'{"amount": "1"}', b'{"amount":', b"[" * 500]),
)
def test_fuzz_the_server_always_answers_with_an_allowed_status(
    method: str, path: str, headers: list[tuple[str, str]], body: bytes
) -> None:
    status, reply_body, content_type = respond(make_api(), method, path, headers, reader(body))
    assert status in ALLOWED_STATUSES
    assert isinstance(reply_body, bytes)
    assert content_type


# provenance: derived
# verifies: units_ledger/http_surface
@pytest.mark.property
@given(
    method=methods,
    path=paths,
    headers=st.dictionaries(text, text, max_size=4),
    body=st.binary(max_size=5000)
    | st.sampled_from([b'{"amount": "1"}', b"[" * 3000, b'{"amount":' * 400]),
)
def test_fuzz_handle_never_raises(
    method: str, path: str, headers: dict[str, str], body: bytes
) -> None:
    response = make_api().handle(method, path, headers, body)
    assert response.status in ALLOWED_STATUSES - {500}
