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
    for digits in [
        "1000000000",
        "18446744073709551621",
        "1844674407370955162100000",
    ] {
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

/// Flooders that keep reconnecting and sending ONE byte, while normal clients
/// send a complete request in one packet.
const FLOODERS: usize = 32;
/// Sockets each flooder keeps open at once: 32 x 4 = 128 > the 48 head slots,
/// so the registry is full the whole time and must evict.
const HELD_PER_FLOODER: usize = 4;
const NORMAL_REQUESTS: usize = 50;
/// Measured on the oldest-first policy (10 runs): every run answered all 50.
/// The "fewest bytes first" policy this replaced answered 4/200 and 6/200
/// under 96 flooders. 40 of 50 leaves a wide margin on both sides.
const MIN_NORMAL_OK: usize = 40;

/// One healthz request, one packet, a short deadline: true on a 200.
fn healthz_ok(addr: std::net::SocketAddr) -> bool {
    let Ok(mut s) = TcpStream::connect(addr) else {
        return false;
    };
    let _ = s.set_read_timeout(Some(Duration::from_millis(1500)));
    if s.write_all(b"GET /healthz HTTP/1.1\r\nHost: t\r\n\r\n")
        .is_err()
    {
        return false;
    }
    let mut out = Vec::new();
    let _ = s.read_to_end(&mut out);
    parse(&String::from_utf8_lossy(&out)).map(|r| r.0) == Some(200)
}

#[test]
fn a_reconnect_flood_of_one_byte_clients_does_not_starve_normal_requests() {
    let _one_at_a_time = HEAVY.lock().unwrap_or_else(PoisonError::into_inner);
    let mut o = options();
    o.head_deadline = Duration::from_secs(1);
    o.request_deadline = Duration::from_secs(2);
    let server = start(o);
    let addr = server.addr;

    let go = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
    let flooders: Vec<_> = (0..FLOODERS)
        .map(|_| {
            let go = go.clone();
            thread::spawn(move || {
                let mut held: std::collections::VecDeque<TcpStream> = Default::default();
                while go.load(std::sync::atomic::Ordering::SeqCst) {
                    if let Ok(mut s) = TcpStream::connect(addr) {
                        let _ = s.write_all(b"G");
                        held.push_back(s);
                        if held.len() > HELD_PER_FLOODER {
                            held.pop_front();
                        }
                    }
                    thread::sleep(Duration::from_millis(2));
                }
                held // still stalled: the server must cut each of them
            })
        })
        .collect();
    thread::sleep(Duration::from_millis(300)); // let the registry fill
    let ok = (0..NORMAL_REQUESTS)
        .filter(|_| {
            let r = healthz_ok(addr);
            thread::sleep(Duration::from_millis(20));
            r
        })
        .count();
    go.store(false, std::sync::atomic::Ordering::SeqCst);
    let mut stalled: Vec<TcpStream> = flooders
        .into_iter()
        .flat_map(|h| h.join().unwrap())
        .collect();
    eprintln!("flood: {ok}/{NORMAL_REQUESTS} normal requests answered");
    assert!(
        ok >= MIN_NORMAL_OK,
        "only {ok}/{NORMAL_REQUESTS} normal requests answered under the flood"
    );

    // Every stalled connection is closed by the server (evicted, or cut by the
    // 1 s head deadline with a 408) well before the request deadline.
    let t = Instant::now();
    for s in &mut stalled {
        let _ = s.set_read_timeout(Some(Duration::from_secs(3)));
        let mut out = Vec::new();
        let _ = s.read_to_end(&mut out);
    }
    assert!(
        t.elapsed() < Duration::from_millis(2500),
        "stalled connections outlived the head deadline: {:?}",
        t.elapsed()
    );
    assert!(
        within(Duration::from_secs(2), || server.monitor.live_connections()
            == 0)
        .is_some(),
        "connections are still live after every client was cut"
    );

    let (_, scrape) = call(addr, "GET", "/metrics", "");
    let evictions: u64 = scrape
        .lines()
        .find_map(|l| l.strip_prefix("svc_http_head_evictions_total "))
        .and_then(|v| v.trim().parse().ok())
        .expect("the eviction counter must be exported");
    assert!(evictions >= 12, "evictions: {evictions}\n{scrape}");
    drop(stalled);
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
