//! Shared harness for the socket tests: a real server on an ephemeral port,
//! and raw-socket helpers (no HTTP client dependency).
#![allow(dead_code, clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use svc_adapter::http::{Monitor, Options, Server};
use svc_adapter::memory::MemoryStore;
use svc_app::{Clock, EventStore, IdGenerator, Ledger, MetricsSource, Telemetry};
use svc_platform::{clock::SystemClock, ids::Sequence, telemetry::Recorder};

pub const TOKEN: &str = "test-token-0123456789";

pub fn options() -> Options {
    Options::new(TOKEN.to_owned())
}

pub struct Running {
    pub addr: SocketAddr,
    pub stop: Arc<AtomicBool>,
    pub monitor: Monitor,
    handle: Option<JoinHandle<usize>>,
}

impl Running {
    /// Stops the server, waits for the drain, returns the abandoned count.
    pub fn finish(mut self) -> usize {
        self.stop.store(true, Ordering::SeqCst);
        self.handle.take().unwrap().join().unwrap()
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

pub fn start(opts: Options) -> Running {
    start_with(opts, Arc::new(MemoryStore::new()), Duration::from_secs(2))
}

pub fn start_with(opts: Options, store: Arc<dyn EventStore>, grace: Duration) -> Running {
    let clock: Arc<dyn Clock> = Arc::new(SystemClock);
    let recorder = Arc::new(Recorder::new(false));
    let telemetry: Arc<dyn Telemetry> = recorder.clone();
    let metrics: Arc<dyn MetricsSource> = recorder;
    let ids: Arc<dyn IdGenerator> = Arc::new(Sequence::new(&clock));
    let ledger = Arc::new(Ledger::new(store, telemetry.clone(), clock));
    let server = Server::bind("127.0.0.1:0", ledger, ids, telemetry, metrics, opts).unwrap();
    let addr = server.local_addr().unwrap();
    let monitor = server.monitor();
    let stop = Arc::new(AtomicBool::new(false));
    let stop2 = stop.clone();
    let handle = thread::spawn(move || server.serve(&stop2, grace));
    Running {
        addr,
        stop,
        monitor,
        handle: Some(handle),
    }
}

/// Status code and body of a raw response; `None` when the server closed
/// without answering.
pub fn parse(out: &str) -> Option<(u16, String)> {
    let code = out.split(' ').nth(1)?.parse().ok()?;
    let body = out.split("\r\n\r\n").nth(1).unwrap_or("").to_owned();
    Some((code, body))
}

/// Sends `bytes` as they are and reads to the end.
pub fn raw(addr: SocketAddr, bytes: &[u8]) -> Option<(u16, String)> {
    let mut s = TcpStream::connect(addr).unwrap();
    let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = s.write_all(bytes);
    read_all(&mut s)
}

pub fn read_all(s: &mut TcpStream) -> Option<(u16, String)> {
    let mut out = Vec::new();
    let _ = s.read_to_end(&mut out);
    parse(&String::from_utf8_lossy(&out))
}

/// A well-formed request; `POST`s carry the right token.
pub fn call(addr: SocketAddr, method: &str, path: &str, body: &str) -> (u16, String) {
    call_with(
        addr,
        method,
        path,
        &format!("Authorization: Bearer {TOKEN}\r\n"),
        body,
    )
}

pub fn call_with(
    addr: SocketAddr,
    method: &str,
    path: &str,
    headers: &str,
    body: &str,
) -> (u16, String) {
    let cl = if method == "GET" {
        String::new()
    } else {
        format!("Content-Length: {}\r\n", body.len())
    };
    let req = format!("{method} {path} HTTP/1.1\r\nHost: t\r\n{headers}{cl}\r\n{body}");
    raw(addr, req.as_bytes()).expect("the server must answer")
}

/// Waits (bounded, test-side) until `cond` holds; returns how long it took.
pub fn within(limit: Duration, mut cond: impl FnMut() -> bool) -> Option<Duration> {
    let start = Instant::now();
    while start.elapsed() < limit {
        if cond() {
            return Some(start.elapsed());
        }
        thread::sleep(Duration::from_millis(10));
    }
    cond().then(|| start.elapsed())
}
