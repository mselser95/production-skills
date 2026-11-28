# <SERVICE>

A Python service born at the production-verifiability standard. `<OWNER>`, `<SERVICE>` and
`<PACKAGE>` are slots `prod-new` substitutes at scaffold time; everything else is real,
working code.

## Names

| slot | rule | example |
|---|---|---|
| `<SERVICE>` | distribution and CLI name: lowercase kebab-case `[a-z0-9]+(-[a-z0-9]+)*`, at most 40 characters (no dots, no underscores) | `order-book` |
| `<PACKAGE>` | import package: `<SERVICE>` with `-` turned into `_`; a lowercase identifier `[a-z_][a-z0-9_]*`, at most 40 characters | `order_book` |
| `<OWNER>` | GitHub user or organisation, at most 39 characters | `acme` |

The assembler enforces the charsets and lengths above (`module.json`) and refuses anything
else before writing a file. It cannot know the rest, so the scaffold's own tests
(`tests/unit/test_scaffold_name.py`) fail in the new repository when `<PACKAGE>` is a Python
keyword or soft keyword (`class`, `match`), shadows a standard-library module (`json`,
`logging`), is `tests`, or does not agree with the distribution name in `pyproject.toml`.
Pick another name; nothing else needs to change.

Why 40: `ruff format` wraps lines by length, and a long package name used to make a source
file fail `ruff format --check`. Every `from <PACKAGE>... import` here is written in the
parenthesised one-name-per-line form with a trailing comma, which the formatter never
re-wraps, so the same source is format-stable at every length; 40 is the longest length
verified (1, 2, 8, 20, 30 and 40 characters). Keep that import form in code you add.

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
src/<PACKAGE>/__main__.py composition root: wires ports to adapters, shuts down on SIGTERM, SIGINT or SIGHUP
```

Dependency direction, enforced by `tests/architecture/test_boundaries.py` (it reads the
sources with `ast`). What it enforces:

- `domain` and `app` each have an ALLOW-list of importable standard-library modules
  (`DOMAIN_ALLOWED`; `APP_ALLOWED` = that set plus `contextlib`, `datetime` as a type and
  `threading`), plus the project's own `domain` (and, for `app`, `app`) package. Any other
  import fails, naming file:line and the module: `import x`, `from x import y`, `import x.y`,
  relative imports, imports inside functions or under `TYPE_CHECKING`, and
  `import_module("x")` / `__import__("x")` (always refused);
- in `domain` and `app`, an attribute named `now`, `utcnow`, `today`, `time`, `monotonic`,
  `perf_counter`, `sleep` (and the `_ns` forms) on ANY expression fails unless the receiver is
  the injected clock port (`clock` / `_clock`), so `datetime.min.now()` is refused too;
- floats in `domain` and `app`: it catches the name `float`, a float literal, true division
  `/` and `/=`, and `**` with a non-literal exponent. It does NOT catch a float that arrives
  without being written (a function from an allowed module that returns one, a `__float__`
  method): the import allow-list is what keeps float-producing modules out;
- the process environment is read only in `platform/config.py`.

These boundary tests are a guard-rail against mistakes, not a sandbox: deliberate evasion
(`__float__`, `object.__getattribute__`, `int.__dict__`, rebinding a module to another name in
an adapter) is out of scope and is not claimed to be caught.

The zone direction rules:

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
SVC_API_TOKEN=<at least 32 characters> uv run <SERVICE>
```

Configuration: `SVC_API_TOKEN` (required: at least 32 characters, only `A-Z a-z 0-9 . _ ~ + / = -`;
anything shorter or with other characters, whitespace included, refuses to start with exit 2),
`SVC_HOST` (default `127.0.0.1`), `SVC_PORT` (default `8080`), `SVC_REVISION`. Routes: `GET /healthz`, `GET /metrics`, `GET /v1/balance`,
`POST /v1/deposits` and `POST /v1/withdrawals` (bearer token; body
`{"amount": "12.34", "event_id": "optional-idempotency-key"}`, amount as a string).

## The HTTP surface: what is bounded and what is not

The inbound adapter is stdlib `http.server`. It is **not hardened for the open internet**.

Bounded by the adapter (constants in `adapters/inbound/http_server.py`):

- a whole-request deadline of 10 s from accept to the last body byte, enforced on every read
  (a client trickling one byte at a time is cut at the deadline, answer 408);
- a head deadline of 2 s: a connection that has not delivered its request head is closed and
  its slot freed; connections are capped at 128 (threads never exceed it; extra connections
  get a fixed `503` with `Retry-After` on the accept thread) and requests past their head at
  64, so `GET /healthz` and `/metrics` stay served while slow clients hold the rest;
- a 4096-byte body cap (413), strict framing (one `Content-Length` of at most 10 digits, no
  `Transfer-Encoding`, no body on GET), at most one `Authorization` and one `Host` header
  (a duplicate is a 400 before auth), a 400 for a bare CR anywhere in the request head (the
  stdlib parser would split headers on it), a body that must be strict UTF-8 JSON (a BOM,
  UTF-16/32 or a lone surrogate is a 400), and an exception barrier: no request raises.

Shutdown: SIGTERM, SIGINT or SIGHUP (there is no config reload, so a hangup drains like a
term) closes the listener (new connections are refused), lets in-flight requests finish for
up to 10 s, then exits `0` if drained, `3` if requests were abandoned at the grace deadline
(`2` is a refused configuration). A second signal during the drain is ignored: it does not
shorten the 10 s.

