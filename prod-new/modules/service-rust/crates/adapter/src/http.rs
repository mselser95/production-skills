//! HTTP/1.1 inbound adapter over `std::net`, one thread per connection.
//! Routes: `GET /healthz`, `GET /metrics`, `GET /balance` (open) and
//! `POST /deposit`, `POST /withdraw` (bearer token required; body
//! `id=<id>&units=<n>`, `id` optional). No TLS: put a proxy in front.
//!
//! Slow-client design (the reason a trickling client cannot starve health):
//!
//! * A request has a DEADLINE fixed at accept, not a per-read timeout. The
//!   head must complete within `head_deadline`, the whole request (head +
//!   body) within `request_deadline`; every read waits at most what is left,
//!   and expiry answers 408 and closes.
//! * Connections still reading their head sit in a bounded registry
//!   (`max_head_conns`). When it is full, the OLDEST unfinished head is
//!   evicted (its socket is shut down) to admit the newcomer, so a flood of
//!   stalled connections can never keep a fast `/healthz` out: the slow ones
//!   evict each other.
//! * Only a request that finished its head AND is a `POST` takes a body slot
//!   (`max_body_conns`); `GET`s need no body, so `/healthz` and `/metrics`
//!   never wait for a slot that a slow writer holds. A `POST` finding the body
//!   slots full is answered 503.
//! * Every counter is released by a drop guard, so a panicking connection
//!   thread frees its slot.
use std::collections::VecDeque;
use std::hint::black_box;
use std::io::{self, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

use svc_app::{Counter, IdGenerator, Ledger, LedgerError, MetricsSource, Receipt, Telemetry};
use svc_domain::{DomainError, Outcome};

/// Largest request head (request line + headers), in bytes.
pub const MAX_HEAD: usize = 8 * 1024;
/// Most header lines accepted.
pub const MAX_HEADERS: usize = 32;
/// Largest request body, in bytes.
pub const MAX_BODY: usize = 1024;
const WRITE_TIMEOUT: Duration = Duration::from_secs(2);
const ACCEPT_IDLE: Duration = Duration::from_millis(20);

/// Server limits and the write-route credential.
pub struct Options {
    /// The bearer token `POST` routes require. There is no default.
    pub auth_token: String,
    /// The request head must be complete this long after accept.
    pub head_deadline: Duration,
    /// The whole request (head + body) must be complete this long after accept.
    pub request_deadline: Duration,
    /// Connections that may be reading a head at once (oldest evicted beyond).
    pub max_head_conns: usize,
    /// `POST`s that may be reading a body / running at once (503 beyond).
    pub max_body_conns: usize,
}

impl Options {
    /// Default limits: 2 s head, 10 s request, 48 head + 16 body = 64.
    pub fn new(auth_token: String) -> Self {
        Self {
            auth_token,
            head_deadline: Duration::from_secs(2),
            request_deadline: Duration::from_secs(10),
            max_head_conns: 48,
            max_body_conns: 16,
        }
    }
}

impl std::fmt::Debug for Options {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Options")
            .field("auth_token", &"<redacted>")
            .field("head_deadline", &self.head_deadline)
            .field("request_deadline", &self.request_deadline)
            .field("max_head_conns", &self.max_head_conns)
            .field("max_body_conns", &self.max_body_conns)
            .finish()
    }
}

/// The HTTP server and the collaborators its handlers use.
pub struct Server {
    listener: TcpListener,
    deps: Arc<Deps>,
}

struct HeadEntry {
    id: u64,
    stream: TcpStream,
    evicted: Arc<AtomicBool>,
}

struct Deps {
    ledger: Arc<Ledger>,
    ids: Arc<dyn IdGenerator>,
    telemetry: Arc<dyn Telemetry>,
    metrics: Arc<dyn MetricsSource>,
    opts: Options,
    /// Connection threads alive (what shutdown drains).
    live: AtomicUsize,
    /// `POST`s holding a body slot.
    body: AtomicUsize,
    heads: Mutex<VecDeque<HeadEntry>>,
    next_conn: AtomicU64,
}

