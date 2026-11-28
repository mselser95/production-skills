# db-postgres

Pins the database image as ONE tested pair: plain PostgreSQL 18.x and, when the
service has time-series data, the TimescaleDB image whose bundled PostgreSQL has
the same minor. Pinned by tag plus INDEX digest in `db/image.lock`, never `latest`.
PostgreSQL 19 is deliberately not used yet (liability `pg19-reevaluate`).

- `bash scripts/db-pin-check.sh [lock] [--compose file...] [--non-db-build svc...]` - the offline gate (no
  network, no Docker; wired into `make gates`). Exit 0 ok / 1 failed / 2 nothing checked.
  A compose file is PARSED (PyYAML, `scripts/db_pin_compose.py`); each service running `postgres` or
  `timescale/timescaledb` must equal the lock's `tag@index-digest`, a file with no such service fails, and
  `build:`, `extends:`, `include:`, a `$` in an image and duplicate YAML keys are refused. A service with
  `build:` is accepted only when the invoker names it with `--non-db-build`. A missing parser is exit 2.
- `bash scripts/tests/db-pin-check-selftest.sh` - selftest plus mutation proof (run by `make selftests`).
- `bash scripts/db-pin-verify-live.sh [--pull] [lock]` - OPT-IN, needs Docker, NOT in `make gates`. Starts each
  image (`--cpus 1 --memory 1g`, no ports, container `dbpin-<pid>-<key>`, always removed) and compares
  `SHOW server_version`, `SHOW data_directory` and the Timescale `default_version` with the lock. Exit 0 / 1
  mismatch / 2 docker absent, image not local (use `--pull`) or not startable.
  Its selftest (`scripts/tests/db-pin-verify-live-selftest.sh`, fake `docker`) runs in `make selftests`.

## The bootstrap test (Docker)

`bash scripts/db-bootstrap-test.sh [--variant plain|timescale]` starts the module's compose stack in a
throwaway project (`dbboot-<pid>`, always removed) and runs the SQL assertions (roles, SCRAM, TLS, settings,
timeouts, hba rule table, role memberships, connection limits, container capabilities, secrets, statistics and
log leaks, certificate renewal, persistence) against the real server. A fresh machine pulls the pinned images itself. It ends with
one line, `db-bootstrap-test: N assertions, N ok, 0 failed (<image>)`. Exit 0 pass / 1 an assertion failed or the
database never became healthy (the run ends right after the 30 s health wait) / 2 could not start.

- Locally: `make db-test` runs the plain image, then the Timescale variant, and stops at the first failure
  (about a minute, needs Docker). It is in no aggregate target (`check-fast`, `gates`, `selftests`).
- In CI: job `db` in `.github/workflows/pr.yaml` runs `make db-test` on `ubuntu-latest` (timeout 5 minutes).
  It always starts and reports; a first step diffs the pull request against its base and, when nothing under
  `prod-new/modules/db-postgres/`, the Makefile or the workflow changed, prints `db: skipped: no database change`
  and ends green (so a required check never hangs on a skipped job). Pushes to master always run it.
  `make gates` also runs `bash scripts/db-ci-wired.sh`, which PARSES `pr.yaml` (python3 + PyYAML; a missing
  parser is exit 2) and requires a job `db` with a step whose `run` is exactly `make db-test`, with no constant
  false `if` and no `continue-on-error` on that step or the job. (A grep for the line is satisfied by a comment.)
- GitHub runners are linux/amd64 and the lock's runtime facts were observed on arm64 only. The `db` job has
  run green once on `ubuntu-latest` (linux/amd64) for this module's pull request, at an earlier commit than
  the secrets, hardening and leak-check changes; it has NOT been observed on the current head, so nothing
  here claims the current test passes on amd64. The lock's runtime facts are still arm64-only.
- The stack needs its secret files first (`db/bootstrap/README.md`, "Secrets"); the test generates throwaway
  ones in a scratch directory.

## Monitoring (born monitored)

Every database this module creates ships with a metrics exporter, a list of metrics that MUST exist, alert
rules with tests, and a scrape test. All of it lives under `db/observability/` plus one additive overlay.

- `db/compose.observability.yml` - adds `exporter` (postgres_exporter, pinned by tag and index digest in
  `db/observability/image.lock`). Read-only root, `cap_drop: [ALL]`, `no-new-privileges`, uid 65534, limits, a
  healthcheck that needs `pg_up 1`, waits for a healthy `db`. It logs in as `app_monitor` (member of `pg_monitor`,
  not superuser) with `sslmode=verify-full`, the password only as a FILE (`db_monitor_password` secret). The
  port is NOT published: reach it on the compose network as `exporter:9187`, or opt in with an override file of
  your own that adds `ports: ["127.0.0.1:9187:9187"]`. Use it with
  `docker compose -f compose.yml [-f compose.timescale.yml] -f compose.observability.yml up -d`.
