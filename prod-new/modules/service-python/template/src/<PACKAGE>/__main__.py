"""Composition root: wires ports to adapters, runs the server, shuts down cleanly.

No business logic lives here. ``build`` is the wiring (testable without a socket);
``run`` serves until ``stop`` is set; ``main`` binds SIGINT and SIGTERM to ``stop``.
"""

import logging
import signal
import threading
from collections.abc import Callable
from dataclasses import dataclass

from <PACKAGE>.adapters.inbound.http_api import Api
from <PACKAGE>.adapters.inbound.http_server import make_server
from <PACKAGE>.adapters.outbound.memory_store import InMemoryEventStore
from <PACKAGE>.app.ledger_service import LedgerService
from <PACKAGE>.platform import config as configuration
from <PACKAGE>.platform.clock import SystemClock
from <PACKAGE>.platform.ids import UuidIds
from <PACKAGE>.platform.observability import MetricsRecorder

_LOG = logging.getLogger("<PACKAGE>")
SHUTDOWN_POLL_SECONDS = 0.05  # how quickly server.shutdown() is noticed


@dataclass(frozen=True, slots=True)
class Runtime:
    api: Api
    service: LedgerService
    recorder: MetricsRecorder


def build(cfg: configuration.Config) -> Runtime:
    recorder = MetricsRecorder()
    service = LedgerService(InMemoryEventStore(), SystemClock(), UuidIds(), recorder)
    recorder.gauge("svc_build_info", 1, revision=cfg.revision)
    return Runtime(Api(service, recorder.render, cfg.api_token), service, recorder)


def _ignore_port(_port: int) -> None:
    return None


def run(
    cfg: configuration.Config,
    stop: threading.Event,
    on_ready: Callable[[int], None] = _ignore_port,
) -> int:
    """Serve until ``stop`` is set, then stop accepting, close the socket and return 0."""
    runtime = build(cfg)
    server = make_server(runtime.api, cfg.host, cfg.port)
    port = int(server.server_address[1])
    thread = threading.Thread(
        target=lambda: server.serve_forever(poll_interval=SHUTDOWN_POLL_SECONDS),
        name="http",
        daemon=True,
    )
    thread.start()
    _LOG.info("serving on %s:%d (revision %s)", cfg.host, port, cfg.revision)
    on_ready(port)
    try:
        stop.wait()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=10)
        _LOG.info("stopped")
    return 0


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    try:
        cfg = configuration.load()
    except configuration.ConfigError as err:
        _LOG.error("configuration refused: %s", err)
        return 2
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda _signum, _frame: stop.set())
    return run(cfg, stop)


if __name__ == "__main__":
    raise SystemExit(main())
