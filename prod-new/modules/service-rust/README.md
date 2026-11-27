# <SERVICE>

A small Rust service that carries the framework's architecture: a units
ledger in four zones that are separate crates (so the dependency direction is
the compiler's, not a convention), an observability contract checked in both
directions, bearer-token auth on the write routes, and a composition root that
drains on SIGTERM. Repository: `<OWNER>/<SERVICE>`.

## Zones (a Cargo workspace)

```
crates/domain    no dependencies, #![no_std]            pure ledger rules
crates/app       domain only, #![no_std] + alloc        use-cases over ports
crates/adapter   app + domain                           HTTP in, memory store out
crates/platform  app (+ ctrlc)                          clock, ids, config, recorder, signals
src/main.rs      all four                               composition root (package `svc`)
```

| enforced by | what |
|---|---|
| the compiler, on a target with no `std` | `make check-nostd` compiles `domain` and `app` for `thumbv7em-none-eabi`, which has no `std`: no file, socket, clock, thread or environment access can compile there, and `extern crate std` in ANY spelling (block comment, macro, `include!`, a missing `#![no_std]`) is error E0463. It runs inside `make check-fast` and `make verify`; `rust-toolchain.toml` installs the target (`targets`), so a `rustup`-driven `cargo` fetches it. `#![forbid(unsafe_code)]` is a workspace lint on every crate: an `unsafe extern` block or an `unsafe` call to a foreign function is a compile error (probed on `domain`). |
| the compiler, through Cargo | A zone names only the crates its `Cargo.toml` lists, so `app` cannot name `adapter`, and `adapter` and `platform` cannot see each other. |
| a test | `tests/architecture.rs` pins the exact dependency lists from `cargo metadata` (add `platform` to `domain` and it goes RED); that `domain` and `app` have only `lib`/`test` targets (no build script, no proc-macro: those run host code at build time and compile fine for any target); that the Makefile's `check-nostd` names exactly those two crates and the target, that `check-fast` runs it, and that `rust-toolchain.toml` installs the target; and that the release profile keeps overflow checks and unwinding. |
| a source scan (weaker) | an early, friendly message that `domain`/`app` name no `std::` item (the compiler check above is the enforcement; the scan strips only `//` comments and is evadable); only `crates/platform/src/config.rs` reads the environment; the token is compared through `ct_eq`. |

Not enforced: the purity of `adapter`, `platform` and `main` (they are the I/O
zones), and build-time code in any crate other than `domain` and `app`. CI
images need the `thumbv7em-none-eabi` rust-std component: `rustup target add`
or the toolchain file's `targets`.

`Cargo.lock` is committed; `rust-toolchain.toml` pins the toolchain;
`[workspace.lints]` carries the lint table every member inherits.

## Observability contract

Every declared label-less series is exported at 0 from the first scrape
(`Recorder::with_declared_series`) and a labelled family shows its `# TYPE`
line before its first sample, so `svc_units_conserved_violations_total` reads
0, never absent. A telemetry call that is dropped (wrong number of label
values, series cap) is counted in `svc_telemetry_errors_total`; it stays 0.

Metrics and spans are named by three enums in `crates/app/src/telemetry.rs`
(`Counter`, `Gauge`, `SpanName`); `Telemetry` takes those, never a string, so a
name that is not declared does not compile. `observability/*.yaml` is compared
with that table in both directions: name, type and label keys
(`tests/observability_contract.rs`).

## HTTP surface, auth and limits

`GET /healthz`, `GET /metrics`, `GET /balance` are open. `POST /deposit` and
`POST /withdraw` (`id=<id>&units=<n>`) need `Authorization: Bearer <token>`.

* The token comes from `SVC_AUTH_TOKEN`. The service REFUSES TO START (exit 1,
  one `config:` line, the token is never printed) without it, with fewer than
  16 bytes, or with any byte outside visible ASCII `0x21..0x7E`: HTTP trims
  whitespace around a header value and forbids control bytes, so such a token
  could never be presented. The header is compared exactly after dropping
  leading/trailing space and tab (RFC 9110 OWS); there is no default.
* A non-loopback `SVC_LISTEN_ADDR` is refused unless `SVC_ALLOW_NON_LOOPBACK=1`.
* This is NOT transport security: there is no TLS and the reads are
  unauthenticated. Put a TLS-terminating proxy in front before exposing it.
* One id sent twice with the same content is a replay (200, `duplicate`); the
  same id with a different kind or amount is a conflict (409).
* Requests have a deadline fixed at accept (head 2 s, whole request 10 s,
  both configurable); expiry answers 408.
* Eviction policy: at most 48 connections may be reading a head. When the
  registry is full a newcomer evicts the connection that has received the
  FEWEST bytes (the oldest on a tie); the victim is closed with no reply and
  `svc_http_head_evictions_total` counts it. So a flood of idle connections
  evicts itself and a slow client that is sending outlives it. It is NOT
  protected outright: a client that has sent less than every other head is the
  victim, and at a sustained rate of R new connections per second a head that
  sends nothing for longer than about 48/R seconds is evicted. An alert on that
  counter is the signal.
* The accept loop polls every 1 ms (`stop` is a bare flag, so a blocking
  `accept` could not be woken without unsafe or a second poller); a burst
  beyond the kernel backlog (128) arriving inside one poll can still lose SYNs.
* `units` is `0` or `[1-9][0-9]*` that fits `u64` (no sign, no leading zero);
  a repeated `units` or `id` is 400.
* Strict RFC 9112 framing: duplicate or malformed `Content-Length`, any
  `Transfer-Encoding`, and a body on `GET` are 400; more than 32 headers or an
  8 KiB head is 431; a body over 1 KiB is 413.

## Run

```
make check-fast      # fmt, clippy -D warnings, tests (the real cargo commands)
SVC_AUTH_TOKEN=$(head -c 24 /dev/urandom | base64) cargo run --locked
curl -H "Authorization: Bearer $SVC_AUTH_TOKEN" -d 'id=a1&units=100' localhost:8080/deposit
curl localhost:8080/balance ; curl localhost:8080/metrics
```

Environment (read only in `crates/platform/src/config.rs`): `SVC_AUTH_TOKEN`
(required), `SVC_LISTEN_ADDR` (default `127.0.0.1:8080`, literal `ip:port`),
`SVC_ALLOW_NON_LOOPBACK` (`0`|`1`), `SVC_TRACING` (`off`|`log`),
`SVC_SHUTDOWN_GRACE_MS` (default 5000), `SVC_HEAD_DEADLINE_MS` (2000),
`SVC_REQUEST_DEADLINE_MS` (10000).

Shutdown: on SIGINT/SIGTERM the listener is closed first (new connections are
refused), connections that have not sent a single request byte are closed and
are not counted as abandoned, in-flight requests drain for up to the grace
period, and the exit code is 0 when drained, 3 when requests were abandoned, 1
on a startup error. A SECOND SIGINT/SIGTERM while draining exits at once with
code 4, abandoning whatever was in flight.

## Limits of this example

* State is process memory; a restart starts empty.
* The applied-id set is never pruned (retention is unbounded here); a real
  store keeps ids for a bounded idempotency window or in a unique index.
* `make verify` equals `make check-fast` today. cargo-deny, coverage and
  mutation testing are a later change.
* The release profile keeps `panic = "unwind"`: a panicking connection thread
  frees its slots and the process keeps serving (see `Cargo.toml`).
