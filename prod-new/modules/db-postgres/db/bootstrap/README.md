# bootstrap — what runs before migrations

The image's init mechanism (`/docker-entrypoint-initdb.d`) runs these files ONCE,
when the data directory is empty, against a temporary server. Everything here is
idempotent, so it can also be re-run by hand against a live database.

| File | What it does |
|---|---|
| `tls-init.sh` | one-shot container: self-signed DEVELOPMENT certificate into the `dbtls` volume; regenerated when absent or expiring within 30 days (never committed; production mounts a real one at the same paths and does not run this) |
| `10-roles.sh` + `roles.sql` | the role split, the `app` schema, grants, default privileges, per-role `search_path` and timeouts, and the passwords. `10-roles.sh` pipes the four passwords (read from `/run/secrets/*`) to psql's stdin and `roles.sql` sets each with `\password`, which sends only the SCRAM-SHA-256 verifier |
| `20-extensions.sql` | `pg_stat_statements` |
| `timescale/30-timescaledb.sql` | `timescaledb`, Timescale variant only |
| `99-final.sql` | last: `pg_stat_statements_reset()` so the statistics start empty |

## Secrets

Five files in `db/secrets/` (git-ignored; `secrets/*.example` are the tracked templates), mounted by Compose
`secrets:` at `/run/secrets/db_{superuser,migrator,app,readonly,monitor}_password`. No password is in the
container environment, so `docker inspect` and `/proc/<pid>/environ` show none (asserted by the test).
`POSTGRES_PASSWORD_FILE` is the image's own file variable. Create them with random values:

```
cd db/secrets
for f in *.example; do head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$(basename "$f" .example)"; done
```

Files are read as uid 70 inside the container, so they are mode 0644; keep `db/secrets/` itself `0700` on a
shared host. `DB_SECRETS_DIR` (see `.env.example`) moves the directory. The files stay mounted in the running
container (a process running as uid 70 there can read them): they are out of `docker inspect` and the
environment, not out of reach of code running inside the container. Production should use the platform's
secret store and rotate; this scaffold only keeps them out of the places that leak by default.

### Why `\password`, and what is NOT leaked

A cleartext password written into an `ALTER ROLE` statement is recorded by `pg_stat_statements` (utility
statements are stored un-normalised) and survives into the running server, where every `pg_monitor` member
can read it; it can also reach the log. `\password` computes the verifier client-side (libpq
`PQencryptPasswordConn`) and sends only an `ALTER ROLE` that carries the `SCRAM-SHA-256$...` verifier, so the cleartext never
exists in SQL text. The init session additionally runs with `pg_stat_statements.track = none` and statement
logging off, `99-final.sql` resets the statistics, and `pg_stat_statements.track_utility = off` in the
server config keeps later utility statements out of the statistics. The test proves, as the monitor role and
as the superuser, before and after a stop/start, that no password value is in `pg_stat_statements`,
`pg_stat_activity`, the container log or anywhere in the data directory.

Residual: the verifier is still an offline-guessing target (as is `pg_authid.rolpassword`, which only the
superuser reads). `10-roles.sh` needs a non-tty stdin (compose gives it one; with a tty psql would prompt
there instead).

### Rotating a password safely

Compute the verifier on the client, never type the cleartext into SQL:

```
docker compose exec -T db sh -c 'PGPASSWORD="$(cat /run/secrets/db_superuser_password)"; export PGPASSWORD; pw="$(cat /run/secrets/db_app_password)"; printf "%s\n%s\n" "$pw" "$pw" | psql -X -h /var/run/postgresql -U postgres -d app -c "\\password app_rw"'
```

(or, interactively, `\password app_rw` in `psql`; the role changing its OWN password does the same).
Update the secret file first, then run it. The defaults here are `log_statement = none` and
`track_utility = off`, so even a cleartext `ALTER ROLE` with a password is not logged or recorded, but it is
still visible in `pg_stat_activity` to `pg_monitor` while it runs, and in a slow-statement log line; do not
rely on that. PostgreSQL always lets a role change its own password (`ALTER ROLE` on itself); nothing
revokes that, and it is a residual of this design.

## Timeouts are guard-rails, not a control

`statement_timeout`, `lock_timeout` and `idle_in_transaction_session_timeout` set per role are DEFAULTS.
`statement_timeout` is a `user`-context setting: any role may `SET statement_timeout = 0` in its session and
may persist `ALTER ROLE <itself> SET statement_timeout = 0` (PostgreSQL lets every role change its own
session defaults). `GRANT SET ON PARAMETER` only governs superuser-context settings and nothing prevents
this. The test names the fact (`app-timeout-is-a-default-not-a-control`). They protect against accidents (a
slow query nobody noticed), not against a hostile client. A control would be a pooler or proxy that enforces
the limit outside the database (or a client that cannot run arbitrary SQL).

## Other databases, network and container

- `PUBLIC` loses CONNECT and TEMP on `postgres` and `template1` (the application database already did), so no
  application role can connect there. Database ACLs are NOT copied by `CREATE DATABASE`: a database created
  later starts with `PUBLIC` CONNECT/TEMP again and needs its own revoke; the contents of `template1`'s
  `public` schema are copied.
- `pg_hba.conf` (exact rule table asserted): `reject` for physical replication for everyone and for the
  superuser `postgres` over any TCP address, then scram-sha-256 on the unix socket and `hostssl` only. The
  superuser logs in only through the socket inside the container (`docker exec`).
- The `db` container runs as uid 70 with `cap_drop: ALL` and no `cap_add` (it needs none: the volume is already
  owned by uid 70), `read_only: true` with tmpfs for `/tmp` and `/run/postgresql`. `tls-init` keeps only
  `CHOWN`, read-only root. Both asserted from `docker inspect` and `/proc/1/status`.
- The certificate is a DEVELOPMENT one (self-signed, 365 days, regenerated within 30 days of expiry). A real
  deployment mounts a CA-issued certificate and key at `/tls/server.crt` and `/tls/server.key` (key 0600, owned
  by uid 70), rotates them with the issuer, and does not run `tls-init`.

## Here vs in migrations

Here: what must exist before the first migration runs, and what a migration must
not be able to change: roles and their attributes and passwords, role-level
settings (timeouts, `search_path`), database-level privileges, the application
schema and its owner, default privileges, extensions that need a restart or
superuser to install.

In migrations (`db/migrations`, T24): every table, index, constraint, view,
function and the grants specific to one object. A migration runs as
`app_migrator` and never creates roles or extensions.

## Roles

| Role | Login | Purpose |
|---|---|---|
| `app_owner` | no | owns schema `app` |
| `app_migrator` | yes | DDL in `app`; member of `app_owner` (may `SET ROLE app_owner`) |
| `app_rw` | yes | SELECT/INSERT/UPDATE/DELETE on `app` tables, sequence use; cannot create anything |
| `app_ro` | yes | SELECT on `app` |
| `app_monitor` | yes | member of `pg_monitor`, nothing else; reads statistics |

None is superuser, createdb, createrole, replication or bypassrls. Only the
bootstrap superuser (`postgres`) is superuser.
