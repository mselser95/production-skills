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
use std::io::Write;
use std::net::TcpStream;
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use common::{call, call_with, options, raw, read_all, start, within, TOKEN};

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

/// Stalled heads that each sent ONE byte: more than the 48 head slots, so the
/// registry is full and every newcomer evicts someone.
const HELD: usize = 60;
/// What `HELD` heads must have evicted at least: `HELD` minus the 48 slots.
const MIN_EVICTIONS: u64 = 12;
/// Well-behaved clients, one after the other.
const ROUNDS: usize = 20;
/// How long a well-behaved client waits for its answer. Generous on purpose:
/// this test asserts WHO is evicted, never how fast anything is answered.
const PATIENT: Duration = Duration::from_secs(10);

/// The property of the eviction policy, built without a clock: when the head
/// table is full, the OLDEST head is evicted, so a newcomer that has sent
/// nothing yet is not evicted by older heads that have sent a byte.
///
/// Why this is deterministic: the accept loop registers connections in accept
/// order and the kernel queues them in connect order, so connecting
/// sequentially FIXES the registry order, whatever the host load. Per round a
/// good client connects (registered, zero bytes), then ONE newer stalled
/// connection arrives while the table is full, and only then does the good
/// client send its request. Oldest-first evicts an old stalled head and the
/// good client is answered; "fewest bytes first" (the policy this replaced)
/// evicts the good client, which has the fewest, and gets no reply.
#[test]
fn a_newcomer_is_not_evicted_by_older_stalled_heads_when_the_head_table_is_full() {
    let _one_at_a_time = HEAVY.lock().unwrap_or_else(PoisonError::into_inner);
    let mut o = options();
    // Deadlines far beyond the test: a slow host cannot make the server cut a client.
    o.head_deadline = Duration::from_secs(120);
    o.request_deadline = Duration::from_secs(120);
    let server = start(o);
    let addr = server.addr;

    // The stalled heads, opened one after the other (each `connect` returns
    // once the handshake is done, so each is established before the next).
    let mut stalled: Vec<TcpStream> = (0..HELD)
        .map(|_| {
            let mut s = TcpStream::connect(addr).unwrap();
            s.write_all(b"G").unwrap();
            s
        })
        .collect();
    // Connections are accepted in order: once this scrape is answered, every
    // stalled head above has been registered, and the table has evicted.
    let (_, scrape) = call(addr, "GET", "/metrics", "");
    let evictions = |scrape: &str| -> u64 {
        scrape
            .lines()
            .find_map(|l| l.strip_prefix("svc_http_head_evictions_total "))
            .and_then(|v| v.trim().parse().ok())
            .expect("the eviction counter must be exported")
    };
    assert!(
        evictions(&scrape) >= MIN_EVICTIONS,
        "the table did not fill: {scrape}"
    );

    for round in 0..ROUNDS {
        let mut good = TcpStream::connect(addr).unwrap();
        let mut newer = TcpStream::connect(addr).unwrap();
        newer.write_all(b"G").unwrap();
        stalled.push(newer);
        good.set_read_timeout(Some(PATIENT)).unwrap();
        good.write_all(b"GET /healthz HTTP/1.1\r\nHost: t\r\n\r\n")
            .unwrap();
        let answer = read_all(&mut good).map(|r| r.0);
        assert_eq!(
            answer,
            Some(200),
            "round {round}: a client that arrived before ONE newer stalled head was evicted (answer {answer:?})"
        );
    }

    // The evictions are the table's work and are counted.
    let (_, scrape) = call(addr, "GET", "/metrics", "");
    // Every round added one newer head to a table that was already full, so
    // each round evicted at least one: the floor is the first phase's plus one
    // per round, derived from the constants (not a literal).
    let floor = MIN_EVICTIONS + u64::try_from(ROUNDS).unwrap();
    assert!(
        evictions(&scrape) >= floor,
        "evictions: {} (every one of {ROUNDS} rounds must have evicted: at least {floor})",
        evictions(&scrape)
    );
    drop(stalled);
    assert!(
        within(Duration::from_secs(10), || server
            .monitor
            .live_connections()
            == 0)
        .is_some(),
        "connections are still live after every client went away"
    );
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

/// A cheap in-tree pin on the zone-purity test: deleting `tests/architecture.rs`
/// (or renaming one of its gate tests) would otherwise leave `make check-fast`
/// green with fewer tests. Every `implemented:` row of `production.yaml`
/// ("<file> <test fn>") must name a file that exists and defines that test, and
/// the architecture file must still define the compiler-gate tests by name.
/// Scope: this raises the cost of dropping the gate from deleting one file to
/// editing two files that review must watch; it is NOT a proof, because an
/// edit that touches both (or the Makefile) is outside what an in-tree test
/// can see.
#[test]
fn the_tests_that_production_yaml_cites_exist_and_the_architecture_gate_is_present() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let yaml = std::fs::read_to_string(root.join("production.yaml")).unwrap();
    let rows: Vec<(String, String)> = yaml
        .lines()
        .skip_while(|l| l.trim_end() != "implemented:")
        .skip(1)
        .take_while(|l| l.starts_with(' '))
        .filter_map(|l| {
            let mut words = l.split_whitespace().skip(1);
            Some((words.next()?.to_owned(), words.next()?.to_owned()))
        })
        .collect();
    assert!(
        rows.iter().any(|(f, _)| f == "tests/architecture.rs"),
        "production.yaml no longer cites tests/architecture.rs: {rows:?}"
    );
    for (file, name) in &rows {
        let text = std::fs::read_to_string(root.join(file))
            .unwrap_or_else(|e| panic!("production.yaml cites {file}, which cannot be read: {e}"));
        assert!(
            text.contains(&format!("fn {name}(")),
            "production.yaml cites {file} {name}, which is not defined there"
        );
    }
    let architecture = std::fs::read_to_string(root.join("tests/architecture.rs")).unwrap();
    for name in [
        "the_compiler_refuses_std_and_unsafe_code_in_domain_and_app",
        "unsafe_code_is_forbidden_from_the_command_line_in_the_other_zones_too",
        "the_compiler_gate_is_armed_and_no_cargo_configuration_can_lower_it",
        "no_cargo_configuration_sits_in_or_above_the_module",
    ] {
        assert!(
            architecture.contains(&format!("fn {name}(")),
            "tests/architecture.rs lost the gate test {name}"
        );
    }
}
