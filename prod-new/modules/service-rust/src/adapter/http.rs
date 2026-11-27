//! HTTP/1.1 inbound adapter over `std::net`, one thread per connection with
//! a hard cap. Routes: `GET /healthz`, `GET /metrics`, `GET /balance`,
//! `POST /deposit`, `POST /withdraw` (body `id=<id>&units=<n>`, `id` optional).
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use crate::app::{IdGenerator, Ledger, LedgerError, MetricsSource, Telemetry};
use crate::domain::{DomainError, Outcome};

const MAX_IN_FLIGHT: usize = 64;
const MAX_HEAD: usize = 8 * 1024;
const MAX_BODY: usize = 1024;
const IO_TIMEOUT: Duration = Duration::from_secs(5);
const ACCEPT_IDLE: Duration = Duration::from_millis(20);

/// The HTTP server and the collaborators its handlers use.
pub struct Server {
    listener: TcpListener,
    deps: Arc<Deps>,
}

struct Deps {
    ledger: Arc<Ledger>,
    ids: Arc<dyn IdGenerator>,
    telemetry: Arc<dyn Telemetry>,
    metrics: Arc<dyn MetricsSource>,
    in_flight: AtomicUsize,
}

struct Reply {
    route: &'static str,
    code: u16,
    content_type: &'static str,
    body: String,
}

impl Reply {
    fn text(route: &'static str, code: u16, body: impl Into<String>) -> Self {
        Self {
            route,
            code,
            content_type: "text/plain; charset=utf-8",
            body: body.into(),
        }
    }

    fn json(route: &'static str, code: u16, body: String) -> Self {
        Self {
            route,
            code,
            content_type: "application/json",
            body,
        }
    }
}

impl Server {
    /// Binds `addr` (use port 0 for an ephemeral port).
    pub fn bind(
        addr: &str,
        ledger: Arc<Ledger>,
        ids: Arc<dyn IdGenerator>,
        telemetry: Arc<dyn Telemetry>,
        metrics: Arc<dyn MetricsSource>,
    ) -> io::Result<Self> {
        let listener = TcpListener::bind(addr)?;
        listener.set_nonblocking(true)?;
        let deps = Arc::new(Deps {
            ledger,
            ids,
            telemetry,
            metrics,
            in_flight: AtomicUsize::new(0),
        });
        Ok(Self { listener, deps })
    }

    /// The bound address.
    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.listener.local_addr()
    }

    /// Accepts until `stop` is set, then waits up to `grace` for in-flight
    /// requests to finish. Returns how many were still running at the end.
    pub fn serve(&self, stop: &AtomicBool, grace: Duration) -> usize {
        while !stop.load(Ordering::SeqCst) {
            match self.listener.accept() {
                Ok((stream, _)) => self.dispatch(stream),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => thread::sleep(ACCEPT_IDLE),
                Err(_) => thread::sleep(ACCEPT_IDLE),
            }
        }
        let deadline = Instant::now() + grace;
        while self.deps.in_flight.load(Ordering::SeqCst) > 0 && Instant::now() < deadline {
            thread::sleep(ACCEPT_IDLE);
        }
        self.deps.in_flight.load(Ordering::SeqCst)
    }

    fn dispatch(&self, mut stream: TcpStream) {
        if stream.set_nonblocking(false).is_err()
            || stream.set_read_timeout(Some(IO_TIMEOUT)).is_err()
            || stream.set_write_timeout(Some(IO_TIMEOUT)).is_err()
        {
            return;
        }
        if self.deps.in_flight.fetch_add(1, Ordering::SeqCst) >= MAX_IN_FLIGHT {
            self.deps.in_flight.fetch_sub(1, Ordering::SeqCst);
            let reply = Reply::text("other", 503, "busy\n");
            self.deps.record(&reply);
            let _ = write_reply(&mut stream, &reply);
            return;
        }
        let deps = Arc::clone(&self.deps);
        let spawned = thread::Builder::new().name("http-conn".into()).spawn({
            let deps = Arc::clone(&deps);
            move || {
                let reply = match read_request(&mut stream) {
                    Ok(req) => deps.route(&req),
                    Err(code) => Reply::text("other", code, "bad request\n"),
                };
                deps.record(&reply);
                let _ = write_reply(&mut stream, &reply);
                deps.in_flight.fetch_sub(1, Ordering::SeqCst);
            }
        });
        if spawned.is_err() {
            deps.in_flight.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

struct Request {
    method: String,
    path: String,
    body: String,
}

fn read_request(stream: &mut TcpStream) -> Result<Request, u16> {
    let mut buf: Vec<u8> = Vec::with_capacity(512);
    let mut chunk = [0u8; 512];
    let head_end = loop {
        if let Some(pos) = find(&buf, b"\r\n\r\n") {
            break pos;
        }
        if buf.len() > MAX_HEAD {
            return Err(431);
        }
        let n = stream.read(&mut chunk).map_err(|_| 400u16)?;
        if n == 0 {
            return Err(400);
        }
        buf.extend_from_slice(chunk.get(..n).ok_or(400u16)?);
    };
    let head = std::str::from_utf8(buf.get(..head_end).ok_or(400u16)?).map_err(|_| 400u16)?;
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or("").split(' ');
    let (method, path) = (first.next().unwrap_or(""), first.next().unwrap_or(""));
    if method.is_empty() || !path.starts_with('/') {
        return Err(400);
    }
    let mut length = 0usize;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            if name.trim().eq_ignore_ascii_case("content-length") {
                length = value.trim().parse().map_err(|_| 400u16)?;
            }
        }
    }
    if length > MAX_BODY {
        return Err(413);
    }
    let mut body: Vec<u8> = buf.get(head_end + 4..).unwrap_or(&[]).to_vec();
    while body.len() < length {
        let n = stream.read(&mut chunk).map_err(|_| 400u16)?;
        if n == 0 {
            return Err(400);
        }
        body.extend_from_slice(chunk.get(..n).ok_or(400u16)?);
    }
    body.truncate(length);
    Ok(Request {
        method: method.to_owned(),
        path: path.to_owned(),
        body: String::from_utf8(body).map_err(|_| 400u16)?,
    })
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

fn write_reply(stream: &mut TcpStream, r: &Reply) -> io::Result<()> {
    let head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        r.code,
        reason(r.code),
        r.content_type,
        r.body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(r.body.as_bytes())?;
    stream.flush()
}

fn reason(code: u16) -> &'static str {
    match code {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        422 => "Unprocessable Entity",
        431 => "Request Header Fields Too Large",
        503 => "Service Unavailable",
        _ => "Internal Server Error",
    }
}