/// A read-only view of the server's load, usable after `serve` took the server.
#[derive(Clone)]
pub struct Monitor(Arc<Deps>);

impl Monitor {
    /// Connection threads currently alive.
    pub fn live_connections(&self) -> usize {
        self.0.live.load(Ordering::SeqCst)
    }
}

/// Decrements a counter when dropped, panic or not.
struct Count<'a>(&'a AtomicUsize);

impl<'a> Count<'a> {
    fn take(counter: &'a AtomicUsize) -> Self {
        counter.fetch_add(1, Ordering::SeqCst);
        Self(counter)
    }
}

impl Drop for Count<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Owned guard that travels into the connection thread and frees its `live`
/// slot on drop, including when the thread panics.
struct LiveGuard(Arc<Deps>);

impl Drop for LiveGuard {
    fn drop(&mut self) {
        self.0.live.fetch_sub(1, Ordering::SeqCst);
    }
}

struct Reply {
    route: &'static str,
    code: u16,
    content_type: &'static str,
    extra: &'static str,
    body: String,
}

impl Reply {
    fn text(route: &'static str, code: u16, body: impl Into<String>) -> Self {
        Self {
            route,
            code,
            content_type: "text/plain; charset=utf-8",
            extra: "",
            body: body.into(),
        }
    }

    fn json(route: &'static str, code: u16, body: String) -> Self {
        Self {
            route,
            code,
            content_type: "application/json",
            extra: "",
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
        opts: Options,
    ) -> io::Result<Self> {
        let listener = TcpListener::bind(addr)?;
        listener.set_nonblocking(true)?;
        let deps = Arc::new(Deps {
            ledger,
            ids,
            telemetry,
            metrics,
            opts,
            live: AtomicUsize::new(0),
            body: AtomicUsize::new(0),
            heads: Mutex::new(VecDeque::new()),
            next_conn: AtomicU64::new(0),
        });
        Ok(Self { listener, deps })
    }

    /// The bound address.
    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.listener.local_addr()
    }

    /// A load view that outlives `serve`.
    pub fn monitor(&self) -> Monitor {
        Monitor(Arc::clone(&self.deps))
    }

    /// Accepts until `stop` is set, then CLOSES the listener (new connections
    /// are refused from that moment) and waits up to `grace` for in-flight
    /// requests. Returns how many were still running at the end: 0 means
    /// drained.
    pub fn serve(self, stop: &AtomicBool, grace: Duration) -> usize {
        let Self { listener, deps } = self;
        while !stop.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((stream, _)) => dispatch(&deps, stream),
                Err(_) => thread::sleep(ACCEPT_IDLE),
            }
        }
        drop(listener);
        let deadline = Instant::now() + grace;
        while deps.live.load(Ordering::SeqCst) > 0 && Instant::now() < deadline {
            thread::sleep(ACCEPT_IDLE);
        }
        deps.live.load(Ordering::SeqCst)
    }
}

fn dispatch(deps: &Arc<Deps>, stream: TcpStream) {
    if stream.set_nonblocking(false).is_err()
        || stream.set_write_timeout(Some(WRITE_TIMEOUT)).is_err()
    {
        return;
    }
    let started = Instant::now();
    deps.live.fetch_add(1, Ordering::SeqCst);
    let guard = LiveGuard(Arc::clone(deps));
    // Registered HERE, in accept order, not inside the thread: the registry
    // order is then the arrival order, so a newcomer is never evicted by older
    // connections whose threads merely started late.
    let registered = Registration::new(deps, &stream);
    let deps = Arc::clone(deps);
    // If the spawn fails the closure (and `guard`) is dropped: slot freed.
    let _ = thread::Builder::new()
        .name("http-conn".into())
        .spawn(move || {
            let _live = guard;
            handle(&deps, stream, started, registered);
        });
}

/// What went wrong while reading a request.
enum Fail {
    /// Answer with this status, then close.
    Reply(u16),
    /// Close without answering (peer gone, or evicted).
    Close,
}

