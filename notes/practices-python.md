# Python backend services: current practices as CI-checkable gates (research dated 2026-11-27)

Format: PRACTICE -> why -> gate (command/key) -> source. Quotes are verbatim from pages fetched on 2026-11-27 (<=25 words).
Tags: [P] primary/official docs; [V] vendor docs (not neutral); [I] my inference, not a source claim.
Package "latest" versions come from pypi.org JSON (a primary registry record) fetched today.

## 1. Interpreter and build
1.1 Run a supported interpreter; fail CI when `requires-python` admits an EOL minor.
- Why: devguide table, fetched today: 3.15 bugfix (released 2026-10-09, EOL 2031-10), 3.14 bugfix (EOL 2030-10), 3.13 and 3.12 and 3.11 security-only (EOL 2029-10 / 2028-10 / 2027-10), 3.10 EOL 2026-10-01, 3.9 EOL 2025-10-31. Quote: "Five years after a release, support ends." Future EOL dates are italic = "scheduled and can be adjusted".
- Gate: parse `[project] requires-python` and assert its floor is >= oldest non-EOL minor (today >=3.11, and 3.11 dies 2027-10); CI matrix = every supported minor you claim. `ruff` infers `target-version` from it ("fall back to the minimum version compatible with the `requires-python` field") so one key drives lint, upgrade rules and the matrix.
- Src: https://devguide.python.org/versions/ [P]; https://docs.astral.sh/ruff/configuration/ [P]

1.2 Pin the interpreter in two places: `requires-python` (range, published metadata) and `.python-version` (exact, dev/CI/Docker). 
- Gate: `uv python pin` writes `.python-version`; CI asserts `.python-version` satisfies `requires-python` and equals the Docker base tag. uv: "The first Python version that is compatible with the requirement will be used, unless a version is otherwise requested".
- Src: https://docs.astral.sh/uv/concepts/python-versions/ [P]

1.3 Free-threaded build and JIT: a service should NOT depend on either today; add a compatibility canary at most.
- Free-threading: PEP 779 is Final, target 3.14; phases: I experimental (3.13), II "officially supported but remains optional", III default needs a separate PEP. 3.14 whatsnew: "Free-threaded Python is officially supported." HOWTO: "Some third-party packages, in particular ones with an extension module, may not be ready for use in a free-threaded build, and will re-enable the GIL." Overhead "about 1% on macOS aarch64 to 8% on x86-64 Linux"; more memory. 3.15 adds `abi3t` stable ABI for free-threaded builds (still needs `cp315t` wheels otherwise).
- JIT: 3.13 doc: build opt-in `--enable-experimental-jit`, "Performance improvements are modest". 3.14: Windows/macOS binaries include the experimental JIT. 3.15: "The experimental JIT compiler has been significantly upgraded." Still experimental: no production dependence.
- Gate: optional non-blocking matrix job on `3.15t`; detect with `sysconfig.get_config_var("Py_GIL_DISABLED") == 1` and `sys._is_gil_enabled()`; run tests with `PYTHON_GIL=0`/`-X gil=0` plus `-W error` to catch the "GIL re-enabled" warning [I: the warning text is in the HOWTO, the flag combo is mine].
- Src: https://peps.python.org/pep-0779/ ; https://docs.python.org/3/howto/free-threading-python.html ; https://docs.python.org/3/whatsnew/3.13.html ; https://docs.python.org/3/whatsnew/3.14.html ; https://docs.python.org/3/whatsnew/3.15.html [P]

1.4 `pyproject.toml` is the single config (project, deps, `[dependency-groups]`, ruff, mypy/pyright, pytest, coverage, deptry, import-linter). Specs: `[build-system]` `requires` is mandatory; `license` is an SPDX expression string (PEP 639: legacy `license` table and `License ::` classifiers deprecated).
- Gate: a "no stray config" check (no setup.cfg/tox.ini/.flake8/requirements*.in drift) [I]; `python -m build` + `twine check dist/*` (twine not fetched, see UNVERIFIED); `ruff check` flags nothing about it, so use `validate-pyproject` [UNVERIFIED].
- Src: https://packaging.python.org/en/latest/specifications/pyproject-toml/ [P]

1.5 src layout. "helps prevent accidental usage of the in-development copy of the code" (cwd is first on the import path). Tests then run against the installed package.
- Gate: tests run against an installed wheel (`uv build && uv pip install dist/*.whl` then `pytest`), or `-P`/`PYTHONSAFEPATH=1` ("don't prepend a potentially unsafe path"). Check: no top-level package dir next to `pyproject.toml`.
- Src: https://packaging.python.org/en/latest/discussions/src-layout-vs-flat-layout/ ; https://docs.python.org/3/using/cmdline.html [P]

1.6 Reproducible installs: install only from a lock, fail if the lock is stale.
- uv: `uv lock --check` ("equivalent to the `--locked` flag for other commands"); `uv sync --locked` / `uv run --locked` error instead of updating; `--frozen` = "use the lockfile without checking if it is up-to-date" (do NOT use in the gate). A newer upstream release does not make the lock outdated; only a pyproject change does.
- pip: `pip install --require-hashes -r requirements.txt` (see 2.1). pip-tools: `pip-compile --generate-hashes`. Poetry: `poetry check --lock`; `poetry install --sync` is deprecated ("use `poetry sync` instead"); `poetry export` is a plugin since Poetry 2.0.
- Src: https://docs.astral.sh/uv/concepts/projects/sync/ ; https://pip.pypa.io/en/stable/topics/secure-installs/ ; https://python-poetry.org/docs/cli/ ; https://pip-tools.pypa.io/en/stable/ [P]
- Caveat: the uv sync page did not itself document `--locked` for `uv sync` in the fetched text; `uv sync --locked` is used by uv's own Docker guide (see 9.5).

