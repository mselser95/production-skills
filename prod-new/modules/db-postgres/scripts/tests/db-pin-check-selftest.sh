#!/usr/bin/env bash
# db-pin-check-selftest.sh — hermetic, sequential selftest for db-pin-check.sh.
# Every case builds its input in a scratch dir from the REAL lock, runs the REAL
# script, and asserts exit code + a substring. The mutation block then breaks one
# rule at a time in a scratch copy of the script and requires the matching case
# to go RED (the case no longer sees the expected result).
# Final line: `N ok, M failed`. Exit 1 if any failed.
set -uo pipefail
src="${BASH_SOURCE[0]}"; [[ $src == */* ]] || src="./$src"
here="$(cd "${src%/*}" && pwd)"
script="$here/../db-pin-check.sh"
helper="$here/../db_pin_compose.py"
real_lock="$here/../../db/image.lock"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export DB_PIN_TODAY="2026-11-27"
unset DB_PIN_WARN_DAYS DB_PIN_FAIL_DAYS

ok=0; bad=0
PG_D=sha256:0115267ab5a509022df9319c77be365cef335adb71556c75f60f5360ee247e71
TS_D=sha256:70e6526ad8e31e3f4833f2c5863b50b92d7a6bee4d432ad1f660e2c6dd956d94
PG_ARM="$(sed -n 's/^postgres.digest.linux\/arm64 = //p' "$real_lock")"
PG_AMD="$(sed -n 's/^postgres.digest.linux\/amd64 = //p' "$real_lock")"

# run <script> <expected-rc> <expected-substring|-> <args...>  -> 0 when matches
run() {
  local s="$1" erc="$2" esub="$3"; shift 3
  local out rc
  out="$(bash "$s" "$@" 2>&1)"; rc=$?
  [[ $rc == "$erc" ]] || return 1
  [[ $esub == - || $out == *"$esub"* ]]
}
check() { # name rc sub args...
  local name="$1"; shift
  if run "$script" "$@"; then echo "ok   $name"; ok=$((ok + 1)); else
    echo "FAIL $name"; bash "$script" "${@:3}" 2>&1 | tail -n 4 | sed 's/^/     | /'; bad=$((bad + 1)); fi
}
# lockwith <file> <sed-expr>...  (mutates a copy of the real lock)
lockwith() { local f="$1"; shift; local a=(); for e in "$@"; do a+=(-e "$e"); done; sed "${a[@]}" "$real_lock" > "$f"; }

compose_ok="$tmp/ok.yml"
cat > "$compose_ok" <<Y
services:
  db:
    image: postgres:18.7-alpine@$PG_D
  ts:
    image: "timescale/timescaledb:2.32.1-pg18@$TS_D"
Y
printf 'services:\n  db:\n    image: postgres:latest\n' > "$tmp/latest.yml"
printf 'services:\n  db:\n    image: postgres:18.7-alpine\n' > "$tmp/nodigest.yml"
printf 'services:\n  db:\n    image: postgres\n' > "$tmp/notag.yml"
printf 'services:\n  db:\n    image: postgres:18.7-alpine@sha256:%064d\n' 0 > "$tmp/wrongdigest.yml"
printf 'services:\n  db:\n    image: redis:7.4@sha256:%064d\n' 0 > "$tmp/other.yml"
printf 'FROM scratch AS base\nFROM postgres:18.7-alpine@%s AS db\nFROM db\n' "$PG_D" > "$tmp/Dockerfile.ok"
printf 'FROM postgres:18\n' > "$tmp/Dockerfile.bad"
printf 'services: {}\n' > "$tmp/noimage.yml"

# ---- cases ---------------------------------------------------------------
check "real lock passes"                      0 "OK db-pin-check"
check "real lock + pinned compose passes"     0 "OK db-pin-check" "$real_lock" --compose "$compose_ok"
check "real lock + pinned Dockerfile passes"  0 "OK db-pin-check" "$real_lock" --compose "$tmp/Dockerfile.ok"
check "compose :latest is RED"                1 "FAIL LATEST" "$real_lock" --compose "$tmp/latest.yml"
check "compose with no tag is RED"            1 "FAIL LATEST" "$real_lock" --compose "$tmp/notag.yml"
check "compose tag without digest is RED"     1 "FAIL DIGEST" "$real_lock" --compose "$tmp/nodigest.yml"
check "compose with a foreign digest is RED"  1 "not the lock's postgres digest" "$real_lock" --compose "$tmp/wrongdigest.yml"
check "compose of only an unrelated image is RED (no database)" 1 "FAIL NO-DB" "$real_lock" --compose "$tmp/other.yml"
check "unpinned Dockerfile FROM is RED"       1 "FAIL DIGEST" "$real_lock" --compose "$tmp/Dockerfile.bad"
check "compose without any image is RED"      1 "FAIL DOC" "$real_lock" --compose "$tmp/noimage.yml"

lockwith "$tmp/l-latest" 's/^postgres.tag = .*/postgres.tag = latest/'
check "lock tag latest is RED"                1 "FAIL LATEST" "$tmp/l-latest"
lockwith "$tmp/l-notag" 's/^timescaledb.tag = .*/timescaledb.tag =/'
check "lock empty tag is RED"                 1 "FAIL LATEST" "$tmp/l-notag"
lockwith "$tmp/l-nodigest" '/^postgres.digest = /d'
check "lock missing digest is RED"            1 "missing key: postgres.digest" "$tmp/l-nodigest"
lockwith "$tmp/l-baddigest" "s/^timescaledb.digest = .*/timescaledb.digest = sha256:abc123/"
check "lock malformed digest is RED"          1 "FAIL DIGEST" "$tmp/l-baddigest"
lockwith "$tmp/l-upper" "s/^postgres.digest.linux\\/arm64 = sha256:./postgres.digest.linux\\/arm64 = sha256:A/"
check "lock uppercase hex digest is RED"      1 "FAIL DIGEST" "$tmp/l-upper"
lockwith "$tmp/l-pg19" 's/^postgres.server_version = .*/postgres.server_version = 19.0/' 's/^timescaledb.pg_server_version = .*/timescaledb.pg_server_version = 19.0/'
check "PostgreSQL major 19 is RED"            1 "is not PostgreSQL 18" "$tmp/l-pg19"
lockwith "$tmp/l-pair" 's/^postgres.server_version = .*/postgres.server_version = 18.8/'
check "minor bumped on one side only: PAIR"   1 "FAIL PAIR" "$tmp/l-pair"
lockwith "$tmp/l-pair-ts" 's/^timescaledb.pg_server_version = .*/timescaledb.pg_server_version = 18.6/'
check "minor lowered on the other side: PAIR" 1 "FAIL PAIR" "$tmp/l-pair-ts"
exc='s/^postgres.server_version = .*/postgres.server_version = 18.8/;s/^postgres.tag = .*/postgres.tag = 18.8-alpine/'
lockwith "$tmp/l-exc-ok" "$exc" 's/^verified_utc = .*/&\npair_exception_until = 2026-12-31\npair_exception_reason = timescale image for 18.8 not published yet/'
check "dated pair_exception is ok"            0 "allowed until 2026-12-31" "$tmp/l-exc-ok"
lockwith "$tmp/l-exc-last" "$exc" 's/^verified_utc = .*/&\npair_exception_until = 2026-11-27\npair_exception_reason = last day/'
check "pair_exception on its last day is ok"  0 "allowed until" "$tmp/l-exc-last"
lockwith "$tmp/l-exc-old" "$exc" 's/^verified_utc = .*/&\npair_exception_until = 2026-11-26\npair_exception_reason = expired yesterday/'
check "expired pair_exception is RED"         1 "pair_exception expired" "$tmp/l-exc-old"
lockwith "$tmp/l-exc-noreason" "$exc" 's/^verified_utc = .*/&\npair_exception_until = 2026-12-31/'
check "pair_exception without reason is RED"  1 "without pair_exception_reason" "$tmp/l-exc-noreason"

# staleness: verified 2026-11-27; thresholds 180 / 365
stale() { DB_PIN_TODAY="$1" bash "$script" "$real_lock" 2>&1; echo "rc=$?"; }
chk_stale() { local name="$1" today="$2" erc="$3" esub="$4" out; out="$(stale "$today")"
  if [[ $out == *"rc=$erc" && ( $esub == - || $out == *"$esub"* ) ]]; then echo "ok   $name"; ok=$((ok + 1)); else echo "FAIL $name"; echo "$out" | tail -n 3 | sed 's/^/     | /'; bad=$((bad + 1)); fi; }
chk_stale "age 179 days: silent ok"           2027-05-25 0 "OK db-pin-check"
chk_stale "age 180 days: WARN, exit 0"        2027-05-26 0 "WARN STALE"
chk_stale "age 364 days: WARN, exit 0"        2027-11-26 0 "WARN STALE"
chk_stale "age 365 days: FAIL"                2027-11-27 1 "FAIL STALE"
chk_stale "verified date in the future: FAIL" 2026-11-26 1 "in the future"
lockwith "$tmp/l-baddate" 's/^verified_utc = .*/verified_utc = 2026-02-30/'
check "impossible verified date is RED"       1 "is not a date" "$tmp/l-baddate"
envout="$(DB_PIN_WARN_DAYS=10 DB_PIN_FAIL_DAYS=20 DB_PIN_TODAY=2026-12-20 bash "$script" "$real_lock" 2>&1)"
if [[ $envout == *"FAIL STALE"* ]]; then
  echo "ok   env thresholds are honoured"; ok=$((ok + 1)); else echo "FAIL env thresholds are honoured"; bad=$((bad + 1)); fi

: > "$tmp/empty.lock"
check "empty lock exits 2"                    2 "nothing checked" "$tmp/empty.lock"
check "missing lock exits 2"                  2 "nothing checked" "$tmp/does-not-exist.lock"
printf '# only comments\n' > "$tmp/comments.lock"
check "comment-only lock exits 2"             2 "nothing checked" "$tmp/comments.lock"
printf 'this is not a lock\n' > "$tmp/junk.lock"
check "garbage lock is RED (parse)"           1 "LOCK-PARSE" "$tmp/junk.lock"
lockwith "$tmp/l-unk" 's/^verified_utc = .*/&\nposgres.tag = 18.7/'
check "typo'd key is RED"                     1 "unknown key" "$tmp/l-unk"
lockwith "$tmp/l-dup" 's/^verified_utc = .*/&\nverified_utc = 2026-11-27/'
check "duplicate key is RED"                  1 "duplicate key" "$tmp/l-dup"

# ---- lock rules added after validation ---------------------------------------
lockwith "$tmp/l-tag186" 's/^postgres.tag = .*/postgres.tag = 18.6-alpine/'
check "postgres.tag 18.6 beside 18.7 is RED"  1 "does not start with postgres.server_version" "$tmp/l-tag186"
lockwith "$tmp/l-tag18x" 's/^postgres.tag = .*/postgres.tag = 18.x/'
check "postgres.tag 18.x is RED"              1 "does not start with postgres.server_version" "$tmp/l-tag18x"
lockwith "$tmp/l-tag187x" 's/^postgres.tag = .*/postgres.tag = 18.70-alpine/'
check "postgres.tag 18.70 beside 18.7 is RED" 1 "does not start with postgres.server_version" "$tmp/l-tag187x"
lockwith "$tmp/l-ts2" 's/^timescaledb.tag = .*/timescaledb.tag = 2-pg18/'
check "timescale tag 2-pg18 is RED"           1 "is not '2.32.1-pg18'" "$tmp/l-ts2"
lockwith "$tmp/l-ts0" 's/^timescaledb.tag = .*/timescaledb.tag = 2.32.0-pg18/'
check "timescale tag older extversion is RED" 1 "is not '2.32.1-pg18'" "$tmp/l-ts0"
lockwith "$tmp/l-tspg17" 's/^timescaledb.tag = .*/timescaledb.tag = 2.32.1-pg17/'
check "timescale tag with another -pgNN: RED" 1 "is not '2.32.1-pg18'" "$tmp/l-tspg17"
lockwith "$tmp/l-tsoss" 's/^timescaledb.tag = .*/timescaledb.tag = 2.32.1-pg18-oss/'
check "timescale tag with a suffix is RED"    1 "is not '2.32.1-pg18'" "$tmp/l-tsoss"
lockwith "$tmp/l-ext-banana" 's/^timescaledb.extversion = .*/timescaledb.extversion = banana/'
check "extversion banana is RED"              1 "extversion 'banana' is not" "$tmp/l-ext-banana"
lockwith "$tmp/l-ext-2" 's/^timescaledb.extversion = .*/timescaledb.extversion = 2.32/'
check "extversion two-part is RED"            1 "extversion '2.32' is not" "$tmp/l-ext-2"
lockwith "$tmp/l-sv-junk" 's/^postgres.server_version = .*/postgres.server_version = 18.junk/'
check "server_version 18.junk is RED"         1 "postgres.server_version '18.junk' is not <major>.<minor>" "$tmp/l-sv-junk"
lockwith "$tmp/l-tsv-junk" 's/^timescaledb.pg_server_version = .*/timescaledb.pg_server_version = 18.7.1/'
check "pg_server_version 18.7.1 is RED"       1 "pg_server_version '18.7.1' is not <major>.<minor>" "$tmp/l-tsv-junk"
lockwith "$tmp/l-dd" 's#^postgres.data_directory = .*#postgres.data_directory = /var/lib/postgresql/data#'
check "old data_directory layout is RED"      1 "postgres.data_directory '/var/lib/postgresql/data' is not /var/lib/postgresql/18/docker" "$tmp/l-dd"
lockwith "$tmp/l-tdd" 's#^timescaledb.data_directory = .*#timescaledb.data_directory = /var/lib/postgresql/data#'
check "timescale old data_directory is RED"   1 "timescaledb.data_directory '/var/lib/postgresql/data'" "$tmp/l-tdd"
lockwith "$tmp/l-samed" "s/^postgres.digest = .*/postgres.digest = $TS_D/"
check "timescale digest in postgres.digest"   1 "postgres.digest and timescaledb.digest are the same digest" "$tmp/l-samed"
lockwith "$tmp/l-idx-arm" "s/^postgres.digest = .*/postgres.digest = $PG_ARM/"
check "index digest equal to a platform one"  1 "same digest" "$tmp/l-idx-arm"
lockwith "$tmp/l-arch-same" "s/^postgres.digest.linux\\/amd64 = .*/postgres.digest.linux\\/amd64 = $PG_ARM/"
check "amd64 digest equal to arm64 digest"    1 "same digest" "$tmp/l-arch-same"
lockwith "$tmp/l-hash1" 's/^postgres.digest = .*/&#note/'
check "digest followed by #comment is RED"    1 "trailing text after the digest" "$tmp/l-hash1"
lockwith "$tmp/l-hash2" 's/^timescaledb.digest = .*/& # note/'
check "digest followed by ' # comment' RED"   1 "trailing text after the digest" "$tmp/l-hash2"
lockwith "$tmp/l-h65" 's/^postgres.digest = .*/&0/'
check "65-hex digest is RED"                  1 "malformed digest" "$tmp/l-h65"
lockwith "$tmp/l-h63" 's/^postgres.digest = \(.*\).$/postgres.digest = \1/'
check "63-hex digest is RED"                  1 "malformed digest" "$tmp/l-h63"
lockwith "$tmp/l-noprefix" 's/^postgres.digest = sha256:/postgres.digest = /'
check "digest without sha256: prefix is RED"  1 "malformed digest" "$tmp/l-noprefix"

# ---- compose attacks (the validator's list) + parser rules --------------------
yml() { cat > "$tmp/$1.yml"; }
yml flow <<'Y'
services:
  db: {image: "postgres:16"}
Y
yml quotedkey <<'Y'
services:
  db:
    "image": postgres:16
Y
yml nextline <<'Y'
services:
  db:
    image:
      postgres:16
Y
yml buildargs <<'Y'
services:
  db:
    build:
      context: .
      args:
        BASE: postgres:16
Y
yml extends <<'Y'
services:
  db:
    extends:
      file: base.yml
      service: db
Y
yml nginx <<'Y'
services:
  web:
    image: nginx:1.27@sha256:0000000000000000000000000000000000000000000000000000000000000000
Y
cat > "$tmp/decoy.yml" <<Y
services:
  app:
    image: nginx:1.27@sha256:0000000000000000000000000000000000000000000000000000000000000000
    command: |
      image: postgres:18.7-alpine@$PG_D
  db:
    build: .
Y
printf 'services:\n' > "$tmp/emptysvc.yml"
printf 'services: {}\n' > "$tmp/emptymap.yml"
: > "$tmp/emptyfile.yml"
printf 'services:\n  db: [oops\n' > "$tmp/garbage.yml"
printf 'just a string\n' > "$tmp/scalar.yml"
yml archdigest <<Y
services:
  db:
    image: postgres:18.7-alpine@$PG_ARM
Y
yml archdigest-amd <<Y
services:
  db:
    image: postgres:18.7-alpine@$PG_AMD
Y
yml var <<'Y'
services:
  db:
    image: ${DB_IMAGE:-postgres:18.7-alpine}
Y
yml wrongtag <<Y
services:
  db:
    image: postgres:16@$PG_D
Y
yml registry-ok <<Y
services:
  db:
    image: docker.io/library/postgres:18.7-alpine@$PG_D
Y
yml registry-ts-ok <<Y
services:
  mirror:
    image: registry.example.com:5000/timescale/timescaledb:2.32.1-pg18@$TS_D
Y
yml registry-bad <<'Y'
services:
  db:
    image: registry.example.com/timescale/timescaledb:16
Y
yml dup-key <<Y
services:
  db:
    image: postgres:18.7-alpine@$PG_D
    image: postgres:16
Y
yml dup-svc <<Y
services:
  db:
    image: postgres:18.7-alpine@$PG_D
  db:
    image: nginx:1
Y
cat > "$tmp/twodocs.yml" <<Y
services:
  db:
    image: postgres:18.7-alpine@$PG_D
---
services:
  db:
    image: postgres:16
Y
yml include <<Y
include:
  - other.yml
services:
  db:
    image: postgres:18.7-alpine@$PG_D
Y
yml merge-ok <<Y
x-db: &db
  image: postgres:18.7-alpine@$PG_D
services:
  db:
    <<: *db
Y
yml merge-bad <<'Y'
x-db: &db
  image: postgres:16
services:
  db:
    <<: *db
Y
yml merge-override <<Y
x-db: &db
  image: postgres:18.7-alpine@$PG_D
services:
  db:
    <<: *db
    image: postgres:16
Y
cat > "$tmp/build-app.yml" <<Y
services:
  db:
    image: postgres:18.7-alpine@$PG_D
  app:
    build: .
Y
cat > "$tmp/build-db.yml" <<Y
services:
  db:
    image: postgres:18.7-alpine@$PG_D
    build: .
Y
yml svc-noimage <<Y
services:
  db:
    image: postgres:18.7-alpine@$PG_D
  odd:
    restart: always
Y
check "flow-map db with postgres:16 is RED"           1 "FAIL PIN" "$real_lock" --compose "$tmp/flow.yml"
check "quoted image key is still read"                1 "FAIL PIN" "$real_lock" --compose "$tmp/quotedkey.yml"
check "image value on the next line is still read"    1 "FAIL PIN" "$real_lock" --compose "$tmp/nextline.yml"
check "build: with args BASE=postgres:16 is RED"      1 "FAIL BUILD" "$real_lock" --compose "$tmp/buildargs.yml"
check "extends: is RED"                               1 "FAIL EXTENDS" "$real_lock" --compose "$tmp/extends.yml"
check "compose with no database service is RED"       1 "FAIL NO-DB" "$real_lock" --compose "$tmp/nginx.yml"
check "heredoc decoy beside build: db is RED"         1 "FAIL BUILD" "$real_lock" --compose "$tmp/decoy.yml"
check "heredoc decoy is not a service (NO-DB)"        1 "FAIL NO-DB" "$real_lock" --compose "$tmp/decoy.yml"
check "services: (null) is RED"                       1 "FAIL DOC" "$real_lock" --compose "$tmp/emptysvc.yml"
check "services: {} is RED"                           1 "FAIL DOC" "$real_lock" --compose "$tmp/emptymap.yml"
check "empty compose file is RED"                     1 "FAIL DOC" "$real_lock" --compose "$tmp/emptyfile.yml"
check "unparseable YAML is RED"                       1 "FAIL DOC" "$real_lock" --compose "$tmp/garbage.yml"
check "scalar top level is RED"                       1 "FAIL DOC" "$real_lock" --compose "$tmp/scalar.yml"
check "per-platform digest in compose is RED"         1 "per-platform digest" "$real_lock" --compose "$tmp/archdigest.yml"
check "linux/amd64 digest in compose is RED"          1 "per-platform digest" "$real_lock" --compose "$tmp/archdigest-amd.yml"
check "image with \$ variable is RED"                 1 "FAIL VARIABLE" "$real_lock" --compose "$tmp/var.yml"
check "right digest, wrong tag is RED"                1 "tag differs from the lock" "$real_lock" --compose "$tmp/wrongtag.yml"
check "registry prefix + library/ still matches"      0 "OK db-pin-check" "$real_lock" --compose "$tmp/registry-ok.yml"
check "registry-prefixed timescale image matches"     0 "OK db-pin-check" "$real_lock" --compose "$tmp/registry-ts-ok.yml"
check "registry-prefixed timescale image is checked"  1 "FAIL PIN" "$real_lock" --compose "$tmp/registry-bad.yml"
check "duplicate key in a mapping is RED"             1 "duplicate key" "$real_lock" --compose "$tmp/dup-key.yml"
check "duplicate service name is RED"                 1 "duplicate key" "$real_lock" --compose "$tmp/dup-svc.yml"
check "two YAML documents are RED"                    1 "2 YAML documents" "$real_lock" --compose "$tmp/twodocs.yml"
check "include: is RED"                               1 "FAIL INCLUDE" "$real_lock" --compose "$tmp/include.yml"
check "merge key resolves to a pinned image: ok"      0 "OK db-pin-check" "$real_lock" --compose "$tmp/merge-ok.yml"
check "merge key resolves to postgres:16: RED"        1 "FAIL PIN" "$real_lock" --compose "$tmp/merge-bad.yml"
check "explicit key overrides the merged one: RED"    1 "FAIL PIN" "$real_lock" --compose "$tmp/merge-override.yml"
check "build service without --non-db-build is RED"   1 "FAIL BUILD" "$real_lock" --compose "$tmp/build-app.yml"
check "build service named by the invoker is ok"      0 "OK db-pin-check" "$real_lock" --compose "$tmp/build-app.yml" --non-db-build app
check "build+database image is RED even when named"   1 "must be the pinned image itself" "$real_lock" --compose "$tmp/build-db.yml" --non-db-build db
check "service with neither image nor build is RED"   1 "has no usable image" "$real_lock" --compose "$tmp/svc-noimage.yml"
check "--compose with no file exits 2"                2 "needs at least one file" "$real_lock" --compose
check "--compose followed by an option exits 2"       2 "needs at least one file" "$real_lock" --compose --non-db-build x
check "--non-db-build without a name exits 2"         2 "needs a service name" "$real_lock" --compose "$compose_ok" --non-db-build
check "unreadable compose file is RED"                1 "cannot read" "$real_lock" --compose "$tmp/nope.yml"

# Dockerfiles (read by FROM lines; same zero-match and per-platform rules)
printf 'FROM postgres:latest\n' > "$tmp/Dockerfile.latest"
printf 'FROM postgres:18.7-alpine\n' > "$tmp/Dockerfile.nodigest"
printf 'FROM redis:7.4@sha256:%064d\n' 0 > "$tmp/Dockerfile.nodb"
printf 'FROM postgres:18.7-alpine@%s\n' "$PG_ARM" > "$tmp/Dockerfile.arch"
printf 'ARG B\nFROM ${B}\n' > "$tmp/Dockerfile.var"
printf 'FROM postgres:18.7-alpine@sha256:%064d\n' 0 > "$tmp/Dockerfile.wrongdigest"
printf 'FROM postgres:16@%s\n' "$PG_D" > "$tmp/Dockerfile.wrongtag"
check "Dockerfile :latest is RED"                     1 "floating tag" "$real_lock" --compose "$tmp/Dockerfile.latest"
check "Dockerfile tag without digest is RED"          1 "has no @sha256 digest" "$real_lock" --compose "$tmp/Dockerfile.nodigest"
check "Dockerfile with no database FROM is RED"       1 "no FROM runs a lock image" "$real_lock" --compose "$tmp/Dockerfile.nodb"
check "Dockerfile per-platform digest is RED"         1 "per-platform digest" "$real_lock" --compose "$tmp/Dockerfile.arch"
check "Dockerfile with a foreign digest is RED"       1 "digest is not the lock's postgres digest" "$real_lock" --compose "$tmp/Dockerfile.wrongdigest"
check "Dockerfile right digest wrong tag is RED"      1 "tag differs from lock" "$real_lock" --compose "$tmp/Dockerfile.wrongtag"
check "Dockerfile FROM \${ARG} is RED"                1 "is a variable" "$real_lock" --compose "$tmp/Dockerfile.var"

# the parser being absent is exit 2, never a pass
mkdir -p "$tmp/noyaml" "$tmp/emptybin" "$tmp/crashyaml"
printf 'raise ImportError("simulated: no PyYAML")\n' > "$tmp/noyaml/yaml.py"
printf 'raise RuntimeError("simulated crash")\n' > "$tmp/crashyaml/yaml.py"
chk_env() { # name rc sub  env-assignment...  -- args
  local name="$1" erc="$2" esub="$3"; shift 3; local out rc
  out="$(env "$@" 2>&1)"; rc=$?
  if [[ $rc == "$erc" && $out == *"$esub"* ]]; then echo "ok   $name"; ok=$((ok + 1)); else echo "FAIL $name (rc=$rc)"; echo "$out" | tail -n 3 | sed 's/^/     | /'; bad=$((bad + 1)); fi
}
chk_env "PyYAML missing exits 2, not a pass"    2 "PyYAML is not importable" PYTHONPATH="$tmp/noyaml" bash "$script" "$real_lock" --compose "$compose_ok"
chk_env "python3 missing exits 2, not a pass"   2 "python3 is not available" PATH="$tmp/emptybin" "$BASH" "$script" "$real_lock" --compose "$compose_ok"
chk_env "helper crash without verdict exits 2"  2 "gave no verdict" PYTHONPATH="$tmp/crashyaml" bash "$script" "$real_lock" --compose "$compose_ok"
chk_env "PyYAML missing does not affect Dockerfile" 0 "OK db-pin-check" PYTHONPATH="$tmp/noyaml" bash "$script" "$real_lock" --compose "$tmp/Dockerfile.ok"

# ---- mutations: break one rule in a scratch copy, the case must go RED -------
# The script finds db_pin_compose.py next to itself, so each mutation runs in a
# scratch copy of BOTH files: mutate <sh|py> <name> <anchor> <replacement> <rc> <substr> <args...>
mkdir -p "$tmp/m"
mutate() {
  local which="$1" name="$2" anchor="$3" repl="$4" erc="$5" esub="$6"; shift 6
  local src_f="$script"; [[ $which == py ]] && src_f="$helper"
  local body; body="$(cat "$src_f")"
  if [[ $body != *"$anchor"* ]]; then echo "FAIL mutation $name: anchor not found"; bad=$((bad + 1)); return; fi
  cp "$script" "$tmp/m/db-pin-check.sh"; cp "$helper" "$tmp/m/db_pin_compose.py"
  local dst="$tmp/m/db-pin-check.sh"; [[ $which == py ]] && dst="$tmp/m/db_pin_compose.py"
  printf '%s\n' "${body//"$anchor"/"$repl"}" > "$dst"
  if run "$tmp/m/db-pin-check.sh" "$erc" "$esub" "$@"; then
    echo "FAIL mutation $name: GREEN (the case did not notice)"; bad=$((bad + 1))
  else echo "RED  mutation $name"; ok=$((ok + 1)); fi
}
L="$real_lock"
mutate sh "pair rule removed"            'if [[ $pg_sv != "$ts_sv" ]]; then' 'if false; then' 1 "FAIL PAIR" "$tmp/l-pair"
mutate sh "latest check removed (lock)"  '[[ $2 == latest || $2 == *latest* ]]' 'false' 1 "floating tag" "$tmp/l-latest"
mutate sh "latest check removed (Dockerfile)" '$tag == *latest* ]]; then fail LATEST' '$tag == NEVER ]]; then fail LATEST' 1 "floating tag" "$L" --compose "$tmp/Dockerfile.latest"
mutate py "latest check removed (compose)"    'elif "latest" in tag:' 'elif False:' 1 "floating tag" "$L" --compose "$tmp/latest.yml"
mutate sh "digest format check removed"  'digest_ok() { [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]]; }' 'digest_ok() { true; }' 1 "malformed digest" "$tmp/l-baddigest"
mutate sh "digest accepts 65 hex"        '[0-9a-f]{64}$' '[0-9a-f]{64,}$' 1 "malformed digest" "$tmp/l-h65"
mutate sh "digest accepts 63 hex"        '[0-9a-f]{64}$' '[0-9a-f]{63,}$' 1 "malformed digest" "$tmp/l-h63"
mutate sh "digest prefix not required"   '^sha256:[0-9a-f]' '^(sha256:)?[0-9a-f]' 1 "malformed digest" "$tmp/l-noprefix"
mutate sh "inline-comment message removed" "if [[ \$2 == *'#'* ]]; then" 'if false; then' 1 "trailing text after the digest" "$tmp/l-hash1"
mutate sh "digest presence check removed (Dockerfile)" 'if [[ -z $dg ]]; then fail DIGEST' 'if false; then fail DIGEST' 1 "has no @sha256" "$L" --compose "$tmp/Dockerfile.nodigest"
mutate py "digest presence check removed (compose)"   'if not digest:' 'if False:' 1 "has no @sha256" "$L" --compose "$tmp/nodigest.yml"
mutate sh "major check removed"          '[[ $maj == 18 ]] ||' 'true ||' 1 "is not PostgreSQL 18" "$tmp/l-pg19"
mutate sh "exception expiry ignored"     'elif ((ex_n < today_n)); then' 'elif false; then' 1 "pair_exception expired" "$tmp/l-exc-old"
DB_PIN_TODAY=2027-11-27 mutate sh "stale fail threshold ignored" 'elif ((age >= fail_days)); then' 'elif false; then' 1 "FAIL STALE" "$L"
mutate sh "tag-starts-with-version removed"   '[[ $pg_tag == "$pg_sv" || $pg_tag == "$pg_sv"-* ]] ||' 'true ||' 1 "does not start with" "$tmp/l-tag186"
mutate sh "tag-version delimiter removed"     '[[ $pg_tag == "$pg_sv" || $pg_tag == "$pg_sv"-* ]] ||' '[[ $pg_tag == "$pg_sv"* ]] ||' 1 "does not start with" "$tmp/l-tag187x"
mutate sh "timescale exact-tag rule removed"  '[[ $(g timescaledb.tag) == "$ts_ev-pg$ts_maj" ]] ||' 'true ||' 1 "is not '2.32.1-pg18'" "$tmp/l-ts2"
mutate sh "extversion format removed"         '[[ $ts_ev =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||' 'true ||' 1 "extversion 'banana'" "$tmp/l-ext-banana"
mutate sh "server_version format removed"     '[[ ${pair#*:} =~ ^[0-9]+\.[0-9]+$ ]] ||' 'true ||' 1 "is not <major>.<minor>" "$tmp/l-sv-junk"
mutate sh "data_directory rule removed"       '[[ $(g "${pair%%:*}.data_directory") == "/var/lib/postgresql/$maj/docker" ]] ||' 'true ||' 1 "data_directory" "$tmp/l-dd"
mutate sh "data_directory rule skipped for >= 18" 'if [[ -n $maj ]] && ((maj >= 18)); then' 'if false; then' 1 "data_directory" "$tmp/l-tdd"
mutate sh "distinct-digest rule removed"      'if [[ -n ${dvals[di]} && ${dvals[di]} == "${dvals[dj]}" ]]; then fail' 'if false; then fail' 1 "same digest" "$tmp/l-samed"
mutate sh "--compose without file allowed"    'if ((compose_flag == 1 && ${#compose[@]} == 0)); then' 'if false; then' 2 "needs at least one file" "$L" --compose
mutate sh "Dockerfile zero-database rule removed" '((db_refs == db_before)) &&' 'false &&' 1 "no FROM runs a lock image" "$L" --compose "$tmp/Dockerfile.nodb"
mutate sh "Dockerfile per-platform rule removed" 'if [[ $dg == "$(g $p.digest.linux/amd64)" || $dg == "$(g $p.digest.linux/arm64)" ]]; then' 'if false; then' 1 "per-platform digest" "$L" --compose "$tmp/Dockerfile.arch"
mutate sh "Dockerfile tag compare removed"    '[[ $tag == "$(g $p.tag)" ]] || fail PIN' 'true || fail PIN' 1 "tag differs" "$L" --compose "$tmp/Dockerfile.wrongtag"
mutate sh "Dockerfile digest compare removed" 'elif [[ $dg != "$(g $p.digest)" ]]; then' 'elif false; then' 1 "digest is not the lock's postgres digest" "$L" --compose "$tmp/Dockerfile.wrongdigest"
mutate sh "Dockerfile variable rule removed"  "if [[ \$ref == *'\$'* ]]; then fail PIN" 'if false; then fail PIN' 1 "is a variable" "$L" --compose "$tmp/Dockerfile.var"
mutate sh "no-verdict check removed"          'if [[ -z $refs_line ]]; then' 'if false; then' 2 "gave no verdict" "$real_lock" --compose "$compose_ok"
mutate sh "parser exit 2 not honoured"        'if ((prc == 2)); then' 'if false; then' 2 "PyYAML is not importable" "$real_lock" --compose "$compose_ok"
mutate py "compose tag compare removed"       'if tag and tag != want_tag:' 'if False:' 1 "tag differs from the lock" "$L" --compose "$tmp/wrongtag.yml"
mutate py "compose digest compare removed"    'if digest and digest != want_digest:' 'if False:' 1 "digest is not the lock's" "$L" --compose "$tmp/wrongdigest.yml"
mutate py "compose per-platform rule removed" 'if digest in platform:' 'if False:' 1 "per-platform digest" "$L" --compose "$tmp/archdigest.yml"
mutate py "compose variable rule removed"     'if "$" in image:' 'if False:' 1 "FAIL VARIABLE" "$L" --compose "$tmp/var.yml"
mutate py "zero-database rule removed"        'if db_services == 0:' 'if False:' 1 "FAIL NO-DB" "$L" --compose "$tmp/nginx.yml"
mutate py "extends rule removed"              'if "extends" in svc:' 'if False:' 1 "FAIL EXTENDS" "$L" --compose "$tmp/extends.yml"
mutate py "build rule removed"                'elif name not in nodb:' 'elif False:' 1 "FAIL BUILD" "$L" --compose "$tmp/buildargs.yml"
mutate py "build+db-image rule removed"       'if is_db:
                        fail("BUILD"' 'if False:
                        fail("BUILD"' 1 "must be the pinned image itself" "$L" --compose "$tmp/build-db.yml" --non-db-build db
mutate py "include rule removed"              'if "include" in top:' 'if False:' 1 "FAIL INCLUDE" "$L" --compose "$tmp/include.yml"
mutate py "duplicate-key rejection removed"   'if dup:' 'if False:' 1 "duplicate key" "$L" --compose "$tmp/dup-key.yml"
mutate py "single-document rule removed"      'if docs is not None and len(docs) != 1:' 'if False:' 1 "2 YAML documents" "$L" --compose "$tmp/twodocs.yml"
mutate py "empty services rule removed"       'if not isinstance(services, dict) or not services:' 'if False:' 1 "FAIL DOC" "$L" --compose "$tmp/emptysvc.yml"
mutate py "registry-prefix stripping removed" '"." in parts[0] or ":" in parts[0] or parts[0] == "localhost"' 'False' 1 "FAIL PIN" "$L" --compose "$tmp/registry-bad.yml"
mutate py "registry-prefix stripping removed (ok case)" '"." in parts[0] or ":" in parts[0] or parts[0] == "localhost"' 'False' 0 "OK db-pin-check" "$L" --compose "$tmp/registry-ts-ok.yml"
mutate py "library/ stripping removed"        'if parts[0] == "library" and len(parts) > 1:' 'if False:' 0 "OK db-pin-check" "$L" --compose "$tmp/registry-ok.yml"

echo "$ok ok, $bad failed"
((bad == 0))
