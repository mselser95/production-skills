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
- No compose files exist in this module yet; once they land they must be passed to `db-pin-check.sh --compose`
  from `make gates` (and listed in `module.json`).
