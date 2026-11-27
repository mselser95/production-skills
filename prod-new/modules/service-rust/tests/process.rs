//! The built binary as a child process: refusal to start on unsafe config,
//! and a real SIGTERM (not a flag flipped in-process).
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
mod common;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use common::{parse, within};

const BIN: &str = env!("CARGO_BIN_EXE_svc");
const TOKEN: &str = "child-token-0123456789";

struct Svc {
    child: Child,
    addr: SocketAddr,
}

fn spawn(extra: &[(&str, &str)]) -> Svc {
    let mut cmd = Command::new(BIN);
    cmd.env_clear()
        .env("SVC_LISTEN_ADDR", "127.0.0.1:0")
        .env("SVC_AUTH_TOKEN", TOKEN)
        .stderr(Stdio::piped())
        .stdout(Stdio::null());
    for (k, v) in extra {
        cmd.env(k, v);
    }
    let mut child = cmd.spawn().unwrap();
    let stderr = child.stderr.take().unwrap();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if let Some(addr) = line.split("listening on ").nth(1) {
                let _ = tx.send(addr.trim().to_owned());
            }
        }
    });
    let addr = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("the service must print its address");
    Svc {
        child,
        addr: addr.parse().unwrap(),
    }
}

impl Svc {
    fn sigterm(&self) {
        let status = Command::new("kill")
            .args(["-TERM", &self.child.id().to_string()])
            .status()
            .unwrap();
        assert!(status.success());
    }

    fn exit(mut self) -> ExitStatus {
        let mut status = None;
        within(Duration::from_secs(10), || {
            status = self.child.try_wait().unwrap();
            status.is_some()
        })
        .expect("the service must exit");
        status.unwrap()
    }
}

impl Drop for Svc {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

fn refused(addr: SocketAddr) -> bool {
    TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_err()
}

#[test]
fn sigterm_closes_the_listener_drains_the_in_flight_request_and_exits_0() {
    // Long deadlines: the in-flight request below must still be open when we
    // check that the listener is already closed (it is not closed late by the
    // drain simply finishing).
    let svc = spawn(&[
        ("SVC_SHUTDOWN_GRACE_MS", "8000"),
        ("SVC_HEAD_DEADLINE_MS", "9000"),
        ("SVC_REQUEST_DEADLINE_MS", "9500"),
    ]);
    // An in-flight request: its head is not finished yet.
    let mut inflight = TcpStream::connect(svc.addr).unwrap();
    inflight
        .write_all(b"GET /healthz HTTP/1.1\r\nHost: t\r\n")
        .unwrap();
    // A second connection proves the first was accepted (accept is serial).
    let mut probe = TcpStream::connect(svc.addr).unwrap();
    probe.write_all(b"GET /healthz HTTP/1.1\r\n\r\n").unwrap();
    let mut out = String::new();
    probe.read_to_string(&mut out).unwrap();
    assert_eq!(parse(&out).map(|r| r.0), Some(200));

    let t = Instant::now();
    svc.sigterm();
    let took = within(Duration::from_secs(3), || refused(svc.addr))
        .expect("new connections must be refused after SIGTERM");
    eprintln!(
        "sigterm: new connections refused after {took:?} (wall {:?})",
        t.elapsed()
    );
    assert!(
        took < Duration::from_secs(1),
        "the listener closes at once, not when the drain ends"
    );

    // The request that was already in flight still completes.
    inflight.write_all(b"\r\n").unwrap();
    inflight
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut out = String::new();
    inflight.read_to_string(&mut out).unwrap();
    assert_eq!(parse(&out), Some((200, "ok\n".to_owned())));

    let status = svc.exit();
    assert_eq!(status.code(), Some(0), "drained: exit 0");
}

#[test]
fn abandoned_requests_exit_with_a_distinct_non_zero_code() {
    let svc = spawn(&[("SVC_SHUTDOWN_GRACE_MS", "300")]);
    let mut stuck = TcpStream::connect(svc.addr).unwrap();
    stuck.write_all(b"GET /healthz HTTP/1.1\r\n").unwrap();
    let mut probe = TcpStream::connect(svc.addr).unwrap();
    probe.write_all(b"GET /healthz HTTP/1.1\r\n\r\n").unwrap();
    let mut out = String::new();
    probe.read_to_string(&mut out).unwrap();
    svc.sigterm();
    let status = svc.exit();
    assert_eq!(status.code(), Some(3), "abandoned at the grace deadline");
}

fn refuses_to_start(env: &[(&str, &str)], mentions: &str) {
    let mut cmd = Command::new(BIN);
    cmd.env_clear().stdout(Stdio::null()).stderr(Stdio::piped());
    for (k, v) in env {
        cmd.env(k, v);
    }
    let mut child = cmd.spawn().unwrap();
    let mut err = String::new();
    let mut stderr = child.stderr.take().unwrap();
    let mut status = None;
    // A service that wrongly STARTS would serve forever: bound the wait.
    let exited = within(Duration::from_secs(5), || {
        status = child.try_wait().unwrap();
        status.is_some()
    });
    if exited.is_none() {
        let _ = child.kill();
        let _ = child.wait();
        panic!("{env:?}: the service started instead of refusing");
    }
    let _ = stderr.read_to_string(&mut err);
    assert_eq!(status.unwrap().code(), Some(1), "{env:?}");
    assert!(err.contains(mentions), "{err}");
    assert!(!err.contains(TOKEN), "the token must never be printed");
}

#[test]
fn the_service_refuses_to_start_without_a_token_or_on_a_public_bind() {
    refuses_to_start(&[("SVC_LISTEN_ADDR", "127.0.0.1:0")], "SVC_AUTH_TOKEN");
    refuses_to_start(
        &[
            ("SVC_LISTEN_ADDR", "127.0.0.1:0"),
            ("SVC_AUTH_TOKEN", "short"),
        ],
        "SVC_AUTH_TOKEN",
    );
    refuses_to_start(
        &[("SVC_LISTEN_ADDR", "0.0.0.0:0"), ("SVC_AUTH_TOKEN", TOKEN)],
        "SVC_ALLOW_NON_LOOPBACK",
    );
}
