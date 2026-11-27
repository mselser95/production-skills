#!/bin/sh
# tls-init.sh - generate a SELF-SIGNED, DEVELOPMENT-ONLY server certificate
# into the dbtls volume (mounted at /tls) when none exists or the existing one
# expires within 30 days (or cannot be parsed).
#
# Why a separate one-shot container: neither the postgres nor the timescale
# image ships the openssl CLI, and the server will not start with ssl=on and a
# missing certificate. Nothing here is committed: the key is created at run
# time inside the volume. A real deployment mounts its own certificate at the
# same two paths, rotated by whatever issues it, and does not run this service.
# TLS_DIR overrides /tls (used by the unit test in db-bootstrap-test.sh).
set -eu
dir="${TLS_DIR:-/tls}"
renew_days=30
if [ -s "$dir/server.crt" ] && [ -s "$dir/server.key" ]; then
  if openssl x509 -in "$dir/server.crt" -noout -checkend $((renew_days * 86400)) >/dev/null 2>&1; then
    echo "tls-init: certificate already present and valid for more than $renew_days days, keeping it"
    exit 0
  fi
  echo "tls-init: certificate expires within $renew_days days or is unreadable, regenerating"
fi
umask 077
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -days 365 -subj "/CN=db-dev-only" \
  -addext "subjectAltName=DNS:localhost,DNS:db,IP:127.0.0.1" \
  -keyout "$dir/server.key.tmp" -out "$dir/server.crt.tmp"
# Modes first, owner last: after the chown this process (root, with only CHOWN)
# no longer owns the files and could not chmod them.
chmod 0600 "$dir/server.key.tmp"
chmod 0644 "$dir/server.crt.tmp"
# uid/gid 70 is `postgres` in both the postgres and the timescale alpine images;
# the server refuses a key that is group/world readable or owned by someone else.
chown 70:70 "$dir/server.key.tmp" "$dir/server.crt.tmp"
mv "$dir/server.key.tmp" "$dir/server.key"
mv "$dir/server.crt.tmp" "$dir/server.crt"
echo "tls-init: generated a self-signed development certificate (365 days)"