## 2. Dependencies and supply chain
2.1 Lock format status. PEP 751 `pylock.toml` is a published PyPA spec (first version April 2025, update March 2026). Quote: "for specifying dependencies to enable reproducible installation in a Python environment". Rules: `lock-version = "1.0"`; file named `pylock.toml` or `pylock.<name>.toml`; every archive/sdist/wheel needs a non-empty `hashes` table, sha256 recommended.
- Reality: `uv.lock` remains uv-specific; `uv export --format pylock.toml` exists ("the standardized Python lockfile format defined in PEP 751"). `pip lock` is "EXPERIMENTAL" and its output "is only guaranteed to be valid for the current python version and platform" (pip docs v26.3). Whether `pip install -r pylock.toml` works was NOT confirmed.
- Gate: keep the native lock (uv.lock/poetry.lock) as source of truth; also export `pylock.toml` (or hashed requirements) as the deploy artifact and verify hashes (`pip install --require-hashes`).
- Src: https://packaging.python.org/en/latest/specifications/pylock-toml/ ; https://docs.astral.sh/uv/concepts/projects/export/ ; https://pip.pypa.io/en/stable/cli/pip_lock/ [P]

2.2 Hash-pinning. pip: "It is possible to force the hash checking mode to be enabled, by passing `--require-hashes` command-line option." It is "all-or-nothing"; "Requirements must be pinned (either to a URL, filesystem path or using `==`)"; "To be safe, install your project using pip and `--no-deps`."
- Gate: `pip install --require-hashes --no-deps -r requirements.txt` in the image build; any unhashed line fails the build. Note pip 26.2 added `--no-require-hashes`, so grep CI for that flag.
- Src: https://pip.pypa.io/en/stable/topics/secure-installs/ [P]

2.3 Private index / dependency confusion.
- uv: default `first-index` "limiting the candidate versions to those present in the first index that contains the package"; `unsafe-best-match` "select[s] the best version from the combined set" and carries the risk (docs cite the `torchtriton` attack). Use `explicit = true` indexes plus `tool.uv.sources` pinning. Named indexes for pinning must be in pyproject.toml.
- pip has no equivalent: PEP 708 (tracks/alternate-locations metadata) is Rejected ("conditions for finalization were never met"). So `--extra-index-url` stays unsafe with pip.
- Gate: grep CI/Dockerfiles/requirements for `--extra-index-url`, `UV_INDEX_STRATEGY=unsafe-*`, `--index-strategy unsafe` -> fail; assert every internal package is pinned to its index in `[tool.uv.sources]`.
- Src: https://docs.astral.sh/uv/concepts/indexes/ ; https://peps.python.org/pep-0708/ [P]

2.4 Vulnerability audit. `pip-audit` (PyPA-maintained; created by Trail of Bits): default service PyPI advisory DB, also `-s osv`. Flags: `-r REQ`, `--locked` ("audit lock files from the local Python project"), `--strict`, `--require-hashes`. Exit 0 clean, 1 vulnerabilities; "exit code cannot be suppressed". Latest 2.10.1 (2026-06-10). OSV-scanner is an alternative (its page did not name supported lockfiles: UNVERIFIED).
- Gate: `pip-audit --strict --require-hashes -r requirements.txt` or `uv export --no-dev --format requirements-txt | pip-audit --strict -r /dev/stdin` [I: pipe form is mine]; run on a schedule too, because new CVEs appear without code change. The PSRT also publishes OSV-format advisories (psf/advisory-database).
- Src: https://github.com/pypa/pip-audit ; https://www.python.org/dev/security/ [P]

2.5 Unused/missing/transitive deps: `deptry .`. DEP002 "defined as a dependency but not used", DEP003 "imported but it is a transitive dependency", DEP004 "imported but declared as a dev dependency"; config `[tool.deptry]`, `per_rule_ignores`. Exit code and DEP001/DEP005 definitions not confirmed.
- Src: https://deptry.com/usage/ [P]

2.6 SBOM: `cyclonedx-py environment` (works for uv venvs: "manifest and lockfile are not explicitly supported" for uv), `cyclonedx-py requirements`, `poetry`, `pipenv`. Gate: SBOM generated and attached per release; `pip-audit` can also emit CycloneDX. Output flags UNVERIFIED.
- Src: https://github.com/CycloneDX/cyclonedx-python ; https://github.com/pypa/pip-audit [P]

2.7 Publishing: PyPI Trusted Publishing (OIDC): "eliminates the need to use manually generated API tokens"; minted token "only valid for 15 minutes". Attestations (PEP 740): "publicly verifiable proof that a package was published via a specific Trusted Publisher"; supported from GitHub Actions, GitLab CI/CD, Google Cloud; ActiveState does not produce them. `sigstore-python` (`sigstore sign`, `sigstore verify github`) needs Python >=3.11; Rekor v2 bundles need sigstore-python >=4.
- Gate: release workflow has `id-token: write`, no `PYPI_API_TOKEN`/`TWINE_PASSWORD` secret anywhere (grep); consumers verify provenance. 
- Src: https://docs.pypi.org/trusted-publishers/ ; https://docs.pypi.org/attestations/ ; https://github.com/sigstore/sigstore-python [P]

2.8 Typosquatting/malicious packages: no pip-level mitigation was found in primary sources. Real controls: allow-list via lock + hashes + `deptry` (new dep = visible diff), review of lock diffs, private mirror. PyPI blog today lists "Stricter checks for uploaded distributions on PyPI" (2026-11-18) but I did not read it. Treat "typosquat detector" gates as UNVERIFIED.

2.9 Update policy: Scorecard checks `Dependency-Update-Tool`, `Pinned-Dependencies` ("declare all your dependencies with specific versions"), `Vulnerabilities`, `Token-Permissions`, `Dangerous-Workflow`, `Signed-Releases`, `SAST`, `Fuzzing`, `SBOM`. Gate: `scorecard --repo=... --checks=Pinned-Dependencies,Token-Permissions,Dangerous-Workflow` [flag form UNVERIFIED]; Dependabot/Renovate config present [I]. Scorecard did not mention `pip --require-hashes` on its page.
- Src: https://github.com/ossf/scorecard/blob/main/docs/checks.md [P]