NOT provided: TLS, per-client rate limits, per-client connection limits, slow-read
protection beyond a write timeout. A flood of
new stalled connections faster than 128 per 2 s can still occupy the head phase. Put a
reverse proxy / TLS terminator in front and have it enforce: TLS, client read and write
timeouts, a request-size limit, and connection and rate limits per client.

## Gates

Every target runs against the lock (the Makefile exports `UV_LOCKED=1`: a stale lock is an
error, never a re-resolve), needs only `uv`, stops at the first failure and prints one final
line `<target>: ok`. `check-fast` and `verify` are in `Makefile` (a scaffold test reads them
there); the rest is `unit.mk`. Times are measured on a laptop with a warm `uv` cache.

| target | what it runs | time | blocks merge |
|---|---|---|---|
| `check-fast` | `uv sync --locked`; `ruff check`; `ruff format --check`; `mypy --strict`; `pytest -q` (all lanes) | about 10 s | yes (CI job `check-fast`) |
| `verify` | `check-fast`; `lock-check`; `test-lanes-cover`; `audit`; `pytest -q` again under `HYPOTHESIS_PROFILE=ci` | about 30 s | yes (CI job `verify`) |
| `lint` / `typecheck` | `ruff check` + `ruff format --check` / `mypy` | under 1 s | via `check-fast` |
| `test` | `pytest -q` over `tests/` | about 7 s | via `check-fast` |
| `test-unit`, `test-contract`, `test-architecture` | one lane = one directory of `tests/` (`make test-architecture` for just the zone rules) | 7 s, 1 s, 1 s | via `check-fast` |
| `lock-check` | `uv lock --check`: `uv.lock` equals what `pyproject.toml` asks for | under 1 s | via `verify` |
| `audit` | `uv audit` over the locked set (needs the network) through `gates/audit.py`; fails closed when the advisory service is unreachable; a finding passes only with a dated line in `gates/audit-waivers.txt`; an expired, duplicate, malformed, over-180-days or stale (matching no finding) line fails | about 1 s | via `verify`; also nightly in CI |
| `test-lanes-cover` | the test ids collected over `tests/` equal the union of the lanes' (collection only) | about 1 s | via `verify` |
| `architecture` | alias of `test-architecture` (the Go template's name) | 1 s | via `check-fast` |
| `fmt` | `ruff format` and `ruff check --fix` (writes files) | n/a | no |

Run one lane: `make test-contract`, or any pytest selection: `uv run pytest tests/unit/test_money.py -q`.

CI: `.github/workflows/python-unit.yml`, the one copy (jobs `check-fast`, `verify`, and a
scheduled `nightly` that runs `make audit`). In the single layout the assembler places it at
the repository root's `.github/workflows/`, where it runs on pull requests and pushes with no
manual step (its path filters include the workflow file itself). GitHub runs a workflow only from
`.github/workflows` of the repository root, and a local `uses: ./.github/workflows/...` can only
reach that directory, so in a monorepo the same file lands at the ROOT's `.github/workflows/`
and the root's own caller uses it with `working-directory: services/<SERVICE>`; its filters
are relative to the repository root, so nothing of a service triggers it from there (the root
owns the prefixed filters, and drops or keeps the schedule). The concurrency group names the
unit, so two units calling it in one run never cancel each other. Actions are pinned by commit
SHA, `uv` by version AND wheel hash (`ci/uv-requirements.txt`, installed with
`pip install --require-hashes`: the hashes are PyPI's published sha256 for the 0.13.7 wheels of
Linux and macOS, x86_64 and arm64), every job has `timeout-minutes` and the same
`working-directory` default, the token is read-only, no secrets are used.

Target names against the sibling templates: `check-fast`, `verify` and `test` are the same in
Go; the Go template calls the architecture lane `architecture`, this one `test-architecture`, so
`make architecture` is an alias here and a monorepo root can delegate `$(MAKE) -C <unit>
architecture` for either language. `make -f <unit>/Makefile <target>` works from any directory.
`verify` also runs `test-lanes-cover`: the test ids `make test` collects must equal the union of
the lane targets', so a test file outside every lane cannot hide from them.

Decisions against the design row ("pyright strict, import-linter"):

- Type checker: `mypy --strict` stays, and it is the only one. Two checkers would disagree
  and double the maintenance; the code is written and tested against mypy.
- Zone direction: `tests/architecture/test_boundaries.py` already refuses a cross-zone import
  (an AST check, so it also sees aliased and function-local imports) and the domain's stdlib
  allowlist, and `make test-architecture` runs it alone. import-linter would be a second,
  weaker statement of the same contract (and a new dependency), so it is not added.

NOT gated yet, and not claimed anywhere: coverage threshold (coverage.py is not in the locked
set; add it with `uv lock` on a networked machine, one `fail_under` in `pyproject.toml`),
mutation testing, an advisory (candidate) test lane, a race / free-threading lane, SBOM and
provenance.

Test headers: every test carries `# provenance: derived` and `# verifies: <clause>` directly
above it, where `<clause>` is declared in `production.yaml` (`tests/unit/test_provenance.py`
checks this). Nothing is `ratified` until a human ratifies an invariant.
