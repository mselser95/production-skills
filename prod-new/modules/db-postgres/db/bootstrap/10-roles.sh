#!/bin/sh
# Init hook: runs roles.sql with the passwords taken from the container's
# environment (psql \getenv inside the file — no password is on a command line
# or in a committed file). The image's entrypoint runs this once, against the
# temporary server, when the data directory is empty. roles.sql is idempotent,
# so it can also be re-run by hand against a live database.
set -eu
exec psql -X -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -f /bootstrap/roles.sql
