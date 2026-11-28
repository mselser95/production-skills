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

#[test]
fn a_token_no_request_can_present_is_refused_with_exit_1_and_a_one_line_error() {
    let sixteen_spaces = " ".repeat(16);
    let sixteen_tabs = "\t".repeat(16);
    for bad in [
        sixteen_spaces.as_str(),
        sixteen_tabs.as_str(),
        "valid-looking-token ",
        "valid-looking token",
        "valid-looking-\u{1}-token",
        "valid-looking-tokén-x",
    ] {
        refuses_to_start(
            &[("SVC_LISTEN_ADDR", "127.0.0.1:0"), ("SVC_AUTH_TOKEN", bad)],
            "SVC_AUTH_TOKEN: only visible ASCII",
        );
    }
}

fn post_deposit(addr: SocketAddr, token: &str) -> Option<u16> {
    let mut s = TcpStream::connect(addr).unwrap();
    let body = "id=p1&units=1";
    write!(
        s,
        "POST /deposit HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer {token}\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    )
    .unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    parse(&out).map(|r| r.0)
}

#[test]
fn a_valid_token_starts_the_service_and_authorises_a_write() {
    let svc = spawn(&[]);
    assert_eq!(post_deposit(svc.addr, TOKEN), Some(200));
    assert_eq!(post_deposit(svc.addr, "child-token-0123456780"), Some(401));
}

#[test]
fn every_declared_metric_is_scrapeable_right_after_start() {
    let svc = spawn(&[]);
    let mut s = TcpStream::connect(svc.addr).unwrap();
    s.write_all(b"GET /metrics HTTP/1.1\r\nHost: t\r\n\r\n")
        .unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    let manifest = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("observability/emitted-metrics.yaml"),
    )
    .unwrap();
    let names: Vec<&str> = manifest
        .lines()
        .filter_map(|l| l.strip_prefix("- name: "))
        .collect();
    assert!(names.len() >= 7, "{names:?}");
    for n in &names {
        assert!(
            out.contains(&format!("# TYPE {n} ")),
            "{n} missing in\n{out}"
        );
    }
    assert!(
        out.contains("svc_units_conserved_violations_total 0\n"),
        "{out}"
    );
}

#[test]
fn a_second_signal_exits_at_once_with_code_4() {
    let svc = spawn(&[
        ("SVC_SHUTDOWN_GRACE_MS", "30000"),
        ("SVC_HEAD_DEADLINE_MS", "20000"),
        ("SVC_REQUEST_DEADLINE_MS", "20000"),
    ]);
    // An in-flight request (bytes sent, head unfinished) keeps the drain open.
    let mut inflight = TcpStream::connect(svc.addr).unwrap();
    inflight.write_all(b"GET /healthz HTTP/1.1\r\n").unwrap();
    let mut probe = TcpStream::connect(svc.addr).unwrap();
    probe.write_all(b"GET /healthz HTTP/1.1\r\n\r\n").unwrap();
    let mut out = String::new();
    probe.read_to_string(&mut out).unwrap();
    let t = Instant::now();
    svc.sigterm();
    // Wait until the FIRST signal is observably handled (the listener is
    // closed, which the server does only after the handler set `stop`) before
    // sending the second. Defensive; NOT reproduced: standard signals do not
    // queue, so two sent while the first is still pending would be delivered
    // as ONE and the process would drain instead of exiting 4, but this test
    // was green 30/30 without the wait, so no failing run shows the race. The
    // wait costs nothing and rules it out by construction.
    within(Duration::from_secs(5), || refused(svc.addr))
        .expect("the first signal must close the listener");
    svc.sigterm();
    let status = svc.exit();
    assert_eq!(status.code(), Some(4), "second signal: forced exit");
    assert!(t.elapsed() < Duration::from_secs(5), "{:?}", t.elapsed());
}

#[test]
fn an_unused_connection_is_not_abandoned_at_shutdown() {
    let svc = spawn(&[("SVC_SHUTDOWN_GRACE_MS", "300")]);
    let _idle = TcpStream::connect(svc.addr).unwrap();
    let mut probe = TcpStream::connect(svc.addr).unwrap();
    probe.write_all(b"GET /healthz HTTP/1.1\r\n\r\n").unwrap();
    let mut out = String::new();
    probe.read_to_string(&mut out).unwrap();
    svc.sigterm();
    assert_eq!(svc.exit().code(), Some(0), "nothing was in flight");
}
