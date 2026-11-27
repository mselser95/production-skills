# <SERVICE>

A small Rust service that carries the framework's architecture: a units
ledger in four zones with an enforced dependency direction, an observability
contract checked in both directions, and a graceful-shutdown composition root.
Repository: `<OWNER>/<SERVICE>`.

## Zones

```
adapter -> app -> domain        platform -> app -> domain
```

| zone | holds | may import |
|---|---|---|
| `src/domain` | pure ledger rules: integer minor units, checked arithmetic, idempotent apply | std collections/fmt/error/cmp only; no I/O, clock, randomness, async, floats |
| `src/app` | use-cases (`Ledger`) over ports (`EventStore`, `Clock`, `IdGenerator`, `Telemetry`, `MetricsSource`) | `domain`, std sync |
| `src/adapter` | HTTP in (`std::net`), in-memory store out | `app`, `domain`, std |
| `src/platform` | system clock, ids, config (the one env reader), recorder, signals | `app`, std, `ctrlc` |
| `src/main.rs` | composition root: wires ports to adapters | everything |

`tests/architecture.rs` enforces the direction by parsing `use` trees and
scanning for banned tokens. A crate split is the upgrade path when a zone
outgrows a module.

## Observability contract

`observability/emitted-metrics.yaml` and `observability/spans.yaml` list every
signal. `tests/observability_contract.rs` fails when code emits a name the
manifest lacks, or the manifest lists one the code never emits.

## Run

```
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --check
SVC_LISTEN_ADDR=127.0.0.1:8080 cargo run --locked
curl -d 'id=a1&units=100' localhost:8080/deposit
curl localhost:8080/balance ; curl localhost:8080/metrics
```

Environment (read only in `src/platform/config.rs`): `SVC_LISTEN_ADDR`
(default `127.0.0.1:8080`), `SVC_TRACING` (`off` | `log`),
`SVC_SHUTDOWN_GRACE_MS` (default 5000).

The toolchain is pinned in `rust-toolchain.toml`; `Cargo.lock` is committed.
