"""Graceful shutdown: refuse new connections at once, drain in-flight requests, exit codes."""

import json
import os
import re
import select
import signal
import socket
import subprocess
import sys
import threading
import time
from collections.abc import Iterator
from contextlib import contextmanager

import pytest

from <PACKAGE> import (
    __main__ as root,
)
from <PACKAGE>.platform.config import (
    Config,
)

TOKEN = "s" * 40
BODY = json.dumps({"amount": "1.00", "event_id": "shutdown-1"}).encode()
HEAD = (
    b"POST /v1/deposits HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
    b"Authorization: Bearer "
    + TOKEN.encode()
    + b"\r\nContent-Length: "
    + str(len(BODY)).encode()
    + b"\r\n\r\n"
)
SPLIT = 10


def read_response(sock: socket.socket, limit: float = 5) -> bytes:
    data, end = b"", time.monotonic() + limit
    while time.monotonic() < end:
        ready, _, _ = select.select([sock], [], [], 0.05)
        if ready:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
    return data


def assert_complete(reply: bytes) -> None:
    """The whole response arrived: the body is exactly Content-Length bytes of valid JSON."""
    head, _, body = reply.partition(b"\r\n\r\n")
    length = re.search(rb"Content-Length: (\d+)", head)
    assert length is not None
    assert len(body) == int(length.group(1))
    json.loads(body)


def wait_refused(port: int, limit: float = 2) -> float:
    """Seconds until a new connection is refused (not hung); fails if it never is."""
    start = time.monotonic()
    while time.monotonic() - start < limit:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
        except ConnectionRefusedError:  # ECONNREFUSED: refused, not hung
            return time.monotonic() - start
        time.sleep(0.02)
    raise AssertionError("the listener stayed open after the signal")


@contextmanager
def child_service() -> Iterator[tuple[subprocess.Popen[bytes], int]]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("SVC_")}
    env.update(SVC_API_TOKEN=TOKEN, SVC_PORT="0", SVC_HOST="127.0.0.1")
    proc = subprocess.Popen(
        [sys.executable, "-m", "<PACKAGE>"],
        env=env,
        stderr=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
    )
    try:
        assert proc.stderr is not None
        line, end = b"", time.monotonic() + 15
        while time.monotonic() < end and b"serving on" not in line:
            ready, _, _ = select.select([proc.stderr], [], [], 0.1)
            if ready:
                line = proc.stderr.readline()
        match = re.search(rb"serving on 127\.0\.0\.1:(\d+)", line)
        assert match is not None, line
        yield proc, int(match.group(1))
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait(timeout=10)
        if proc.stderr is not None:
            proc.stderr.close()


# provenance: derived
# verifies: clean_shutdown
def test_sigterm_mid_request_finishes_it_refuses_new_connections_and_exits_0() -> None:
    with child_service() as (proc, port):
        client = socket.create_connection(("127.0.0.1", port), timeout=5)
        client.sendall(HEAD + BODY[:SPLIT])  # in flight: the body is still on its way
        time.sleep(0.2)
        proc.send_signal(signal.SIGTERM)
        refused_after = wait_refused(port)
        assert proc.poll() is None  # still draining: the request has not finished
        client.sendall(BODY[SPLIT:])
        reply = read_response(client)
        client.close()
        code = proc.wait(timeout=10)
        err = proc.stderr.read() if proc.stderr else b""
    assert reply.startswith(b"HTTP/1.0 200 "), reply
    assert_complete(reply)
    assert refused_after < 1.0
    assert code == 0
    assert b"Traceback" not in err


# provenance: derived
# verifies: clean_shutdown
def test_an_idle_service_exits_promptly_on_sigterm() -> None:
    with child_service() as (proc, port):
        start = time.monotonic()
        proc.send_signal(signal.SIGTERM)
        code = proc.wait(timeout=10)
        elapsed = time.monotonic() - start
        with pytest.raises(OSError):  # noqa: PT011 - refused
            socket.create_connection(("127.0.0.1", port), timeout=1)
    assert code == 0
    assert elapsed < 2


def run_in_thread(grace: float) -> tuple[threading.Event, list[int], list[int], threading.Thread]:
    stop, ready = threading.Event(), threading.Event()
    ports: list[int] = []
    codes: list[int] = []

    def on_ready(port: int) -> None:
        ports.append(port)
        ready.set()

    cfg = Config("127.0.0.1", 0, TOKEN, "rev")
    thread = threading.Thread(target=lambda: codes.append(root.run(cfg, stop, on_ready, grace)))
    thread.start()
    assert ready.wait(timeout=5)
    return stop, ports, codes, thread


# provenance: derived
# verifies: clean_shutdown
def test_requests_abandoned_at_the_grace_deadline_give_exit_code_3() -> None:
    stop, ports, codes, thread = run_in_thread(grace=0.3)
    client = socket.create_connection(("127.0.0.1", ports[0]), timeout=5)
    client.sendall(HEAD + BODY[:SPLIT])  # cannot finish: the rest of the body never comes
    time.sleep(0.2)
    start = time.monotonic()
    stop.set()
    thread.join(timeout=5)
    elapsed = time.monotonic() - start
    client.close()
    assert not thread.is_alive()
    assert codes == [root.EXIT_ABANDONED] == [3]
    assert 0.3 <= elapsed < 2


# provenance: derived
# verifies: clean_shutdown
def test_a_request_that_finishes_inside_the_grace_gives_exit_code_0() -> None:
    stop, ports, codes, thread = run_in_thread(grace=5)
    client = socket.create_connection(("127.0.0.1", ports[0]), timeout=5)
    client.sendall(HEAD + BODY[:SPLIT])
    time.sleep(0.2)
    stop.set()
    time.sleep(0.2)
    client.sendall(BODY[SPLIT:])
    reply = read_response(client)
    client.close()
    thread.join(timeout=5)
    assert reply.startswith(b"HTTP/1.0 200 "), reply
    assert_complete(reply)
    assert codes == [0]