- `db/observability/required-metrics.txt` - the contract: names a scrape must contain, each with its reason.
  A name no alert uses must say `dashboard-only`.
- `db/observability/alerts/postgres.rules.yml` + `postgres.rules.test.yml` - 13 alerts (availability, exporter absent, collector
  failure, connections, replication lag, xid wraparound x2, dead tuples, long transactions, deadlocks,
  checkpoints, temp files, WAL size), each with severity, summary, description and a `runbook` annotation that
  points at a heading of `db/observability/RUNBOOK.md`; each has a firing and a non-firing `promtool` case.
- `bash db/observability/parity-check.sh` - offline, hermetic, python3 + PyYAML (exit 2 without it). Red when
  an alert uses a metric outside the contract, a required metric is orphaned, an alert lacks a firing or a
  non-firing test, severity/summary/description/runbook, or a runbook anchor; and when the overlay is not
  digest-pinned (or differs from the lock), not read-only / `cap_drop: [ALL]` / `no-new-privileges` / non-root,
  publishes a port, carries a password in the environment or URI, lacks a healthcheck, a needed collector or
  resource limits, has anything but exactly one `sslmode=verify-full` and one `sslrootcert`, or mounts the
  certificate read-write. It REFUSES (never guesses) a `__name__` matcher, a nameless selector, an unknown
  function and any `record:` rule, and runs `promtool check rules` when promtool is on PATH. `make db-test`
  runs it first. Thresholds marked TUNABLE (temp files, WAL size) are starting points; see the runbook.
- `bash scripts/db-scrape-test.sh [--mutate revoke-monitor] [--promtool]` - NEEDS DOCKER, not run by the
  selftest. Starts `db` + `exporter` as project `dbscrape-<pid>` with a 60 s budget (`DB_SCRAPE_BUDGET_S`),
  scrapes from the db container, and asserts `pg_up 1`, no failing collector, every required metric present,
  the port not on the host, that `app_monitor` is not superuser and cannot create or insert, that the RUNNING
  exporter's `DATA_SOURCE_URI` (docker inspect; only the `sslmode`/`sslrootcert` parameters are read) has
  exactly one `sslmode=verify-full` and a `sslrootcert`, and that its session is encrypted (`pg_stat_ssl`).
  Exit 0 pass, 1 a failed assertion, 2 nothing could be asserted, 3 and 4 only with `--mutate`.
  `--mutate revoke-monitor` revokes `pg_monitor` first and exits 1 only when the failures are the ones the revoke
  explains (wal/database collector, `pg_wal_size_bytes`); any other failure is exit 3; exit 4 means the mutation
  survived. `--promtool` also runs `promtool test rules` in the pinned Prometheus image (no network, read-only).
  Torn down with `down -v` of its own project on every exit path.
- `bash scripts/tests/db-observability-selftest.sh` - hermetic selftest and mutation proof of all of the above
  (fake `docker`); runs `promtool test rules` locally when a `promtool` is on PATH, else prints a SKIP.

Not proven offline: that the exporter image really emits the names in `required-metrics.txt` (several are marked
UNVERIFIED there), that its busybox has `wget` for the healthcheck, and that the `DATA_SOURCE_*` variables work
as written in v0.21.1. The scrape test is that proof; run it after every exporter bump.

## Bumping the pair

1. Edit `db/image.lock` (tags, index and per-platform digests, versions).
2. `bash scripts/db-pin-verify-live.sh --pull` - the lock's runtime facts against the real images.
3. Update `verified_utc`; `bash scripts/db-pin-check.sh` must print OK.
4. Then change the compose files / Dockerfiles to the same `tag@digest`
   (`db-pin-check.sh <lock> --compose <file>` compares them with the lock).

## What is and is not proven

- The runtime facts in the lock (server version, data directory, extension version) were observed on
  **linux/arm64 only**; linux/amd64 was not run. Re-verify on the deployment platform with the live script.
- Both images are **Alpine (musl)**. Moving data to a glibc image (Debian tags) changes collation behaviour
  and needs a reindex; that is a known limitation and is not solved here.
- The offline gate proves the lock is self-consistent and that compose files match it. Only the live script
  compares the lock with the real images, and it is a step a human runs.
- `make gates` passes both compose files (`db/compose.yml`, `db/compose.timescale.yml`) to `db-pin-check.sh`
  together with the lock, so a compose image that drifts from the lock is red offline.
- The bootstrap test (above) is what proves the compose stack itself starts and behaves. Its linux/amd64
  result on the current head has not been observed (see CI).
