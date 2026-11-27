//! End-to-end over a real socket: wiring (ports -> adapters), the HTTP
//! contract, idempotency, and graceful shutdown.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use svc::adapter::{http::Server, memory::MemoryStore};
use svc::app::{Clock, IdGenerator, Ledger, MetricsSource, Telemetry};
use svc::platform::{clock::SystemClock, ids::Sequence, telemetry::Recorder};

fn call(addr: SocketAddr, method: &str, path: &str, body: &str) -> (u16, String) {
    let mut s = TcpStream::connect(addr).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: t\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    s.write_all(req.as_bytes()).unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    let code = out.split(' ').nth(1).unwrap().parse().unwrap();
    let body = out.split("\r\n\r\n").nth(1).unwrap_or("").to_owned();
    (code, body)
}

#[test]
fn serves_the_ledger_and_stops_gracefully() {
    let clock: Arc<dyn Clock> = Arc::new(SystemClock);
    let recorder = Arc::new(Recorder::new(false));
    let telemetry: Arc<dyn Telemetry> = recorder.clone();
    let metrics: Arc<dyn MetricsSource> = recorder;
    let ids: Arc<dyn IdGenerator> = Arc::new(Sequence::new(&clock));
    let ledger = Arc::new(Ledger::new(
        Arc::new(MemoryStore::new()),
        telemetry.clone(),
        clock,
    ));
    let server = Server::bind("127.0.0.1:0", ledger, ids, telemetry, metrics).unwrap();
    let addr = server.local_addr().unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let stop2 = stop.clone();
    let handle = thread::spawn(move || server.serve(&stop2, Duration::from_secs(2)));

    assert_eq!(call(addr, "GET", "/healthz", "").0, 200);
    let (c, b) = call(addr, "POST", "/deposit", "id=d1&units=100");
    assert_eq!(c, 200, "{b}");
    assert!(
        b.contains("\"outcome\":\"applied\"") && b.contains("\"balance_units\":100"),
        "{b}"
    );
    let (_, b) = call(addr, "POST", "/deposit", "id=d1&units=100");
    assert!(
        b.contains("\"outcome\":\"duplicate\"") && b.contains("\"balance_units\":100"),
        "{b}"
    );
    assert_eq!(call(addr, "POST", "/withdraw", "id=w1&units=30").0, 200);
    assert_eq!(call(addr, "POST", "/withdraw", "id=w2&units=999").0, 409);
    assert_eq!(call(addr, "POST", "/withdraw", "id=bad id&units=1").0, 400);
    assert_eq!(call(addr, "POST", "/deposit", "units=0").0, 400);
    assert_eq!(call(addr, "GET", "/deposit", "").0, 405);
    assert_eq!(call(addr, "GET", "/nope", "").0, 404);
    let (_, b) = call(addr, "GET", "/balance", "");
    assert!(b.contains("\"balance_units\":70"), "{b}");

    let (_, scrape) = call(addr, "GET", "/metrics", "");
    assert!(
        scrape.contains("svc_events_total{kind=\"deposit\",outcome=\"applied\"} 1"),
        "{scrape}"
    );
    assert!(
        scrape.contains("svc_events_total{kind=\"deposit\",outcome=\"duplicate\"} 1"),
        "{scrape}"
    );
    assert!(
        scrape.contains("svc_http_requests_total{route=\"withdraw\",code=\"4xx\"} 2"),
        "{scrape}"
    );
    assert!(scrape.contains("svc_balance_units 70"), "{scrape}");

    stop.store(true, Ordering::SeqCst);
    let abandoned = handle.join().unwrap();
    assert_eq!(abandoned, 0, "shutdown must drain in-flight requests");
}
