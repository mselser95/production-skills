"""A framework-free HTTP API: ``Api.handle`` maps (method, path, headers, body) to a Response.

Writes need a bearer token (compared in constant time); the body is size-capped; amounts
travel as strings and a JSON number in ``amount`` is refused, so no float enters the service.
"""

import hmac
import json
from collections.abc import Callable, Mapping
from dataclasses import dataclass

from <PACKAGE>.app.ledger_service import LedgerService
from <PACKAGE>.domain.errors import DomainError, InsufficientFunds

MAX_BODY_BYTES = 4096
JSON = "application/json"
TEXT = "text/plain; version=0.0.4; charset=utf-8"


@dataclass(frozen=True, slots=True)
class Response:
    status: int
    body: bytes
    content_type: str = JSON


def _json(status: int, payload: Mapping[str, str]) -> Response:
    return Response(status, json.dumps(payload).encode())


def _error(status: int, code: str) -> Response:
    return _json(status, {"error": code})


class Api:
    def __init__(
        self, service: LedgerService, metrics_text: Callable[[], str], api_token: str
    ) -> None:
        self._service = service
        self._metrics_text = metrics_text
        self._token = api_token.encode()

    def handle(self, method: str, path: str, headers: Mapping[str, str], body: bytes) -> Response:
        if method == "GET":
            return self._read(path)
        if method == "POST" and path in {"/v1/deposits", "/v1/withdrawals"}:
            return self._write(path, headers, body)
        known = path in {"/healthz", "/metrics", "/v1/balance", "/v1/deposits", "/v1/withdrawals"}
        return _error(405, "method_not_allowed") if known else _error(404, "not_found")

    def _read(self, path: str) -> Response:
        if path == "/healthz":
            return _json(200, {"status": "ok"})
        if path == "/metrics":
            return Response(200, self._metrics_text().encode(), TEXT)
        if path == "/v1/balance":
            return _json(200, {"balance": self._service.balance().format()})
        if path in {"/v1/deposits", "/v1/withdrawals"}:
            return _error(405, "method_not_allowed")
        return _error(404, "not_found")

    def _authorized(self, headers: Mapping[str, str]) -> bool:
        scheme, _, presented = headers.get("authorization", "").partition(" ")
        return scheme == "Bearer" and hmac.compare_digest(presented.encode(), self._token)

    def _write(self, path: str, headers: Mapping[str, str], body: bytes) -> Response:  # noqa: PLR0911
        if not self._authorized(headers):
            return _error(401, "unauthorized")
        if len(body) > MAX_BODY_BYTES:
            return _error(413, "body_too_large")
        try:
            payload = json.loads(body)
        except ValueError:
            return _error(400, "invalid_json")
        if not isinstance(payload, dict) or not set(payload) <= {"amount", "event_id"}:
            return _error(400, "invalid_body")
        amount, event_id = payload.get("amount"), payload.get("event_id")
        if not isinstance(amount, str) or not (event_id is None or isinstance(event_id, str)):
            return _error(400, "invalid_body")
        try:
            if path == "/v1/deposits":
                receipt = self._service.deposit(amount, event_id)
            else:
                receipt = self._service.withdraw(amount, event_id)
        except InsufficientFunds:
            return _error(409, "insufficient_funds")
        except DomainError:
            return _error(400, "invalid_request")
        return _json(
            200,
            {
                "event_id": receipt.event_id,
                "outcome": receipt.outcome.value,
                "balance": receipt.balance.format(),
            },
        )