impl Deps {
    fn record(&self, r: &Reply) {
        let class = match r.code {
            200..=299 => "2xx",
            400..=499 => "4xx",
            _ => "5xx",
        };
        self.telemetry.counter_inc(
            "svc_http_requests_total",
            &[("route", r.route), ("code", class)],
        );
    }

    fn route(&self, req: &Request) -> Reply {
        let want = |route: &'static str, method: &str| -> Option<Reply> {
            (req.method != method).then(|| Reply::text(route, 405, "method not allowed\n"))
        };
        match req.path.as_str() {
            "/healthz" => {
                want("healthz", "GET").unwrap_or_else(|| Reply::text("healthz", 200, "ok\n"))
            }
            "/metrics" => want("metrics", "GET")
                .unwrap_or_else(|| Reply::text("metrics", 200, self.metrics.render())),
            "/balance" => want("balance", "GET").unwrap_or_else(|| self.balance()),
            "/deposit" => {
                want("deposit", "POST").unwrap_or_else(|| self.command("deposit", true, &req.body))
            }
            "/withdraw" => want("withdraw", "POST")
                .unwrap_or_else(|| self.command("withdraw", false, &req.body)),
            _ => Reply::text("other", 404, "not found\n"),
        }
    }

    fn balance(&self) -> Reply {
        match self.ledger.snapshot() {
            Ok(s) => Reply::json(
                "balance",
                200,
                format!(
                    "{{\"balance_units\":{},\"version\":{}}}\n",
                    s.balance, s.version
                ),
            ),
            Err(_) => Reply::text("balance", 500, "internal error\n"),
        }
    }

    fn command(&self, route: &'static str, deposit: bool, body: &str) -> Reply {
        let (mut id, mut units) = (None, None);
        for pair in body.split('&').filter(|p| !p.is_empty()) {
            match pair.split_once('=') {
                Some(("id", v)) => id = Some(v.to_owned()),
                Some(("units", v)) => units = v.parse::<u64>().ok(),
                _ => return Reply::text(route, 400, "bad body\n"),
            }
        }
        let Some(units) = units else {
            return Reply::text(route, 400, "units required\n");
        };
        let id = id.unwrap_or_else(|| self.ids.next_id());
        let result = if deposit {
            self.ledger.deposit(&id, units)
        } else {
            self.ledger.withdraw(&id, units)
        };
        match result {
            Ok(outcome) => {
                let name = if outcome == Outcome::Applied {
                    "applied"
                } else {
                    "duplicate"
                };
                match self.ledger.snapshot() {
                    Ok(s) => Reply::json(
                        route,
                        200,
                        format!(
                            "{{\"outcome\":\"{name}\",\"id\":\"{id}\",\"balance_units\":{},\"version\":{}}}\n",
                            s.balance, s.version
                        ),
                    ),
                    Err(_) => Reply::text(route, 500, "internal error\n"),
                }
            }
            Err(LedgerError::Domain(DomainError::InsufficientFunds { .. })) => {
                Reply::text(route, 409, "insufficient funds\n")
            }
            Err(LedgerError::Domain(DomainError::Overflow)) => {
                Reply::text(route, 422, "overflow\n")
            }
            Err(LedgerError::Domain(_)) => Reply::text(route, 400, "invalid command\n"),
            Err(LedgerError::Store(_) | LedgerError::InvariantViolated) => {
                Reply::text(route, 500, "internal error\n")
            }
        }
    }
}
