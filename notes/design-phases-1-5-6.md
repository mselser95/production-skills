# Design — Phases 1 (greenfield monorepo + React + DS + e2e), 5 (Go/Rust/Python), 6 (Postgres born monitored)

Status: PROPOSED 2026-11-27, against master `0df80ad`; inputs: `practices-*.md`, hosts note, `STATE.md`. Every
UNVERIFIED/[U] is inherited from those notes or not establishable from the repo; section 8 says how to check each.

Repo facts this leans on (read, not assumed): template = 176 Go files, instantiated by `cp -R` + `sed` over
contents AND paths + a zero-slots check; `TEMPLATE-DIGEST` hashes the 40 files `stamp-template-provenance.sh`
lists; `install.sh` hashes every regular file in a skill dir (new `prod-new/` files need no installer change).
`verify-standard.sh` (6,332 lines, vendored byte-identical) refuses non-Go repos (`PROD_LANG`, ~line 254) and
already has `row()` (PASS without evidence => FAIL), `declined()`, `waived()` (live dated waiver), 4 shard groups
and a `--merge` that refuses missing/duplicate/unknown rows; ~75 literal ids + variable-built families.
`prove-mutation.sh` is language-neutral; `row-vacuity-sweep.sh` is Go-only (`//`, `*.go`). The nine SKILL.md are
nearly Go-free; Go lives in the probe, template, `formats/test-provenance.md`, `verification-probes.md`, the eval
env (`GOCACHE`/`GOPROXY`) and `_lib` tree hash (`.go .mod .sum`). prod-new eager = 237 KB refs + 28.5 KB SKILL.md.
The skill-weight gate is NOT on master (branch `budget/skill-weight`); assumed to land with 64/128 KB ceilings.
Rust/Python prod-review tasks (`py-*`, `rs-*`) exist UNTRACKED in the corpus worktree — another agent's work in flight.

## 1. Decisions
D1. **Composable modules, not one template with overlays and not one template per language.**
`prod-new/modules/<id>/` for `monorepo-root`, `service-go`, `service-rust`, `service-python`, `web-react`,
`design-system`, `e2e-playwright`, `db-postgres`, `db-timescale`; `prod-new` assembles the derived set.
Rationale: each module is testable alone, owned by disjoint files (parallel tasks), and the combinatorics are
paid at assembly, not by duplicating root files three times. Rejected: per-language full templates (three copies of
registries/gates/workflows drift apart — the defect `check-template-drift.sh` exists for); one template + overlays
(overlays that delete are order-dependent and every combination lives in one tree).
D2. **`service-go` IS today's `prod-new/template/`, in place.** Its `module.json` points at `../../template` and
maps paths to `root` or `unit`; no file moves. Rationale: TEMPLATE-DIGEST, the CI instantiate job and every
downstream stamp stay valid; the Go path cannot regress by relocation. Rejected: moving the 176 files into
`modules/service-go/` (digest churn for zero behaviour).
D3. **Assembly is a python3-stdlib script (`scripts/assemble.py`); slot substitution stays literal token replace.**
Modules contribute WHOLE files; the only generated files are indexes (root `production.yaml` `units:`,
`pnpm-workspace.yaml` package list, root Makefile unit list, `.prod/modules.json`). Slots stay `<UPPER>` tokens
replaced literally in contents and paths, with the existing "zero slots left in contents AND paths" check.
Rationale: sed semantics already work; what does not scale in bash is the path map and JSON. Rejected: Jinja/
cookiecutter (new dependency, logic inside templates); bash assembler (path maps in bash are where the
`cmd/<SERVICE>` bug came from). Manifests are JSON, not YAML: PyYAML is not a dependency (same reason as eval).
D4. **`module.json` contract:** `id`, `requires[]`, `conflicts[]`, `slots{}`, `placement` (glob → `root` |
`unit`), `unit_kind` (`service|app|package|database|none`), `vendored[]` (files the drift check pins),
`unit_stanza` (the `units:` entry it adds), `gates` (its `unit.mk` targets and its workflow file).
Nothing else; no hooks, no conditionals inside files.
D5. **Workflows are one file per unit; no YAML merging.** `.github/workflows/repo.yaml` (repo-scope gates) +
`<unit>.yaml` per unit with `paths:` filters + `nightly.yaml`. Root `Makefile` delegates (`make -C services/x
check-fast`, `pnpm -r --filter ./apps/... run ...`). Every job carries `timeout-minutes: 2` (finding: no
workflow has one today; nightly lanes keep their explicit longer bounds as declared exceptions).
D6. **Generated layout for a NEW spec is the monorepo, always** (one service and no UI included):

