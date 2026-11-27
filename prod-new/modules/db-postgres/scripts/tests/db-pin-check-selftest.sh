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
real_lock="$here/../../db/image.lock"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export DB_PIN_TODAY="2026-11-27"
unset DB_PIN_WARN_DAYS DB_PIN_FAIL_DAYS

ok=0; bad=0
PG_D=sha256:0115267ab5a509022df9319c77be365cef335adb71556c75f60f5360ee247e71
TS_D=sha256:70e6526ad8e31e3f4833f2c5863b50b92d7a6bee4d432ad1f660e2c6dd956d94

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
check "unrelated pinned image is ok"          0 "OK db-pin-check" "$real_lock" --compose "$tmp/other.yml"
check "unpinned Dockerfile FROM is RED"       1 "FAIL DIGEST" "$real_lock" --compose "$tmp/Dockerfile.bad"
check "compose without any image only warns"  0 "no image reference found" "$real_lock" --compose "$tmp/noimage.yml"

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
exc='s/^postgres.server_version = .*/postgres.server_version = 18.8/'
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

# ---- mutations: break one rule in a scratch copy, the case must go RED -------
# mutate <name> <anchor> <replacement> <case-rc> <case-substr> <args...>
mutate() {
  local name="$1" anchor="$2" repl="$3" erc="$4" esub="$5"; shift 5
  local m="$tmp/mut.sh" body; body="$(cat "$script")"
  if [[ $body != *"$anchor"* ]]; then echo "FAIL mutation $name: anchor not found"; bad=$((bad + 1)); return; fi
  printf '%s\n' "${body//"$anchor"/"$repl"}" > "$m"
  if run "$m" "$erc" "$esub" "$@"; then
    echo "FAIL mutation $name: GREEN (the case did not notice)"; bad=$((bad + 1))
  else echo "RED  mutation $name"; ok=$((ok + 1)); fi
}
mutate "pair rule removed"        'if [[ $pg_sv != "$ts_sv" ]]; then' 'if false; then' 1 "FAIL PAIR" "$tmp/l-pair"
mutate "latest check removed (compose)" '$tag == *latest* ]]; then fail LATEST' '$tag == NEVER ]]; then fail LATEST' 1 "floating tag" "$real_lock" --compose "$tmp/latest.yml"
mutate "latest check removed (lock)"    '[[ $2 == latest || $2 == *latest* ]]' 'false' 1 "floating tag" "$tmp/l-latest"
mutate "digest format check removed"    'digest_ok() { [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]]; }' 'digest_ok() { true; }' 1 "malformed digest" "$tmp/l-baddigest"
mutate "digest presence check removed"  'if [[ -z $dg ]]; then fail DIGEST' 'if false; then fail DIGEST' 1 "has no @sha256" "$real_lock" --compose "$tmp/nodigest.yml"
mutate "major check removed"            '[[ $maj == 18 ]] ||' 'true ||' 1 "is not PostgreSQL 18" "$tmp/l-pg19"
mutate "exception expiry ignored"       'elif ((ex_n < today_n)); then' 'elif false; then' 1 "pair_exception expired" "$tmp/l-exc-old"
DB_PIN_TODAY=2027-11-27 mutate "stale fail threshold ignored" 'elif ((age >= fail_days)); then' 'elif false; then' 1 "FAIL STALE" "$real_lock"

echo "$ok ok, $bad failed"
((bad == 0))
