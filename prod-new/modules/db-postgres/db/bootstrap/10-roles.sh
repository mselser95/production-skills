#!/bin/sh
# Init hook: runs roles.sql, feeding it the four role passwords on STDIN (one
# line each, twice: psql's \password asks for the new password and its
# confirmation). \password computes the SCRAM-SHA-256 verifier in libpq
# (PQencryptPasswordConn) and sends only an ALTER ROLE carrying the verifier,
# so no cleartext password is ever in SQL text: not in the server log, not in
# pg_stat_statements, not on a command line (printf is a shell builtin; cat
# only gets a file name). The image's entrypoint runs this once, against the
# temporary server, when the data directory is empty. A re-run by hand needs
# the same stdin and a non-tty session (with a tty psql prompts there instead).
# Order is a contract with roles.sql: migrator, app, readonly, monitor.
set -eu
secrets="${DB_SECRETS_DIR:-/run/secrets}"
names="db_migrator_password db_app_password db_readonly_password db_monitor_password"
for n in $names; do
  f="$secrets/$n"
  if [ ! -r "$f" ] || [ ! -s "$f" ]; then
    echo "10-roles.sh: $f is missing, unreadable or empty" >&2
    exit 1
  fi
  if [ "$(wc -l <"$f")" -gt 1 ]; then
    echo "10-roles.sh: $f has more than one line" >&2
    exit 1
  fi
done
{
  for n in $names; do
    pw="$(cat "$secrets/$n")"
    printf '%s\n%s\n' "$pw" "$pw"
  done
} | psql -X -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -f /bootstrap/roles.sql
