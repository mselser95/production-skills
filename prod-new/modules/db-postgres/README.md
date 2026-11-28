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
- In CI: job `db` in `.github/workflows/pr.yaml` runs `make db-test` on `ubuntu-latest` (timeout 10 minutes).
  It always starts and reports; a first step diffs the pull request against its base and, when nothing under
  `prod-new/modules/db-postgres/`, the Makefile or the workflow changed, prints `db: skipped: no database change`
  and ends green (so a required check never hangs on a skipped job). Pushes to master always run it.
  `make gates` also runs `bash scripts/db-ci-wired.sh`, which PARSES `pr.yaml` (python3 + PyYAML; a missing
  parser is exit 2) and claims exactly this: job `db` has the change-detection step (id `changed`) EQUAL to the text
  pinned in the script (its `env` and whole `run`; only `name` is free), the PyYAML and image pre-pull steps before
  the gate, and one `make db-test` step whose `run` is exactly `make db-test`, whose `if` is exactly
  `steps.changed.outputs.run == 'true'` (and that step runs before it), and which carries only
  `name`/`run`/`if`/`id`/`timeout-minutes`; earlier steps carry only `name`/`uses`/`with`/`run`/`if`/`id`/`env`/
  `continue-on-error` with no `MAKE*`/`SHELL`/`PATH` env and no `GITHUB_ENV`/`GITHUB_PATH` write; the job carries only
  `name`/`runs-on`/`timeout-minutes`/`steps`, with `timeout-minutes` >= 10. Not judged: shell in EARLIER steps (a
  step that rewrites the Makefile or a dotfile) and third-party `uses:` actions before the gate; review covers
  those. If the change-detection step is edited on purpose, the pin is a one-line update in `scripts/db-ci-wired.sh`
  (`CHANGED_PIN`). (A grep for the line is satisfied by a comment.)
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
  port is NOT published: reach it on the compose network as `exporter:9187`, or opt in with a file of
  your own OUTSIDE `db/`, passed as one more `-f` (any other compose-named file inside `db/` is refused; a file you pass from OUTSIDE `db/` is never read by `parity-check.sh`, so what it adds is your responsibility), that adds `ports: ["127.0.0.1:9187:9187"]`. Use it with
  `docker compose -f compose.yml [-f compose.timescale.yml] -f compose.observability.yml up -d`. Keep no `.env`
  in `db/`: compose loads it on its own and would substitute `${VAR}` from it, so `parity-check.sh` refuses one.
  THE GUARANTEE (it is about files): no file under `db/` - whatever its name or extension, at any depth - defines
  the exporter service other than the overlay, and no compose-shaped file exists there beyond the three listed; a
  directory reached through a symbolic link is refused; so any `docker compose` command that only names files under
  `db/` gets the pinned exporter. A file from OUTSIDE `db/` passed with `-f`, or a compose file fed on stdin, is
  outside what this check reads and is the caller's responsibility. `parity-check.sh` enforces it by walking `db/`
  recursively and judging EVERY regular file by its content, because compose merges any file passed with `-f`,
  whatever it is called, and JSON is YAML. EVERY `.yml`/`.yaml` file (any case, any depth), compose or not, must be
  a single plain YAML document (no tags, no merge keys, no duplicate keys) and is loaded with a strict loader, so
  that what the check reads is exactly what compose merges; one that cannot be read is `COMPOSE-UNREADABLE-FILE`
  (for the three listed files this exits 2, fail closed). Files with any other name are read leniently, only to
  find compose-shaped content: all documents of a multi-document stream, unknown tags (`!override`, `!reset`) and
  merge keys accepted. A file that does not parse is read once more with every TAB that is not leading
  indentation replaced by one space (PyYAML rejects `a: 1<TAB># c`, compose's parser accepts it); if it parses then,
  it is judged like any other file (and a finding says "read after replacing tabs, as compose does"). Skipped
  without a finding: binary files (a NUL byte in the first 8 KiB; UTF-16 with a BOM is text), files that are not
  UTF-8 (compose rejects both), and files that parse neither way when they are PROSE or a SCRIPT: a line that starts
  with three backticks or three tildes (Markdown) or a first line `#!`. The reason is one premise: a YAML parser
  rejects such a line at column 0 after a mapping (checked for PyYAML here; compose's Go parser is not run by
  this check), so compose could not merge that file either. Every other file that parses neither way and has a
  line at COLUMN 0 starting `services:`, `"services":` or `include:` (the top-level keys of a block-style compose
  document), or starts with `{` and has such a key, is `COMPOSE-UNREADABLE-FILE` (fail closed: it looks like a
  compose file and cannot be read). Consequences, on purpose: a SQL file or text file with a column-0 `services:`
  line and no fence is refused; so is a `.properties`-style file with a `services:` line, a plain-text note with a
  column-0 `services:` line, and a Markdown file WITHOUT a code fence around its snippet; a file of a different kind
  with a top-level `services` mapping (a Helm `values.yaml`, say) is a compose-shaped file and is refused: keep such
  files outside `db/`. A refusal names the line of the key and, when the parser reports one, the line of its error
  (never the line's text); if the file is not a compose file, move it out of `db/` or rename that key. A file over
  1 MiB is not parsed unless a line starts `services:` / `"services":` / `include:` at ANY indentation (the whole file
  is scanned as text, cheap; a dump starting `include/x.sql` is not a key) or its first significant character is `{`;
  one that has one is parsed in full and judged the same way, except that when it does not parse it is refused only
  if the key line has the smallest indentation among the non-blank, non-comment lines of its first 64 KiB (a
  top-level key of an indented document), else it is skipped (a `    services: text` line deep in a SQL dump is not
  a compose key). Cost: a compose-shaped text file is parsed in pure Python at about 4 s per MiB, so a large
  generated YAML under `db/` slows every check; keep large generated files out of `db/`. Over 64 MiB a file is not read at all and is
  `COMPOSE-UNCHECKED-FILE` (fail closed). A FIFO, socket or device is NOT skipped: it is reported as
  `COMPOSE-UNREADABLE-FILE` (not read, so no hang). Limits: other differences between PyYAML and compose's parser
  (`%TAG` directives, scalars that start with a reserved indicator, `{{ }}`) are NOT covered by this check. A document with
  a `services` mapping (or null) or a top-level `include` is compose-shaped: it may not define a service the overlay
  defines (`BASE-EXPORTER`, whatever the file is called), and must be one of `compose.yml`, `compose.timescale.yml`,
  `compose.observability.yml` at those exact paths (else `COMPOSE-UNKNOWN-FILE`). YAML that is not compose-shaped
  (the Prometheus alert rules and their tests) is left alone. A link to a directory is `COMPOSE-SYMLINK-DIR` (the
  walk does not enter it: put the files under `db/` or remove the link); a link to a file is judged by its target's
  content, and a finding names the target; a dangling link is refused. Compose-named files outside the list, the
  auto-merged names (`compose.override.y[a]ml`, `docker-compose*.y[a]ml`, `compose.yaml`) and a compose-named link
  that is not a regular file are refused by name as well.
  The documented commands are a LINT, not the guarantee: `COMPOSE-DOC-FILE` refuses the spellings it knows in every
  `*.md` under `db/`, this README, the compose files' comments and the two container scripts: more than three `-f`
  pairs or a `-f` file off the list, `--file`, `-fFILE`, `--profile`, `--project-directory`, `--env-file`, `-p`, a
  path or `./` before a file name, the compose environment variables, `docker-compose`/`podman`/`nerdctl`, and any
  global docker flag between `docker` and `compose` (write `docker compose` with no global flags). It cannot read
  variables, command substitution, `"$@"`, or a command wrapped over a plain newline (only a `\` continuation is
  joined). Two costs for a doc author: write `logs --follow`, not `logs -f`; and a `-f`/`-p`/`--file` that belongs to
  an inner command (`exec db psql -f x.sql`, `run -p 9187:9187`) is refused too, so put such commands in a script,
  not in a documented compose line. `db-scrape-test.sh` and `db-bootstrap-test.sh` are check scripts whose edits are
  out of the trust model: the check keeps their two command constructions and their `-f "$dbdir/..."` files as a
  lint, but their own file lists are not a guarantee surface.
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
  certificate read-write. The exporter's command, variables, entrypoint and mounts must lie within
  `db/observability/exporter-allowlist.txt` (an ALLOW-list, one entry per line with its reason): any other flag
  (`--datasource.uri`, `--config.file`, ...), variable (`DATA_SOURCE_URI_FILE`, `DATA_SOURCE_NAME`, `PG*`), an
  overridden entrypoint or an extra mount is red. Variables are pinned as exact `NAME=VALUE` pairs (no value is a
  slot: `exporter.env` is a literal), mounts as `source destination` pairs, and the monitor secret's file in
  `compose.yml` is pinned too. What compose could take from anywhere but the overlay is refused, and only this:
  in the overlay, a `$` (also `$$`) in the exporter's command, environment, `env_file` (path and contents), volumes, secrets,
  entrypoint, image or user (`OVERLAY-INTERPOLATION`), `extends`, a top-level `include`, any top-level key but `services`, a second service, and `extra_hosts` / `dns` /
  `links` / `network_mode` / `networks` on the exporter (`OVERLAY-NETWORK`), which could re-point the name `db`; in EVERY other compose file of `db/` (`compose.yml`, `compose.timescale.yml`, any compose-named file), ANY `exporter` service (even `{}`), an `extends`
  aimed at the overlay and an `include` (`BASE-EXPORTER`, naming the file: compose merges a service key by key across files, so the
  exporter is defined in the overlay alone); in `db/`, a `.env` (`OVERLAY-DOTENV`) and the files compose merges or
  picks up by itself (`compose.override.y[a]ml`, `docker-compose[.override].y[a]ml`, `compose.yaml`:
  `OVERLAY-OVERRIDE-FILE`). The connection URI is floored apart from the allow-list: host `db`, port 5432, a plain
  database name and only `sslmode=verify-full` and `sslrootcert=/tls/server.crt` (`OVERLAY-URI`). It REFUSES (never guesses) a `__name__` matcher, a nameless
  selector, an unknown function, a keyword where an operand belongs (a series named `offset`), a `query`
  template in an annotation and any `record:` rule, understands subqueries `[5m:1m]`, and runs `promtool check rules` when promtool is on PATH. `make db-test`
  runs it first. Thresholds marked TUNABLE (temp files, WAL size) are starting points; see the runbook.
- `bash scripts/db-scrape-test.sh [--mutate revoke-monitor] [--promtool]` - NEEDS DOCKER, not run by the
  selftest. Starts `db` + `exporter` as project `dbscrape-<pid>` with a 60 s budget (`DB_SCRAPE_BUDGET_S`),
  scrapes from the db container, and asserts `pg_up 1`, no failing collector, every required metric present,
  the port not on the host, that `app_monitor` is not superuser and cannot create or insert, that the RUNNING
  exporter's `DATA_SOURCE_URI` (docker inspect; only the `sslmode`/`sslrootcert` parameters are read) has
  exactly one `sslmode=verify-full` and a `sslrootcert`, that its session is encrypted (`pg_stat_ssl`), and that
  the RUNNING exporter's command, entrypoint, variables (exact `NAME=VALUE`; only names are ever printed) and mount destinations are within
  the same `exporter-allowlist.txt` (`exporter-args-allowlisted`, `exporter-env-allowlisted`,
  `exporter-mounts-expected`; one `docker inspect`).
  Exit 0 pass, 1 a failed assertion, 2 nothing could be asserted, 3 and 4 only with `--mutate`.
  `--mutate revoke-monitor` revokes `pg_monitor` first and exits 1 only when the failures are the ones the revoke
  explains (wal/database collector, `pg_wal_size_bytes`); any other failure is exit 3; exit 4 means the mutation
  survived. `--promtool` also runs `promtool test rules` in the pinned Prometheus image (no network, read-only).
  Torn down with `down -v` of its own project on every exit path.
  The real scrape runs `compose.yml` + `compose.observability.yml` only. The documented Timescale combination
  (`compose.yml` + `compose.timescale.yml` + the overlay) is held by `parity-check.sh` alone (the closed list, and
  no other file may touch the exporter); no second real-container variant runs, because it would double the CI time.
- `bash scripts/tests/db-observability-selftest.sh` - hermetic selftest and mutation proof of all of the above
  (fake `docker`); runs `promtool test rules` locally when a `promtool` is on PATH, else prints a SKIP. Every
  mutant is paired with an unmutated control that must be green first, else `its control is not green`; a mutant
  that dies of a shell error (`unbound variable`, `command not found`, a signal) is reported as crashed, not RED.

Not proven offline: that the exporter image really emits the names in `required-metrics.txt` (several are marked
UNVERIFIED there), that its busybox has `wget` for the healthcheck, and that the `DATA_SOURCE_*` variables work
as written in v0.21.1. The scrape test is that proof; run it after every exporter bump. The `image-env`,
`entrypoint` and `mount` entries of `exporter-allowlist.txt` passed on real v0.21.1 containers in the third
review (2026-11-28); a mismatch on a later image prints the real name or destination, and the entry is corrected
deliberately.

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