fn handle(deps: &Deps, mut stream: TcpStream, started: Instant, registered: Registration) {
    let reply = match serve_one(deps, &mut stream, started, registered) {
        Ok(r) => r,
        Err(Fail::Close) => return,
        Err(Fail::Reply(code)) => Reply::text("other", code, "bad request\n"),
    };
    deps.record(&reply);
    let _ = write_reply(&mut stream, &reply);
}

fn serve_one(
    deps: &Deps,
    stream: &mut TcpStream,
    started: Instant,
    registered: Registration,
) -> Result<Reply, Fail> {
    let head_until = started + deps.opts.head_deadline;
    let request_until = started + deps.opts.request_deadline;
    // `registered` leaves the registry when this block ends (head read or not).
    let (raw, leftover) = match read_head(stream, head_until.min(request_until)) {
        Ok(v) => v,
        Err(_) if registered.was_evicted() => return Err(Fail::Close),
        Err(f) => return Err(f),
    };
    drop(registered);
    let head = parse_head(&raw).map_err(Fail::Reply)?;
    let route = match deps.classify(&head) {
        Ok(r) => r,
        Err(reply) => return Ok(reply),
    };
    let Route::Command { name, deposit } = route else {
        return Ok(deps.read_route(&route));
    };
    let Some(_slot) = deps.take_body_slot() else {
        return Ok(Reply::text(name, 503, "busy\n"));
    };
    let body = read_body(stream, leftover, head.length, request_until).map_err(Fail::Reply)?;
    Ok(deps.command(name, deposit, &body))
}

/// A connection reading its head, visible to the evictor.
struct Registration {
    deps: Arc<Deps>,
    id: u64,
    evicted: Arc<AtomicBool>,
}

impl Registration {
    fn new(deps: &Arc<Deps>, stream: &TcpStream) -> Self {
        let id = deps.next_conn.fetch_add(1, Ordering::SeqCst);
        let evicted = Arc::new(AtomicBool::new(false));
        if let Ok(clone) = stream.try_clone() {
            let mut heads = deps.heads.lock().unwrap_or_else(PoisonError::into_inner);
            while heads.len() >= deps.opts.max_head_conns.max(1) {
                if let Some(old) = heads.pop_front() {
                    old.evicted.store(true, Ordering::SeqCst);
                    let _ = old.stream.shutdown(Shutdown::Both);
                }
            }
            heads.push_back(HeadEntry {
                id,
                stream: clone,
                evicted: Arc::clone(&evicted),
            });
        }
        Self {
            deps: Arc::clone(deps),
            id,
            evicted,
        }
    }

    fn was_evicted(&self) -> bool {
        self.evicted.load(Ordering::SeqCst)
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        let mut heads = self
            .deps
            .heads
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        heads.retain(|e| e.id != self.id);
    }
}

/// One bounded read: waits at most until `until`.
fn read_some(stream: &mut TcpStream, until: Instant, chunk: &mut [u8]) -> Result<usize, Fail> {
    let left = until
        .checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
        .ok_or(Fail::Reply(408))?;
    stream
        .set_read_timeout(Some(left.max(Duration::from_millis(1))))
        .map_err(|_| Fail::Close)?;
    loop {
        return match stream.read(chunk) {
            Ok(n) => Ok(n),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                Err(Fail::Reply(408))
            }
            Err(_) => Err(Fail::Close),
        };
    }
}

/// Reads until the blank line; returns the head text and any body bytes
/// already read behind it.
fn read_head(stream: &mut TcpStream, until: Instant) -> Result<(String, Vec<u8>), Fail> {
    let mut buf: Vec<u8> = Vec::with_capacity(512);
    let mut chunk = [0u8; 512];
    let head_end = loop {
        if let Some(pos) = find(&buf, b"\r\n\r\n") {
            break pos;
        }
        if buf.len() > MAX_HEAD {
            return Err(Fail::Reply(431));
        }
        let n = read_some(stream, until, &mut chunk)?;
        if n == 0 {
            return Err(Fail::Reply(400));
        }
        buf.extend_from_slice(chunk.get(..n).ok_or(Fail::Reply(400))?);
    };
    if head_end > MAX_HEAD {
        return Err(Fail::Reply(431));
    }
    let head = buf.get(..head_end).ok_or(Fail::Reply(400))?;
    let head = String::from_utf8(head.to_vec()).map_err(|_| Fail::Reply(400))?;
    let rest = buf.get(head_end + 4..).unwrap_or(&[]).to_vec();
    Ok((head, rest))
}

