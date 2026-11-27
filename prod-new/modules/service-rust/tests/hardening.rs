//! Request-parsing strictness, the eviction policy and shutdown of idle
//! connections, over real sockets. Added after the second review of the
//! service template; each test names the behaviour it pins.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
mod common;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::{Mutex, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

use common::{call, call_with, options, parse, raw, start, within, TOKEN};

/// Tests that open many sockets run one at a time.
static HEAVY: Mutex<()> = Mutex::new(());

#[test]
fn units_must_be_zero_or_canonical_and_a_field_may_not_repeat() {
    let server = start(options());
    let addr = server.addr;
    for bad in [
        "id=a&units=+5",
        "id=a&units=007",
        "id=a&units=-1",
        "id=a&units=1&units=2",
        "id=a&id=b&units=1",
        "id=a&units=",
    ] {
        assert_eq!(call(addr, "POST", "/deposit", bad).0, 400, "{bad}");
    }
    assert_eq!(call(addr, "POST", "/deposit", "id=ok&units=5").0, 200);
    assert!(call(addr, "GET", "/balance", "")
        .1
        .contains("\"balance_units\":5"));
    server.finish();
}

#[test]
fn a_content_length_that_would_wrap_is_a_400() {
    let server = start(options());
    for digits in ["18446744073709551621", "1844674407370955162100000"] {
        let req = format!(
            "POST /deposit HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: {digits}\r\n\r\nunits=1"
        );
        assert_eq!(
            raw(server.addr, req.as_bytes()).map(|r| r.0),
            Some(400),
            "{digits}"
        );
    }
    server.finish();
}

#[test]
fn only_optional_whitespace_around_the_header_value_is_ignored() {
    let server = start(options());
    let addr = server.addr;
    let with = |h: String| call_with(addr, "POST", "/deposit", &h, "units=1").0;
    assert_eq!(with(format!("Authorization: Bearer {TOKEN}\r\n")), 200);
    assert_eq!(
        with(format!("Authorization:   Bearer {TOKEN} \t \r\n")),
        200
    );
    assert_eq!(with(format!("authorization: bearer {TOKEN}\r\n")), 200);
    assert_eq!(with(format!("Authorization: Bearer  {TOKEN}\r\n")), 401);
    assert_eq!(with(format!("Authorization: Bearer {TOKEN}x\r\n")), 401);
    assert_eq!(
        with(format!("Authorization: Bearer {}\r\n", &TOKEN[1..])),
        401
    );
    server.finish();
}

#[test]
fn a_slow_but_sending_client_outlives_newer_idle_connections() {
    let _one_at_a_time = HEAVY.lock().unwrap_or_else(PoisonError::into_inner);
    let mut o = options();
    o.head_deadline = Duration::from_secs(5);
    o.request_deadline = Duration::from_secs(6);
    let server = start(o);
    let addr = server.addr;

    let mut legit = TcpStream::connect(addr).unwrap();
    legit
        .write_all(b"GET /healthz HTTP/1.1\r\nHost: t\r\n")
        .unwrap();
    // Sixty newer connections that never send a byte, spread over ~1.5 s: more
    // than the 48 head slots, so the registry must evict many of them.
    let mut idle = Vec::new();
    for _ in 0..60 {
        idle.push(TcpStream::connect(addr).unwrap());
        thread::sleep(Duration::from_millis(25));
    }
    legit.write_all(b"\r\n").unwrap();
    legit
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut out = String::new();
    let _ = legit.read_to_string(&mut out);
    assert_eq!(parse(&out).map(|r| r.0), Some(200), "legit client: {out:?}");

    let (_, scrape) = call(addr, "GET", "/metrics", "");
    let evictions: u64 = scrape
        .lines()
        .find_map(|l| l.strip_prefix("svc_http_head_evictions_total "))
        .and_then(|v| v.trim().parse().ok())
        .expect("the eviction counter must be exported");
    assert!(evictions >= 12, "evictions: {evictions}\n{scrape}");
    drop(idle);
    server.finish();
}

#[test]
fn connections_that_sent_nothing_are_closed_at_shutdown_and_not_abandoned() {
    let mut o = options();
    o.head_deadline = Duration::from_secs(20);
    o.request_deadline = Duration::from_secs(20);
    let server = start(o);
    let idle: Vec<TcpStream> = (0..3)
        .map(|_| TcpStream::connect(server.addr).unwrap())
        .collect();
    // Accept is serial: once this is answered, the idle ones are registered.
    assert_eq!(call(server.addr, "GET", "/healthz", "").0, 200);
    assert!(
        within(Duration::from_secs(2), || server.monitor.live_connections()
            == 3)
        .is_some()
    );
    let t = Instant::now();
    assert_eq!(server.finish(), 0, "idle connections are not abandoned");
    assert!(
        t.elapsed() < Duration::from_millis(1500),
        "{:?}",
        t.elapsed()
    );
    drop(idle);
}
