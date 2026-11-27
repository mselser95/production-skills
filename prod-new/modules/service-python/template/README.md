# <SERVICE>

A Python service born at the production-verifiability standard. `<OWNER>`, `<SERVICE>` and
`<PACKAGE>` are slots `prod-new` substitutes at scaffold time; everything else is real,
working code.

## Names

| slot | value | example |
|---|---|---|
| `<SERVICE>` | distribution and CLI name, lowercase kebab-case | `order-book` |
| `<PACKAGE>` | import package: `<SERVICE>` with `-` turned into `_` (lowercase identifier, up to 20 characters keeps `ruff format` stable) | `order_book` |

## The example domain

An append-only **units ledger**: deposit and withdraw, event-sourced, idempotent by event
id. Money is integer minor units; amounts parse from strings with an explicit rounding mode
(half-even by default); floats never appear. Replace the domain with your own and keep the
zones.

## Zones

```
src/<PACKAGE>/domain      pure decisions: stdlib allowlist only (dataclasses, decimal, enum,
                          re, typing, ...); no I/O, no clock, no randomness, no asyncio
src/<PACKAGE>/app         use-cases over ports (typing.Protocol) declared in app/ports.py
src/<PACKAGE>/adapters    inbound/ (HTTP, stdlib) and outbound/ (in-memory event store)
src/<PACKAGE>/platform    clock, ids, config (the ONLY reader of os.environ), observability
src/<PACKAGE>/__main__.py composition root: wires ports to adapters, shuts down on SIGTERM
```

Dependency direction, enforced by `tests/architecture/test_boundaries.py` (it reads the
sources with `ast`; it fails on a forbidden import, a float in domain or app, or an
environment read outside `platform/config.py`):

- `domain` imports only an allowlist of pure standard-library modules and itself
- `app` never imports `adapters` or `platform`
- `adapters.inbound` never imports `adapters.outbound`; `adapters.outbound` never imports
  `app` or `adapters.inbound`
- `platform` never imports `app` or `adapters`

## Observability contract

`observability/emitted-metrics.yaml` and `observability/spans.yaml` are the source of truth.
`tests/contract/test_observability_contract.py` compares them with the `counter`, `gauge`
and `span` calls in `src/` (signal names and label keys must be string literals) and with a
real `/metrics` scrape, in both directions. Signals go through the `Recorder` protocol;
spans are not exported yet (exporter wiring is a later step).

## Run

```
uv sync --locked
uv run pytest
SVC_API_TOKEN=<at least 16 characters> uv run <SERVICE>
```

Configuration: `SVC_API_TOKEN` (required), `SVC_HOST` (default `127.0.0.1`), `SVC_PORT`
(default `8080`), `SVC_REVISION`. Routes: `GET /healthz`, `GET /metrics`, `GET /v1/balance`,
`POST /v1/deposits` and `POST /v1/withdrawals` (bearer token; body
`{"amount": "12.34", "event_id": "optional-idempotency-key"}`, amount as a string).

## Checks that run today

```
uv run pytest                       # strict config: warnings are errors, strict markers
uv run ruff check && uv run ruff format --check
uv run mypy                         # --strict, from pyproject.toml
HYPOTHESIS_PROFILE=ci uv run pytest # derandomised property tests
```

Gates, CI and the Makefile fragment are a later step.