## 3. Static analysis and typing
3.1 ruff as the single linter+formatter. Exit codes: 0 clean, 1 violations, 2 "terminated abnormally, due to invalid configuration". Gates: `ruff check --no-fix .` [flag from my knowledge; page did not document it: UNVERIFIED] and `ruff format --check .` ("exit with a non-zero status code if any files would have been modified"). Ruff is "a linter, not a type checker".
- Recommended `lint.select` (config keys `lint.select`, `lint.extend-select`, `lint.ignore`, `lint.per-file-ignores`): F (Pyflakes), E/W, B (bugbear), S (flake8-bandit), ASYNC, UP (pyupgrade), PL (Pylint), RUF, DTZ (naive datetimes), T20 (print), BLE (blind except), TRY, PERF, LOG and G (logging), PT (pytest style), SIM, FAST (FastAPI). Per-file ignore `S101` for tests only.
- Default set: the fetched pages conflict (one page says the first five categories compose the default set and are preview-gated; the rules page says F, E, B, UP, RUF "as well as many more"). Do not rely on defaults: set `select` explicitly. [UNVERIFIED which is current]
- Src: https://docs.astral.sh/ruff/linter/ ; https://docs.astral.sh/ruff/rules/ ; https://docs.astral.sh/ruff/faq/ [P]

3.2 Type checking is a blocking gate. 
- mypy `--strict` enables: `--disallow-any-generics --disallow-subclassing-any --disallow-untyped-calls --disallow-untyped-defs --disallow-incomplete-defs --check-untyped-defs --disallow-untyped-decorators --warn-redundant-casts --warn-unused-ignores --warn-return-any --no-implicit-reexport --strict-equality --extra-checks`; NOT `--warn-unreachable` (add it). `--warn-unused-ignores` keeps suppressions honest.
- pyright: `typeCheckingMode` = off|basic|standard|strict (default standard); "In strict mode, most type-checking rules are enabled"; `strict = [paths]` key or `# pyright: strict` per file. That per-path list is the ratchet: grow `strict` module by module. mypy equivalent: per-module `[[tool.mypy.overrides]]` (`[mypy-<pattern>]`) with `disallow_untyped_defs = true`.
- Ratchet gate: strict on new/changed packages; baseline error count stored in repo and may only fall [I]. `py.typed` marker for libraries (spec not fetched: UNVERIFIED).
- ty (Astral): "An extremely fast Python type checker and language server, written in Rust", run `uvx ty check`; the page shows no stability statement and no strict mode, so do not make it the sole gate [I].
- Src: https://mypy.readthedocs.io/en/stable/command_line.html ; https://raw.githubusercontent.com/microsoft/pyright/main/docs/configuration.md ; https://docs.astral.sh/ty/ [P]

3.3 SAST. Bandit: "a tool designed to find common security issues in Python code" (AST + plugins), latest 1.9.4 (2026-02-25); ruff's `S` family ports flake8-bandit (the FAQ links that entry to an open issue, so coverage is partial; most S rules stable, S401-S415 preview). Use `S` for speed, bandit only if you need a rule `S` lacks [I]. CodeQL Python queries cover injection (SQL, command, code, template, regex), path/SSRF/redirect, XSS/CSRF/cookies, unsafe deserialization/XXE/entity expansion, weak crypto/TLS/cert validation, clear-text logging, Flask debug, Jinja2 autoescape. Semgrep CE: "Single-function taint analysis"; interprocedural, interfile and Django/Flask/FastAPI framework analysis are Pro (vendor) features: "will **fail** to return findings" on CE for framework-specific rules.
- Gate: `codeql` workflow (language python, `security-extended` suite [name UNVERIFIED]) blocking on error severity; `semgrep ci` or `semgrep --config p/python --error`; ruff `S`.
- Src: https://bandit.readthedocs.io/en/latest/ ; https://codeql.github.com/codeql-query-help/python/ ; https://docs.semgrep.dev/languages/python [P/V]

3.4 Architecture/boundaries: import-linter (`lint-imports`, contracts in `pyproject.toml` `[tool.importlinter]`: forbidden, layers, independence). I could not fetch its docs (404 on both URLs): contract names and keys are from memory = UNVERIFIED. Latest 2.17 (2026-11-18, requires Python >=3.11). Alternative for "no cross-context import": ruff `TID251` banned-api / `TID253` [I, UNVERIFIED].

## 4. Testing
4.1 pytest config in `pyproject.toml`. pytest 9.0 (2025-11-05) added native TOML `[tool.pytest]` and a `strict` option: "Added a "strict mode" enabled by the strict configuration option." (`[tool.pytest.ini_options]` still works, the two tables cannot be combined); 9.2.0 is latest in the changelog (2026-10-27); 9.0 dropped Python 3.9. Precedence: `pytest.toml` > `pytest.ini` > `pyproject.toml` ([tool.pytest]) > `tox.ini` > `setup.cfg`; "options from multiple candidate files are never merged".
- Gate keys: `strict = true` (else `--strict-markers --strict-config` and `xfail_strict = true`: "`strict_xfail` ... False by default" so set it), `filterwarnings = ["error", ...]` ("the action for the last matching option is performed", so put ignores AFTER `error`), `testpaths`, `minversion`. Exactly which sub-options `strict` bundles was not shown: UNVERIFIED.
- `-p no:cacheprovider` debate: no primary source found. CI runners are ephemeral so cache is moot; the cache is harmless in read-only containers only if `cache_dir` is writable [I].
- Order/flake control: `pytest-randomly` ("Shuffles test order"; reseeds `random`, Faker; `--randomly-seed=1234` reproduces, `-p no:randomly` disables); `pytest-xdist` `-n auto` (physical cores), `--dist loadscope|loadgroup|worksteal`. Always print the seed in CI logs [I].
- Src: https://docs.pytest.org/en/stable/reference/customize.html ; https://docs.pytest.org/en/stable/changelog.html ; https://docs.pytest.org/en/stable/how-to/capture-warnings.html ; https://github.com/pytest-dev/pytest-randomly ; https://pytest-xdist.readthedocs.io/en/stable/distribution.html [P]

