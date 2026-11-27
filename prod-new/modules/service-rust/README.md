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
| the compiler | `domain` and `app` are `no_std`: no file, socket, clock, environment or thread is reachable. A zone names only the crates its `Cargo.toml` lists, so `app` cannot name `adapter`, and `adapter` and `platform` cannot see each other. `#![forbid(unsafe_code)]` everywhere. |
| a test | `tests/architecture.rs` asserts the exact dependency lists from `cargo metadata` (add `platform` to `domain` and it goes RED), that `domain`/`app` carry `#![no_std]` and no `extern crate` other than `alloc` (an `extern crate std` would link std back in), and that the release profile keeps overflow checks and unwinding. |
| a source scan (weaker) | only `crates/platform/src/config.rs` reads the environment (runtime `std::env::var`, build-time `option_env!`), and the token is compared through `ct_eq`. A scan can be evaded by a determined author; it catches the accidental case. |

`Cargo.lock` is committed; `rust-toolchain.toml` pins the toolchain;
`[workspace.lints]` carries the lint table every member inherits.

## Observability contract

Metrics and spans are named by three enums in `crates/app/src/telemetry.rs`
(`Counter`, `Gauge`, `SpanName`); `Telemetry` takes those, never a string, so a
name that is not declared does not compile. `observability/*.yaml` is compared
with that table in both directions: name, type and label keys
(`tests/observability_contract.rs`).

## HTTP surface, auth and limits

`GET /healthz`, `GET /metrics`, `GET /balance` are open. `POST /deposit` and
`POST /withdraw` (`id=<id>&units=<n>`) need `Authorization: Bearer <token>`.

* The token comes from `SVC_AUTH_TOKEN`. The service REFUSES TO START without
  it or with fewer than 16 bytes; there is no default.
* A non-loopback `SVC_LISTEN_ADDR` is refused unless `SVC_ALLOW_NON_LOOPBACK=1`.
* This is NOT transport security: there is no TLS and the reads are
  unauthenticated. Put a TLS-terminating proxy in front before exposing it.
* One id sent twice with the same content is a replay (200, `duplicate`); the
  same id with a different kind or amount is a conflict (409).
* Requests have a deadline fixed at accept (head 2 s, whole request 10 s,
  both configurable); expiry answers 408. A flood of stalled connections evicts
  its own oldest members instead of starving `/healthz`.
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
refused), in-flight requests drain for up to the grace period, and the exit
code is 0 when drained, 3 when requests were abandoned, 1 on a startup error.

## Limits of this example

* State is process memory; a restart starts empty.
* The applied-id set is never pruned (retention is unbounded here); a real
  store keeps ids for a bounded idempotency window or in a unique index.
* `make verify` equals `make check-fast` today. cargo-deny, coverage and
  mutation testing are a later change.
* The release profile keeps `panic = "unwind"`: a panicking connection thread
  frees its slots and the process keeps serving (see `Cargo.toml`).
