//! Slow clients, load caps and panics. Every number is a real socket.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
mod common;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

use common::{call, options, parse, start, start_with, within, TOKEN};
use svc_app::{EventStore, LedgerError, Snapshot, StoreError};
use svc_domain::{Outcome, State};

/// The two flood tests open hundreds of sockets: run them one at a time so a
/// loaded machine cannot make their timing assertions flaky.
static HEAVY: Mutex<()> = Mutex::new(());

fn stalled(addr: SocketAddr, n: usize) -> Vec<TcpStream> {
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        // Pace the burst: the kernel accept backlog is only 128 here, and a
        // handshake finished while it is full is dropped silently, which would
        // make a LATER well-behaved connection fail for reasons the server
        // cannot influence.
        if i % 16 == 15 {
            thread::sleep(Duration::from_millis(5));
        }
        let mut s = TcpStream::connect(addr).expect("connect");
        // A connection evicted before this write may already be reset.
        let _ = s.write_all(b"G");
        out.push(s);
    }
    out
}

#[test]
fn stalled_connections_cannot_starve_health_and_are_closed_at_the_deadline() {
    let _one_at_a_time = HEAVY.lock().unwrap_or_else(PoisonError::into_inner);
    let mut o = options();
    o.head_deadline = Duration::from_millis(1000);
    o.request_deadline = Duration::from_secs(3);
    let server = start(o);
    let addr = server.addr;

    let t0 = Instant::now();
    let mut conns = stalled(addr, 80); // more than the 64 total slots
    let t = Instant::now();
    let (code, _) = call(addr, "GET", "/healthz", "");
    let health = t.elapsed();
    assert_eq!(code, 200);
    assert!(health < Duration::from_secs(1), "healthz took {health:?}");
    assert_eq!(call(addr, "GET", "/metrics", "").0, 200);

    // Every stalled connection is closed: evicted at once or 408 at the
    // head deadline. Never held for the 5 s per-read timeout of old.
    let mut answered_408 = 0;
    for c in &mut conns {
        c.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut out = Vec::new();
        let _ = c.read_to_end(&mut out);
        if parse(&String::from_utf8_lossy(&out)).is_some_and(|(code, _)| code == 408) {
            answered_408 += 1;
        }
    }
    let closed = t0.elapsed();
    eprintln!(
        "slow-client: 80 stalled conns, healthz 200 in {health:?}, all closed after {closed:?}, {answered_408} answered 408"
    );
    assert!(
        closed < Duration::from_millis(2500),
        "closed after {closed:?}"
    );
    assert!(answered_408 >= 1, "survivors must be told 408");
    assert!(
        within(Duration::from_secs(2), || server.monitor.live_connections()
            == 0)
        .is_some()
    );
    server.finish();
}

#[test]
fn the_number_of_live_connections_stays_bounded_under_a_flood() {
    let _one_at_a_time = HEAVY.lock().unwrap_or_else(PoisonError::into_inner);
    let mut o = options();
    o.head_deadline = Duration::from_secs(15);
    o.request_deadline = Duration::from_secs(16);
    let server = start(o);
    let _conns = stalled(server.addr, 300);
    assert_eq!(call(server.addr, "GET", "/healthz", "").0, 200);
    // 48 head slots + the transient handler of the call above, with a little
    // room for evicted threads that have not exited yet.
    let settled = within(Duration::from_secs(5), || {
        server.monitor.live_connections() <= 48 + 4
    });
    assert!(
        settled.is_some(),
        "live connections: {}",
        server.monitor.live_connections()
    );
    server.finish();
}

#[test]
fn a_trickling_header_is_cut_off_by_the_deadline_not_by_read_gaps() {
    let mut o = options();
    o.head_deadline = Duration::from_millis(900);
    o.request_deadline = Duration::from_secs(3);
    let server = start(o);
    let mut s = TcpStream::connect(server.addr).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(4))).unwrap();
    let start_at = Instant::now();
    // One byte every 200 ms: no single read ever waits 900 ms.
    let writer = {
        let mut w = s.try_clone().unwrap();
        thread::spawn(move || {
            for b in b"GET /healthz HTTP/1.1\r\nHost: t\r\nX-Slow: aaaaaaaaaaaaaaaaaaaaaaaa".iter()
            {
                if w.write_all(&[*b]).is_err() {
                    return;
                }
                thread::sleep(Duration::from_millis(200));
            }
        })
    };
    let mut out = Vec::new();
    let _ = s.read_to_end(&mut out);
    let took = start_at.elapsed();
    let (code, _) = parse(&String::from_utf8_lossy(&out)).expect("a 408 reply");
    assert_eq!(code, 408);
    assert!(took < Duration::from_millis(1800), "closed after {took:?}");
    writer.join().unwrap();
    server.finish();
}

