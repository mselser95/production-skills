# PR #31 service-python — independent review (2026-11-27), CHANGES REQUIRED

Module: `prod-new/modules/service-python/` (sources under `template/`, placeholders
`<SERVICE>`, `<PACKAGE>`, `<OWNER>` in contents and paths). Reviewed at 0a44a1b.
Green at review time: `uv sync --locked`, pytest 113, ruff, format, `mypy --strict`; auth
refuses missing/wrong/empty tokens; service refuses to start without a >=16-char token;
amounts `+1`, `1e3`, non-ASCII digits, numbers, `true`, `NaN` refused; money mutations RED.

## Blockers
B1 `adapters/inbound/http_server.py:19-23`: a `Content-Length` of 5000 ASCII digits passes
   `isdigit`, then `int()` raises ValueError (4300-digit limit): no response, traceback in the
   log, BEFORE auth (works on `GET /healthz` without a token).
B2 `tests/architecture/test_boundaries.py:81-88`, `DOMAIN_ALLOWED:21-24`: with every test and
   linter green the domain can `open('/dev/null')`, do true division on money
   (`self.minor / 2` -> float), call `math.sqrt` (`math` is allowlisted). The float rule checks
   names and literals only; builtins are unchecked.
B3 `http_server.py:1,16,45-46`: docstring says "Bounded: header, body and socket timeouts":
   false. Timeout is per `recv` (one header byte every 4 s kept a connection past 16 s against
   a 10 s timeout); threads unbounded (300 half-open connections -> 302 threads). README never
   says stdlib `http.server` is not for production or that a reverse proxy belongs in front.
B4 `module.json:7-8`: a grammar-valid 39-char kebab-case SERVICE/PACKAGE fails
   `ruff format --check` ("6 files would be reformatted"); the 20-char limit is only in the
   README; module.json sets no cap or charset.

## Warnings
W1 `platform/config.py:37`: a token of 16 spaces is accepted; `Bearer ` + 16 spaces authenticates.
W2 `http_server.py:42-43`: a token sent in a query string appears in the INFO request-line log.
W3 `domain/money.py:51-54`: no upper bound in the constructor; two maximum deposits gave a
   balance `parse` would refuse (round trip only holds below 10^17). Zero amounts ("0",
   "0.005") are applied and journaled as events.
W4 `__main__.py:46`: on SIGTERM the process exits 0 in 0.02 s and drops an in-flight request
   (daemon threads): nothing drains.
W5 `http_api.py:72`: duplicate JSON keys: last wins.
W6 `tests/support/manifest.py:32-38`: diverges from PyYAML: keeps quotes, `null` stays a
   string, accepts `a: b` where YAML errors, a scalar `labels: ab` compared as {a,b}, an
   unquoted `# c` comment ends up inside the name.
W7 62 test headers say `derived` against `invariants: []`; `prod-test-synth/SKILL.md:35-37`
   says such a test "still lands as `candidate`"; the Go template does the same (8 `derived`
   tests citing capability clauses).
W8 slots: a dotted SERVICE (`order.book`) breaks `uv sync --locked` (dotted TOML key in
   `[project.scripts]`); PACKAGE=`1ledger`/`ledger-svc` fail at sync, `class` at import; the
   assembler says "ok" (it offers `charset: identifier`, `max_len`).
W9 `production.yaml` names `make check-fast` etc.; the module has no Makefile.

## Mutations that stayed GREEN
`hmac.compare_digest` -> `==` (http_api.py:64); server-side read cap `min(length, cap)`
removed (http_server.py:25); nothing tests an oversized Content-Length; aliased import
`import os as o; o.getenv` (test_boundaries.py:91-103).

## Working rules for every sub-task
Edit in the worktree `~/dev/personal/production-skills/.wt/mod-service-python`, ONLY the files
named in your task. RUN in an instantiated scratch copy outside the repo (SERVICE=ledger-svc,
PACKAGE=ledger_svc, OWNER=acme): `uv sync --locked`, `uv run pytest`, `uv run ruff check`,
`uv run ruff format --check`, `uv run mypy`. Never create `.venv`, caches or build output in
the worktree. Other agents edit OTHER files of this module in the same worktree at the same
time: never `git add`, `git stash`, `git checkout` or `git status`-driven cleanup; touch only
your files; when you re-instantiate the scratch copy you may see their in-progress edits — if
a failure is outside your files, report it and do not fix it. Stdlib only at runtime; no new
dependency. Do not commit.