fn read_body(
    stream: &mut TcpStream,
    mut body: Vec<u8>,
    length: usize,
    until: Instant,
) -> Result<String, u16> {
    let mut chunk = [0u8; 512];
    while body.len() < length {
        let n = read_some(stream, until, &mut chunk).map_err(|f| match f {
            Fail::Reply(c) => c,
            Fail::Close => 400,
        })?;
        if n == 0 {
            return Err(400);
        }
        body.extend_from_slice(chunk.get(..n).ok_or(400u16)?);
    }
    body.truncate(length);
    String::from_utf8(body).map_err(|_| 400u16)
}

/// A parsed request head.
#[derive(Debug, PartialEq, Eq)]
struct Head {
    method: String,
    path: String,
    length: usize,
    authorization: Option<String>,
}

fn is_token_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b)
}

/// RFC 9112 head parsing, strict: any ambiguity is a 400 (or 413/431).
fn parse_head(head: &str) -> Result<Head, u16> {
    if head
        .bytes()
        .any(|b| (b < 0x20 && b != b'\t' && b != b'\r' && b != b'\n') || b == 0x7f)
    {
        return Err(400);
    }
    let mut lines = head.split("\r\n");
    let request_line = lines.next().ok_or(400u16)?;
    let mut parts = request_line.split(' ');
    let (method, path, version) = (parts.next(), parts.next(), parts.next());
    let (Some(method), Some(path), Some(version), None) = (method, path, version, parts.next())
    else {
        return Err(400);
    };
    if method.is_empty()
        || !method.bytes().all(is_token_char)
        || !path.starts_with('/')
        || !(version == "HTTP/1.1" || version == "HTTP/1.0")
    {
        return Err(400);
    }
    let (mut length, mut authorization, mut count) = (None::<usize>, None::<String>, 0usize);
    for line in lines {
        if line.contains('\r') || line.contains('\n') || line.starts_with([' ', '\t']) {
            return Err(400); // bare CR/LF, or obsolete line folding
        }
        count += 1;
        if count > MAX_HEADERS {
            return Err(431);
        }
        let (name, value) = line.split_once(':').ok_or(400u16)?;
        // A name with whitespace (`Content-Length : 5`) is not a token.
        if name.is_empty() || !name.bytes().all(is_token_char) {
            return Err(400);
        }
        if name.eq_ignore_ascii_case("transfer-encoding") {
            return Err(400); // no chunked or other codings: smuggling surface
        } else if name.eq_ignore_ascii_case("content-length") {
            let digits = value.strip_prefix(' ').unwrap_or(value);
            if length.is_some()
                || digits.is_empty()
                || digits.len() > 9
                || !digits.bytes().all(|b| b.is_ascii_digit())
            {
                return Err(400); // duplicate, `+5`, ` 5 `, `5x`, empty
            }
            length = Some(digits.parse().map_err(|_| 400u16)?);
        } else if name.eq_ignore_ascii_case("authorization") {
            if authorization.is_some() {
                return Err(400);
            }
            authorization = Some(value.trim_matches([' ', '\t']).to_owned());
        }
    }
    let length = length.unwrap_or(0);
    if length > MAX_BODY {
        return Err(413);
    }
    if method == "GET" && length > 0 {
        return Err(400); // a body on GET is a smuggling vector
    }
    Ok(Head {
        method: method.to_owned(),
        path: path.to_owned(),
        length,
        authorization,
    })
}