#[test]
fn a_trickling_body_is_cut_off_by_the_whole_request_deadline() {
    let mut o = options();
    o.head_deadline = Duration::from_millis(500);
    o.request_deadline = Duration::from_millis(1200);
    let server = start(o);
    let mut s = TcpStream::connect(server.addr).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(4))).unwrap();
    let head = format!(
        "POST /deposit HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: 20\r\n\r\n"
    );
    let start_at = Instant::now();
    s.write_all(head.as_bytes()).unwrap();
    let writer = {
        let mut w = s.try_clone().unwrap();
        thread::spawn(move || {
            for _ in 0..19 {
                if w.write_all(b"u").is_err() {
                    return;
                }
                thread::sleep(Duration::from_millis(250));
            }
        })
    };
    let mut out = Vec::new();
    let _ = s.read_to_end(&mut out);
    let took = start_at.elapsed();
    assert_eq!(
        parse(&String::from_utf8_lossy(&out)).map(|r| r.0),
        Some(408)
    );
    assert!(took < Duration::from_millis(2200), "closed after {took:?}");
    writer.join().unwrap();
    server.finish();
}

#[test]
fn post_bodies_are_capped_with_a_503_and_health_stays_up() {
    let mut o = options();
    o.max_body_conns = 4;
    let server = start(o);
    let addr = server.addr;
    let head = format!(
        "POST /deposit HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: 10\r\n\r\n"
    );
    let mut holders = Vec::new();
    for _ in 0..4 {
        let mut s = TcpStream::connect(addr).unwrap();
        s.write_all(head.as_bytes()).unwrap();
        holders.push(s);
    }
    // Four POSTs are now waiting for a body they will not get quickly.
    assert_eq!(call(addr, "GET", "/healthz", "").0, 200);
    let t = Instant::now();
    let mut over = None;
    // The holders may not all have a slot yet; the 5th..Nth must be refused.
    for _ in 0..50 {
        let (c, b) = call(addr, "POST", "/deposit", "units=1");
        if c == 503 {
            over = Some(b);
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        over.as_deref(),
        Some("busy\n"),
        "no 503 after {:?}",
        t.elapsed()
    );
    assert_eq!(call(addr, "GET", "/healthz", "").0, 200);
    drop(holders);
    server.finish();
}

struct PanicStore;
impl EventStore for PanicStore {
    fn update(
        &self,
        _change: &mut dyn FnMut(&mut State) -> Result<Outcome, LedgerError>,
    ) -> Result<(Outcome, Snapshot), LedgerError> {
        panic!("boom: a connection thread dies mid-request");
    }
    fn read(&self) -> Result<Snapshot, StoreError> {
        Ok(Snapshot {
            balance: 0,
            version: 0,
        })
    }
}

#[test]
fn a_panicking_connection_frees_its_slot_and_the_server_keeps_serving() {
    let mut o = options();
    o.max_body_conns = 1; // a leaked body slot would turn request 2 into a 503
    let server = start_with(o, Arc::new(PanicStore), Duration::from_secs(2));
    let addr = server.addr;
    for round in 0..3 {
        let req = format!(
            "POST /deposit HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: 7\r\n\r\nunits=1"
        );
        let mut s = TcpStream::connect(addr).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        s.write_all(req.as_bytes()).unwrap();
        let mut out = Vec::new();
        let _ = s.read_to_end(&mut out);
        assert!(out.is_empty(), "round {round}: the thread died, no reply");
        assert!(
            within(Duration::from_secs(2), || server.monitor.live_connections()
                == 0)
            .is_some(),
            "round {round}: live slot leaked: {}",
            server.monitor.live_connections()
        );
        assert_eq!(call(addr, "GET", "/healthz", "").0, 200);
    }
    assert_eq!(server.finish(), 0);
}