4.2 coverage.py: `[tool.coverage.run] branch = true`, `source = ["pkg"]`, `parallel = true`, `concurrency = [...]` ("If your program uses multiprocessing, gevent, greenlet, or eventlet, you must name that library in this option, or coverage.py will produce very wrong results"), `patch = ["subprocess"]` ("Python sub-processes normally won't get coverage measurement"), `sigterm = true`, `dynamic_context = "test_function"` (per-test contexts). `[tool.coverage.report] fail_under = N` ("exit with a status code of 2"), `show_missing`, `skip_covered`, `exclude_also` (keeps default `pragma: no cover`). Flow: `coverage run -m pytest && coverage combine && coverage report`. Subprocess alt: `COVERAGE_PROCESS_START` + `coverage.process_startup()` via a `.pth`. Async: threads are the default concurrency; asyncio needs no entry [I]. Coverage is a weak oracle by itself: pair with mutation (4.4).
- Src: https://coverage.readthedocs.io/en/latest/config.html ; https://coverage.readthedocs.io/en/latest/subprocess.html [P]

4.3 Hypothesis. CI profile: `settings.register_profile("ci", ...)` + `settings.load_profile(...)`. Defaults on CI (documented): `derandomize` True ("seed ... using a hash of the test function"), `deadline` None (else 200 ms), `print_blob` True. `max_examples` default 100. Database default `.hypothesis/examples` (cache it between CI runs to replay failures). Stateful: `RuleBasedStateMachine` with `@rule`, `@initialize`, `@invariant` ("run after every step"), `@precondition`, `Bundle`; run via `MyMachine.TestCase`. The `pytest --hypothesis-profile` flag was not shown in the fetched text (UNVERIFIED, but widely used).
- Src: https://hypothesis.readthedocs.io/en/latest/reference/api.html ; https://hypothesis.readthedocs.io/en/latest/stateful.html [P]

4.4 Mutation testing. mutmut is maintained: PyPI 3.8.1 uploaded 2026-10-28, `requires_python >=3.10`; config `[tool.mutmut]` with `source_paths`, `pytest_add_cli_args_test_selection`, `do_not_mutate_patterns`; `mutmut run`, `mutmut browse`, `mutmut export-cicd-stats`; "Mutmut must be run on a system with fork support" (Windows only via WSL). cosmic-ray also maintained: 8.9.0 (2026-11-10), Python >=3.9, docs at cosmic-ray.readthedocs.org. Both are slow: use them on changed modules only, with the fast test subset [I]. Gate: mutation score on the diff >= threshold using `mutmut export-cicd-stats` (output schema UNVERIFIED).
- Src: https://github.com/boxed/mutmut ; https://pypi.org/pypi/mutmut/json ; https://github.com/sixty-north/cosmic-ray ; https://pypi.org/pypi/cosmic-ray/json [P]

4.5 Fuzzing: atheris (Google; libFuzzer, "Python versions 3.11-3.14" on Linux and macOS; PyPI 3.1.0; "fully supported by OSS-Fuzz"). Python 3.15 support not stated. Failure = uncaught exception, so fuzz parsers/deserializers/validators. Scorecard `Fuzzing` check rewards it. Gate: short time-boxed fuzz run per PR plus corpus regression replay [I].
- Src: https://github.com/google/atheris [P]

4.6 Real dependencies: testcontainers-python (`PostgresContainer("postgres:16")`, `get_connection_url()`; Ryuk env `TESTCONTAINERS_RYUK_DISABLED`; since 4.0 no separate `testcontainers-*` packages, and you must declare your own DB driver). Time control: `time-machine` (decorator `@time_machine.travel(...)`; page gives no comparison); freezegun last release 1.5.5 on 2025-08-09 (stale-ish, [I]). Snapshot tests: tool-specific (syrupy etc.), not researched.
- Gate: integration lane marker (`@pytest.mark.integration`, run with `-m integration`, strict markers on), no network in unit lane.

4.7 Dev-mode runtime checks in test runs: `python -X dev -W error -m pytest` (`-X dev` = "additional runtime checks that are too expensive to be enabled by default"; `-W error` / `PYTHONWARNINGS=error` converts warnings to exceptions). Catches ResourceWarning and never-awaited coroutines. `PYTHONHASHSEED`: random by default, fixed integer for reproduction.
- Src: https://docs.python.org/3/using/cmdline.html [P]

## 5. Async and concurrency
- Never block the loop: "Blocking (CPU-bound) code should not be called directly." Offload with `asyncio.to_thread` (propagates contextvars; "can typically only be used to make IO-bound functions non-blocking") or `loop.run_in_executor` (thread/process/Interpreter pool). Gate: ruff `ASYNC` rules (blocking calls in async def), plus `-X dev`/`asyncio.run(main(), debug=True)`: callbacks >100 ms are logged ("slow_callback_duration").
- Never-awaited coroutines: `RuntimeWarning: coroutine ... was never awaited`; ruff `RUF006` (store task refs) [I: rule id from memory]; with `-W error` it fails tests.
- Task references: "Save a reference to the result of this function, to avoid a task disappearing mid-execution"; docs prefer `TaskGroup`.
- Structured concurrency: `async with asyncio.TaskGroup()`; on a failing task "the remaining tasks in the group are cancelled", errors arrive as `ExceptionGroup` (use `except*`). 3.15 adds `TaskGroup.cancel`. 3.13 fixed nested-group cancellation bugs: another reason to run >=3.12/3.13.
- Cancellation: `CancelledError` "should generally be propagated when clean-up is complete"; TaskGroup and `asyncio.timeout()` "might misbehave if a coroutine swallows `asyncio.CancelledError`". Gate: ruff `BLE001`/`S110`/`TRY` plus a grep/semgrep rule for `except BaseException` or `except CancelledError` without `raise` [I].
- Deadlines: `async with asyncio.timeout(10)` (converts to `TimeoutError` outside the block) instead of ad-hoc `wait_for` [I]. Every outbound await needs one (see 6).
- 3.14 changes: default multiprocessing start method on Linux is now `forkserver` (unpicklable shared state breaks); `python -m asyncio ps PID` / `pstree PID` for live task introspection.
- Race detection: no equivalent of Go `-race` (see 11). Thread safety under free-threading is the developer's job ("It is generally not thread-safe to access the same iterator object from multiple threads concurrently").
- Deterministic async tests: pytest-asyncio / anyio / trio docs were NOT fetched: UNVERIFIED. Technique: inject clocks and fake time at the I/O boundary [I].
- Src: https://docs.python.org/3/library/asyncio-task.html ; https://docs.python.org/3/library/asyncio-dev.html ; https://docs.python.org/3/whatsnew/3.13.html ; /3.14.html ; /3.15.html [P]

