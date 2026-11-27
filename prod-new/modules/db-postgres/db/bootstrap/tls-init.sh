#!/bin/sh
# tls-init.sh — generate a SELF-SIGNED, DEVELOPMENT-ONLY server certificate
# into the dbtls volume (mounted at /tls) when none exists.
#
# Why a separate one-shot container: neither the postgres nor the timescale
# image ships the openssl CLI, and the server will not start with ssl=on and a
# missing certificate. Nothing here is committed: the key is created at run
# time inside the volume. A real deployment mounts its own certificate at the
# same two paths and does not run this service.
set -eu
dir=/tls
if [ -s "$dir/server.crt" ] && [ -s "$dir/server.key" ]; then
  echo "tls-init: certificate already present, keeping it"
  exit 0
fi
umask 077
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -days 365 -subj "/CN=db-dev-only" \
  -addext "subjectAltName=DNS:localhost,DNS:db,IP:127.0.0.1" \
  -keyout "$dir/server.key.tmp" -out "$dir/server.crt.tmp"
# uid/gid 70 is `postgres` in both the postgres and the timescale alpine images;
# the server refuses a key that is group/world readable or owned by someone else.
chown 70:70 "$dir/server.key.tmp" "$dir/server.crt.tmp"
chmod 0600 "$dir/server.key.tmp"
chmod 0644 "$dir/server.crt.tmp"
mv "$dir/server.key.tmp" "$dir/server.key"
mv "$dir/server.crt.tmp" "$dir/server.crt"
echo "tls-init: generated a self-signed development certificate (365 days)"
