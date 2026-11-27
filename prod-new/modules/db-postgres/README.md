# db-postgres

Pins the database image as ONE tested pair: plain PostgreSQL 18.x and, when the
service has time-series data, the TimescaleDB image whose bundled PostgreSQL has
the same minor. Pinned by tag plus digest in `db/image.lock`, never `latest`.
PostgreSQL 19 is deliberately not used yet (liability `pg19-reevaluate`).

- `bash scripts/db-pin-check.sh [lock] [--compose file...]` — static gate, exit 0 ok / 1 failed / 2 nothing checked.
- `bash scripts/tests/db-pin-check-selftest.sh` — selftest plus mutation proof.
- Bump: re-run the commands at the top of `db/image.lock`, change both halves and the date together.