## 6. Runtime correctness
- Boundary validation: pydantic v2 is lax by default ("By default, Pydantic will attempt to coerce values to the desired type when possible", `'123'` -> 123). Strict: `model_config = ConfigDict(strict=True)`, `Field(strict=True)`, `validate_python(strict=True)`, `StrictInt/StrictStr`. Gate: grep that every boundary model sets strict (custom check); `extra="forbid"` not confirmed on fetched page [UNVERIFIED].
- `assert` is not a runtime check: `-O` "Remove assert statements and any code conditional on the value of `__debug__`." Gate: ruff `S101` outside tests; OpenSSF guide has "Avoid Assertions In Production".
- Exceptions: ruff `BLE001`, `S110`, `TRY`; OpenSSF categories "Use Specific Exception Types", "Propagate Exceptions and Preserve Context", "Ensure Cleanup on Exceptions".
- Resources: context managers (`with requests.Session()`, `with open`). requests: "By default, requests do not time out unless a timeout value is set explicitly. Without a timeout, your code may hang for minutes or more." httpx: "raise a `TimeoutException` after 5 seconds of network inactivity" by default; `timeout=None` disables; four timeouts (connect/read/write/pool). Gate: ruff `S113` (requests without timeout) [rule id from memory: UNVERIFIED], and ban `timeout=None`.
- Retries: requests "does not retry failed connections" by default; use `urllib3.util.Retry(total=3, backoff_factor=0.1, status_forcelist=[502,503,504])` via `HTTPAdapter(max_retries=...)`. Docs example includes `allowed_methods={'POST'}`: retrying non-idempotent methods is a double-write risk, do not copy it [I]. Always bound count and total deadline.
- Encoding: 3.15 makes UTF-8 default ("independent of the system's environment"); still pass `encoding=` (ruff `PLW1514` [from memory]).
- Src: https://pydantic.dev/docs/validation/latest/concepts/strict_mode/ ; https://requests.readthedocs.io/en/latest/user/advanced/#timeouts ; https://www.python-httpx.org/advanced/timeouts/ ; https://best.openssf.org/Secure-Coding-Guide-for-Python/ -> https://github.com/ossf/python-secure-coding-guide [P]

