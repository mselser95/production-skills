"""Standard-library HTTP transport around ``Api``, with hard resource bounds.

NOT hardened for the open internet. Bounded here: a whole-request DEADLINE (accept to the last
body byte, enforced by setting the socket timeout from the REMAINING budget before every
``recv``, so a byte-a-second trickle is cut at the deadline), a short HEAD deadline, a cap on
concurrent connections (thread count never exceeds it; extras get a fixed 503 on the accept
thread, no handler thread), a cap on concurrent requests past the head, a body cap, strict
framing, and an exception barrier. Health: every connection starts in a head phase of at most
HEAD_DEADLINE_SECONDS; only MAX_ACTIVE_REQUESTS < MAX_CONNECTIONS connections can be in the
long phase (a slot taken after the head, except GET /healthz and /metrics which take none), so
slow-body clients can never fill the connection cap and a stalled client frees its slot within
the head deadline. A storm of NEW stalled connections faster than cap/head-deadline per second
can still fill the head phase: that is a per-client limit and belongs in the proxy. NOT here:
TLS, per-client rate or connection limits, slow-read (response) protection beyond a write
timeout. Put a reverse proxy / TLS terminator in front (TLS, client timeouts, request size,
per-client connection limits).
"""

import contextlib
import io
import logging
import re
import socket
import threading
import time
from collections.abc import Callable, Sequence
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from <PACKAGE>.adapters.inbound.http_api import (
    MAX_BODY_BYTES,
    ROUTES,
    Api,
)

_LOG = logging.getLogger(__name__)
REQUEST_TIMEOUT_SECONDS = 10.0  # whole request: accept to last body byte
HEAD_DEADLINE_SECONDS = 2.0  # accept to the end of the request head
MAX_CONNECTIONS = 128  # connections (= handler threads) alive at once
MAX_ACTIVE_REQUESTS = 64  # of those, requests past their head (strictly below MAX_CONNECTIONS)
RETRY_AFTER_SECONDS = 1
BACKLOG = 128
MAX_LENGTH_DIGITS = 10
LOGGED_PATH_LIMIT = 64
JSON = "application/json"
HEALTH_PATHS = frozenset({"/healthz", "/metrics"})
_DIGITS = re.compile(rf"[0-9]{{1,{MAX_LENGTH_DIGITS}}}", re.ASCII)
_UNSAFE = re.compile(r"[^\x21-\x7e]", re.ASCII)
_BODYLESS = frozenset({"GET", "HEAD"})
_MIN_TIMEOUT = 0.001
_SHED_LOG_EVERY = 100
_DRAIN_BYTES = 65536

Reply = tuple[int, bytes, str]
_Sock = socket.socket
_Client = tuple[str, int]


class DeadlineExceededError(TimeoutError):
    """The request's head or whole-request budget ran out (a plain ``TimeoutError`` is not this)."""


def _refuse(status: int, code: str) -> Reply:
    return status, b'{"error": "' + code.encode() + b'"}', JSON


_SHED_BODY = _refuse(503, "over_capacity")[1]
_SHED_RESPONSE = (
    b"HTTP/1.0 503 Service Unavailable\r\n"
    b"Retry-After: " + str(RETRY_AFTER_SECONDS).encode() + b"\r\n"
    b"Content-Type: application/json\r\n"
    b"Content-Length: " + str(len(_SHED_BODY)).encode() + b"\r\n"
    b"Connection: close\r\n\r\n" + _SHED_BODY
)


def frame(method: str, headers: Sequence[tuple[str, str]]) -> int | Reply:  # noqa: PLR0911
    """Validate the body framing; return the declared body length or the refusal to send.

    Exactly one ``Content-Length`` of 1-10 ASCII digits (absent means 0); no
    ``Transfer-Encoding`` of any kind; no body on GET/HEAD; a length above the cap is a 413.
    """
    names = [name.lower() for name, _ in headers]
    if "transfer-encoding" in names:
        return _refuse(400, "invalid_framing")
    values = [value for name, value in headers if name.lower() == "content-length"]
    if len(values) > 1:
        return _refuse(400, "invalid_length")
    if not values:
        return 0
    if _DIGITS.fullmatch(values[0]) is None:
        return _refuse(400, "invalid_length")
    length = int(values[0])
    if method in _BODYLESS and length > 0:
        return _refuse(400, "unexpected_body")
    if length > MAX_BODY_BYTES:
        return _refuse(413, "body_too_large")
    return length


