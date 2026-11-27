# bootstrap — what runs before migrations

The image's init mechanism (`/docker-entrypoint-initdb.d`) runs these files ONCE,
when the data directory is empty, against a temporary server. Everything here is
idempotent, so it can also be re-run by hand against a live database.

| File | What it does |
|---|---|
| `tls-init.sh` | one-shot container: self-signed DEVELOPMENT certificate into the `dbtls` volume (never committed; production mounts a real one at the same paths) |
| `10-roles.sh` + `roles.sql` | the role split, the `app` schema, grants, default privileges, per-role `search_path` and timeouts. Passwords are read from the container environment with `\getenv`; no literal is in the repo |
| `20-extensions.sql` | `pg_stat_statements` |
| `timescale/30-timescaledb.sql` | `timescaledb`, Timescale variant only |

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