## 7. Security-relevant coding (each: practice -> gate)
- OpenSSF guide categories (9): Neutralization ("Prevent SQL Injection", "Prevent OS Command Injection", "Extract Archives Safely", "Secure Deserialization"), Logging ("Exclude Sensitive Data From Logs"), Concurrency, Cryptography ("Use Sufficiently Random Values"), Numbers ("Use String Literals for Decimal Construction"). The guide has moved to github.com/ossf/python-secure-coding-guide; the repo labels "stable release" vs "development, unstable".
- SQL: bound parameters only. SQLAlchemy `bindparam`/`:name` (`connection.execute(stmt, {"username": "wendy"})`); `extract()` doc: "DO NOT PASS UNTRUSTED INPUT TO THIS STRING". Gate: ruff `S608`; CodeQL SQL injection; semgrep p/python.
- Commands: `subprocess` "will not implicitly choose to call a system shell"; with `shell=True` "it is the application's responsibility to ensure that all whitespace and metacharacters are quoted". Gate: ruff `S602`, `S603`, `S604`, `S605`.
- Deserialization: pickle "is not secure. Only unpickle data you trust" (arbitrary code execution); sign with `hmac` if you must. YAML: "`yaml.load` is as powerful as `pickle.load`"; use `yaml.safe_load`. 3.14 whatsnew confirms no change. Gate: ruff `S301` (pickle), `S506` (yaml.load) [ids from memory].
- XML: stdlib page lists billion laughs, quadratic blowup, decompression bomb; Expat <2.7.2 "may be vulnerable" (check `pyexpat.EXPAT_VERSION`); "By default, Expat itself does not access local files or create network connections." defusedxml is still the library for untrusted XML (README table still marks stdlib "Maybe" for entity bombs); its `defusedxml.lxml`/`cElementTree` are deprecated and `defuse_stdlib()` "should be avoided". Latest release listed 0.8.0 (2023): maintained but slow. Gate: ruff `S313`-`S320` (preview family), CodeQL XXE.
- Archives: tarfile default filter became `data` in 3.14 ("Previously, the default was equivalent to `fully_trusted`"); filters exist since 3.12, so pass `filter="data"` explicitly for older runtimes. Still: "None of the available filters blocks _all_ dangerous archive features. Never extract archives from untrusted sources without prior inspection." and filters "do not prevent denial-of-service attacks". 3.15 fixes more tarfile link CVEs (data filter normalizes symlink targets). Gate: ruff `S202` (tarfile.extractall) [from memory]; always set size/count limits.
- Passwords/crypto: `hashlib` doc: "Naive algorithms such as `sha1(password)` are not resistant against brute-force attacks"; "A good password hashing function must be tunable, slow, and include a salt"; salt >=16 bytes from `os.urandom`; PBKDF2 "hundreds of thousands of iterations of SHA-256" (as of 2022). `crypt` module was removed in 3.13 (replacements named: `hashlib`, bcrypt, argon2-cffi). Do not set `usedforsecurity=False` for secrets. Gate: ruff `S324` (weak hashes), `S303`.
- Constant-time compare: `hmac.compare_digest` "designed to prevent timing analysis by avoiding content-based short circuiting"; both args same type (`str` ASCII or bytes). Randomness for tokens: `secrets` module (docs not fetched: UNVERIFIED); ruff `S311` flags `random`.
- TLS: requests `verify=False` "will make your application vulnerable to man-in-the-middle (MitM) attacks"; default True. Gate: ruff `S501` (verify=False) [from memory]; CodeQL certificate validation.
- Templates: Jinja2 `Environment` autoescape is off unless set ("autoescaping is not yet enabled by default though this will most likely change"); `select_autoescape()` defaults `('html','htm','xml')`. Gate: ruff `S701`; CodeQL `jinja2 autoescape`.
- SSRF/path traversal/ReDoS/logging PII: covered by CodeQL (SSRF, path expression, regex injection, clear-text logging). No stdlib-only gate for ReDoS found: UNVERIFIED tool (recheck `re2`/`regex` timeouts).
- Web frameworks: FastAPI CORS: "None of `allow_origins`, `allow_methods` and `allow_headers` can be set to `['*']` if `allow_credentials` is set to `True`" (the page's own example violates this: do not copy it; gate = grep for `allow_origins=["*"]` with credentials). Django: `python manage.py check --deploy`; "You must never enable debug in production"; `SECRET_KEY = os.environ["SECRET_KEY"]`; `ALLOWED_HOSTS`, `CSRF_COOKIE_SECURE`, `SESSION_COOKIE_SECURE`. Request-size limits (Starlette/ASGI server) NOT verified; gunicorn `limit_request_line` page returned 404.
- Standards to cite in specs: OWASP ASVS 5.0.0 ("dated May 2025"; chapter "Encoding and Sanitization"); NIST SP 800-218 SSDF v1.1 (02/03/22).
- Src: https://docs.python.org/3/library/{subprocess,pickle,tarfile,xml,hashlib,hmac}.html ; https://pyyaml.org/wiki/PyYAMLDocumentation ; https://jinja.palletsprojects.com/en/stable/api/ ; https://github.com/tiran/defusedxml ; https://fastapi.tiangolo.com/tutorial/cors/ ; https://docs.djangoproject.com/en/stable/howto/deployment/checklist/ ; https://github.com/OWASP/ASVS ; https://csrc.nist.gov/pubs/sp/800/218/final [P]

## 8. Money and numerics
- Use `decimal.Decimal` built from strings: `Decimal(3.14)` gives `Decimal('3.140000000000000124344978758017532527446746826171875')` ("Construction from an integer or a float performs an exact conversion"). OpenSSF: "Use String Literals for Decimal Construction", "Specify Rounding for Numeric Conversions".
- Set context explicitly, never rely on global: default is `prec=28`, `ROUND_HALF_EVEN`, traps on Overflow/InvalidOperation/DivisionByZero; use `with localcontext(prec=..)`; `quantize(Decimal('.01'), rounding=ROUND_...)` (without `rounding` "the rounding mode of the current thread's context is used"). `round(x)` ignores context and ties-to-even. Enable `FloatOperation` trap (`c.traps[FloatOperation] = True`): then mixing float and Decimal raises (except equality/explicit conversion).
- Gate: ruff `RUF032` (Decimal from float literal) [id from memory]; test conftest sets FloatOperation trap [I]; pydantic: Decimal fields strict, wire format = decimal strings; or integer minor units with `int` (never float). Property test: sum of split parts == whole.
- Src: https://docs.python.org/3/library/decimal.html [P]

## 9. Observability and operations
9.1 Logging: structlog guidance: log "to unbuffered standard out", JSON in production and pretty output on a TTY, context-local loggers (`contextvars`) for one canonical line per request. Stdlib integration not covered by that page. Gate: ruff `T20` (no print), `LOG`/`G` (no f-string in logging calls), test that a secret fixture never appears in captured log output [I].
9.2 OpenTelemetry Python: traces Stable, metrics Stable, logs "Development" (as of the page). Instrumentations are separate packages `opentelemetry-instrumentation-*`; whether zero-code `opentelemetry-instrument` is current was NOT on the fetched page (UNVERIFIED). Gate: a test asserts a span/metric is emitted for each endpoint with an in-memory exporter [I].
9.3 Servers: uvicorn docs: process manager "run multiple processes in a resilient manner", gunicorn "probably the simplest way to run and manage Uvicorn"; `uvicorn.workers.UvicornWorker` is deprecated in favor of the `uvicorn-worker` package; `--reload` and `--workers` are mutually exclusive; `--limit-concurrency` is not supported under gunicorn; `--proxy-headers`/`--forwarded-allow-ips`: "Only trust clients you can actually trust!". Timeouts/graceful-shutdown flags and gunicorn defaults NOT confirmed (UNVERIFIED). Gate: smoke test sends SIGTERM during an in-flight request and asserts completion + exit 0 [I]; config lint that `forwarded-allow-ips` is not `*` [I].
9.4 Health/readiness: no primary source fetched: UNVERIFIED; gate = liveness has no dependency checks, readiness does [I].
9.5 Containers (uv guide): multi-stage, copy only the venv; `uv sync --locked --no-install-project` in a dependency layer; `UV_COMPILE_BYTECODE`, `UV_LINK_MODE=copy`, `UV_NO_DEV=1`; cache mount `--mount=type=cache,target=/root/.cache/uv`; pin the uv image (`ghcr.io/astral-sh/uv:0.13.10` in the example; digest pinning is "considered best practice"); `.venv` in `.dockerignore`. The uv page does NOT cover non-root: examples run as root. Env: `PYTHONDONTWRITEBYTECODE` ("won't try to write `.pyc` files"), `PYTHONUNBUFFERED` (= `-u`). Distroless/slim/non-root guidance: NOT fetched (UNVERIFIED). Gate: hadolint [not fetched] + a grep for `USER`, no `pip`/compilers in final stage, base image pinned by digest, `uv sync --locked`.
- Src: https://docs.astral.sh/uv/guides/integration/docker/ ; https://docs.python.org/3/using/cmdline.html ; https://www.structlog.org/en/stable/logging-best-practices.html ; https://opentelemetry.io/docs/languages/python/ ; https://uvicorn.dev/deployment/ [P]

## 10. Performance
- Regression gate: `pytest-benchmark`: `--benchmark-save NAME` / `--benchmark-autosave`, `--benchmark-compare` (default: latest saved run), `--benchmark-compare-fail=EXPR` with `min:5%` or `mean:0.001` (seconds), repeatable. Wall-clock benchmarks are noisy on shared CI runners [I]. pytest-codspeed [V]: `@pytest.mark.benchmark`, `pytest tests/ --codspeed`; CI mode `simulation` via `CodSpeedHQ/action@v5`; "API is backward compatible with pytest-benchmark"; needs `id-token: write`, and results are reported in the vendor service, not locally ("no performance reporting" locally).
- Profiling: `py-spy` (`record`, `top`, `dump`): "without restarting the program or modifying the code"; in containers needs `SYS_PTRACE` (Kubernetes drops it by default); supports CPython 3.3-3.15; macOS needs root. 3.15 adds sampling profiler `profiling.sampling` with PID attach and frame pointers on by default (PEP 831); `cProfile` stays, `profile` module deprecated (removal 3.17). Memory: tracemalloc/memray not researched (UNVERIFIED).
- Src: https://pytest-benchmark.readthedocs.io/en/latest/usage.html ; https://codspeed.io/docs/benchmarks/python [V] ; https://github.com/benfred/py-spy ; https://docs.python.org/3/whatsnew/3.15.html [P]

## 11. Dimension -> Python mechanism -> gate; and gaps
| Dimension | Python mechanism | Gate command / key |
|---|---|---|
| Structural correctness/coverage | coverage.py branch | `coverage run -m pytest; coverage combine; coverage report` with `fail_under` |
| Mutation testing | mutmut (alt cosmic-ray) | `mutmut run` + `mutmut export-cicd-stats`, threshold on changed files |
| Invariants/property tests | Hypothesis, stateful machines | `pytest --hypothesis-seed`/CI profile (derandomize on CI) |
| Failure-mode scenarios | pytest + fault-injecting fakes, `-X dev -W error` | `python -X dev -W error -m pytest -m scenario` |
| Integration/contract | testcontainers-python | `pytest -m integration` |
| Perf and capacity | pytest-benchmark / codspeed | `--benchmark-compare-fail=mean:5%` |
| Resilience/recovery | timeouts+bounded retries, SIGTERM smoke | grep for missing timeout, ruff S113 |
| Observability | OTel + structlog | in-memory exporter test; ruff T20/LOG |
| Security | ruff S, bandit, CodeQL, semgrep, pip-audit | each exits non-zero |
| Deployability | multi-stage uv Docker | `docker build` + hadolint [UNVERIFIED] |
| Reproducibility | lock + hashes | `uv lock --check`, `uv sync --locked`, `pip install --require-hashes` |
| Scalability | uvicorn/gunicorn workers | load test (no Python-specific tool researched) |
| Bounded auto-recovery | process manager restart caps | k8s/systemd config check, not Python |
| Published contracts | OpenAPI from FastAPI/pydantic | diff exported schema in CI (tool UNVERIFIED) |
| Data lifecycle/schema evolution | Alembic [not fetched] | migration up/down test [UNVERIFIED] |
| Wiring | DI container or composition root test | import-time smoke: construct app, hit `/ready` |
| Progressive delivery, chaos, SLO, soak | platform-level | not Python-specific |
| SAST/dataflow | CodeQL, semgrep (taint), ruff S | see 3.3 |
| Consumer-driven contracts | Pact-python [not fetched] | UNVERIFIED |
| Dependency currency/pinning | uv/pip-tools/Poetry + pip-audit + Scorecard | see 2.x |
| Domain boundaries | import-linter, ruff TID | `lint-imports` |
| Overload/metastability | load shedding in ASGI server/middleware | no off-the-shelf gate found |
| Deterministic simulation | none | see below |

No good off-the-shelf mechanism today (my assessment [I], not a sourced claim; I searched no primary source asserting absence):
- Race detection: no `-race`. Substitutes: free-threaded canary job, `-X dev`, thread-hammer tests with `sys.setswitchinterval(1e-6)` [I], TSan-built CPython (not researched), single-threaded event-loop design + immutability.
- Deterministic simulation: none like FoundationDB/Antithesis-style for Python. Substitutes: inject clock/random/IO ports, Hypothesis stateful tests with a fake network, seeded `pytest-randomly`.
- Goroutine-leak checks: partial via `-W error` (ResourceWarning/never-awaited) and asyncio debug.
- Typed lock-free guarantees, `go vet`-grade nil analysis: type checker strict + `warn-unreachable` only.
- Fast mutation testing: slow and fork-only (mutmut), so diff-scoped.

## 12. What changed recently (older advice that is now wrong)
- Python 3.9 EOL 2025-10-31 and 3.10 EOL 2026-10-01; 3.15 is released (2026-10-09). Advice "support 3.8/3.9/3.10" is stale. pytest 9 dropped 3.9.
- PEP 751 `pylock.toml` exists: "requirements.txt is the only portable lock" is outdated, though pip's support is experimental and `uv.lock` is still richer.
- PEP 708 dependency-confusion mitigation was rejected: do not wait for pip to fix `--extra-index-url`.
- tarfile: default filter is `data` from 3.14; older "always pass `filter=`" is still right for <3.14 but "tarfile is safe now" is wrong.
- 3.13 removed 19 "dead batteries" including `cgi`, `crypt`, `telnetlib`, `pipes`; stale code using them fails on import.
- Free-threading moved from experimental (3.13) to supported-optional (3.14); JIT still experimental through 3.15.
- 3.14: deferred annotations (PEP 649, `from __future__ import annotations` no longer needed for forward refs), t-strings (PEP 750, injection-safe templating hook), `forkserver` default start method on Linux, incremental GC reverted (3.14.5).
- 3.15: lazy imports (`lazy` keyword, PEP 810; failures surface at first use), UTF-8 default I/O, `TaskGroup.cancel`, `.pth` `import` lines deprecated (PEP 829).
- ruff now ships categories/preview naming and is explicitly paired with a separate type checker; ty exists (no stability statement seen).
- pytest 9: native `[tool.pytest]` TOML and `strict` option; `ini_options` is the legacy table.
- Poetry 2.0: `poetry export` is a plugin; `install --sync` deprecated. Gunicorn docs moved to gunicorn.org; uvicorn docs to uvicorn.dev; pydantic docs moved to pydantic.dev/docs (old URLs 301).
- pip 26.2: `--no-require-hashes` added; hash enforcement may be automatic in some contexts.
- OpenSSF Python secure-coding guide moved to its own repo. ASVS 5.0.0 (May 2025) replaces 4.x.

## UNVERIFIED (what I could not confirm; what I tried)
- import-linter contract types/keys: both doc URLs returned 404. Only PyPI version (2.17) confirmed.
- pyright: the microsoft.github.io page rendered only the title; used raw configuration.md instead. The exact strict-only rule list was not extracted.
- Ruff default rule set: two fetched pages disagree; exact current default not established. `--no-fix` flag, rule ids S113/S202/S301/S313-320/S324/S501/S608/S701/RUF006/RUF032/PLW1514/TID251 are from memory, not fetched.
- pytest `strict` option contents, `-p no:cacheprovider` rationale: no primary text found.
- Hypothesis `--hypothesis-profile` pytest flag: not in the fetched portion.
- Python 3.14/3.15 "Removed" and "Deprecated" sections: fetch truncated; not read in full.
- pip `install -r pylock.toml` support; uv `sync --locked` doc text; OSV-scanner supported files and flags.
- PyPI anti-typosquat/malware controls: the blog listing had no such post titles; "Stricter checks for uploaded distributions" (2026-11-18) not opened.
- OTel zero-code `opentelemetry-instrument` command; structlog stdlib integration; uvicorn graceful-shutdown/keep-alive/limit flags; gunicorn defaults (page 404 after redirect); health/readiness guidance; Docker non-root/distroless guidance; hadolint; Starlette/FastAPI request-size limits; django CSRF specifics.
- time-machine vs freezegun comparison, freezegun maintenance beyond PyPI date; pytest-asyncio/anyio/trio docs; testcontainers supported Pythons; atheris Python 3.15 support and latest release date.
- tox/nox, hatch, `py.typed` spec, `validate-pyproject`, twine, Alembic, Pact, Scorecard CLI flags, SLSA, license-check tools (pip-licenses etc.), tracemalloc/memray, ReDoS tooling, `secrets` module doc.
- cyclonedx-py output flags/spec versions: README lacked them.
- Semgrep and CodeQL "what they realistically find": only capability tables were read, not empirical detection rates.

## SOURCES (date shown on page, else "no date shown"; all fetched 2026-11-27)
- https://devguide.python.org/versions/ (no date shown; table lists 3.15 released 2026-10-09)
- https://docs.python.org/3/whatsnew/3.13.html, /3.14.html, /3.15.html (no date shown)
- https://docs.python.org/3/library/{tarfile,asyncio-task,asyncio-dev,subprocess,pickle,decimal,hmac,hashlib,xml}.html ; https://docs.python.org/3/using/cmdline.html ; https://docs.python.org/3/howto/free-threading-python.html (no date shown)
- https://peps.python.org/pep-0779/ (accepted 16-Jun-2025); https://peps.python.org/pep-0708/ (no date shown, Rejected)
- https://www.python.org/dev/security/ (no date shown)
- https://packaging.python.org/en/latest/specifications/pylock-toml/ (history: April 2025, March 2026); /specifications/pyproject-toml/ ; /discussions/src-layout-vs-flat-layout/ (no date shown)
- https://pip.pypa.io/en/stable/topics/secure-installs/ ; https://pip.pypa.io/en/stable/cli/pip_lock/ (pip v26.3 header); https://pip-tools.pypa.io/en/stable/ (no date shown)
- https://docs.pypi.org/trusted-publishers/ ; https://docs.pypi.org/attestations/ ; https://blog.pypi.org/ (posts dated 2026-11-18, 2026-11-06, 2026-10-16)
- https://pypi.org/pypi/{mutmut,cosmic-ray,atheris,pip-audit,bandit,freezegun,time-machine,import-linter}/json (upload times as quoted above)
- https://docs.astral.sh/uv/{concepts/projects/sync,concepts/projects/export,concepts/indexes,concepts/python-versions,guides/integration/docker}/ ; https://docs.astral.sh/ruff/{linter,rules,configuration,faq}/ ; https://docs.astral.sh/ty/ (page date "November 26, 2026")
- https://github.com/pypa/pip-audit ; https://github.com/sigstore/sigstore-python ; https://github.com/CycloneDX/cyclonedx-python ; https://github.com/boxed/mutmut ; https://github.com/sixty-north/cosmic-ray ; https://github.com/google/atheris ; https://github.com/tiran/defusedxml ; https://github.com/adamchainz/time-machine ; https://github.com/pytest-dev/pytest-randomly ; https://github.com/benfred/py-spy ; https://github.com/ossf/python-secure-coding-guide ; https://best.openssf.org/Secure-Coding-Guide-for-Python/ ; https://github.com/ossf/scorecard/blob/main/docs/checks.md ; https://github.com/OWASP/ASVS (no dates shown; ASVS 5.0.0 "May 2025")
- https://csrc.nist.gov/pubs/sp/800/218/final (02/03/22)
- https://mypy.readthedocs.io/en/stable/command_line.html ; https://raw.githubusercontent.com/microsoft/pyright/main/docs/configuration.md ; https://bandit.readthedocs.io/en/latest/ ; https://codeql.github.com/codeql-query-help/python/ ; https://docs.semgrep.dev/languages/python [V] ; https://deptry.com/usage/ (no date shown)
- https://docs.pytest.org/en/stable/{reference/customize,changelog,how-to/capture-warnings}.html (9.x release dates up to 2026-10-27); https://coverage.readthedocs.io/en/latest/{config,subprocess}.html ; https://hypothesis.readthedocs.io/en/latest/{reference/api,stateful}.html ; https://pytest-xdist.readthedocs.io/en/stable/distribution.html ; https://pytest-benchmark.readthedocs.io/en/latest/usage.html ; https://testcontainers-python.readthedocs.io/en/latest/ ; https://codspeed.io/docs/benchmarks/python [V] (no dates shown)
- https://pydantic.dev/docs/validation/latest/concepts/strict_mode/ ; https://requests.readthedocs.io/en/latest/user/advanced/ ; https://www.python-httpx.org/advanced/timeouts/ ; https://docs.sqlalchemy.org/en/20/core/sqlelement.html ; https://pyyaml.org/wiki/PyYAMLDocumentation ; https://jinja.palletsprojects.com/en/stable/api/ ; https://fastapi.tiangolo.com/tutorial/cors/ ; https://docs.djangoproject.com/en/stable/howto/deployment/checklist/ (Django 6.1 docs) ; https://opentelemetry.io/docs/languages/python/ ; https://www.structlog.org/en/stable/logging-best-practices.html ; https://uvicorn.dev/deployment/ ; https://python-poetry.org/docs/cli/ (no dates shown)
