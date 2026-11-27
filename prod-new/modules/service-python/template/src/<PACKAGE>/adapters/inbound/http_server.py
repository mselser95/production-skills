"""Standard-library HTTP transport around ``Api``. Bounded: header, body and socket timeouts."""

import logging
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from <PACKAGE>.adapters.inbound.http_api import MAX_BODY_BYTES, Api

_LOG = logging.getLogger(__name__)
REQUEST_TIMEOUT_SECONDS = 10


def make_server(api: Api, host: str, port: int) -> ThreadingHTTPServer:
    """Bind a threading server; port 0 picks a free port (read it from server_address)."""

    class Handler(BaseHTTPRequestHandler):
        timeout = REQUEST_TIMEOUT_SECONDS

        def _dispatch(self) -> None:
            length_text = self.headers.get("Content-Length", "0")
            if not length_text.isascii() or not length_text.isdigit():
                self._send(400, b'{"error": "invalid_length"}', "application/json")
                return
            length = int(length_text)
            # Read one byte past the cap so the API can answer 413 without buffering more.
            body = self.rfile.read(min(length, MAX_BODY_BYTES + 1))
            response = api.handle(
                self.command, self.path, {k.lower(): v for k, v in self.headers.items()}, body
            )
            self._send(response.status, response.body, response.content_type)

        def _send(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        do_GET = _dispatch  # noqa: N815 - http.server's naming
        do_POST = _dispatch  # noqa: N815

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002
            _LOG.info("%s %s", self.address_string(), format % args)

    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    return server
