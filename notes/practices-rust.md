# Rust backend practices as CI-checkable gates (researched 2026-11-27)

Format: PRACTICE -> why -> gate (command/flag/key) -> source [S#]. Quotes <=25 words. Sources listed at the end with dates ("no date shown" where the page shows none).
Labels: [P] primary (rust-lang.org, doc.rust-lang.org, tool's own docs/README), [N] non-primary, [K] my own knowledge, NOT confirmed by a fetched page.
Caveat: pages were read through a summarising fetcher; quotes are as returned. Re-check any quote you will cite externally.

## 1. Toolchain and build

1.1 Pin the toolchain, track current stable. Why: Rust supports only the newest stable. Gate: `rust-toolchain.toml` (channel = exact version) present and equal to a CI-declared value; CI job `rustup show`.
- Newest stable today: 1.100.0, 2026-11-12; previous 1.99.1 (2026-10-15), 1.99.0 (2026-10-01), 1.98.0 (2026-08-20) [S1][S2]. Cadence about six weeks (my inference from dates; page states no cadence).
- Support: "The Rust project only provides support and security updates for the most recent stable release." [S3] -> a stale pin is a security finding; gate = pin age <= N releases (script compares to blog releases feed).
- [K] `rust-toolchain.toml` file format; not fetched.
1.2 MSRV declared and enforced. Why: dependency bumps silently raise the floor. Gate: `[workspace.package] rust-version = "x.y"`; CI `cargo hack check --rust-version --workspace` [S12]; optional `cargo msrv verify` (cargo-msrv named by the Cargo book [S4]).
- Quote: "When your package is compiled on an unsupported toolchain, Cargo will report that as an error to the user." [S4]
- Resolver 3 (default for edition 2024, needs Rust 1.84+) changes `resolver.incompatible-rust-versions` from `allow` to `fallback` [S5]. Clippy reads `rust-version` as `msrv` [S6].
1.3 Cargo.lock committed; `--locked` everywhere in CI. Why: reproducible, auditable resolution. Gate: `cargo build|test|clippy --locked`; `--frozen` = `--locked --offline` [S7]. Quote: "It may be used in environments where deterministic builds are desired, such as in CI pipelines." [S7]. ANSSI rule DENV-CARGO-LOCK "Track Cargo.lock in version control system" [S8].
1.4 Workspace hygiene. Gate: root `[workspace.dependencies]` (members use `dep = { workspace = true }`) and `[workspace.lints]` + `[lints] workspace = true` in every member (requires Rust 1.74) [S9]. A CI script asserts every member has `[lints] workspace = true`. `resolver = "3"` must be explicit in virtual workspaces [S9].
1.5 Cargo lints for manifests. New in 1.100: `[lints.cargo] unused_dependencies = "deny"` [S10]. Caveats from the page: dev-dependencies are unchecked; false positives when a transitive dep activates a feature [S10].
1.6 Profiles that matter (defaults from [S11]): `overflow-checks` is `false` in release (dev true); `panic = "unwind"` default; `lto = false`; `strip = "none"`; release `debug = false`.
- Gate: grep `[profile.release]` for explicit `overflow-checks = true` (money/risk code) and an explicit `panic` value. ANSSI DENV-CARGO-OPTS: "Keep default values for critical variables in cargo profiles" [S8] conflicts with enabling overflow-checks; decide per service and record it.
- `lto = "fat"` / `codegen-units = 1` / `strip = "symbols"` for size/speed: effect [S11] documented; gate is "profile present", not a lint.
1.7 Reproducible builds. `--remap-path-prefix` via `RUSTFLAGS`/`build.rustflags` [S13, K]. `trim-paths` profile key is STILL UNSTABLE: "-Z trim-paths" tracking issue #12137 [S14]; so use `--remap-path-prefix` today. Gate: build twice in two directories, compare sha256 (`cargo build --release --locked` twice).
- Note: 1.100 changed the build-dir layout; "tools should use Cargo's JSON messages to find artifacts" (release notes summary) [S2]. Fix any script that globs `target/`.
- Incremental is off by default when `CI` is set (config page) [S15].
1.8 Feature hygiene. Gate: `cargo hack check --feature-powerset --no-dev-deps` (optionally `--depth 2`, `--exclude-features`) [S12]. Quote: `--feature-powerset`: "Perform for the feature powerset which includes `--no-default-features` and default features of the package." [S12]
1.9 Warnings as errors. Since Cargo 1.97: `CARGO_BUILD_WARNINGS=deny cargo clippy` or `[build] warnings = "deny"`; the old `-- -Dwarnings` "will invalidate build caches and is therefore not recommended" [S6][S15]. Pitfall: a new compiler adds warnings and breaks a pinned-CI build; only deny on the pinned toolchain.

## 2. Dependencies and supply chain
2.1 cargo-deny as the policy gate: `cargo deny check` over advisories, bans, licenses, sources [S16]. Keys:
- advisories: `yanked` default `warn` (set `"deny"`); `unmaintained`, `unsound` default `"workspace"` (only direct workspace deps fail); `ignore` empty [S17]. Set `unmaintained = "all"` to cover transitive.
- bans: `multiple-versions`, `wildcards`, `deny`, `skip`/`skip-tree`, `workspace-default-features` / `external-default-features` [S18]. Set `multiple-versions = "deny"` with explicit `skip`s.
- licenses: allow list; "all licenses are denied unless explicitly allowed" (v2); `confidence-threshold` default 0.8 [S19].
- sources: `unknown-registry`, `unknown-git` default `warn`; set `"deny"`; `allow-registry` defaults to crates.io index [S20].
2.2 cargo-audit (RustSec) vs cargo-deny: both read the RustSec DB [S21][S22]. cargo-deny covers licenses/bans/sources; cargo-audit's unique value is `cargo audit bin <paths>` scanning built binaries (full accuracy only if built with `cargo auditable`) [S21]. Use both: deny on the lockfile, audit on the release artifact. Safety note: `cargo audit` on an untrusted tree runs `cargo update --workspace` if no lockfile; use `--file` [S21]. `cargo audit fix` is experimental [S21].
2.3 cargo-auditable: embeds dependency JSON in linker section `.dep-v0`, "under 4kB even on large dependency trees" [S23]. Gate: `cargo auditable build --release --locked` then `cargo audit bin target/release/<bin>`; scanners that read it: cargo-audit 0.17.3+, Trivy 0.31.0+, Grype 0.83.0+, Syft 1.15.0+ [S23].
2.4 cargo-vet (Mozilla): audits-by-trusted-entities; CI line `cargo vet --locked` [S24][S25]; exemptions "can be ratcheted down over time" [S24]. Heavy to adopt; gate = exemptions count must not grow (script diffing `supply-chain/config.toml`) [K].
2.5 crates.io Trusted Publishing: announced July 2025 (RFC 3691) [S26]; Jan 2026 added GitLab.com and blocked `pull_request_target` and `workflow_run` triggers; "Trusted Publishing Only Mode" disables token publishing [S27]. Gate (published crates only): repo has no `CARGO_REGISTRY_TOKEN` secret; publish workflow uses OIDC.
2.6 Dependency cooldown (new, 1.100): `[registry] global-min-publish-age = "7 days"`, `[resolver] incompatible-publish-age = "deny"` (default `deny`; min age default `"0"`); "Respected as of 1.100+" [S28]. Only affects resolution, not `cargo install` [S2]. Gate: set the age in `.cargo/config.toml`; assert it.
2.7 Build scripts and proc-macros run arbitrary code at build time (note: profile `panic` setting is ignored for them [S11]). Mitigations: cargo-vet/deny `bans`, build in sandbox without secrets, vendor + review. I found no primary-source gate that sandboxes build.rs [K]; see section 12.
2.8 SBOM: `cargo cyclonedx` (CycloneDX project tool; output format/spec version not stated on README) [S29]. Cargo's own `-Z sbom` is unstable [S14]; cargo-auditable README recommends `CARGO_BUILD_SBOM=true cargo +nightly auditable build -Z sbom` for better accuracy [S23]. Gate: SBOM file produced and attached to the release.
2.9 Unused deps: stable `[lints.cargo] unused_dependencies` (1.100) [S10]; `cargo machete` is "fast (yet imprecise)", exit 0/1/2 usable in CI, `--with-metadata` may modify Cargo.lock [S30]; `cargo +nightly udeps` needs nightly, "Some unused crates might not be detected" [S31]. Prefer the built-in lint now; keep machete as a cheap extra.
2.10 Provenance: GitHub artifact attestations (`actions/attest@v4`, `gh attestation verify <artifact> -R org/repo`) [S32]; SLSA Build L2 needs provenance signed and tied to hosted infrastructure; L3 needs isolated runs and secret-protected signing keys [S33]. Whether GitHub attestations meet L2 or L3 is not stated on the page I fetched: see UNVERIFIED.
2.11 OpenSSF Scorecard checks to adopt as a gate: Vulnerabilities, Dependency Update Tool, Pinned Dependencies, Token Permissions, Signed Releases, SAST, Fuzzing, Dangerous Workflow, Branch Protection [S34].

## 3. Static analysis and lints
3.1 Clippy groups: `correctness` is the only deny-by-default group; `style` warn; `pedantic` and `restriction` allow-by-default; "You shouldn't enable the whole lint group, but cherry-pick lints from this group." [S6][S35]. Levels for suspicious/complexity/perf not stated on fetched pages [K: warn].
3.2 Configure in manifest (Rust 1.74+): `[lints.clippy]` with `priority`; lower priority gets overridden by higher [S36]. Suggested deny set for services (all [K] except those listed verified): `unwrap_used`, `expect_used`, `panic`, `indexing_slicing`, `arithmetic_side_effects` (restriction, allow by default [S37]), `as_conversions` (restriction [S37]), `await_holding_lock` and `await_holding_refcell_ref` (suspicious, warn [S37]), `dbg_macro`, `todo`, `undocumented_unsafe_blocks`, `mem_forget`, `let_underscore_future`, `large_futures`. `cast_possible_truncation` is pedantic [S37]. I could not fetch group/description for the unlisted ones (page truncated); verify with `cargo clippy -- -W clippy::<lint>` in a probe.
3.3 `clippy.toml`: `allow-unwrap-in-tests`, `allow-expect-in-tests`, `allow-indexing-slicing-in-tests` all default `false`; `disallowed-methods` / `disallowed-types` take `path`, `reason`, `replacement`; `await-holding-invalid-types`; `arithmetic-side-effects-allowed`; `msrv` defaults to `rust-version` [S38]. `disallowed-methods` is the generic hook to ban `std::env::var`, `std::thread::sleep` in async, `SystemTime::now` (determinism) [K for examples].
3.4 Gate: `cargo clippy --workspace --all-targets --all-features --locked` with `CARGO_BUILD_WARNINGS=deny` [S6]. Use `--no-deps` to lint only your crate [S6].
3.5 Unsafe lints: `#![forbid(unsafe_code)]` (cannot be overridden by an inner `allow`, [K]) vs `deny`; workspace form `[workspace.lints.rust] unsafe_code = "forbid"` [S9]. `unsafe_op_in_unsafe_fn`: warns by default in edition 2024; "detects calls to unsafe operations in unsafe functions without an explicit unsafe block" [S39]. Deny it.
3.6 rustc lints worth enabling (allow-by-default [S40]): `unreachable_pub`, `missing_docs`, `missing_debug_implementations`, `let_underscore_drop`, `trivial_casts`, `unsafe_code`; `unused_crate_dependencies` and `unused_results` [K, descriptions not in fetched text]. `-D warnings` pitfalls: new compiler versions add lints; deny only on the pinned toolchain; `rustc -W help` lists exact levels for your compiler [S41].
3.7 Groups: `future-incompatible` and `rust-2024-compatibility` exist as groups [S41]; deny `future-incompatible` in CI to catch hard errors early.
3.8 rustfmt: `cargo fmt --all --check` [K]; ANSSI DENV-FORMAT [S8].
3.9 rustdoc: lints `broken_intra_doc_links`, `private_intra_doc_links`, `bare_urls` warn by default; `missing_crate_level_docs` allowed by default [S42]. Gate: `RUSTDOCFLAGS="-D warnings" cargo doc --no-deps --locked` [K for env var form; page did not show it]; doctests: `cargo test --doc`.
3.10 Semver for published crates: `cargo semver-checks`; does NOT catch all breaks (type changes, generics/lifetimes, feature-specific); relies on unstable rustdoc JSON [S43].
3.11 SAST/dataflow: CodeQL supports Rust editions 2021 and 2024 with models for axum, actix-web, reqwest, sqlx, tokio, rustls; stable toolchain only [S44]. GA status not stated. Semgrep: Rust "Generally available", "Cross-function dataflow analysis", "40+ Pro rules" (no cross-file) [S45]. Realistic yield: injection/SSRF/taint across functions; not logic or concurrency bugs [K].

## 4. unsafe and memory safety
4.1 Policy (recommended): `unsafe_code = "forbid"` at workspace level; a crate that needs unsafe is isolated (own crate), `#![deny(unsafe_op_in_unsafe_fn, clippy::undocumented_unsafe_blocks)]`, every block carries `// SAFETY:`. Core guarantee: "No matter what, Safe Rust clients can't cause Undefined Behavior." [S46]. ANSSI: LANG-UNSAFE "Don't use unsafe blocks", LANG-UNSAFE-ENCP, UNSAFE-NOUB [S8].
4.2 Gate for forbid: add a probe file with `unsafe {}` and expect compile failure [K, mutation proof].
4.3 Miri: detects out-of-bounds, use-after-free, uninitialised reads, misalignment, data races, leaks; "does not catch every violation of the Rust specification"; one execution per seed; FFI mostly unsupported [S47]. Gate: `rustup toolchain install nightly --component miri; cargo +nightly miri test`; `MIRIFLAGS="-Zmiri-strict-provenance -Zmiri-many-seeds=0..16"` (default 64 seeds is slow) [S47]. Run only on unsafe-bearing crates.
4.4 Sanitizers (nightly): address, thread, memory, leak (testing only) and CFI, SafeStack, ShadowCallStack (may be used in production) [S48]. Gate: `RUSTFLAGS=-Zsanitizer=address cargo +nightly build -Zbuild-std --target x86_64-unknown-linux-gnu` [S48]; "strongly recommended" to use `-Zbuild-std` [S48].
4.5 cargo-geiger: counts unsafe in crate and dependencies; "not meant to advise directly whether the code ultimately is truly insecure" [S49]. Latest release 0.14.0 on 2026-10-12 per crates.io API [S50]. Use as a ratchet (count must not rise), not a proof.
4.6 FFI (ANSSI): FFI-CTYPE, FFI-CK-PTR-VALID, FFI-NOENUM, FFI-NOPANIC "Handle panic! correctly in FFI", FFI-CAPI [S8]. 1.99.1 fixed a miscompilation of FFI `bool` returns on x86_64 [S2], so stay current.
4.7 Policy statements: CISA lists "development of new product lines ... in a memory-unsafe language" as a bad practice and asks for memory-safety roadmaps [S51]. Rust satisfies this only for the safe subset.

## 5. Testing
Status key: PROD = production-ready; EXP = experimental or caveated.
5.1 Runner: cargo-nextest (PROD). Retries via `.config/nextest.toml` `retries = { backoff = "fixed", count = 2, delay = "1s" }`; flaky tests "treated as ultimately successful" by default; `--flaky-result fail` / `NEXTEST_FLAKY_RESULT=fail` fails the run [S52]. Policy: CI sets `--flaky-result fail` for blocking lane, retries only in a quarantine lane. Partition: `--partition slice:m/n` or `hash:m/n`; `count:m/n` is deprecated [S53]. Doctests are not run by nextest [K]: run `cargo test --doc` separately.
5.2 Coverage: cargo-llvm-cov (PROD for lines/regions/functions): `cargo llvm-cov nextest --locked --fail-under-lines N --fail-under-regions N --fail-under-functions N --lcov --output-path lcov.info` [S54]. "Support for branch coverage is unstable." "Support for doc tests is unstable and has known issues." [S54]. cargo-tarpaulin: line coverage only; Linux default backend ptrace on x86_64; `--engine llvm` available; `--branch` "NOT IMPLEMENTED"; latest 0.37.6 on 2026-11-05 [S55][S56]. Prefer llvm-cov.
5.3 Property tests: proptest (PROD). Regression files under `proptest-regressions/` and "It is recommended to check these files in to your source control." [S57]. Gate: CI fails if the tree is dirty after tests (new regression file uncommitted); `PROPTEST_CASES` env var [K; page silent]. quickcheck: [K] smaller, no shrink persistence. bolero: "fuzz and property testing front-end", `cargo bolero test <name>` [S58] (maturity not stated).
5.4 Fuzzing: cargo-fuzz is "the recommended tool for fuzz testing Rust code", libFuzzer only [S59]. `cargo fuzz run <target>` [S60]. Time-boxed CI: `cargo +nightly fuzz run <t> -- -max_total_time=60` and corpus caching [K; not on fetched pages]. `arbitrary` crate for structured inputs [K]. Gate: every parser/decoder crate has a fuzz target that builds (`cargo fuzz build`), plus a corpus replay run.
5.5 Mutation: cargo-mutants (PROD). Default test timeout "5 times the baseline test time, with a minimum of 20 seconds"; `--timeout`, `--timeout-multiplier`, `--minimum-test-timeout`; with `--baseline=skip`/`--in-place` the default is 300 s [S61]. `--in-diff DIFF_FILE` tests only mutants overlapping changed regions [S62]. CI recipe: `cargo mutants -vV --in-place`, "This will fail if it finds any uncaught mutants."; annotations via `--annotations=github` [S63]. Config file `.cargo/mutants.toml` [K; keys not fetched]. Gate: `git diff origin/main... > pr.diff; cargo mutants --in-diff pr.diff --in-place`.
5.6 Snapshots: insta (PROD) [K]; CI flags (`cargo insta test --check`, `--unreferenced=reject`, `INSTA_UPDATE=no`) NOT confirmed from a page. Snapshots are change-detectors; do not count them as invariants.
5.7 Concurrency: loom (PROD for small primitives): exhaustive permutations under C11 model, but "does not implement the full C11 memory model", `SeqCst` treated as `AcqRel`, "not sound"; run `RUSTFLAGS="--cfg loom" cargo test --release` [S64]; 0.7.3 released 2026-11-08 [S50]. shuttle: randomized, "not sound" but "scales to much larger test cases than Loom"; wrappers for tokio and rand [S65].
5.8 Deterministic simulation: turmoil: "family of crates for deterministic simulation testing of distributed systems", seeded RNG fault injection, `turmoil-net` drop-in for `tokio::net`, `turmoil-fs` for fs [S66]; 0.7.2 on 2026-04-24 [S50]; maturity label not on page (EXP-to-PROD, my judgment). madsim: "Magical Deterministic Simulator", tokio-like runtime [S67]; latest crates.io 0.2.34 on 2025-10-11 [S50], about 13 months old, so treat as low-activity (seed var `MADSIM_TEST_SEED` not confirmed on the page).
5.9 Model checking: Kani "bit-precise model checker for Rust", `#[kani::proof]`, `kani::any()` [S68] (EXP for services; useful for small pure functions like fee/PnL math). Bounds/unwinding limits not on the fetched page [K].
5.10 Test runs must use `--locked`; snapshot, regression and corpus directories must be committed.

## 6. Async and concurrency (tokio)
6.1 Timeouts on every outbound call: `tokio::time::timeout`: "an error is returned and the future is canceled"; "Cancelling a timeout is done by dropping the future." [S69]. Gate: `clippy::disallowed_methods` banning bare `reqwest::Client::new` / building clients without a timeout [K]; lint cannot see "missing timeout" generically (see section 12).
6.2 Cancellation safety: dropping a future cancels it at the next `.await`; each `select!` branch must be cancel-safe (JoinSet `join_next` documented cancel safe) [S70]. No lint; covered by tests + shuttle/turmoil.
6.3 Bounded channels: "Once the buffer is full, attempts to send new messages will wait until a message is received from the channel." [S71]. Gate: `disallowed-methods = [{ path = "tokio::sync::mpsc::unbounded_channel" }]` [S38 for key; K for application].
6.4 Task lifetimes: `JoinSet`: "When the JoinSet is dropped, all tasks in the JoinSet are immediately aborted." [S70]. Ban fire-and-forget `tokio::spawn` without a tracked handle (convention; `disallowed-methods` for `tokio::spawn` forces a wrapper) [K].
6.5 Graceful shutdown: three parts (detect, tell, wait); `CancellationToken` + `TaskTracker` [S72]. Gate: integration test that sends SIGTERM and asserts in-flight request completes and exit code 0 [K].
6.6 Blocking in async: "issuing a blocking call or performing a lot of compute in a future without yielding is problematic"; `spawn_blocking` tasks "cannot be aborted" [S73]. Runtime defaults: worker threads = cores, `max_blocking_threads` 512, worker stack 2 MiB [S74]. Clippy has no general "blocking in async" lint [K]; use `disallowed-methods` on `std::fs::*`, `std::thread::sleep` and tokio-console (6.8) for detection.
6.7 Locks across `.await`: std Mutex held across await "virtually never leads to correct concurrent code in practice as it can easily lead to deadlocks"; std Mutex is "often preferred" when not held across await [S75]. Gate: `clippy::await_holding_lock` and `await_holding_refcell_ref` deny [S37]; `await-holding-invalid-types` for custom guard types [S38].
6.8 tokio-console needs `RUSTFLAGS="--cfg tokio_unstable"` [S76]; the page gives no production overhead guidance, so keep it dev/staging only (policy, not verified).

## 7. Errors and panics
7.1 Result discipline: "returning Result is a good default choice when you're defining a function that might fail." [S77]. `expect` OK with a documented impossible-Err reason, tests and prototypes [S77]. Gate: deny `unwrap_used`, `expect_used`, `panic`, `indexing_slicing` (3.2) with `allow-*-in-tests` (3.3); ANSSI LANG-LIMIT-PANIC, LANG-LIMIT-PANIC-SRC, LANG-ARRINDEXING [S8].
7.2 thiserror for typed library/domain errors, anyhow for application code: thiserror docs point to anyhow "for application code"; thiserror "deliberately does not appear in your public API" [S78]. ANSSI LANG-ERRWRAP: custom Error type wrapping all errors [S8].
7.3 Panic policy: default `panic = "unwind"` [S11]. `panic = "abort"` + supervisor restart is simplest for fail-fast; but it removes catch-at-task-boundary (tokio converts task panics into `JoinError` only under unwind) [K]. Choose one, record in ADR, gate by grepping `[profile.release] panic`. Note: tests, benches, build scripts and proc macros ignore the `panic` setting [S11].
7.4 Overflow: release builds wrap unless `overflow-checks = true` [S11]; "When overflow-checks are enabled, a panic will occur on overflow." [S11]. ANSSI LANG-ARITH [S8]. For money use checked/saturating ops or deny `arithmetic_side_effects` (section 9).
7.5 Never panic in `Drop`: ANSSI LANG-DROP-NO-PANIC [S8].

## 8. Security-relevant coding
8.1 Deserialization: `#[serde(deny_unknown_fields)]`: "Always error during deserialization when encountering unknown fields."; unsupported with `flatten` [S79]. Size limits are not a serde feature: cap the body at the HTTP layer (axum `DefaultBodyLimit`, tower-http `RequestBodyLimitLayer`) [K]. Gate: grep that every request DTO derives with `deny_unknown_fields` (script) and an integration test posting an oversize body.
8.2 SQL: sqlx `query!` is "Statically checked SQL"; bind parameters per backend ($N Postgres, ? MySQL/SQLite); CI: `cargo sqlx prepare --check` with no `DATABASE_URL` at compile time [S80]. Gate: `cargo sqlx prepare --workspace --check` plus a grep/semgrep rule banning `format!` into `sqlx::query(` [K for rule]. The page does not contrast with interpolation.
8.3 SSRF, path traversal: no Rust-specific primitive found in primary sources; gate via semgrep/CodeQL taint rules (3.11) and a URL-allowlist wrapper type [K].
8.4 TLS: rustls "implements TLS1.2 and TLS1.3"; default provider aws-lc-rs, `ring` via feature; `fips` feature for FIPS 140-3 via aws-lc-rs; "provides no unsafe features or obsolete cryptography by default" [S81]. Gate: `cargo deny` bans `openssl`/`native-tls` if policy says rustls only (`[bans] deny`) [S18]; `cargo tree -i openssl-sys` must be empty [K]. Do not roll custom crypto. RustCrypto vs ring status: not verified (see UNVERIFIED).
8.5 Constant-time compare: `subtle::ConstantTimeEq`, but "best-effort", "fundamentally limited", compiler may undo it, `debug_assert` branches mean release builds only [S82]. Gate: ban `==` on token/MAC types via a newtype without `PartialEq`.
8.6 Secrets: zeroize uses volatile writes; caveats: moves leave copies, stack spills, Vec/String reallocation copies, no protection from Spectre-class leaks [S83]. secrecy `SecretBox`: wipes on drop, `ExposeSecret` makes access "explicit and easy-to-audit" [S84]; `Debug` redaction not confirmed on the page. Gate: config structs holding secrets use `SecretString`; grep for `#[derive(Debug)]` on structs with fields named `*_key`, `*_secret`, `*_token`.
8.7 Randomness: use the OS CSPRNG (`getrandom`, `rand::rngs::OsRng`) [K; not fetched]. Gate: `disallowed-methods` for `rand::thread_rng` in key/nonce code paths is a policy choice.
8.8 Integer casts: ban `as` for narrowing: `as_conversions` (restriction) and `cast_possible_truncation` (pedantic) [S37]; use `TryFrom`.
8.9 Regex: "meant to be able to run regex searches on untrusted haystacks without fear of ReDoS"; worst case `O(m * n)` (`O(m * n^2)` iterating all matches); limit untrusted patterns via `RegexBuilder::size_limit` [S85]. Gate: ban `fancy-regex`/backtracking engines on untrusted input via cargo-deny `bans` (policy) [K].
8.10 Logging: no secrets/PII: type-level (SecretString, redacting Debug) + test that serialises a request context and asserts no secret substrings [K].

## 9. Money and numerics
- `rust_decimal`: 96-bit mantissa, "roughly 28 base-10 digits (29 in some cases)"; `serde-str` makes (de)serialisation use strings; `serde-float` sends JSON as float, which loses precision [S86]. Gate: Cargo feature `serde-str` (or `serde-with-str`) enabled; `disallowed-types` for `f32`/`f64` is not expressible (primitives), so use `clippy::float_arithmetic` deny [K lint exists; group not confirmed] in domain crates.
- Prefer integer minor units (i64/i128) with checked ops in the ledger core; `arithmetic_side_effects` deny flags unchecked `+ - *` [S37]. `checked_add`/overflow behaviour of rust_decimal: not confirmed on the page (it can panic on overflow in operators [K]; use `checked_*`).
- bigdecimal: not fetched.

## 10. Observability and operations
10.1 tracing: "framework for instrumenting Rust programs to collect structured, event-based diagnostic information"; `tracing-subscriber` registered early in `main` via `set_global_default` [S76b]. Gate: integration test asserts a span with request id exists; deny `println!` via `clippy::print_stdout` [K].
10.2 OpenTelemetry Rust status: Traces Beta, Metrics Stable, Logs Stable [S87]. Pin versions; expect API churn on traces.
10.3 Health/readiness: no Rust-specific standard; implement `/livez`, `/readyz`, assert in e2e [K].
10.4 Allocator: tikv-jemallocator exists ("successor of jemallocator") but I could not verify maintenance status from its page [S88]; alternative mimalloc [K]. Custom allocators (`Allocator` trait for `Vec`/`Box`) stabilised in 1.100 [S2]; the global allocator (`#[global_allocator]`) is old [K]. Gate: benchmark with and without under realistic load; no lint.
10.5 Containers: distroless `static-debian13` (~2 MiB), tags `latest`, `nonroot`, `debug`, `debug-nonroot` [S89]. Static musl binary + `static:nonroot` is the smallest; glibc dynamic needs `base` or `cc` images [K for mapping]. Gate: `docker inspect` user != root; `hadolint`/trivy image scan [K]. cargo-chef: `cargo chef prepare` then `cargo chef cook --release --recipe-path recipe.json` caches the dependency layer [S90].
10.6 Binary scanning: build with `cargo auditable`, scan image with Trivy/Grype (2.3).

## 11. Performance
- Criterion: wall-clock benchmarks are noisy on shared CI runners [K]. iai-callgrind: its repo now presents Gungraun as successor ("Gungraun and the predecessor Iai-Callgrind"), with a migration checklist [S91]; crates.io `iai-callgrind` last release 0.16.1 on 2025-07-30 [S50]. Prefer Gungraun for instruction-count gates (deterministic, needs Valgrind/Linux); the page does not describe regression-limit config, check its docs.
- cargo-pgo: wraps PGO and BOLT; "Support for BOLT and Docker is marked as experimental"; do not strip symbols when using BOLT; profiles reflect only the workloads run [S92]. Treat as an optimisation lane, not a gate.

## 12. Dimension map (your 27 dimensions)
| Dimension | Rust mechanism | Gate command |
|---|---|---|
| structural correctness/coverage | llvm-cov | `cargo llvm-cov nextest --locked --fail-under-lines N` |
| mutation testing | cargo-mutants | `cargo mutants --in-diff pr.diff --in-place` |
| invariants and property tests | proptest, bolero | `cargo nextest run`; regression dir clean |
| failure-mode scenarios | turmoil, fault-injection fakes, tests | `cargo nextest run -E 'test(scenario_)'` |
| integration/contract tests | testcontainers [K], nextest | `cargo nextest run --test '*'` |
| performance and capacity | Gungraun/criterion | bench job, compare baseline |
| resilience and recovery | timeouts, shutdown tests | disallowed-methods + SIGTERM test |
| observability | tracing, OTel | span-assert test; `clippy::print_stdout` |
| security | deny, audit, clippy, CodeQL/semgrep | `cargo deny check`; `cargo audit` |
| deployability | distroless, auditable | image scan + `cargo audit bin` |
| reproducibility | `--locked`, remap, pinned toolchain | double build + sha compare |
| scalability | benchmarks/load tools (not Rust-specific) | k6/oha job [K] |
| bounded auto-recovery | supervisor + panic policy | chaos/restart test |
| published contracts | OpenAPI/proto + semver-checks | `cargo semver-checks`; proto breaking check (buf) [K] |
| data lifecycle | sqlx migrations | `cargo sqlx prepare --check`; migrate-up test |
| wiring | integration test of composition root | e2e boot test |
| progressive delivery | platform (not Rust) | out of scope |
| SAST/dataflow | CodeQL, semgrep | CI action |
| schema evolution | sqlx migrate, serde defaults | migration up/down test |
| chaos | turmoil faults; external (toxiproxy) [K] | scenario job |
| consumer-driven contracts | pact-rust [K] | not verified |
| SLO/error budget | platform metrics | out of scope |
| dependency currency/pinning | deny, Dependabot/Renovate [K], cooldown, vet | `cargo deny check`; `cargo update --locked` diff |
| domain boundaries | crate graph + `cargo deny` bans, `pub(crate)` + `unreachable_pub` | `cargo tree`/`cargo deny check bans` |
| load/stress/soak | external tools | not in toolchain |
| overload/metastability | bounded channels, timeouts, load shedding (tower) [K] | load test |
| deterministic simulation | turmoil / madsim | `cargo nextest run` under sim |

No good off-the-shelf Rust mechanism (what people do instead):
- Blocking-in-async detection: no stable lint; use `disallowed-methods` lists plus tokio-console in staging.
- Missing-timeout detection: no lint; wrap clients in a crate that forces a timeout and ban the raw constructors.
- Cancellation-safety checking: no tool; tests with `select!` fault injection, shuttle/turmoil.
- Build-script/proc-macro sandboxing: none in Cargo; vet/deny, hermetic CI, vendoring.
- Branch coverage: llvm-cov flags it unstable, tarpaulin "NOT IMPLEMENTED"; use mutation testing instead.
- Consumer-driven contracts, SLO/error budget, load/soak, progressive delivery: ecosystem-agnostic tooling outside Cargo.
- Formal "no panics" proof: no stable tool; Clippy restriction lints approximate it; `no-panic` crate [K, unverified].

## 13. What changed recently (makes older advice wrong)
- 1.100.0 (2026-11-12): `[lints.cargo]` with `unused_dependencies` (cargo-udeps no longer needed for the common case); `min-publish-age` cooldowns; `cargo install` uses the bundled lockfile; build-dir layout changed; never type `!` stable; custom allocators stable; `aligned_fields_in_packed` deny-by-default lint [S2][S10][S28].
- 1.99.0: built-in `debug` profile in preparation for changing `dev`; incremental disabled by default in CI; Pin::new_unchecked invariants tweaked [S2]. 1.98.0: new deny-by-default `invalid_runtime_symbol_definitions` [S2].
- 1.97+: `build.warnings = "deny"` replaces `-- -Dwarnings` and `RUSTFLAGS=-D warnings` (which invalidate caches) [S6][S15].
- 1.84+/edition 2024: resolver 3 makes MSRV-aware resolution default [S5]; `unsafe_op_in_unsafe_fn` warns by default in 2024 [S39]; `rust-2024-compatibility` group lists `static-mut-refs`, `unsafe-attr-outside-unsafe`, `missing-unsafe-on-extern`, `if-let-rescope`, `tail-expr-drop-order` [S41]. [K] let chains stable since 1.88 (not verified by a fetched page; the edition-guide copy I fetched was an old 1.85 snapshot).
- Workspace lints (1.74) replace per-crate `#![deny(...)]` blocks and CI `-D` flags [S9][S36].
- iai-callgrind is succeeded by Gungraun [S91]; cargo-tarpaulin is no longer the only coverage option, and llvm-cov is preferred [S54][S55].
- cargo-deny `version = 2` config: "no longer used" fields error; licenses are deny-by-default [S17][S19].
- crates.io: trusted publishing (2025-07), GitLab and trigger blocks (2026-01) [S26][S27]; cargo-audit and cargo-deny now complemented by cooldowns.
- rustls default provider is aws-lc-rs, not ring [S81].

## UNVERIFIED (what I could not confirm from a primary source, and what I tried)
- Clippy group and description for `unwrap_used`, `expect_used`, `panic`, `indexing_slicing`, `dbg_macro`, `todo`, `undocumented_unsafe_blocks`, `float_arithmetic`, `let_underscore_future`, `large_futures`, `mem_forget`: lint index page was truncated at 100k of 618k characters; fetched arithmetic_side_effects, as_conversions, await_holding_*, cast_possible_truncation only. Default levels of suspicious/complexity/perf not stated on clippy lints page.
- `cargo fuzz` flags (`-max_total_time`), corpus handling, `cargo fuzz cmin`, nightly requirement: rust-fuzz book pages fetched did not contain them.
- cargo-mutants `.cargo/mutants.toml` keys, `--shard`, exit codes; insta CI flags; PROPTEST_CASES; `RUSTDOCFLAGS` form; `rust-toolchain.toml` format; `--remap-path-prefix` docs; cargo-msrv commands; cargo-hack `--rust-version` CI usage beyond README.
- Kani bounds/unwinding limits; Miri/sanitizer CI timings; loom preemption bound.
- rust-lang platform support/tier page (redirect, not read); rustc target tiers for musl/gnu.
- RustCrypto vs ring vs aws-lc-rs maturity; rustls maintenance policy; bigdecimal; subtle/zeroize alternatives; `getrandom`/`OsRng` docs; sqlx vs diesel comparison; diesel not fetched.
- ANSSI guide: only checklist titles confirmed (rule bodies not fetched); guide is labelled "unstable", no version/date on page.
- Trusted publishing docs page (crates.io/docs/trusted-publishing) returned no body; used rust-lang blog posts instead.
- NIST SSDF: fetched v1.1 (Feb 2022); no v1.2/Rev found on that page; did not search for a newer revision.
- SLSA level reached by GitHub attestations: page does not say.
- Maintenance state of cargo-deny, cargo-audit, cargo-vet, cargo-nextest, proptest, insta, cargo-hack (release dates not checked); tikv-jemallocator and cargo-pgo state only from README signals; madsim state inferred from crates.io date only; Gungraun crate release date not checked.
- OpenSSF/CNCF guidance on Rust-specific hardening flags (`-C relro-level`, `-C control-flow-guard`, stack protector): not researched.
- Whether Cargo's `-Z sbom` or `trim-paths` stabilised after the page snapshot: unstable.html content could be older than 1.100; one fetch said both unstable. Page date not shown.
- All quotes passed through a summarising fetcher; no raw HTML inspected.
- [N] sources: S50 (crates.io API, registry metadata, primary-ish), the Socket/Willison search hits (not used for claims).

## SOURCES (date shown on page, or "no date shown")
S1 https://blog.rust-lang.org/releases/ (lists 1.100.0 on 2026-11-12) | S2 https://raw.githubusercontent.com/rust-lang/rust/main/RELEASES.md and https://blog.rust-lang.org/2026/11/12/Rust-1.100.0/ (2026-11-12; RELEASES.md read only first 100k chars)
S3 https://www.rust-lang.org/policies/security (no date shown) | S4 https://doc.rust-lang.org/cargo/reference/rust-version.html (no date shown)
S5 https://doc.rust-lang.org/cargo/reference/resolver.html (no date shown) | S6 https://doc.rust-lang.org/clippy/usage.html (no date shown)
S7 https://doc.rust-lang.org/cargo/commands/cargo-build.html (no date shown) | S8 https://anssi-fr.github.io/rust-guide/checklist.html (no date shown; guide "unstable")
S9 https://doc.rust-lang.org/cargo/reference/workspaces.html (no date shown) | S10 https://doc.rust-lang.org/cargo/reference/lints.html (no date shown)
S11 https://doc.rust-lang.org/cargo/reference/profiles.html (no date shown) | S12 https://github.com/taiki-e/cargo-hack (no date shown)
S13 [K] rustc `--remap-path-prefix`: no page fetched | S14 https://doc.rust-lang.org/cargo/reference/unstable.html (no date shown)
S15 https://doc.rust-lang.org/cargo/reference/config.html (no date shown) | S16 https://embarkstudios.github.io/cargo-deny/ (no date shown)
S17 https://embarkstudios.github.io/cargo-deny/checks/advisories/cfg.html (no date shown) | S18 https://embarkstudios.github.io/cargo-deny/checks/bans/cfg.html (no date shown)
S19 https://embarkstudios.github.io/cargo-deny/checks/licenses/cfg.html (no date shown) | S20 https://embarkstudios.github.io/cargo-deny/checks/sources/cfg.html (no date shown)
S21 https://github.com/rustsec/rustsec/tree/main/cargo-audit (no date shown) | S22 https://rustsec.org/ (no date shown)
S23 https://github.com/rust-secure-code/cargo-auditable (no date shown) | S24 https://mozilla.github.io/cargo-vet/ (no date shown)
S25 https://mozilla.github.io/cargo-vet/configuring-ci.html (no date shown) | S26 https://blog.rust-lang.org/2025/07/11/crates-io-development-update-2025-07 (2025-07-11)
S27 https://blog.rust-lang.org/2026/01/21/crates-io-development-update (2026-01-21) | S28 https://doc.rust-lang.org/cargo/reference/config.html#registryglobal-min-publish-age (no date shown)
S29 https://github.com/CycloneDX/cyclonedx-rust-cargo (no date shown) | S30 https://github.com/bnjbvr/cargo-machete (no date shown)
S31 https://github.com/est31/cargo-udeps (no date shown) | S32 https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds (no date shown)
S33 https://slsa.dev/spec/v1.0/levels (no date shown) | S34 https://scorecard.dev/ (no date shown)
S35 https://doc.rust-lang.org/clippy/lints.html (no date shown) | S36 https://doc.rust-lang.org/cargo/reference/manifest.html#the-lints-section (no date shown)
S37 https://clippy.rust-lang.org/master/index.html (no date shown; first 100k chars only) | S38 https://doc.rust-lang.org/clippy/lint_configuration.html (no date shown)
S39 https://doc.rust-lang.org/edition-guide/rust-2024/unsafe-op-in-unsafe-fn.html (no date shown) | S40 https://doc.rust-lang.org/rustc/lints/listing/allowed-by-default.html (no date shown)
S41 https://doc.rust-lang.org/rustc/lints/groups.html (no date shown) | S42 https://doc.rust-lang.org/rustdoc/lints.html (no date shown)
S43 https://github.com/obi1kenobi/cargo-semver-checks (no date shown) | S44 https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/ (no date shown)
S45 https://docs.semgrep.dev/supported-languages (no date shown) | S46 https://doc.rust-lang.org/nomicon/safe-unsafe-meaning.html (no date shown)
S47 https://github.com/rust-lang/miri (no date shown) | S48 https://doc.rust-lang.org/beta/unstable-book/compiler-flags/sanitizer.html (no date shown)
S49 https://github.com/geiger-rs/cargo-geiger (no date shown) | S50 https://crates.io/api/v1/crates/{madsim,cargo-geiger,cargo-udeps,loom,turmoil,cargo-tarpaulin,iai-callgrind,cargo-machete} (updated_at fields, dates quoted inline)
S51 https://www.cisa.gov/resources-tools/resources/product-security-bad-practices (2025-01-17) | S52 https://nexte.st/docs/features/retries/ (no date shown)
S53 https://nexte.st/docs/ci-features/partitioning/ (no date shown) | S54 https://github.com/taiki-e/cargo-llvm-cov (no date shown)
S55 https://github.com/xd009642/tarpaulin (no date shown) | S56 crates.io API, see S50
S57 https://proptest-rs.github.io/proptest/proptest/failure-persistence.html (no date shown) | S58 https://github.com/camshaft/bolero (no date shown)
S59 https://rust-fuzz.github.io/book/cargo-fuzz.html (no date shown) | S60 https://rust-fuzz.github.io/book/cargo-fuzz/tutorial.html (no date shown)
S61 https://mutants.rs/timeouts.html (no date shown) | S62 https://mutants.rs/in-diff.html (no date shown)
S63 https://mutants.rs/ci.html (no date shown) | S64 https://github.com/tokio-rs/loom (no date shown)
S65 https://github.com/awslabs/shuttle (no date shown) | S66 https://github.com/tokio-rs/turmoil (no date shown)
S67 https://github.com/madsim-rs/madsim (no date shown) | S68 https://github.com/model-checking/kani (no date shown)
S69 https://docs.rs/tokio/latest/tokio/time/fn.timeout.html (no date shown) | S70 https://docs.rs/tokio/latest/tokio/task/struct.JoinSet.html (no date shown)
S71 https://docs.rs/tokio/latest/tokio/sync/mpsc/fn.channel.html (no date shown) | S72 https://tokio.rs/tokio/topics/shutdown (no date shown)
S73 https://docs.rs/tokio/latest/tokio/task/fn.spawn_blocking.html (no date shown) | S74 https://docs.rs/tokio/latest/tokio/runtime/struct.Builder.html (no date shown)
S75 https://docs.rs/tokio/latest/tokio/sync/struct.Mutex.html (no date shown) | S76 https://github.com/tokio-rs/console (no date shown); S76b https://tokio.rs/tokio/topics/tracing (no date shown)
S77 https://doc.rust-lang.org/book/ch09-03-to-panic-or-not-to-panic.html (no date shown) | S78 https://docs.rs/thiserror/latest/thiserror/ (no date shown)
S79 https://serde.rs/container-attrs.html (no date shown) | S80 https://docs.rs/sqlx/latest/sqlx/macro.query.html (no date shown)
S81 https://docs.rs/rustls/latest/rustls/ (no date shown) | S82 https://docs.rs/subtle/latest/subtle/ (no date shown)
S83 https://docs.rs/zeroize/latest/zeroize/ (no date shown) | S84 https://docs.rs/secrecy/latest/secrecy/ (no date shown)
S85 https://docs.rs/regex/latest/regex/ (no date shown) | S86 https://docs.rs/rust_decimal/latest/rust_decimal/ (no date shown)
S87 https://opentelemetry.io/docs/languages/rust/ (no date shown) | S88 https://github.com/tikv/jemallocator (no date shown)
S89 https://github.com/GoogleContainerTools/distroless (no date shown) | S90 https://github.com/LukeMathWalker/cargo-chef (no date shown)
S91 https://github.com/iai-callgrind/iai-callgrind (no date shown) | S92 https://github.com/Kobzol/cargo-pgo (no date shown)
Also read: NIST SP 800-218 v1.1 https://csrc.nist.gov/pubs/sp/800/218/final (2022-02-03); Rust edition guide index (stale 1.85 snapshot) https://doc.rust-lang.org/edition-guide/rust-2024/index.html.