```
<repo>/
  production.yaml  AGENTS.md  CODEOWNERS  Makefile  package.json  pnpm-workspace.yaml  pnpm-lock.yaml
  .nvmrc  tsconfig.base.json  .changeset/  registries/  .prod/  docs/
  .github/workflows/   repo.yaml  svc-<svc>.yaml  web.yaml  ds.yaml  e2e.yaml  db.yaml  nightly.yaml
  scripts/             verify-standard.sh  verify-standard.d/{rows.d,adapters,lib.sh,driver.sh}
                       check-registries.sh  brand-strings.sh  check-template-drift.sh  ...
  services/<svc>/      production.yaml(v1)  go.mod  Makefile  cmd/  internal/{domain,app,adapter,platform}
                       verification/  regressions/  benchmarks/  observability/  queries/
  apps/web/            package.json  vite.config.ts  src/{routes,features,api}  e2e/{flows.yaml,specs,fixtures}
  packages/tokens/     src/{primitives,semantic,typography,dimensions}
  packages/theme/      src/{contract.css.ts,themes}
  packages/ui/         src/components/<Component>/
  packages/docs/       .storybook/  stories/{foundations,components,patterns}
  packages/format/     src/  (formatMoney/Percent/Date/Num, property tests)
  packages/api-client/ src/{parse.ts,schemas}  fixtures/  (recorded from the service)
  db/                  image.lock  compose.yml  compose.ci.yml  conf/  bootstrap/  migrations/  schema.sql
                       observability/{required_metrics.txt,alerts.yml,alerts_test.yml}  .squawk.toml
```
D7. **The single-service repo stays reachable as `layout: single`:** `assemble.py --layout single
--modules service-go` places `unit` at the repo root and must produce a tree byte-identical to
`instantiate-template.sh` (parity gate, T03). Chosen only when the human says so ("single repo", "no
monorepo") or for an existing scaffold. Rejected: deleting the single path (breaks every repo already stamped).
D8. **`production.yaml`: root v2 lists units; each service keeps its v1 spec.**
```yaml
version: v2
repo: { name: <REPO>, owner: <OWNER>, layout: monorepo }
units:
  - { id: svc-<svc>, kind: service,  language: go,  path: services/<svc>, spec: services/<svc>/production.yaml }
  - { id: web,       kind: app,      language: ts,  path: apps/web, flows: apps/web/e2e/flows.yaml }
  - { id: ds,        kind: package,  language: ts,  path: packages, members: [tokens, theme, ui, docs, format] }
  - { id: db,        kind: database, engine: postgres, major: 18, timescale: false, path: db, lock: db/image.lock }
```
A file without `units:` is a v1 single-unit spec (today's meaning). Tier, invariants and capabilities stay in
the service spec: the probe's existing parsing is reused unchanged per service.
D9. **verify-standard scores per unit, one verdict.** `--unit <id>` runs that unit's applicable rows with
`UNIT_ROOT=<path>`, `REPO_ROOT=.`; `--unit repo` runs repo-scope rows once (workflows, registries, secret scan,
drift). Row ids print as `<unit>/<id>`. `--merge` (existing) requires every (unit × group) file exactly once and
FAIL 0 overall; the evidence record is one per commit with a per-unit table. Rejected: one flat verdict over a
merged tree (Go rows grepping `cmd/` would scan TS) and per-unit verdicts with no aggregate (a red unit hides).
D10. **Language is a unit attribute; default Go.** Backend ∈ {go, rust, python}; frontend is React + TS only.
Anything else: `language-unsupported` / `frontend-unsupported` bail, never a half-scaffold.
D11. **A missing adapter is `FAIL no-adapter:<lang>`, or an NA backed by a live dated waiver.** Reuse
`waived()`: id `adapter-gap:<lang>:<row>` in `registries/waivers.yaml` with owner + expiry → row prints
`NA liability adapter-gap until <date>` and the summary counts liabilities separately; `check-registries.sh`
reddens the build at expiry. No new registry, no silent NA.
D12. **Database: one pinned pair, plain-SQL migrations.** `db/image.lock` records PG minor + Timescale version +
image digest + the CI run id that tested them together; never `latest`. DDL lives once in
`db/migrations/NNNN_name.sql` (forward-only, expand/contract); each backend's runner reads that directory
(goose annotation compatibility UNVERIFIED — section 8). Liability `pg19-reevaluate` (expiry 2027-05-31) retires when
Timescale declares PG 19 support AND a 19.x ≥ 19.1 exists.
D13. **Skill weight goes down, not up.** prod-new's eager set drops tier-policy/dimensions/mechanism-derivation/
verification-probes in favour of VERBATIM slices pulled at the step that needs them (`policy-slice.sh <key>`,
`dimension-slice.sh <n>` print the exact byte range — not a paraphrase, so no second source of truth, the
lesson recorded in prod-spec step 4). Phase-2 "What ships" (~10 KB) moves to `references/what-ships.md`.
Target: prod-new eager 258 KB → ≤ 45 KB; prod-spec eager unchanged or smaller.
D14. **Brand neutrality is a gate, not a review note.** `brand-strings.sh` scans contents, path names and
SVG/JSON of the whole generated tree, case-insensitive, against a denylist file named in the uncommitted
`config.sh`; an empty or missing list exits 2 (refuses), never 0. The DS is written fresh, same shape as the
yardstick, never copied and scrubbed.
D15. **New agents are host-neutral sources** in `agents/*.md` with abstract capabilities + `write_mask`, rendered
per host by the Phase-4 generator; write-mask and no-spawn are enforced on both hosts by the shared PreToolUse
hook (Codex DEGRADED until a run proves it blocks — hosts note).

## 2. The adapter model for verify-standard (strangler, no big bang)
**Row catalogue.** `scripts/verify-standard.d/rows.d/<NN>-<dimension>.tsv` (one file per dimension, so tasks own
disjoint files), one row per id:

Columns: `id` (exact emitted id; `observability:*`-style families listed member by member) · `dimension` (1–32) ·
`property` (one language-free sentence, e.g. "every inbound route opens a span parented on the caller's context") ·
`scope` (`repo`|`unit`) + `unit_kinds` (`service,app,package,database`) · `bucket` (N/S/T/E, below) ·
`tiers` (`0:B,1:B,2:A`, Blocking/Advisory, read from tier-policy where a key exists) · `budget_s` (ceiling in one shard).

**Adapter contract.** `scripts/verify-standard.d/adapters/<lang>/<name>.sh` with sidecar `<name>.rows`
(the ids it owns; `lang` ∈ `neutral go rust python ts`). Invocation:
`<adapter> --unit-root D --repo-root D --spec F --rows id,id`. Output: one line per owned row,
`ROW\t<id>\t<PASS|FAIL|NA>\t<evidence>`. Driver rules (all reuse existing helpers from `lib.sh`): PASS with
empty evidence → FAIL (the `row()` guard); NA must cite a `declined:` key or "nothing to measure: <fact>";
an owned row not printed → FAIL "adapter omitted row"; exit ≠ 0 or `budget_s` exceeded → FAIL for every owned row;
an applicable row with no adapter for the unit's language → D11. Go rows not yet migrated are
`go=inline`: the monolith emits them exactly as today.

**Bucket estimate (ESTIMATE from the ids and greps read, not a census; T02 produces the real count):**

| bucket | what it reads | ~rows | examples |
|---|---|---|---|
| N neutral | spec, registries, workflows, Makefile, docs, artifacts | ~80 | registries, registries-expiry-gated, runbook-citations-resolve, slo-objectives-ratified, ratification-*, scenario-matrix, secret-scan-all-triggers, workflow-definitions-valid, nightly-trends, sbom, artifact-provenance, deployment-resource-limits, delivery-progressive, chaos-experiments-declared, data-lifecycle:*, ops:* |
| T tool-run | runs a toolchain, parses its output | ~25 | build, tests, race, lint, coverage, coverage-ratchet, changed-line-coverage, vuln-scan, sast-blocking, fuzz, benchmarks, dependency-lockfile, loc-ratio |
| E test-exec | runs NAMED tests / mutations | ~40 | implemented_row ids, invariants-non-vacuity, replay-corpus, integration-real-lane, candidate-lane-segregated, crash-only-state-identity, backup-restore-test, auto-recovery:*, scalability:* |
| S source-grep | greps source with Go syntax | ~50 | tracing-wired-in-prod, observability:*, error-handling-fitness, mechanisms-driven, write-surface-authn, authz-invariants, overload:*, operational-determinism, profiling, provenance-headers, differential-observability |

**Strangler order** (each step leaves the Go verdict byte-identical on the instantiated template — golden gate):
1. Catalogue only (T02): no behaviour change; a check fails when the probe emits/declares an id the catalogue
   lacks, or the catalogue lists an id nothing emits.
2. Extract `lib.sh` (T10): `row`, `declined`, `waived`, evidence/merge writers move out; monolith sources it.
3. Driver + dispatch (T11): Go → monolith as today; rust/python/ts → driver over the catalogue. Day one every
   non-neutral row is `FAIL no-adapter` — an honest red baseline, not a refusal.
4. N rows (T12) first: no language content, they give Rust/Python/TS units their first real PASSes, and they
   prove the contract on cheap rows. The monolith calls the same adapter for Go (one implementation).
5. T rows (T13–T15): one `suite` adapter per language runs the toolchain ONCE and emits build/tests/coverage/
   lint/vuln/lockfile (the single-suite-run invariant, `single-suite-run-selftest.sh`, carries over per language).
   Go's inline suite moves last, after three other adapters proved the contract.
6. E rows (T16): `implemented:` values become `<runner-target> <test-name>`; per-language `named-test.sh`
   (`go test -run '^X$'`, `cargo nextest run -E 'test(=X)'`, `pytest <nodeid>`, `vitest -t`). The Go-output
   `classify_mutation_result` gets a per-language twin with the same four verdicts.
7. S rows last (T46, after owner Q5): most Go-specific and most semantic; until then Rust/Python carry
   `adapter-gap` waivers with expiry.

**Non-vacuity carries over.** (a) Each adapter ships `<name>-selftest.sh` driving it against
`verify-standard.d/fixtures/<lang>/` repos where the property is FALSE (must print FAIL) and TRUE (PASS) — the
existing selftest discipline, globbed by `make selftests`. (b) A catalogue check refuses an adapter-owned row
with no FAIL-expecting case in its selftest (mutation: delete the RED case → RED). (c) `row-vacuity-sweep.sh`
scans `adapters/**` too, with the comment grammar of the adapter's language (`//`, `/* */`, `///`; `#`,
docstrings; TS `//`, JSX `{/* */}`) (T17). (d) `prove-mutation.sh` is reused unchanged for every new gate.
(e) `mutation-baseline.sh` records selftest case counts per adapter, so deleting cases shows.

**2-minute rule.** Units × groups as a CI matrix; driver-enforced `budget_s`; times in `benchmarks/gate-runtime.md`.
NOT determined: whether today's four Go groups each finish < 2 min (sequential is ~5 min per the probe). T11 measures; over budget = split.

## 3. Per-dimension mechanism table
Status: E exists (Go) · B to build · L no off-the-shelf mechanism → dated liability. [U] = UNVERIFIED in the notes. [K] = Rust note's own-knowledge mark.

| # dimension | property | Go | Rust | Python | React/TS | gate sketch | status |
|---|---|---|---|---|---|---|---|
| 1 structural | coverage measured; ratchet + changed-line signal | `go test -cover`, covdata | `cargo llvm-cov nextest --fail-under-lines` (branch cov unstable) | coverage.py branch, `fail_under` | `vitest run --coverage` (threshold keys [U]) | `suite` adapter → coverage rows | Go E · others B |
| 2 fault sensitivity (adv.) | mutation trend on changed code | go-mutesting/gremlins (no native threshold) | cargo-mutants `--in-diff` (flags/exit [U]) | mutmut diff-scoped (slow, fork-only) | Stryker `--incremental` | nightly; `mutation-baseline` artifact row (N) | Go E · B |
| 3 invariants/properties | ratified invariants executable, non-vacuous; decode boundaries fuzzed | rapid, native fuzz | proptest/bolero; cargo-fuzz (nightly/flags [U]) | Hypothesis (derandomize in CI); atheris (3.15 [U]) | fast-check on format/schema | `invariants-non-vacuity` via per-lang classifier; `fuzz` | Go E · B |
| — concurrency (rows `race`) | data races detected in the suite | `-race` | loom/shuttle targeted; Miri/TSan (timings [U]) | **none** (free-threaded canary, `-X dev`) | n/a single thread | `race` row | Py **L** · Rust partial B |
| 4 scenarios | class-checklist matrix covered | table tests + fakes, synctest | turmoil + fakes | pytest `-m scenario`, `-X dev -W error` | Playwright adversarial fixtures | `scenario-matrix` (N) + per-lang test-id lister | B |
| 5 integration | ≥1 lane vs a real dependency | testcontainers-go, tag | testcontainers [K], `nextest --test '*'` | testcontainers-python, `-m integration` | contract replay of recorded API fixtures | `ci-runs-integration-lane`, `integration-real-lane` | Go E · B |
| 6 performance | relative statistical baseline | benchstat | criterion / Gungraun | pytest-benchmark `--benchmark-compare-fail` | size-limit; LHCI (borderline 2 min) | `benchmarks` | Go E · B |
| 7 resilience | crash-only state identity | `kill-durability.sh` | same script (container-level) | same | n/a | `crash-only-state-identity` (E) | B (port per lang) |
| 8 observability | manifests == real endpoint; tracing wired; logs correlate | OTel, slog, pprof | tracing + OTel, `clippy::print_stdout` | OTel + structlog, ruff T20 | browser OTel "experimental" → n/a; no-PII error report e2e | `observability-contract-checked` (N scrape) + S rows | Go E · S rows B |
| 9 security | vulns, secrets, authn on writes | govulncheck, gosec | cargo deny/audit, clippy | pip-audit, ruff S/bandit | pnpm audit / osv-scanner (exit codes [U]) | `vuln-scan`, `secret-scan-all-triggers`, `write-surface-authn` | Go E · B |
| 10 deployability | hardened image, limits, probes | distroless multi-stage | distroless + `cargo auditable` | multi-stage uv; hadolint [U] | no sourcemaps in `dist`, CSP | `deployment-resource-limits` (N) | partly E |
| 11 reproducibility | locked inputs, double build equal | `-trimpath`, double build | `--locked`, remap (docs [U]) | `uv lock --check`, `--require-hashes` | `--frozen-lockfile` [U], `packageManager` pin | `dependency-lockfile` + double-build | Go E · B |
| 12 scalability | bounded boot/storage, partition key | named tests | named tests | named tests | n/a | `implemented_row` → `named-test.sh` | B |
| 13 auto-recovery | self recovery within bound | named tests, contextcheck | supervisor/panic tests | timeouts + bounded retries; S113 id [U] | n/a | `auto-recovery:*` (E) | B |
| 14 published contract | versioned, shape pinned | buf breaking, codegen diff | `cargo semver-checks`, buf | OpenAPI export diff (tool [U]) | api-client schemas vs recorded fixtures | `published-contract:*` | partly B |
| 15 data lifecycle | retention, deletion, restore proven | goose + restore test | sqlx | Alembic not fetched → neutral SQL runner | n/a | `data-lifecycle:*`, `backup-restore-test` (neutral pg_dump/restore) | B |
| 16 wiring | mechanisms driven from composition root | build + symbol grep | boot test + grep | import smoke + `/ready` | knip unused exports (exit [U]) | `mechanisms-driven` (S) | B |
| 17 progressive delivery | platform + formal model advisory | platform | platform | platform | n/a | `delivery-progressive` (N) | E (neutral) |
| 18 SAST | taint on declared untrusted input | gosec, CodeQL | CodeQL/semgrep | CodeQL/semgrep taint | eslint bans (rule names [U]), CodeQL JS | `sast-blocking`: SARIF zero alerts (N parser) | Go E · B |
| 19 schema evolution | breaking change caught at merge; safe DDL; queries match schema | `sqlc diff`; squawk | `cargo sqlx prepare --check`; squawk | run every named query vs migrated container; squawk | zod schema replay | `compatibility` + new `ddl-lint`, `query-schema` | B |
| 20 chaos/consistency | declared experiments, history check | external tools | turmoil faults | none | n/a | `chaos-experiments-declared`, `consistency-verification` (N) | E (neutral) |
| 21 consumer contracts | consumer pacts verified | pact-go (not fetched) | pact-rust [K][U] | pact-python (not fetched) | not researched | — | **L** all languages |
| 22 SLO | objectives ratified, burn-rate alerts | platform | platform | platform | CWV p75 field data | `slo-objectives-ratified` (N) | E (neutral) |
| 23 dependency currency | lockfile enforced, cadence, SHA/digest pins | `go mod tidy -diff`, verify | cargo deny, `min-publish-age` (1.100) | `uv lock --check`, pip-audit | catalogs strict, `minimumReleaseAge`, `trustPolicy` (names [U]) | `dependency-lockfile`, action pins + PG pair pin | partly E |
| 24 domain boundaries | imports respect zones | depguard, `internal/` | cargo deny bans, `pub(crate)` | import-linter (keys [U]), ruff TID | eslint-plugin-boundaries / depcruise | architecture test per lang | Go E · B |
| 25 load/soak | open-loop baseline on target hw | `loadgen.go` | reuse loadgen binary (black box) | same | n/a | `load-baseline` (N artifact) | E (neutral) |
| 26 overload | shedding + retry budget | MaxBytesReader, timeouts | tower load-shed [K] | ASGI middleware — no off-the-shelf gate | n/a | `overload:*` (S) | Go E · Rust B · Py **L** |
| 27 det. simulation (adv.) | seeded whole-system run | synctest (in-process) | turmoil / madsim | **none** | n/a | `simulation-advisory` | Py **L** |
| 28 frontend e2e flows | NEW, §4 | — | — | — | Playwright | `adapters/ts/e2e.sh` | B |
| 29 frontend data boundary | NEW, §4 | — | — | — | zod/valibot + format pkg | `adapters/ts/data-boundary.sh` | B |
| 30 accessibility | NEW, §4 | — | — | — | axe, Storybook a11y, keyboard tests | `adapters/ts/a11y.sh` | B |
| 31 design-system integrity | NEW, §4 | — | — | — | vanilla-extract contract, Storybook | `adapters/ts/ds.sh` + `brand-strings.sh` | B |
| 32 datastore operability | NEW, §4 | sqlc typed queries | sqlx | psycopg + query-run test | n/a | `adapters/neutral/db-operability.sh` | B |

Rust gaps with no off-the-shelf mechanism (blocking-in-async, missing timeouts, cancellation safety, build-script
sandboxing, branch coverage, no-panic proof) and Python's (race, simulation, overload, fast mutation) become
`adapter-gap` waivers whose text names the substitute (`disallowed-methods`, a timeout-forcing client, ...).

## 4. New dimensions (28–32) and what folds into existing ones
All five are NA (with the reason "no `app`/`package`/`database` unit in `units:`") when the unit kind is absent —
an NA the spec states, never a missing row.
**28. Frontend end-to-end user flows.** Every flow in `apps/web/e2e/flows.yaml` (id, route, states) has ≥1
Playwright spec tagged `@flow:<id>`, and every tag names a declared flow (cross-check from
`playwright test --list --reporter=json`). Rendered in a real browser (Chromium; mocked responses via
`page.route` with recorded real-shaped payloads), projects at 360 / 768 / 1280 px. After every step a shared
fixture asserts: no text matching `NaN|undefined|\[object Object\]|Infinity`; no page or element overflow
(scrollWidth/rect checks with 1 px tolerance; intentional truncation needs `data-truncate` + accessible full
text); every visible number/box equals an INDEPENDENTLY computed expected string (decimals, separators,
currency, %, sign, dates, negative/zero/18-digit/empty); axe WCAG 2.2 AA zero violations; visual snapshot per
viewport in the pinned Playwright container. Adversarial fixtures: 300-char strings, 18-digit decimal strings,
empty lists, 4xx/5xx, 3 s latency, partial bodies, wrong-type fields. `forbidOnly`, `retries: 1`,
`failOnFlakyTests`, `fullyParallel`, sharded to stay under 2 min. Blocking at every tier; visual snapshots
blocking T0/T1, advisory T2 (owner Q4). Mutations (all via `prove-mutation.sh` in T35): delete one spec →
flow-coverage RED; formatter `halfExpand`→`trunc` → e2e RED; inject `width:2000px` in a component → overflow
RED; change a fixture field number→string → schema-flag RED; render a raw `undefined` → text guard RED.
**29. Frontend data-boundary correctness.** Only `packages/api-client` calls `fetch`/`.json()` (eslint
`no-restricted-syntax`); every response passes ONE `parseResponse(schema, res)`; schemas `.strict()`; no `as`
on parsed data; parse failure is a typed `SchemaError` the UI renders as "unexpected data" (never a blank or a
coerced value); a replay test runs recorded real service responses through the schemas; all display formatting
goes through `packages/format`, which formats decimal STRINGS (MDN: exact for strings) with property tests
(no `NaN`/`e+`, digits round-trip up to 30 digits). Blocking all tiers. Mutations: `res.json()` in `apps/web`
→ lint RED; drop `.strict()` → schema test RED; `toFixed` outside format → lint RED; recorded fixture field
type flipped → replay RED. Folds the formatting half of the owner's e2e list into a cheap unit-level gate so
e2e is not the only line.
**30. Accessibility.** WCAG 2.2 AA bar: axe in every e2e step (28) and in every Storybook story
(`parameters.a11y.test = 'error'` globally; any `'todo'` fails a script); keyboard tests (Tab order, Escape
returns focus, modal focus trap) for Dialog/Menu/Tabs; reduced-motion project; token-level contrast test.
Blocking: axe + contrast all tiers; keyboard suites T0/T1, advisory T2. Mutations: remove IconButton's
`aria-label` → story a11y RED; set a story to `'todo'` → script RED; break Dialog focus return → keyboard RED.
Kept separate from 28 because it also applies to `packages/ui` with no app and has its own NA condition.
**31. Design-system integrity.** Three token layers (primitives → semantic colour → typography composition, plus
dimensions) in DTCG-shaped JSON (Style Dictionary v5 partial support [U] → tokens compiled by a small in-repo
script, no generator dependency); vanilla-extract `createThemeContract` with light/dark themes and a test that
every theme fills every contract key (compile-error behaviour [U], so the test asserts it); every export of
`packages/ui` has a story (story-coverage test); contrast test over all semantic fg/bg pairs per theme
(≥4.5 text, ≥3 large/UI); changesets required for package changes; `brand-strings.sh` over the whole tree.
Blocking all tiers. Mutations: delete a story → coverage RED; delete one key from dark theme → contract RED;
darken a bg token → contrast RED; put a listed brand string in a comment, a path name or an SVG → RED; change
`packages/ui` without a changeset → `changeset status` RED (exit code [U]).
**32. Datastore operability (born monitored).** A `database` unit ships: least-privilege roles
(owner/migrator/app/readonly/monitor; monitor = `pg_monitor` only, not super, conn limit), `scram-sha-256`
hba with a final reject, TLS on, per-role timeouts, `pg_stat_statements` + `track_io_timing` + lock/temp/
autovacuum logging, postgres_exporter (0.21.1) as `monitor`, `pg_isready` liveness + app readiness via a real
query, `required_metrics.txt` with one alert each in `alerts.yml` + `promtool test rules`. The CI test (<60 s)
starts the pinned image, runs bootstrap + migrations, starts the exporter, scrapes, and asserts `pg_up 1` and
every required metric present. Timescale adds job_stats/chunk/compression/cagg-freshness metrics + alerts.
Blocking all tiers when a database unit exists. Mutations: revoke `pg_monitor` → scrape RED; drop
`pg_stat_statements` from preload → RED; delete one alert → metric↔alert parity RED; hba `trust` → RED;
image tag `latest` or digest removed → pin RED.
**Folds instead of new dimensions:** safe-DDL lint (squawk) and query↔schema typing → **19**; restore test →
existing `backup_restore_test` key in **15**; PG/Timescale pair pin → **23**; real Postgres in tests → **5**
(`integration-real-lane`); DB auth/TLS findings also cite **9**. Only the monitoring bundle is new, because its
unit of proof is one container test and it has one NA condition.

## 5. Skill changes
**prod-spec** (eager must not grow):
- Opening paragraph: add ONE conditional sentence — "If step 0 says NEW, read `references/greenfield.md`."
  (counts toward REACHABLE, not EAGER; check against the hardened EAGER parser before merging).
- New step 0 (≤ 8 lines): NEW iff the target has no `production.yaml` AND the intent creates a service or
  product; existing repos unchanged; the "No production.yaml" bail then applies only to non-NEW intents.
- `references/greenfield.md` (new, `_shared/formats/greenfield.md`, ~6 KB): the default-decision table
  (layout monorepo; frontend React+TS whenever the intent has a user; backend Go unless the human names
  Rust/Python; DB PG 18, Timescale iff the intent names time-series/metrics/ticks/telemetry; nothing else),
  each recorded as `{decision, value, source: default|human}`; the agent activation record (below); the hand-off
  (plan task 1 = `kind: scaffold` → prod-new with the module list). The two format files get ONE pointer line
  each, not the schema.
- Agent activation record in the change plan: `agents: [{name, activated, criterion, evidence}]`, inactive ones
  listed too (same rule as not-warranted mechanisms); criteria = the `activation` column of the agents table below.

**prod-new** (eager 258 KB → ≤ 45 KB target):
- Opening paragraph: eager = preamble only; tier-policy, dimensions, mechanism-derivation, verification-probes are
  pulled as verbatim slices at the step that needs them (`references/probes/policy-slice.sh`, `dimension-slice.sh`).
- Contract: input gains `language` (go|rust|python, default go) and `layout` (monorepo default for NEW | single).
- RULE FOUR-QUESTIONS stays four. Module selection is DERIVED (new "Phase 1c", ≤ 12 lines): Q1 purpose → web
  (has users) and Timescale (time-series); Q3 boundaries → db-postgres (`source_of_truth` with relational state);
  language from the intent. Verdicts ride in the batched message like mechanism verdicts; `needs one more question`
  is the only one that may reach the human. Detail in `references/modules.md` (on-demand).
- Phase 2: "What ships" block → `references/what-ships.md`; step 1 "copy template/ + sed + path rename" → "run
  `scripts/assemble.py` with the derived modules" (the path-slot story moves into the assembler's docstring).
- Bail: `language-unsupported` only outside go/rust/python; new `frontend-unsupported`. Headless bail stays; an
  answers file carrying `ratified_by` counts as the present human's answers (owner Q2).

**The other seven** (one line each; detailed edit lists come with T43):
- prod-implement — gate commands come from the unit's spec, never a `go test` example; provenance header syntax
  per language from the `test-provenance.md` table; write-mask expressed in unit paths.
- prod-review — `review-depth.md` deep-pass idioms (handler shapes, `-race`) get a per-language table; provenance
  audit parses `#` headers (Python) and `//` (Rust/TS).
- prod-test-synth — candidate lane: Go build tag → Rust cargo feature `candidate` + nextest filter, Python
  `@pytest.mark.candidate` + `-m "not candidate"`, TS `*.candidate.test.ts`; generators rapid → proptest /
  Hypothesis / fast-check.
- prod-bootstrap — language detection via the catalogue; the gap report uses adapters; a `no-adapter` row is a gap
  row with a proposed waiver (SKILL.md:321 currently describes the probe as Go).
- prod-incident — the minimized replay fixture runs through a per-language `regressions/` driver, not the Go one.
- prod-ops — flake rerun `-race -count=N -shuffle=on` (SKILL.md:104) → the adapter's rerun command per language.
- prod-curate — mutant dedup and kata runs parse go-mutesting output → per-language mutation-report parsers.

**New agents** (sources in `agents/`, generated per host; abstract capabilities: read, write(mask), exec, spawn=never):
| name | purpose | tools | write mask | activation |
|---|---|---|---|---|
| `ux-flow` | flows, IA, empty/error/loading/partial states per view | read, write | `docs/ux/**`, `apps/*/e2e/flows.yaml` | app unit or user journey in intent |
| `ui-system` | tokens, themes, DS components + stories | read, write, exec | `packages/{tokens,theme,ui,docs}/**` | DS selected or DS path touched |
| `a11y-auditor` | read-only WCAG 2.2 AA audit, runs axe/Storybook a11y, mutation-proves findings | read, exec | none | rendered UI changed |
| `frontend-implementer` | one bounded TS/React task inside the plan | read, write, exec | task's `apps/**`/`packages/**` minus `e2e/` | task owns frontend files |
| `e2e-author` | Playwright specs per flow, proven RED before the feature | read, write, exec | `apps/*/e2e/**` | flow or route added/changed |

## 6. Work breakdown
Rules: one task = one implementer + one validator; owned paths are exclusive while the task is open; every task
leaves master green; Go golden parity is part of every task that touches `verify-standard*`. `[W1]` = first wave,
start now in parallel. `[OQ#]` = needs owner question # first. Wiring: after T01, each task wires its gate in its
own `mk/<task>.mk` (no shared Makefile edits); before T01 lands, wave-1 gates run through their globbed selftest.

| id | title | owns (exclusive) | deps | deliverable | gate · mutation that turns it RED | eval | size |
|---|---|---|---|---|---|---|---|
| T01 [W1] | Makefile fragments | `Makefile`, `_shared/probes/probe-wiring.sh`, `probe-wiring-selftest.sh` | — | `-include mk/*.mk`, `VERIFY_EXTRA`; probe-wiring reads fragments | probe-wiring selftest · probe named only in a fragment comment → RED | — | S |
| T02 [W1] | Row catalogue | `_shared/probes/verify-standard.d/rows.d/**`, `_shared/probes/row-catalogue.sh`, `row-catalogue-selftest.sh` | — | every emitted/declared id catalogued with property, scope, bucket | selftest on real tree GREEN; fixture probe with an uncatalogued id → RED; delete a tsv line → RED | — | M |
| T03 [W1] | Assembler + service-go manifest, single parity | `scripts/assemble.py`, `prod-new/modules/service-go/module.json`, `scripts/tests/assemble-parity-selftest.sh` | — | `--layout single` ≡ `instantiate-template.sh` | `diff -r` empty · drop one placement glob → RED; leave one `<SLOT>` in a path → RED | — | M |
| T04 [W1] [OQ6] | Brand-string gate | `_shared/probes/brand-strings.sh`, `brand-strings-selftest.sh`, `_shared/brand-denylist.example.txt` | — | contents + paths + SVG/JSON scan, refuses empty list | selftest · listed string in a comment / path / SVG → RED; empty list → exit 2 | — | S |
| T05 [W1] | DS tokens + theme contract | `prod-new/modules/design-system/packages/{tokens,theme}/**` | — | 3-layer tokens + dims, light/dark themes, contract + contrast tests | `pnpm -F tokens -F theme test` · darken one bg token → contrast RED; delete a dark-theme key → contract RED | — | M |
| T06 [W1] | prod-new eager cut | `prod-new/SKILL.md`, `prod-new/references/what-ships.md`, `_shared/probes/{policy-slice,dimension-slice}.sh` + selftests | skill-weight branch merged | eager ≤ 45 KB; slices byte-exact | skill-weight EAGER ratchet; slice selftest · truncate/paraphrase a slice → RED | prod-new held-out must not lose (T41) | M |
| T07 [W1] | prod-review corpus in Rust + Python | `benchmarks/eval/corpus/prod-review/{rs-*,py-*}/**`, `_lib/regen_expected.sh` | — | ≥ 5 held-out + dev per language, seeded + clean | `make eval` lint (grader RED unsolved, GREEN reference) · break one reference → RED | itself | M |
| T09 [W1] | PG/Timescale pin | `prod-new/modules/db-postgres/db/image.lock`, `.../scripts/db-pin-check.sh` + selftest | §8 items 1–2 | verified pair + digest + tested-run id; `pg19-reevaluate` waiver | selftest · `:latest` → RED; bump PG minor only → pair RED | — | S |
| T08 | Eval harness per language | `benchmarks/eval/{run.sh,report.py,selftest.sh,lib/runenv.py}` | T07 | `language` in task.json; offline CARGO_HOME/target, venv caches; never pool languages | `selftest.sh` · pool two languages → RED | all corpora | M |
| T10 | Extract `lib.sh` | `_shared/probes/verify-standard.sh`, `verify-standard.d/lib.sh`, template copy + digest | T02 | pure move of row/declined/waived/evidence | golden parity on instantiated template · weaken PASS-without-evidence guard → load-rows selftest RED | — | M |
| T11 | Driver + dispatch | `verify-standard.d/driver.sh`, dispatch block of `verify-standard.sh`, `fixtures/{rust,python,ts}/minimal/**` | T10 | non-Go → catalogue; `no-adapter` FAIL; waiver → NA liability; runtime per group measured | driver selftest · driver skips a catalogued row → RED; delete waiver → FAIL; expire it → check-registries RED | — | M |
| T12 | Neutral adapters, repo scope | `verify-standard.d/adapters/neutral/**` | T11 | registries, workflows, ratification, runbook, SLO, secret-scan rows as adapters; Go calls them | per-adapter selftests + Go golden · each adapter's FALSE fixture → FAIL | — | M |
| T13 | Rust suite adapter | `adapters/rust/suite.*`, `fixtures/rust/suite/**` | T11 | build/tests/coverage/lint/vuln/lockfile rows | selftest · failing test, clippy warning, advisory crate → RED each | — | M |
| T14 [OQ3] | Python suite adapter | `adapters/python/suite.*`, `fixtures/python/suite/**` | T11 | same rows; `race` → shipped `adapter-gap` waiver + substitute | selftest · same mutations; remove waiver → `race` FAIL | — | M |
| T15 | TS suite adapter | `adapters/ts/suite.*`, `fixtures/ts/suite/**` | T11 | tsc -b, eslint `--max-warnings 0`, vitest cov, knip, audit, frozen lockfile | selftest · type error, lint warning, unused export → RED | — | M |
| T16 | Named-test runners | `adapters/*/named-test.*`, `adapters/*/classify-mutation.*` | T13–T15 | `implemented:` generalized; 4-verdict classifier per lang | selftest · named test absent → FAIL (not NA); mutation stayed green → FAIL | — | M |
| T17 | Vacuity sweep per language | `_shared/probes/row-vacuity-sweep.sh` + selftest, template copy | T12 | scans adapters; comment grammar per lang | selftest · Python row satisfied only by `#` comment → RED | — | S |
| T18 | service-rust: zones + observability | `prod-new/modules/service-rust/**` except `unit.mk`, `ci/`, `deny.toml`, `.config/` | T03 | domain/app/adapter/platform, composition root, metrics+spans manifests + contract test, registries, spec | `cargo nextest run` · drift a manifest metric → contract RED | prod-new rs task | L |
| T19 | service-rust: gates + CI | `service-rust/{unit.mk,ci/**,deny.toml,.config/**}` | T18 | check-fast/verify, deny, llvm-cov, mutants nightly, `timeout-minutes` | assembled `make check-fast` · advisory crate → deny RED | — | M |
| T20/T21 | service-python: zones+obs / gates+CI | `modules/service-python/**` split as T18/T19 | T03 | uv locked, pytest lanes/markers, ruff, pyright strict, import-linter, pip-audit | assembled `make check-fast` · cross-zone import → import-linter RED | prod-new py task | L/M |
| T22 | db bootstrap | `modules/db-postgres/db/{compose*.yml,conf/**,bootstrap/**}` | T09 | roles, hba, TLS, settings, extensions, timeouts | `db-ci` SQL assertions · hba `trust` → RED; monitor superuser → RED | — | M |
| T23 | db born monitored | `modules/db-postgres/{db/observability/**,scripts/db-scrape-test.sh}` | T22, §8 item 3 | exporter, required_metrics, alerts + promtool tests, scrape test < 60 s | scrape test · revoke `pg_monitor` → RED; drop an alert → parity RED | — | M |
| T24 | migrations + restore | `modules/db-postgres/db/{migrations/**,.squawk.toml,schema.sql}`, `scripts/db-{migrate,restore-test}.sh` | T22 | squawk, apply-from-zero, schema snapshot, restore test | job · non-concurrent index → squawk RED; corrupt dump → restore RED | — | M |
| T25a/b/c | Typed queries go / rust / python | `modules/db-postgres/lang/{go,rust,python}/**` | T24, T18, T20 | sqlc / sqlx offline / query-run test | each · migrate a column type without regen → RED | — | M each |
| T27 | db-timescale overlay | `prod-new/modules/db-timescale/**` | T23 | hypertable example, policies, job/chunk/cagg metrics + alerts | scrape + alert tests · failing job → alert test RED | — | M |
| T28 | monorepo-root module | `prod-new/modules/monorepo-root/**` | T03 | pnpm catalogs strict, `packageManager`, engines, root Makefile, repo.yaml, v2 spec | assembled `pnpm install --frozen-lockfile` + settings check · non-catalog dep → RED | — | M |
| T29a/b | web app + api-client / format package | `modules/web-react/{apps/**,packages/api-client/**}` / `modules/web-react/packages/format/**` | T28 | strict TS, eslint bans, parseResponse, SchemaError view / formatters + fast-check | vitest + lint · §4 dims 29 mutations | — | L/M |
| T30/T31 | DS components A / B | `packages/ui/src/components/{Button,IconButton,Input,Checkbox,Switch,Select,Badge,Card,Callout,Divider}` / `{EmptyState,Menu,Pagination,Progress,Skeleton,Tabs,Dialog,Tooltip,DataTable,AppBar,Num}` | T05 | real components, native elements, keyboard tests | vitest browser · break Dialog focus return → RED | — | M each |
| T32 | DS docs + changesets | `modules/design-system/{packages/docs/**,.changeset/**}` | T30 | Foundations/Components/Patterns, a11y `error`, story-coverage | storybook vitest · delete a story → RED; a `'todo'` → RED | — | M |
| T34a/b [OQ4] | e2e harness / adversarial + visual | `modules/e2e-playwright/{config,fixtures,flow-coverage}/**` / `{adversarial,visual}/**` | T29a | projects 360/768/1280, overflow/text/axe fixtures, flows cross-check / fixtures + baselines | `playwright test` sharded < 2 min · §4 dim 28 mutations | — | L/M |
| T35 | e2e non-vacuity | `modules/e2e-playwright/mutations/**`, `scripts/tests/e2e-nonvacuity-selftest.sh` | T34 | the five dim-28 mutations as patches via `prove-mutation.sh` | each patch must yield RED; a patch that stays green → selftest RED | — | S |
| T36 | Dims 28–32 in the standard | `_shared/dimensions.md` (§28–32 append), `_shared/tier-policy.yaml`, `rows.d/{28..32}-*.tsv`, `adapters/ts/{e2e,data-boundary,a11y,ds}.*`, `adapters/neutral/db-operability.*` | T12, T15, T23, T35 | text + keys + rows land together (policy-coverage) | policy-coverage + adapter selftests · a key nothing scores → RED | — | L |
| T37 | prod-spec greenfield | `prod-spec/SKILL.md`, `_shared/formats/{greenfield.md,resolved-context.md,change-plan.md}` | T06 | step 0, defaults, activation record | skill-weight (prod-spec EAGER not larger) · grader of T38 | T38 | M |
| T38 | prod-spec corpus | `benchmarks/eval/corpus/prod-spec/**` | T08 | greenfield intents (go/rs/py) → structured defaults + activation; ≥ 5 held-out | lint · omit `e2e-author` with a flow present → grader RED | itself | M |
| T39 | prod-new module selection | `prod-new/references/modules.md`, Phase 1c lines in `prod-new/SKILL.md` | T06, T03 | derivation of modules from 4 answers | skill-weight; selftest of example derivations · wrong module for a time-series intent → RED | T41 | S |
| T40 | Agents | `agents/{ux-flow,ui-system,a11y-auditor,frontend-implementer,e2e-author}.md` | Phase-4 generator + hook | 5 host-neutral sources + generated per host | `agents-budget.sh` + hook selftest · e2e-author writing outside mask → hook RED | — | M |
| T41 | prod-new corpus | `benchmarks/eval/corpus/prod-new/**` | T08, T39 | answers → assembled tree graded by its own gates, per language | lint · reference tree with one gate disabled → grader RED | itself | L |
| T42 [OQ1,2] | Greenfield demo in CI | `scripts/demo-greenfield.sh`, `demo/answers-go-web-ds-pg.json`, `.github/workflows/demo.yaml` | T19–T36 | assemble → build/test/e2e/verify-standard `--merge` FAIL 0 + every new gate RED under its patch | matrix jobs each < 2 min · revert one module's gate → demo RED | — | L |
| T43 ×7 | De-Go the other skills | one skill dir each + `_shared/formats/test-provenance.md` (T43a only) | T16 | §5 one-liners executed | Phase-5 item 5 probe (single-language tool named as THE way) · add "run go test" to a SKILL → RED | each skill's corpus | S each |
| T44 | Digest/stamp per module | `scripts/template-digest.sh` + selftest, `prod-new/TEMPLATE-DIGEST`, `prod-new/modules/*/DIGEST`, template stamper + drift check | T03 | per-module vendored lists, stamp records module | template-digest selftest · edit a module file without DIGEST → RED | — | M |
| T45 | Unit/repo roots + `--unit` merge | `verify-standard.sh` (root handling), `driver.sh` | T12 | `REPO_ROOT` vs `UNIT_ROOT`; per-unit merge | Go golden + 2-unit fixture · drop one unit's file → merge RED | — | M |
| T46 [OQ5] | S-bucket adapters Rust/Python | `adapters/{rust,python}/source-*.*` | T17, T45 | tracing-wired, observability:*, error-handling, mechanisms-driven | selftests incl. comment-only fixtures → RED | — | L |

Wave 1 (T01–T07, T09) owns disjoint paths as listed. T07 overlaps the untracked `py-*`/`rs-*` tasks already in the
corpus worktree: adopt and validate them, do not re-author. Earliest demo: T03 + T28 + T05 assemble a monorepo
skeleton with a green token/theme package; T11 then gives a Rust fixture its first honest verdict.

## 7. Risks and owner questions
| risk | mitigation |
|---|---|
| Combinatorics: 3 backends × web/no-web × {no db, pg, pg+ts} = 18 trees | modules are tested alone; CI assembles 3 (each backend alone) + 3 (each backend + pg + ts) + 1 full demo (Go+web+DS+pg); web talks to recorded fixtures, so it is backend-agnostic and tested once |
| CI time / 2-minute rule | matrix per unit × group, `timeout-minutes: 2` everywhere, adapter `budget_s`; T11 measures today's Go groups first; Playwright sharded + only Chromium in PR lane |
| Skill weight | T06 before any prod-new/prod-spec growth; new prose only in on-demand refs; skill-weight ratchet reviews every load-set change |
| Go path regressing | `service-go` = template in place; golden parity in T10–T12, T45; Go inline rows move only after 3 other adapters proved the contract |
| Playwright < 2 min | fullyParallel + shards, pinned container image, fixtures mocked, visual only at 3 viewports, failOnFlakyTests to stop retry creep |
| DS size vs "no file dump" | ~21 components, each small and REAL (test + story + keyboard where interactive); EMPTY-BUT-REAL rule applies; module only when an app exists |
| Adapter-gap waivers become permanent | expiry enforced by check-registries; a waiver without a substitute mechanism in its text is refused by T11's selftest |

Questions that need the owner (recommended answer first):
1. Does a NEW spec with one service and no UI still get the monorepo layout? **Yes** — one layout to test, an app
   can be added later without a move; `single` only on explicit request.
2. Demo "no clarifications" vs the headless bail (tier, boundaries, invariants are never guessed): **the demo ships an
   answers file with `ratified_by`; prod-new asks nothing when every answer is present, and still bails headless.**
3. Python race detection / deterministic simulation and the Rust gaps: **dated `adapter-gap` liabilities with a written
   substitute (expiry 2027-06-30)**, not a block on Python/Rust scaffolds.
4. Visual regression: **committed per-viewport baselines from the pinned Linux Playwright image; blocking T0/T1,
   advisory T2.**
5. S-bucket rows for Rust/Python: **per-language regex adapters with comment grammars first** (no new dependency);
   revisit ast-grep/semgrep only if the vacuity sweep keeps finding prose-satisfied rows.
6. Brand denylist location: **uncommitted `config.sh` path; a committed neutral list only for the selftest; the gate
   refuses an empty list.**

## 8. Verify before building
- [ ] 1. TimescaleDB × PG 18 pair and image naming — `docker buildx imagetools inspect` on the candidate tags (official
  `postgres:18.7-*` and the Timescale image tag for 2.32.1 on PG 18; tag scheme UNVERIFIED); run it, `SELECT version()`,
  `SELECT extversion FROM pg_extension`, and a scheduler job; read 2.32.1 release notes for the 18.7 fix. Cost: minutes.
- [ ] 2. Timescale editions: whether compression/columnstore and policies need the TSL licence in the chosen image.
- [ ] 3. postgres_exporter 0.21.1 real metric names and PG 18 behaviour (`stat_io`, removed `pg_stat_wal` columns,
  collectors off by default) — run against the pinned image, scrape, and freeze `required_metrics.txt` from output.
- [ ] 4. squawk: `--pg-version=18` flag and behaviour on hypertable/columnstore DDL — run on a sample migration.
- [ ] 5. goose/sqlx/Python runner on ONE plain-SQL migrations dir (goose `-- +goose Up` annotations) — try all three.
- [ ] 6. pnpm 12 setting names/defaults: `catalogMode`, `minimumReleaseAge`, `trustPolicy`, `allowBuilds`,
  `strictDepBuilds`, `engineStrict`, `--frozen-lockfile` exit — scratch workspace with each setting violated.
- [ ] 7. Exit codes on findings: knip, depcruise, `changeset status`, osv-scanner, `pnpm audit` — seeded fixture each.
- [ ] 8. Vitest 5 coverage threshold keys; Storybook 10 `parameters.a11y.test` values; Playwright `trace`/`video`
  option names, `failOnFlakyTests` — config + deliberate failure.
- [ ] 9–11. vanilla-extract: does a theme missing a contract key fail `tsc`; Style Dictionary v5 DTCG level; Radix /
  React Aria maintenance (else Dialog/Menu stay native); Node LTS to pin (24 vs 26) and Corepack on Node ≥ 25.
- [ ] 12. Rust: cargo-mutants flags/exit codes, cargo-fuzz on stable vs nightly, Clippy restriction lint names,
  `build.warnings = "deny"` on the pinned toolchain — `cargo` on a fixture.
- [ ] 13. Python: ruff rule ids (S113, TID251…), import-linter contract keys, mutmut `export-cicd-stats`, pytest 9
  `[tool.pytest]` strict — run each on a fixture.
- [ ] 14. Eval hosts: `claude --json-schema` result field (harness reads `structured_output`, else `result`); Codex skill
  root (`.agents/skills` vs `$CODEX_HOME/skills`); Codex PreToolUse on `apply_patch`/`spawn_agent` actually denies —
  one cheap run each (haiku/smallest model, < USD 0.01).
- [ ] 15. Runtime of today's four verify-standard groups on a CI runner (is each < 2 min?) and of `make check-fast`
  (~100 s measured locally, near the limit) — one timed run.
