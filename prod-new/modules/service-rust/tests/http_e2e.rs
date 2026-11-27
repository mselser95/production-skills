//! End-to-end over a real socket: wiring (ports -> adapters), the HTTP
//! contract, idempotency, conflict, authentication and graceful shutdown.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
mod common;
use common::{call, call_with, options, raw, start, TOKEN};

#[test]
fn serves_the_ledger_and_stops_gracefully() {
    let server = start(options());
    let addr = server.addr;

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
    for expect in [
        "svc_events_total{kind=\"deposit\",outcome=\"applied\"} 1",
        "svc_events_total{kind=\"deposit\",outcome=\"duplicate\"} 1",
        "svc_events_total{kind=\"withdraw\",outcome=\"applied\"} 1",
        "svc_events_total{kind=\"withdraw\",outcome=\"rejected\"} 2",
        "svc_http_requests_total{route=\"healthz\",code=\"2xx\"} 1",
        "svc_http_requests_total{route=\"deposit\",code=\"2xx\"} 2",
        "svc_http_requests_total{route=\"deposit\",code=\"4xx\"} 2",
        "svc_http_requests_total{route=\"withdraw\",code=\"2xx\"} 1",
        "svc_http_requests_total{route=\"withdraw\",code=\"4xx\"} 2",
        "svc_http_requests_total{route=\"balance\",code=\"2xx\"} 1",
        "svc_http_requests_total{route=\"other\",code=\"4xx\"} 1",
        "svc_balance_units 70",
    ] {
        assert!(scrape.contains(expect), "missing {expect:?} in\n{scrape}");
    }

    assert_eq!(server.finish(), 0, "shutdown must drain in-flight requests");
}

#[test]
fn write_routes_need_the_bearer_token_and_reads_stay_open() {
    let server = start(options());
    let addr = server.addr;
    let none = call_with(addr, "POST", "/deposit", "", "id=a&units=5");
    assert_eq!(none.0, 401);
    for bad in [
        "Authorization: Bearer wrong-token-0123456789\r\n",
        "Authorization: Bearer test-token-012345678\r\n",
        "Authorization: Bearer test-token-01234567890\r\n",
        "Authorization: Basic dGVzdA==\r\n",
        "Authorization: test-token-0123456789\r\n",
        "Authorization:\r\n",
    ] {
        let (c, _) = call_with(addr, "POST", "/deposit", bad, "id=a&units=5");
        assert_eq!(c, 401, "{bad:?}");
    }
    let raw401 = raw(
        addr,
        b"POST /withdraw HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n",
    );
    assert_eq!(raw401.unwrap().0, 401);
    assert!(call(addr, "GET", "/balance", "")
        .1
        .contains("\"balance_units\":0"));
    assert_eq!(call(addr, "GET", "/metrics", "").0, 200);
    let ok = call_with(
        addr,
        "POST",
        "/deposit",
        &format!("authorization: bearer {TOKEN}\r\n"),
        "id=a&units=5",
    );
    assert_eq!(ok.0, 200, "scheme is case-insensitive: {}", ok.1);
    assert!(call(addr, "GET", "/balance", "")
        .1
        .contains("\"balance_units\":5"));
    server.finish();
}

#[test]
fn an_id_reused_with_a_different_amount_is_a_409_not_a_silent_duplicate() {
    let server = start(options());
    let addr = server.addr;
    assert_eq!(call(addr, "POST", "/deposit", "id=x&units=10").0, 200);
    let (c, b) = call(addr, "POST", "/deposit", "id=x&units=11");
    assert_eq!(c, 409, "{b}");
    assert!(b.contains("different content"), "{b}");
    let (c, _) = call(addr, "POST", "/withdraw", "id=x&units=10");
    assert_eq!(c, 409, "same id, other kind");
    let (c, b) = call(addr, "POST", "/deposit", "id=x&units=10");
    assert_eq!((c, b.contains("duplicate")), (200, true), "{b}");
    assert!(call(addr, "GET", "/balance", "")
        .1
        .contains("\"balance_units\":10"));
    server.finish();
}

fn post(headers: &str, body: &str) -> Vec<u8> {
    format!(
        "POST /deposit HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer {TOKEN}\r\n{headers}\r\n{body}"
    )
    .into_bytes()
}

#[test]
fn request_framing_ambiguity_is_rejected_over_the_socket() {
    let server = start(options());
    let addr = server.addr;
    let code = |bytes: Vec<u8>| raw(addr, &bytes).map(|r| r.0);
    for headers in [
        "Content-Length: 7\r\nContent-Length: 7\r\n",
        "Content-Length: 7\r\nTransfer-Encoding: chunked\r\n",
        "Transfer-Encoding: chunked\r\n",
        "Content-Length: +7\r\n",
        "Content-Length:  7\r\n",
        "Content-Length: 7 \r\n",
        "Content-Length: 7x\r\n",
    ] {
        assert_eq!(code(post(headers, "units=1")), Some(400), "{headers:?}");
    }
    let get_body = b"GET /healthz HTTP/1.1\r\nHost: t\r\nContent-Length: 3\r\n\r\nabc".to_vec();
    assert_eq!(code(get_body), Some(400));
    assert_eq!(code(post("Content-Length: 7\r\n", "units=1")), Some(200));
    assert!(call(addr, "GET", "/balance", "")
        .1
        .contains("\"balance_units\":1"));
    server.finish();
}

#[test]
fn more_than_32_headers_is_a_431() {
    let server = start(options());
    let many: String = (0..40).map(|i| format!("X-{i}: v\r\n")).collect();
    let req = format!("GET /healthz HTTP/1.1\r\nHost: t\r\n{many}\r\n");
    assert_eq!(raw(server.addr, req.as_bytes()).map(|r| r.0), Some(431));
    server.finish();
}

#[test]
fn an_oversized_head_is_a_431() {
    let server = start(options());
    let big = format!(
        "GET /healthz HTTP/1.1\r\nHost: t\r\nX-Big: {}\r\n\r\n",
        "a".repeat(9 * 1024)
    );
    assert_eq!(raw(server.addr, big.as_bytes()).map(|r| r.0), Some(431));
    server.finish();
}

#[test]
fn an_announced_body_over_1_kib_is_a_413_without_waiting_for_it() {
    let server = start(options());
    // 1025 bytes announced and NONE sent: the answer must come from the
    // announced length, not from waiting for the body.
    let announced = post("Content-Length: 1025\r\n", "");
    assert_eq!(raw(server.addr, &announced).map(|r| r.0), Some(413));
    let exact = post(
        "Content-Length: 1024\r\n",
        &format!("units=1&id={}", "a".repeat(1024 - "units=1&id=".len())),
    );
    assert_eq!(
        raw(server.addr, &exact).map(|r| r.0),
        Some(400),
        "1024 bytes are read in full (the id is too long, hence 400)"
    );
    server.finish();
}