/// Constant-time equality: the time depends on the longer length, never on
/// where the first difference is.
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    let mut diff = a.len() ^ b.len();
    for i in 0..a.len().max(b.len()) {
        let x = a.get(i).copied().unwrap_or(0);
        let y = b.get(i).copied().unwrap_or(0);
        diff |= usize::from(x ^ y);
    }
    black_box(diff) == 0
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

fn write_reply(stream: &mut TcpStream, r: &Reply) -> io::Result<()> {
    let head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\n{}Content-Length: {}\r\nConnection: close\r\n\r\n",
        r.code,
        reason(r.code),
        r.content_type,
        r.extra,
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
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        409 => "Conflict",
        413 => "Payload Too Large",
        422 => "Unprocessable Entity",
        431 => "Request Header Fields Too Large",
        503 => "Service Unavailable",
        _ => "Internal Server Error",
    }
}

enum Route {
    Health,
    Metrics,
    Balance,
    Command { name: &'static str, deposit: bool },
}

impl Deps {
    fn record(&self, r: &Reply) {
        let class = match r.code {
            200..=299 => "2xx",
            400..=499 => "4xx",
            _ => "5xx",
        };
        self.telemetry
            .counter_inc(Counter::HttpRequests, &[r.route, class]);
    }

    fn take_body_slot(&self) -> Option<Count<'_>> {
        let slot = Count::take(&self.body);
        (self.body.load(Ordering::SeqCst) <= self.opts.max_body_conns).then_some(slot)
    }

    fn authorized(&self, head: &Head) -> bool {
        head.authorization
            .as_deref()
            .and_then(|v| v.split_once(' '))
            .is_some_and(|(scheme, token)| {
                scheme.eq_ignore_ascii_case("bearer")
                    && ct_eq(token.as_bytes(), self.opts.auth_token.as_bytes())
            })
    }

