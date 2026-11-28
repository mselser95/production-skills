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
| the compiler, on a target with no `std` | `tests/architecture.rs` itself runs `cargo rustc --lib --all-features --target thumbv7em-none-eabi --profile check -- -F unsafe_code` on `domain` and on `app` (no `make`, no variable a Makefile owns). On that target any `std` item, and `extern crate std` in ANY spelling (`r#std` too), is error E0463; the test fails (never skips) if the target is not installed. `-F unsafe_code` is a forbid on the rustc command line: no attribute (`#![allow(unsafe_code)]` is E0453) and no `[lints]` table can lower it, so the unsafe ban does not rest on `Cargo.toml` or `lib.rs` text; the same flag is applied to `adapter`, `platform` and `svc`. `make check-nostd` runs the same compile as a convenience; nothing rests on the Makefile. The architecture test is the gate for edits to sources, manifests and cargo configuration; an edit that changes or deletes the test files or the Makefile is OUT OF SCOPE of any in-tree test and only review can catch it (this module ships no workflow and no CODEOWNERS; required review on `tests/architecture.rs`, `tests/hardening.rs` and `Makefile` is the recommended control, and it is not shipped). It builds only what is NOT conditionally compiled, which is why the next three rows exist. |
| the compiler, through Cargo | A zone names only the crates its `Cargo.toml` lists, so `app` cannot name `adapter`, and `adapter` and `platform` cannot see each other. |
| a test, L1: which files exist | `tests/architecture.rs` runs `cargo check --workspace --lib --message-format=json` ONCE (the host build, with the same feature unification as `make check-fast`), takes each pure crate's output file from the compiler's own artifact message, reads the dep-info rustc wrote beside it (every source file it read, `#[path]` modules and `include!`d files included) and requires every one to be inside that crate's `src/`. | Alone this guards ownership (a pure crate's code lives in its own `src/`), not purity: the gate compiles those files anyway.
| a test, L2: no conditional compilation | every file L1 lists is REFUSED (not parsed) if it contains the word `cfg` anywhere, comments included, unless the whole line is exactly `#[cfg(test)]`; also `include!`, `include_str!`, `include_bytes!` and `#[path = ...]`. Without proc macros and build scripts (both refused) `macro_rules!` cannot synthesise the identifier `cfg`, so a source with no such token has no conditional compilation; `#[cfg(test)]` code exists only in test builds. | Alone this guards the one thing the gate cannot see: `std` behind a `cfg` that is false on the bare-metal target.
| a test, L3: no features | `cargo metadata`: `domain` and `app` declare an empty `features` map and no optional dependency; no package enables a feature on them or sets `default-features = false`; the host build enabled none on them. | Defence in depth: the gate builds with `--all-features`, so L3 alone adds nothing the gate does not already refuse.
| a test | the exact dependency lists (add `platform` to `domain` and it is RED); `domain` and `app` have only `lib`/`test` targets (no build script, no proc-macro); the release profile keeps overflow checks and unwinding. Fixtures: one attack each on a copy of `domain` (the lints table commented out plus `unsafe`; `#![allow(unsafe_code)]`; `extern crate r#std`; `std` behind a declared feature; `std` behind a `cfg`; a multi-line `#[path]`; `[lib] path` outside `src/`) must turn exactly the layer that owns it RED, with a clean control. The Makefile text is no longer pinned: nothing rests on it. |
| a source scan (weaker) | an early message that `domain`/`app` name no `std::` item outside their `#[cfg(test)]` tail; only `crates/platform/src/config.rs` reads the environment; the token is compared through `ct_eq`. |
| the compiler gate itself, three layers | (1) `no_cargo_configuration_sits_in_or_above_the_module` REFUSES any `.cargo/config.toml` or `.cargo/config` in the module tree (`target/` and `.git` skipped) and in every directory above it up to the repository root (the nearest directory with a `.git`), and every toolchain file but one: the only accepted is `rust-toolchain.toml` at the module root, whose every non-comment line must be `[toolchain]`, an element line of an open array, or a `channel`/`components`/`targets`/`profile` line (a bare line, another table or key is refused, never skipped) and whose `channel` is required and must be `stable`/`beta`/`nightly` (optionally `-YYYY-MM-DD`) or a version `N.N[.N]`, so no path (strings may be double-quoted or TOML literal single-quoted, and `[ toolchain ]` with inner spaces is the same header; the grammar REFUSES what rustup would accept: a host triple suffix such as `1.99.0-x86_64-apple-darwin` or `stable-aarch64-apple-darwin`, a prerelease tag such as `1.99.1-beta.2`, and a UTF-8 BOM, so a file with any of them must be rewritten as a plain channel); a legacy `rust-toolchain` file, and a `rust-toolchain.toml` in a subdirectory of the module or in a directory above it up to the repository root, are refused by presence. So the gate requires NO cargo config between the module and the repository root; `$CARGO_HOME` is the user's own machine and is out of scope. (2) The nested cargo runs with a scrubbed environment (`RUSTC_WRAPPER`, `RUSTC_WORKSPACE_WRAPPER`, `RUSTC`, `RUSTDOC`, `RUSTFLAGS`, `CARGO_ENCODED_RUSTFLAGS`, `CARGO_BUILD_RUSTFLAGS`/`_RUSTC`/`_RUSTC_WRAPPER`/`_RUSTC_WORKSPACE_WRAPPER` and every `CARGO_TARGET_*_{RUSTFLAGS,LINKER,RUNNER}` removed), an empty `CARGO_ENCODED_RUSTFLAGS` (measured: then no `build.rustflags` or `target.*.rustflags` key from any file is read; `--config 'build.rustflags=[]'` is accepted but removes nothing, lists are concatenated), `RUSTC` set to the absolute `rustc` found on PATH, and `--config 'build.rustc-wrapper=""'` and `--config 'build.rustc-workspace-wrapper=""'` (accepted, and they beat any config file). A config `[env]` table does not set cargo's own wrapper and cargo refuses `RUSTUP_TOOLCHAIN` there. (3) Before any green compile is trusted, three probe crates (`unsafe` on the host and on the no-std target, `extern crate std` on the no-std target) are compiled the same way, from inside the module, and must FAIL with the unsafe lint / E0463; otherwise the test fails with "the compiler gate is not armed". Fixtures (`the_compiler_gate_is_armed_and_no_cargo_configuration_can_lower_it`) place the wrapper attack in the module root, in a parent directory and in the environment; layer 3 is pinned by a case with layer 2 switched off. | What is proven is the list above (attributes, manifests' `[lints]`, in-tree and parent cargo config, the listed environment variables), not "nothing can override". Not covered: `$CARGO_HOME/config.toml`, a custom `RUSTUP_TOOLCHAIN`, a replaced `cargo` or `rustc` binary on PATH, and any edit to the test files or the Makefile. |

Not enforced: the purity of `adapter`, `platform` and `main` (they are the I/O
zones); test-only code (`#[cfg(test)]` may use `std` and files); the
environment of the person running `make` (it does not matter to the zone
checks: the test runs its own compile); the host build is the DEFAULT target, so
code that exists only on another operating system is not read (L2 refuses the
`cfg` that would select it). CI images need the `thumbv7em-none-eabi`
rust-std component: `rustup target add` or the toolchain file's `targets`.

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
  registry is full a newcomer evicts the OLDEST connection still reading its
  head (closed with no reply, `svc_http_head_evictions_total` counts it). A
  flood of reconnecting clients that send one byte therefore cannot keep
  normal one-packet requests out (`tests/hardening.rs` holds 60 stalled
  1-byte heads open, then 20 times connects a good client, lets ONE newer
  stalled head arrive while the table is full, and requires the good client to
  be answered: a property of who is evicted, with no throughput floor and no
  clock); every stalled connection is closed by the head deadline
  (`tests/http_limits.rs`). Policies that rank by progress ("fewest bytes first") were
  measured and starve normal clients (4/200 and 6/200 answered under 96
  flooders), because a flooder that has sent one byte outranks every newcomer.
  KNOWN COST: a legitimately slow head can be evicted when the table is full
  (at R new connections per second, a head older than about 48/R seconds). An
  alert on the counter is the signal.
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

The gate is green with the default target directory (`target/` in the module) and with `CARGO_TARGET_DIR` set elsewhere: the architecture fixtures live under the OS temp directory (`TMPDIR` honoured), never inside the module, and the pure test `the_parent_walks_stop_at_the_ceiling` pins that the configuration and toolchain walks never climb past the repository root (or the module itself, when that is the ceiling).

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
* No CI is generated by this module: the zone-purity compile (a test in
  `tests/architecture.rs`) runs in `make check-fast` locally, but nothing in a generated repository runs
  it on a pull request until the repository's workflow calls `make check-fast`.
* `tests/hardening.rs` asserts that `tests/architecture.rs` exists and defines the
  gate tests `production.yaml` cites. That raises the cost of dropping the gate from
  deleting one file to editing two; it is not a proof (an edit that touches both, or
  the Makefile, is outside any in-tree test, so review of those files is the control).
* Trust model: the architecture gate guards against MISTAKES and casual shortcuts:
  code, manifest, cargo-configuration and toolchain-file edits that would let I/O or
  `unsafe` into the pure crates. It is NOT a defence against a contributor who sets out
  to defeat it: anyone who can add a compiler, or edit the tests or the Makefile, can
  get a green run. Only review (required reviewers on `tests/`, `Makefile`,
  `rust-toolchain.toml`, `.cargo/`) and a CI that builds with a toolchain the repository
  does not control can stop that; this module ships neither. What the tests refuse: the
  manifest and source allow-lists, cargo configuration in or above the module, the
  toolchain-file allow-list above, the nested compile's scrubbed environment, and a
  probe that must fail to compile `unsafe`/`std`.
* `make verify` equals `make check-fast` today. cargo-deny, coverage and
  mutation testing are a later change.
* The release profile keeps `panic = "unwind"`: a panicking connection thread
  frees its slots and the process keeps serving (see `Cargo.toml`).