def printable(text: str, limit: int = LOGGED_PATH_LIMIT) -> str:
    """Truncate to ``limit`` characters and escape everything outside printable ASCII."""
    return _UNSAFE.sub(lambda m: f"\\u{ord(m.group()):04x}", text[:limit])


def log_path(raw_path: str) -> str:
    """The path as logged: no query string, and only a known route is echoed at all."""
    path = raw_path.partition("?")[0]
    return printable(path) if path in ROUTES else "-"


def respond(
    api: Api,
    method: str,
    raw_path: str,
    headers: Sequence[tuple[str, str]],
    read: Callable[[int], bytes],
) -> Reply:
    """One request in, one reply out. The exception barrier: this function never raises."""
    try:
        framed = frame(method, headers)
        if not isinstance(framed, int):
            return framed
        body = read(framed) if framed else b""
        response = api.handle(method, raw_path, {k.lower(): v for k, v in headers}, body)
    except DeadlineExceededError:
        return _refuse(408, "request_timeout")
    except ConnectionError as error:  # the peer reset: not a fault of ours, nobody to tell
        _LOG.info("client gone: %s", type(error).__name__)
        return _refuse(400, "client_gone")
    except Exception as error:  # noqa: BLE001 - the barrier: nothing may escape a request
        _LOG.error("request failed: %s", type(error).__name__)
        return _refuse(500, "internal_error")
    return response.status, response.body, response.content_type


class _Budget:
    """The current absolute deadline (monotonic) of one connection: head first, then whole."""

    def __init__(self, head_seconds: float, total_seconds: float) -> None:
        self.started = time.monotonic()
        self.total_until = self.started + total_seconds
        self.until = min(self.started + head_seconds, self.total_until)
        self.expired = False

    def enter_body_phase(self) -> None:
        self.until = self.total_until


class _DeadlineReader(io.RawIOBase):
    """Raw socket reader: every ``recv`` gets the REMAINING budget as its socket timeout."""

    def __init__(self, sock: socket.socket, budget: _Budget) -> None:
        self._sock = sock
        self._budget = budget

    def readable(self) -> bool:
        return True

    def readinto(self, buffer: bytearray | memoryview) -> int:  # type: ignore[override]
        remaining = self._budget.until - time.monotonic()
        if remaining <= 0:
            self._budget.expired = True
            raise DeadlineExceededError("deadline")
        self._sock.settimeout(max(remaining, _MIN_TIMEOUT))
        try:
            return self._sock.recv_into(buffer)
        except TimeoutError as error:
            self._budget.expired = True
            raise DeadlineExceededError("deadline") from error


class BoundedServer(ThreadingHTTPServer):
    """Threading server with a connection cap, a request cap and a drain with a deadline."""

    daemon_threads = True  # abandoned requests must not keep the process alive past the grace
    request_queue_size = BACKLOG

    def __init__(  # noqa: PLR0913
        self,
        address: tuple[str, int],
        handler: type[BaseHTTPRequestHandler],
        *,
        max_connections: int,
        max_requests: int,
        head_deadline: float,
        request_deadline: float,
    ) -> None:
        if not 0 < max_requests < max_connections:
            raise ValueError("need 0 < max_requests < max_connections")
        if not 0 < head_deadline <= request_deadline:
            raise ValueError("need 0 < head_deadline <= request_deadline")
        self.head_deadline = head_deadline
        self.request_deadline = request_deadline
        self.connection_slots = threading.BoundedSemaphore(max_connections)
        self.request_slots = threading.BoundedSemaphore(max_requests)
        self._inflight = 0
        self._shed = 0
        self._idle = threading.Condition()
        super().__init__(address, handler)

    def process_request(self, request: _Sock, client_address: _Client) -> None:  # type: ignore[override]
        if not self.connection_slots.acquire(blocking=False):
            self._shed_connection(request)
            return
        with self._idle:
            self._inflight += 1
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._finished()
            raise

    def process_request_thread(self, request: _Sock, client_address: _Client) -> None:  # type: ignore[override]
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._finished()

    def _finished(self) -> None:
        self.connection_slots.release()
        with self._idle:
            self._inflight -= 1
            self._idle.notify_all()

    def _shed_connection(self, request: socket.socket) -> None:
        """Over the connection cap: a fixed 503, bounded work, on the accept thread, no thread."""
        self._shed += 1
        if self._shed % _SHED_LOG_EVERY == 1:
            _LOG.warning("connection cap reached: shedding (count %d)", self._shed)
        try:
            request.setblocking(False)
            with contextlib.suppress(OSError):
                request.recv(_DRAIN_BYTES)  # unread input would turn the close into an RST
            request.send(_SHED_RESPONSE)
        except OSError:
            pass
        finally:
            self.shutdown_request(request)

    def handle_error(self, request: object, client_address: object) -> None:  # noqa: ARG002
        _LOG.error("connection failed: unhandled transport error")

    def drain(self, grace_seconds: float) -> bool:
        """Wait until no request is in flight; False when some are still running at the deadline."""
        with self._idle:
            return self._idle.wait_for(lambda: self._inflight == 0, timeout=grace_seconds)