    /// Method and path decide the route; write routes also need the token.
    /// Runs BEFORE any body is read.
    fn classify(&self, head: &Head) -> Result<Route, Reply> {
        let want = |route: &'static str, method: &str| -> Result<(), Reply> {
            if head.method == method {
                Ok(())
            } else {
                Err(Reply::text(route, 405, "method not allowed\n"))
            }
        };
        let command = |name: &'static str, deposit: bool| -> Result<Route, Reply> {
            want(name, "POST")?;
            if self.authorized(head) {
                Ok(Route::Command { name, deposit })
            } else {
                let mut r = Reply::text(name, 401, "unauthorized\n");
                r.extra = "WWW-Authenticate: Bearer\r\n";
                Err(r)
            }
        };
        match head.path.as_str() {
            "/healthz" => want("healthz", "GET").map(|()| Route::Health),
            "/metrics" => want("metrics", "GET").map(|()| Route::Metrics),
            "/balance" => want("balance", "GET").map(|()| Route::Balance),
            "/deposit" => command("deposit", true),
            "/withdraw" => command("withdraw", false),
            _ => Err(Reply::text("other", 404, "not found\n")),
        }
    }

    fn read_route(&self, route: &Route) -> Reply {
        match route {
            Route::Health => Reply::text("healthz", 200, "ok\n"),
            Route::Metrics => Reply::text("metrics", 200, self.metrics.render()),
            Route::Balance => match self.ledger.snapshot() {
                Ok(s) => Reply::json(
                    "balance",
                    200,
                    format!(
                        "{{\"balance_units\":{},\"version\":{}}}\n",
                        s.balance, s.version
                    ),
                ),
                Err(_) => Reply::text("balance", 500, "internal error\n"),
            },
            Route::Command { name, .. } => Reply::text(name, 500, "internal error\n"),
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
            Ok(Receipt { outcome, snapshot }) => {
                let name = if outcome == Outcome::Applied {
                    "applied"
                } else {
                    "duplicate"
                };
                Reply::json(
                    route,
                    200,
                    format!(
                        "{{\"outcome\":\"{name}\",\"id\":\"{id}\",\"balance_units\":{},\"version\":{}}}\n",
                        snapshot.balance, snapshot.version
                    ),
                )
            }
            Err(LedgerError::Domain(DomainError::InsufficientFunds { .. })) => {
                Reply::text(route, 409, "insufficient funds\n")
            }
            Err(LedgerError::Domain(DomainError::IdConflict)) => {
                Reply::text(route, 409, "event id reused with different content\n")
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

#[cfg(test)]
mod tests {
    use super::*;

    fn head(extra: &str) -> String {
        format!("POST /deposit HTTP/1.1\r\nHost: t{extra}")
    }

    #[test]
    fn a_plain_head_parses() {
        let h = parse_head(&head("\r\nContent-Length: 5\r\nAuthorization: Bearer x")).unwrap();
        assert_eq!(
            (h.method.as_str(), h.path.as_str(), h.length),
            ("POST", "/deposit", 5)
        );
        assert_eq!(h.authorization.as_deref(), Some("Bearer x"));
        assert_eq!(parse_head(&head("\r\nContent-Length:5")).unwrap().length, 5);
    }

    #[test]
    fn content_length_ambiguity_is_a_400() {
        for bad in [
            "\r\nContent-Length: 5\r\nContent-Length: 5",
            "\r\nContent-Length: 5\r\ncontent-length: 6",
            "\r\nContent-Length: 5\r\nTransfer-Encoding: chunked",
            "\r\nTransfer-Encoding: chunked",
            "\r\nTransfer-Encoding: identity",
            "\r\nContent-Length: +5",
            "\r\nContent-Length:  5",
            "\r\nContent-Length: 5 ",
            "\r\nContent-Length: 5x",
            "\r\nContent-Length: -1",
            "\r\nContent-Length:",
            "\r\nContent-Length : 5",
            "\r\n Content-Length: 5",
            "\r\nContent-Length: 1_0",
            "\r\nBare-LF: a\nb: c",
            "\r\nNo-Colon",
        ] {
            assert_eq!(parse_head(&head(bad)), Err(400), "{bad:?}");
        }
    }

    #[test]
    fn size_and_count_limits() {
        assert_eq!(parse_head(&head("\r\nContent-Length: 1025")), Err(413));
        assert!(parse_head(&head("\r\nContent-Length: 1024")).is_ok());
        let many = |n: usize| (0..n).map(|i| format!("\r\nX-{i}: v")).collect::<String>();
        // `Host` is the first header, so MAX_HEADERS - 1 more fit exactly.
        assert!(parse_head(&head(&many(MAX_HEADERS - 1))).is_ok());
        assert_eq!(parse_head(&head(&many(MAX_HEADERS))), Err(431));
    }

    #[test]
    fn a_body_on_get_is_refused_but_a_zero_length_is_fine() {
        let get = |extra: &str| format!("GET /healthz HTTP/1.1\r\nHost: t{extra}");
        assert_eq!(parse_head(&get("\r\nContent-Length: 3")), Err(400));
        assert!(parse_head(&get("\r\nContent-Length: 0")).is_ok());
        assert!(parse_head(&get("")).is_ok());
    }

    #[test]
    fn request_line_must_be_three_parts_and_http_1() {
        for bad in [
            "GET /x",
            "GET /x HTTP/1.1 extra",
            "GET x HTTP/1.1",
            "GET /x HTTP/2",
            " /x HTTP/1.1",
            "G ET /x HTTP/1.1",
        ] {
            assert_eq!(parse_head(bad), Err(400), "{bad:?}");
        }
    }

    #[test]
    fn duplicate_authorization_is_refused() {
        assert_eq!(
            parse_head(&head(
                "\r\nAuthorization: Bearer a\r\nAuthorization: Bearer b"
            )),
            Err(400)
        );
    }

    #[test]
    fn ct_eq_compares_whole_values() {
        assert!(ct_eq(b"secret-token-0001", b"secret-token-0001"));
        assert!(!ct_eq(b"secret-token-0001", b"secret-token-0002"));
        assert!(!ct_eq(b"secret-token-0001", b"secret-token-000"));
        assert!(!ct_eq(b"", b"x"));
        assert!(ct_eq(b"", b""));
    }
}
