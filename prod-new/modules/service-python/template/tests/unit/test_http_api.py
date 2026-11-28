import http.client
import json
import threading
from datetime import UTC, datetime

import pytest

from <PACKAGE>.adapters.inbound.http_api import (
    MAX_BODY_BYTES,
    Api,
)
from <PACKAGE>.adapters.inbound.http_server import (
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

TOKEN = "t" * 20
AUTH = {"authorization": f"Bearer {TOKEN}"}


def make_api() -> Api:
    recorder = MetricsRecorder()
    clock = ManualClock(datetime(2026, 1, 1, tzinfo=UTC))
    service = LedgerService(InMemoryEventStore(), clock, SequenceIds(), recorder)
    return Api(service, recorder.render, TOKEN)


def post(
    api: Api, path: str, payload: object, headers: dict[str, str] | None = None
) -> tuple[int, dict[str, str]]:
    response = api.handle(
        "POST", path, AUTH if headers is None else headers, json.dumps(payload).encode()
    )
    return response.status, json.loads(response.body)


# provenance: derived
# verifies: units_ledger/http_surface
def test_deposit_then_read_the_balance() -> None:
    api = make_api()
    status, body = post(api, "/v1/deposits", {"amount": "12.34", "event_id": "k1"})
    assert (status, body) == (200, {"event_id": "k1", "outcome": "applied", "balance": "12.34"})
    balance = api.handle("GET", "/v1/balance", {}, b"")
    assert (balance.status, json.loads(balance.body)) == (200, {"balance": "12.34"})
    assert api.handle("GET", "/healthz", {}, b"").status == 200


# provenance: derived
# verifies: units_ledger/write_authn
@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"authorization": "Bearer wrong"},
        {"authorization": TOKEN},
        {"authorization": f"Basic {TOKEN}"},
    ],
)
def test_writes_without_the_exact_bearer_token_are_refused_and_do_nothing(
    headers: dict[str, str],
) -> None:
    api = make_api()
    assert post(api, "/v1/deposits", {"amount": "1"}, headers)[0] == 401
    assert json.loads(api.handle("GET", "/v1/balance", {}, b"").body) == {"balance": "0.00"}


# provenance: derived
# verifies: units_ledger/http_surface
@pytest.mark.parametrize(
    "payload",
    [
        {"amount": 5},
        {"amount": 5.5},
        {"amount": None},
        {},
        {"amount": "1", "extra": "x"},
        {"amount": "1", "event_id": 7},
        ["1"],
    ],
)
def test_malformed_bodies_are_400(payload: object) -> None:
    assert post(make_api(), "/v1/deposits", payload)[0] == 400


# provenance: derived
# verifies: units_ledger/http_surface
def test_domain_errors_map_to_400_and_409() -> None:
    api = make_api()
    assert post(api, "/v1/deposits", {"amount": "-1"}) == (400, {"error": "invalid_request"})
    assert post(api, "/v1/deposits", {"amount": "1", "event_id": ""}) == (
        400,
        {"error": "invalid_request"},
    )
    assert post(api, "/v1/withdrawals", {"amount": "1"}) == (409, {"error": "insufficient_funds"})


# provenance: derived
# verifies: units_ledger/http_surface
def test_invalid_json_and_oversized_bodies_are_refused() -> None:
    api = make_api()
    assert api.handle("POST", "/v1/deposits", AUTH, b"{").status == 400
    assert api.handle("POST", "/v1/deposits", AUTH, b" " * (MAX_BODY_BYTES + 1)).status == 413


# provenance: derived
# verifies: units_ledger/http_surface
def test_unknown_paths_and_wrong_methods() -> None:
    api = make_api()
    assert api.handle("GET", "/nope", {}, b"").status == 404
    assert api.handle("POST", "/nope", AUTH, b"{}").status == 404
    assert api.handle("GET", "/v1/deposits", {}, b"").status == 405
    assert api.handle("POST", "/v1/balance", AUTH, b"{}").status == 405
    assert api.handle("DELETE", "/v1/balance", {}, b"").status == 405


# provenance: derived
# verifies: health_metrics_surface/metrics
def test_metrics_endpoint_serves_prometheus_text() -> None:
    api = make_api()
    post(api, "/v1/deposits", {"amount": "1"})
    response = api.handle("GET", "/metrics", {}, b"")
    text = response.body.decode()
    assert response.content_type.startswith("text/plain")
    assert 'svc_commands_total{command="deposit",outcome="applied"} 1' in text


def _request(
    port: int, method: str, path: str, body: bytes | None, headers: dict[str, str]
) -> tuple[int, bytes]:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


# provenance: derived
# verifies: units_ledger/http_surface
def test_the_stdlib_transport_serves_the_api_over_a_real_socket() -> None:
    server = make_server(make_api(), "127.0.0.1", 0)
    port = int(server.server_address[1])
    thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.05), daemon=True)
    thread.start()
    try:
        assert _request(port, "GET", "/healthz", None, {})[0] == 200
        status, body = _request(
            port,
            "POST",
            "/v1/deposits",
            b'{"amount": "2.00"}',
            {"Authorization": f"Bearer {TOKEN}"},
        )
        assert (status, json.loads(body)["balance"]) == (200, "2.00")
        assert _request(port, "POST", "/v1/deposits", b"{}", {"Content-Length": "x1"})[0] == 400
        assert _request(port, "GET", "/missing", None, {})[0] == 404
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