def make_server(  # noqa: PLR0913
    api: Api,
    host: str,
    port: int,
    *,
    max_connections: int = MAX_CONNECTIONS,
    max_requests: int = MAX_ACTIVE_REQUESTS,
    head_deadline: float = HEAD_DEADLINE_SECONDS,
    request_deadline: float = REQUEST_TIMEOUT_SECONDS,
) -> BoundedServer:
    """Bind a bounded threading server; port 0 picks a free port (read it from server_address)."""

    class Handler(BaseHTTPRequestHandler):
        timeout = request_deadline
        server: BoundedServer
        budget: _Budget
        answered = False

        def setup(self) -> None:
            super().setup()
            # Defaults for a request whose head never parsed (a 408 still needs them):
            self.request_version = "HTTP/1.0"
            self.requestline = ""
            self.command = ""
            self.budget = _Budget(self.server.head_deadline, self.server.request_deadline)
            self.rfile = io.BufferedReader(_DeadlineReader(self.request, self.budget))

        def handle(self) -> None:
            try:
                super().handle()
            except OSError as error:  # a reset or a broken pipe: the peer is gone, nothing to say
                _LOG.info("connection dropped: %s", type(error).__name__)

        def handle_one_request(self) -> None:
            super().handle_one_request()  # swallows a head timeout: close, no response
            if self.budget.expired and not self.answered:
                self._answer(408, _refuse(408, "request_timeout")[1], JSON)

        def _dispatch(self) -> None:
            self.budget.enter_body_phase()
            exempt = self.command == "GET" and self.path.partition("?")[0] in HEALTH_PATHS
            held = exempt or self.server.request_slots.acquire(blocking=False)
            try:
                if held:
                    status, body, content_type = respond(
                        api, self.command, self.path, list(self.headers.items()), self.rfile.read
                    )
                    self._answer(status, body, content_type)
                else:
                    self._answer(503, _SHED_BODY, JSON, retry_after=True)
            finally:
                if held and not exempt:
                    self.server.request_slots.release()
            self.close_connection = True  # one request per connection; framing is never reused

        def _answer(
            self, status: int, body: bytes, content_type: str, *, retry_after: bool = False
        ) -> None:
            self.close_connection = True
            self.answered = True
            try:
                self.connection.settimeout(self.server.request_deadline)  # write budget
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                if retry_after:
                    self.send_header("Retry-After", str(RETRY_AFTER_SECONDS))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
            except ConnectionError as error:
                _LOG.info("client gone: %s", type(error).__name__)
            except Exception as error:  # noqa: BLE001 - the barrier covers the write too
                _LOG.error("response failed: %s", type(error).__name__)

        do_GET = _dispatch  # noqa: N815 - http.server's naming
        do_POST = _dispatch  # noqa: N815

        def log_request(self, code: int | str = "-", size: int | str = "-") -> None:  # noqa: ARG002
            # Method + path only: never the query string, never a header.
            _LOG.info(
                "%s %s %s -> %s",
                self.address_string(),
                printable(str(getattr(self, "command", None) or "-"), 8),
                log_path(str(getattr(self, "path", ""))),
                code,
            )

        def log_error(self, format: str, *args: object) -> None:  # noqa: A002, ARG002
            # The stdlib puts the raw request line (query string included) in these messages.
            _LOG.info("%s protocol error", self.address_string())

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002, ARG002
            _LOG.info("%s transport message", self.address_string())

    return BoundedServer(
        (host, port),
        Handler,
        max_connections=max_connections,
        max_requests=max_requests,
        head_deadline=head_deadline,
        request_deadline=request_deadline,
    )
