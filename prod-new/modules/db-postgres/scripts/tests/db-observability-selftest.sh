#!/usr/bin/env bash
# db-observability-selftest.sh - hermetic selftest of the database's monitoring bundle.
# NO Docker, no network: scripts/db-scrape-test.sh runs against a fake `docker` first on
# PATH that records every call and serves canned scrape text. Covers:
#   1. parity-check.sh on the real tree, and one breaking case per rule;
#   2. the exporter overlay's static rules, one breaking case each;
#   3. `promtool test rules` on the alert tests IF promtool is on PATH (else SKIP);
#   4. db-scrape-test.sh: clean, pg_up 0, a missing metric, a failing collector, a
#      published port, an elevated role, a write that works, teardown of exactly its own
#      project, --mutate revoke-monitor (RED, and a survivor), a hung docker;
#   5. mutations of the checks themselves, on scratch copies: each must turn a case RED.
# Final line: `N ok, M failed[, K skipped]`. Exit 1 if any failed.
# Needs python3 + PyYAML (the same dependency as parity-check.sh); without it the run
# FAILS, it does not skip.
set -uo pipefail
src="${BASH_SOURCE[0]}"; [[ $src == */* ]] || src="./$src"
here="$(cd "${src%/*}" && pwd)"
scripts="$(cd "$here/.." && pwd)"
dbdir="$(cd "$here/../../db" && pwd)"
obs="$dbdir/observability"
scrape="$scripts/db-scrape-test.sh"
parity="$obs/parity-check.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dbobs-selftest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
ok=0; bad=0; skipped=0
export TMPDIR="$tmp"   # the scrape test's scratch dir lands here, never in the real /tmp

if ! python3 -B -c 'import yaml' 2>/dev/null; then
  echo "FAIL prerequisite: python3 with PyYAML is required (pip install PyYAML)"
  echo "0 ok, 1 failed"; exit 1
fi

pass() { echo "ok   $1"; ok=$((ok + 1)); }
flunk() { echo "FAIL $1${2:+ ($2)}"; bad=$((bad + 1)); }
expect_ok() { # name fn args...: the case must pass
  local name="$1"; shift
  if "$@"; then pass "$name"; else flunk "$name"; fi
}
expect_red() { # name fn args...: the case must NOT pass (the mutation is noticed)
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then flunk "mutation $name: GREEN (the cases did not notice)"; else echo "RED  mutation $name"; ok=$((ok + 1)); fi
}
# tmo SECS cmd...: a hard wall-clock limit (no GNU timeout on a stock macOS)
tmo() {
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$s" "$@"
  else "$@"; fi
}
# replace_in FILE OLD NEW: literal, every occurrence; fails when OLD is absent
replace_in() {
  local f="$1" body
  body="$(cat "$f"; printf x)"; body="${body%x}"
  [[ $body == *"$2"* ]] || { echo "selftest: anchor not found in $f: $2" >&2; return 1; }
  printf '%s' "${body//"$2"/"$3"}" > "$f"
}

# ---- 1+2. parity-check.sh --------------------------------------------------------------
mk_tree() { # a scratch db/ with the observability tree and the overlay
  rm -rf "$tmp/w"; mkdir -p "$tmp/w/db"
  cp -R "$obs" "$tmp/w/db/observability"; cp "$dbdir/compose.observability.yml" "$tmp/w/db/"
}
W="$tmp/w/db"
# pcase SCRIPT SUBSTR|OK FILE OLD NEW: edit the scratch tree, run SCRIPT on it. Returns 0
# when the outcome is the expected one (exit 1 with SUBSTR in the output; or exit 0 for OK).
pcase() {
  local s="$1" want="$2" f="$3" old="$4" new="$5" out rc
  mk_tree
  if [[ -n $f ]]; then replace_in "$W/$f" "$old" "$new" || return 1; fi
  out="$(bash "$s" --dir "$W/observability" 2>&1)"; rc=$?
  if [[ $want == OK ]]; then [[ $rc == 0 && $out == *"parity-check: OK"* ]]
  else [[ $rc == 1 && $out == *"$want"* ]]; fi
}
R="observability/alerts/postgres.rules.yml"
T="observability/alerts/postgres.rules.test.yml"
RM="observability/required-metrics.txt"
RB="observability/RUNBOOK.md"
OV="compose.observability.yml"
LK="observability/image.lock"
EV="observability/exporter/exporter.env"
DIG="sha256:a88794758ad461c75f3825b51cde4bde730bdff04b3b24d00efe14217e41f615"

expect_ok "parity-check passes on the tree" pcase "$parity" OK "" "" ""
out="$(bash "$parity" 2>&1)"; rc=$?
if [[ $rc == 0 && $out == *"12 alerts"* ]]; then pass "parity-check default paths: 12 alerts read"; else flunk "parity-check default paths" "rc=$rc"; fi
expect_ok "unknown metric in an alert -> UNKNOWN-METRIC" pcase "$parity" 'UNKNOWN-METRIC: alert PostgresDown uses `pg_upp`' "$R" "expr: pg_up == 0" "expr: pg_upp == 0"
expect_ok "orphan required metric -> ORPHAN-METRIC" pcase "$parity" 'ORPHAN-METRIC: required metric `pg_orphan_x`' "$RM" "pg_up  " $'pg_orphan_x # nothing uses it\npg_up  '
expect_ok "dashboard-only orphan is allowed" pcase "$parity" OK "$RM" "pg_up  " $'pg_orphan_x # dashboard-only: panel\npg_up  '
expect_ok "alert without a firing test -> NO-FIRING-TEST" pcase "$parity" "NO-FIRING-TEST: alert PostgresWalDirectoryLarge" "$T" $'eval_time: 20m\n        alertname: PostgresWalDirectoryLarge' $'eval_time: 20m\n        alertname: PostgresWalDirectoryLargeX'
expect_ok "alert without a non-firing test -> NO-QUIET-TEST" pcase "$parity" "NO-QUIET-TEST: alert PostgresWalDirectoryLarge" "$T" "{eval_time: 5m, alertname: PostgresWalDirectoryLarge, exp_alerts: []}" "{eval_time: 5m, alertname: PostgresWalDirectoryLargeX, exp_alerts: []}"
expect_ok "test for an undefined alert -> TEST-ORPHAN" pcase "$parity" "TEST-ORPHAN: the test file names alert PostgresWalDirectoryLargeX" "$T" "{eval_time: 5m, alertname: PostgresWalDirectoryLarge, exp_alerts: []}" "{eval_time: 5m, alertname: PostgresWalDirectoryLargeX, exp_alerts: []}"
expect_ok "alert without severity -> ANNOTATION" pcase "$parity" "ANNOTATION: alert PostgresDown has no severity" "$R" $'        labels:\n          severity: critical\n        annotations:\n          summary: "PostgreSQL is not' $'        labels: {}\n        annotations:\n          summary: "PostgreSQL is not'
expect_ok "alert with an unknown severity -> ANNOTATION" pcase "$parity" "ANNOTATION: alert PostgresDown has no severity" "$R" "severity: critical
        annotations:
          summary: \"PostgreSQL is not" "severity: page-me
        annotations:
          summary: \"PostgreSQL is not"
expect_ok "alert without summary -> ANNOTATION" pcase "$parity" "ANNOTATION: alert PostgresDown has no summary" "$R" '          summary: "PostgreSQL is not reachable by its exporter"' '          x-summary: "PostgreSQL is not reachable by its exporter"'
expect_ok "alert without description -> ANNOTATION" pcase "$parity" "ANNOTATION: alert PostgresDown has no description" "$R" '          description: "pg_up has been 0' '          x-description: "pg_up has been 0'
expect_ok "alert without runbook -> ANNOTATION" pcase "$parity" "ANNOTATION: alert PostgresDown has no runbook" "$R" 'runbook: "db/observability/RUNBOOK.md#postgresdown"' 'x-runbook: "db/observability/RUNBOOK.md#postgresdown"'
expect_ok "runbook anchor missing -> RUNBOOK-ANCHOR" pcase "$parity" "RUNBOOK-ANCHOR: alert PostgresDown" "$RB" "## PostgresDown" "## Something else"
expect_ok "exporter image by tag -> OVERLAY-DIGEST" pcase "$parity" "OVERLAY-DIGEST: exporter image" "$OV" "@$DIG" ""
expect_ok "exporter image :latest -> OVERLAY-DIGEST" pcase "$parity" "OVERLAY-DIGEST: exporter image" "$OV" "postgres-exporter:v0.21.1@" "postgres-exporter:latest@"
expect_ok "overlay digest differs from image.lock -> OVERLAY-DIGEST" pcase "$parity" "differs from image.lock" "$LK" "exporter.digest = $DIG" "exporter.digest = sha256:${DIG:7:63}0"
expect_ok "placeholder digest in the lock -> OVERLAY-DIGEST" pcase "$parity" "not a sha256 digest" "$LK" "exporter.digest = $DIG" "exporter.digest = sha256:UNRESOLVED-resolve-in-a-container"
expect_ok "overlay read_only off -> OVERLAY-READONLY" pcase "$parity" "OVERLAY-READONLY" "$OV" "read_only: true" "read_only: false"
expect_ok "overlay cap_drop not ALL -> OVERLAY-CAPDROP" pcase "$parity" "OVERLAY-CAPDROP" "$OV" "cap_drop: [ALL]" "cap_drop: [NET_RAW]"
expect_ok "overlay no-new-privileges gone -> OVERLAY-NNP" pcase "$parity" "OVERLAY-NNP" "$OV" 'security_opt: ["no-new-privileges:true"]' 'security_opt: []'
expect_ok "overlay runs as root -> OVERLAY-USER" pcase "$parity" "OVERLAY-USER" "$OV" 'user: "65534:65534"' 'user: "0:0"'
expect_ok "overlay without a user -> OVERLAY-USER" pcase "$parity" "OVERLAY-USER" "$OV" '    user: "65534:65534"' '    x-note: none'
expect_ok "overlay publishes a port -> OVERLAY-PORTS" pcase "$parity" "OVERLAY-PORTS" "$OV" $'    expose:\n      - "9187"' $'    expose:\n      - "9187"\n    ports:\n      - "9187:9187"'
expect_ok "overlay without the secret -> OVERLAY-SECRET" pcase "$parity" "OVERLAY-SECRET: exporter must mount" "$OV" $'    secrets:\n      - db_monitor_password' '    secrets: []'
expect_ok "password in the environment -> OVERLAY-SECRET" pcase "$parity" "OVERLAY-SECRET: DATA_SOURCE_PASS puts a password" "$EV" "DATA_SOURCE_USER=app_monitor" $'DATA_SOURCE_USER=app_monitor\nDATA_SOURCE_PASS=hunter2'
expect_ok "password in the URI -> OVERLAY-SECRET" pcase "$parity" "OVERLAY-SECRET: DATA_SOURCE_URI carries a password" "$EV" "DATA_SOURCE_URI=db:5432" "DATA_SOURCE_URI=postgresql://app_monitor:hunter2@db:5432"
expect_ok "overlay without a healthcheck -> OVERLAY-HEALTHCHECK" pcase "$parity" "OVERLAY-HEALTHCHECK" "$OV" "    healthcheck:" "    x-healthcheck:"
expect_ok "sslmode weakened -> OVERLAY-TLS" pcase "$parity" "OVERLAY-TLS" "$EV" "sslmode=verify-full" "sslmode=require"
expect_ok "stat_checkpointer collector off -> OVERLAY-COLLECTORS" pcase "$parity" "OVERLAY-COLLECTORS: exporter command lacks --collector.stat_checkpointer" "$OV" "      - --collector.stat_checkpointer
" ""
expect_ok "exporter not waiting for a healthy db -> OVERLAY-DEPENDS" pcase "$parity" "OVERLAY-DEPENDS" "$OV" "condition: service_healthy" "condition: service_started"
expect_ok "privileged exporter -> OVERLAY-PRIVILEGE" pcase "$parity" "OVERLAY-PRIVILEGE" "$OV" "    read_only: true" $'    read_only: true\n    privileged: true'

# a missing PyYAML must be exit 2, not a green: python3 shim that cannot import yaml
mkdir -p "$tmp/noyaml"; printf '#!/bin/sh\nexit 1\n' > "$tmp/noyaml/python3"; chmod +x "$tmp/noyaml/python3"
out="$(PATH="$tmp/noyaml:$PATH" bash "$parity" 2>&1)"; rc=$?
if [[ $rc == 2 && $out == *"PyYAML is not importable"* ]]; then pass "no PyYAML -> exit 2, never green"; else flunk "no PyYAML -> exit 2" "rc=$rc"; fi

# ---- 3. promtool ----------------------------------------------------------------------------
if command -v promtool >/dev/null 2>&1; then
  pt() { (cd "$1" && promtool test rules postgres.rules.test.yml >"$tmp/pt.out" 2>&1); }
  expect_ok "promtool test rules passes on the alert tests" pt "$obs/alerts"
  # the tests must be able to go red: raise one threshold on a scratch copy
  mkdir -p "$tmp/pt"; cp "$obs/alerts/"*.yml "$tmp/pt/"
  replace_in "$tmp/pt/postgres.rules.yml" "pg_wal_size_bytes > 4e9" "pg_wal_size_bytes > 4e19" && expect_red "alert threshold changed: promtool test goes red" pt "$tmp/pt"
else
  echo "SKIP promtool test rules: no promtool on PATH (the parity check still proves every alert has a firing and a non-firing case by reading the test file; db-scrape-test.sh --promtool runs it in the pinned Prometheus image)"
  skipped=$((skipped + 1))
fi

# ---- 4. db-scrape-test.sh against a fake docker ------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/empty"
cat > "$tmp/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
[[ ${FAKE_HANG:-0} == 1 ]] && exec sleep "${FAKE_HANG_S:-60}"
args="$*"; lastarg="${*: -1}"
case "$1" in
  compose)
    case "$args" in
      *" down -v "*) exit 0 ;;
      *" up -d --wait"*) exit "${FAKE_UP_RC:-0}" ;;
      *" port exporter 9187"*)
        if [[ ${FAKE_PUBLISHED:-0} == 1 ]]; then echo "0.0.0.0:9187"; exit 0; fi
        echo "no port 9187/tcp for container" >&2; exit 1 ;;
      *" exec -T db wget "*)
        if [[ -e $FAKE_LOG.revoked && ${FAKE_REVOKE_NOOP:-0} != 1 ]]; then cat "$FAKE_METRICS_REVOKED"; else cat "$FAKE_METRICS"; fi
        exit 0 ;;
      *" exec -T db sh -c "*)
        case "$lastarg" in
          *"REVOKE pg_monitor"*) : > "$FAKE_LOG.revoked"; exit 0 ;;
          *rolsuper*) echo "${FAKE_ROLSUPER:-f}"; exit 0 ;;
          "CREATE TABLE public.monitor_write_probe"* | "INSERT INTO"*)
            [[ ${FAKE_WRITE_OK:-0} == 1 ]] && exit 0
            echo "ERROR:  permission denied for schema public" >&2; exit 1 ;;
        esac ;;
    esac
    exit 0 ;;
  run) exit "${FAKE_RUN_RC:-0}" ;;
esac
exit 0
FAKE
chmod +x "$tmp/bin/docker"

# canned scrapes from the REAL contract: every required name once, so a rename in
# required-metrics.txt keeps this selftest consistent
names=()
while IFS= read -r l; do
  l="${l%%#*}"; l="${l//[[:space:]]/}"; [[ -n $l ]] && names+=("$l")
done < "$obs/required-metrics.txt"
nreq=${#names[@]}
{ echo "# canned scrape"; echo "pg_up 1"
  for n in "${names[@]}"; do [[ $n == pg_up ]] || echo "$n{datname=\"app\"} 1"; done
  echo 'pg_scrape_collector_success{collector="wal"} 1'; } > "$tmp/m.ok"
sed 's/^pg_up 1$/pg_up 0/' "$tmp/m.ok" > "$tmp/m.pgup0"
grep -v '^pg_wal_size_bytes' "$tmp/m.ok" > "$tmp/m.missing"
{ cat "$tmp/m.ok"; echo 'pg_scrape_collector_success{collector="stat_statements"} 0'; } > "$tmp/m.collector"
grep -v -E '^pg_wal_(size_bytes|segments)' "$tmp/m.ok" | sed 's/collector="wal"} 1/collector="wal"} 0/' > "$tmp/m.revoked"

# srun SCRIPT [VAR=val...] [-- args...]: sets out, rc, and the fake's call log in $tmp/log
srun() {
  local s="$1"; shift
  local envs=()
  while (($#)) && [[ $1 != -- ]]; do envs+=("$1"); shift; done
  (($#)) && shift
  : > "$tmp/log"; rm -f "$tmp/log.revoked"
  out="$(env PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" FAKE_METRICS="$tmp/m.ok" FAKE_METRICS_REVOKED="$tmp/m.revoked" \
    ${envs[@]+"${envs[@]}"} bash "$s" "$@" 2>&1)"; rc=$?
}
projof() { [[ $out =~ \((dbscrape-[0-9]+) ]] && echo "${BASH_REMATCH[1]}"; }

sc_clean() { srun "$1"; [[ $rc == 0 && $out == *"db-scrape-test: $((nreq + 7)) assertions, $((nreq + 7)) ok, 0 failed"* ]]; }
sc_pgup() { srun "$1" FAKE_METRICS="$tmp/m.pgup0"; [[ $rc == 1 && $out == *"FAIL pg-up: pg_up is '0'"* ]]; }
sc_missing() { srun "$1" FAKE_METRICS="$tmp/m.missing"; [[ $rc == 1 && $out == *"FAIL required-metric pg_wal_size_bytes"* ]]; }
sc_collector() { srun "$1" FAKE_METRICS="$tmp/m.collector"; [[ $rc == 1 && $out == *"FAIL collectors-succeed: failing: collector=\"stat_statements\""* ]]; }
sc_published() { srun "$1" FAKE_PUBLISHED=1; [[ $rc == 1 && $out == *"FAIL exporter-not-published"* ]]; }
sc_super() { srun "$1" FAKE_ROLSUPER=t; [[ $rc == 1 && $out == *"FAIL monitor-not-superuser"* ]]; }
sc_write() { srun "$1" FAKE_WRITE_OK=1; [[ $rc == 1 && $out == *"FAIL monitor-cannot-create"* && $out == *"FAIL monitor-cannot-write"* ]]; }
sc_nodocker() { out="$(env PATH="$tmp/empty" "$BASH" "$1" 2>&1)"; rc=$?; [[ $rc == 2 && $out == *"docker not found"* ]]; }
# teardown: exactly one `down -v`, of the project the run printed, and no docker call at
# all outside that project; two runs never share a project name
sc_teardown() {
  local p1 p2 line downs=0 foreign=0
  srun "$1"; p1="$(projof)"; [[ $p1 =~ ^dbscrape-[0-9]+$ ]] || return 1
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    case "$line" in
      "compose -p $p1 "*) [[ $line == *" down -v "* ]] && downs=$((downs + 1)) ;;
      *) foreign=$((foreign + 1)) ;;
    esac
  done < "$tmp/log"
  ((downs == 1 && foreign == 0)) || return 1
  [[ $(tail -n 1 "$tmp/log") == "compose -p $p1 "*" down -v --remove-orphans" ]] || return 1  # last call of all
  srun "$1"; p2="$(projof)"; [[ -n $p2 && $p2 != "$p1" ]]
}
sc_teardown_on_failed_start() {
  srun "$1" FAKE_UP_RC=1
  [[ $rc == 2 && $out == *"FAIL START"* ]] || return 1
  grep -q -E '^compose -p dbscrape-[0-9]+ .* down -v --remove-orphans$' "$tmp/log"
}
sc_teardown_on_failed_assertion() {
  srun "$1" FAKE_METRICS="$tmp/m.pgup0"; grep -q -E '^compose -p dbscrape-[0-9]+ .* down -v --remove-orphans$' "$tmp/log"
}
sc_mutate() {
  srun "$1" -- --mutate revoke-monitor
  [[ $rc == 1 && $out == *"RED as intended"* ]] && grep -q 'REVOKE pg_monitor FROM app_monitor' "$tmp/log" \
    && grep -q -E ' down -v ' "$tmp/log"
}
sc_mutate_survivor() { srun "$1" FAKE_REVOKE_NOOP=1 -- --mutate revoke-monitor; [[ $rc == 4 && $out == *"MUTATION SURVIVED"* ]]; }
sc_no_revoke_without_mutate() { srun "$1"; ! grep -q 'REVOKE' "$tmp/log"; }
sc_hang() {
  local t0=$SECONDS
  out="$(tmo 30 env PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" FAKE_HANG=1 FAKE_HANG_S="${HANGS:-60}" DB_SCRAPE_BUDGET_S=2 DB_SCRAPE_CLEANUP_S=1 bash "$1" 2>&1)"; rc=$?
  ((SECONDS - t0 <= 8)) && [[ $rc == 2 && $out == *"FAIL START"* ]]
}
sc_hang_short() { HANGS=4 sc_hang "$1"; }
sc_promtool() {
  srun "$1" -- --promtool
  local runl; runl="$(grep '^run ' "$tmp/log" | head -n 1)"; local p; p="$(projof)"
  [[ $rc == 0 && $runl == *"--name $p-promtool"* && $runl == *"--network none"* && $runl == *"--cpus 1"* && $runl == *"--memory 1g"* \
    && $runl == *"quay.io/prometheus/prometheus:v3.16.0@sha256:"* ]] && grep -q "^rm -f $p-promtool\$" "$tmp/log"
}
sc_promtool_off() { srun "$1"; ! grep -q '^run ' "$tmp/log"; }
sc_usage() { out="$(bash "$1" --bogus 2>&1)"; rc=$?; [[ $rc == 2 && $out == *usage* ]]; }

expect_ok "scrape test: clean scrape -> exit 0, every assertion passed" sc_clean "$scrape"
expect_ok "scrape test: pg_up 0 -> RED" sc_pgup "$scrape"
expect_ok "scrape test: a required metric missing -> RED naming it" sc_missing "$scrape"
expect_ok "scrape test: a failing collector -> RED" sc_collector "$scrape"
expect_ok "scrape test: exporter port published on the host -> RED" sc_published "$scrape"
expect_ok "scrape test: monitor role elevated -> RED" sc_super "$scrape"
expect_ok "scrape test: monitor role can write -> RED" sc_write "$scrape"
expect_ok "scrape test: docker missing -> exit 2" sc_nodocker "$scrape"
expect_ok "scrape test: unknown option -> exit 2" sc_usage "$scrape"
expect_ok "scrape test: teardown is down -v of its own unique project, last, nothing foreign" sc_teardown "$scrape"
expect_ok "scrape test: teardown also after a failed start" sc_teardown_on_failed_start "$scrape"
expect_ok "scrape test: teardown also after a failed assertion" sc_teardown_on_failed_assertion "$scrape"
expect_ok "scrape test: no revoke without --mutate" sc_no_revoke_without_mutate "$scrape"
expect_ok "scrape test: --mutate revoke-monitor issues the revoke, goes RED, tears down" sc_mutate "$scrape"
expect_ok "scrape test: a mutation that stays green -> exit 4" sc_mutate_survivor "$scrape"
expect_ok "scrape test: a hung docker -> gives up within the budget (exit 2)" sc_hang "$scrape"
expect_ok "scrape test: --promtool runs the pinned image, own name, no network, removed" sc_promtool "$scrape"
expect_ok "scrape test: no promtool container without --promtool" sc_promtool_off "$scrape"
# the call shapes the real docker needs (a fake cannot prove the real flags; these pin them)
srun "$scrape"
if grep -q -E '^compose -p dbscrape-[0-9]+ --env-file [^ ]+ -f [^ ]+/compose.yml -f [^ ]+/compose.observability.yml up -d --wait --wait-timeout [0-9]+$' "$tmp/log"; then pass "up uses both compose files and a bounded --wait"; else flunk "up call shape: $(grep ' up ' "$tmp/log")"; fi
if grep -q ' exec -T db wget -q -O - http://exporter:9187/metrics$' "$tmp/log"; then pass "the scrape goes from the db container to the exporter by service name"; else flunk "scrape call shape"; fi

# ---- 5. mutations of the checks themselves -----------------------------------------------------
mutant() { # SRC NAME ANCHOR REPL -> $tmp/mut/NAME (a scratch copy; the real file is untouched)
  mkdir -p "$tmp/mut"; cp "$1" "$tmp/mut/$2"
  replace_in "$tmp/mut/$2" "$3" "$4"
}
m_scrape() { mutant "$scrape" scrape.sh "$1" "$2"; }
if m_scrape 'if [[ $l == "PASS "* ]]; then emit PASS "required-metric ${l#PASS }"; else emit FAIL "required-metric ${l#FAIL }" "absent from the scrape"; fi' 'emit PASS "required-metric ${l#* }"'; then
  expect_red "scrape test: required-metric check removed" sc_missing "$tmp/mut/scrape.sh"; fi
if m_scrape 'if [[ $up == 1 ]]; then' 'if true; then'; then
  expect_red "scrape test: pg_up check removed" sc_pgup "$tmp/mut/scrape.sh"; fi
if m_scrape 'proj="dbscrape-$$"' 'proj="dbscrape-fixed"'; then
  expect_red "scrape test: cleanup/project with a fixed name instead of the unique one" sc_teardown "$tmp/mut/scrape.sh"; fi
if m_scrape 'trap cleanup EXIT' ':'; then
  expect_red "scrape test: teardown trap removed" sc_teardown "$tmp/mut/scrape.sh"; fi
if m_scrape 'if bounded "$(cap 8)" "${DC[@]}" port exporter 9187 && [[ $(cat "$last") == *:* ]]; then' 'if false; then'; then
  expect_red "scrape test: published-port check removed" sc_published "$tmp/mut/scrape.sh"; fi
if m_scrape 'if ! sup_psql '"'"'REVOKE pg_monitor FROM app_monitor'"'"'; then' 'if false; then'; then
  expect_red "scrape test: --mutate no longer revokes" sc_mutate "$tmp/mut/scrape.sh"; fi
if m_scrape '    if ((fail > 0)); then echo "RED as intended: --mutate $mutate was detected"; exit 1; fi' '    if true; then echo "RED as intended: --mutate $mutate was detected"; exit 1; fi'; then
  expect_red "scrape test: a surviving mutation reported as RED" sc_mutate_survivor "$tmp/mut/scrape.sh"; fi
if m_scrape 'kill -KILL "$pid" 2>/dev/null' 'true'; then
  # the watchdog no longer kills: each hung call runs its full 4 s, three calls exceed the 8 s allowance
  expect_red "scrape test: watchdog kill removed (hung docker is no longer bounded)" sc_hang_short "$tmp/mut/scrape.sh"; fi
# parity-check mutations: run a breaking case against the weakened rule
pm() { mutant "$parity" parity-check.sh "$1" "$2"; }
if pm '    if name not in fires:' '    if False:'; then
  expect_red "parity rule 'alert has a firing test' removed" pcase "$tmp/mut/parity-check.sh" "NO-FIRING-TEST: alert PostgresWalDirectoryLarge" "$T" $'eval_time: 20m\n        alertname: PostgresWalDirectoryLarge' $'eval_time: 20m\n        alertname: PostgresWalDirectoryLargeX'; fi
if pm '    if name not in quiet:' '    if False:'; then
  expect_red "parity rule 'alert has a non-firing test' removed" pcase "$tmp/mut/parity-check.sh" "NO-QUIET-TEST: alert PostgresWalDirectoryLarge" "$T" "{eval_time: 5m, alertname: PostgresWalDirectoryLarge, exp_alerts: []}" "{eval_time: 5m, alertname: PostgresWalDirectoryLargeX, exp_alerts: []}"; fi
if pm 'if not re.fullmatch(r"[^@\s]+:[^@\s:/]+@sha256:[0-9a-f]{64}", image) or ":latest@" in image:' 'if False:'; then
  if replace_in "$tmp/mut/parity-check.sh" 'if image != want:' 'if False:'; then
    expect_red "parity digest check removed" pcase "$tmp/mut/parity-check.sh" "OVERLAY-DIGEST: exporter image" "$OV" "@$DIG" ""; fi; fi
if pm '    for m in sorted(ms - set(required)):' '    for m in []:'; then
  expect_red "parity rule 'metric is in the contract' removed" pcase "$tmp/mut/parity-check.sh" "UNKNOWN-METRIC" "$R" "expr: pg_up == 0" "expr: pg_upp == 0"; fi
if pm '    if m not in used and not dash:' '    if False:'; then
  expect_red "parity rule 'no orphan metric' removed" pcase "$tmp/mut/parity-check.sh" "ORPHAN-METRIC" "$RM" "pg_up  " $'pg_orphan_x # nothing uses it\npg_up  '; fi
if pm 'if svc.get("ports"):' 'if False:'; then
  expect_red "port published by default: overlay ports check removed" pcase "$tmp/mut/parity-check.sh" "OVERLAY-PORTS" "$OV" $'    expose:\n      - "9187"' $'    expose:\n      - "9187"\n    ports:\n      - "9187:9187"'; fi
if pm 'if not path.endswith("RUNBOOK.md") or not anchor or anchor not in anchors:' 'if False:'; then
  expect_red "parity runbook anchor check removed" pcase "$tmp/mut/parity-check.sh" "RUNBOOK-ANCHOR" "$RB" "## PostgresDown" "## Something else"; fi
if ((skipped > 0)); then echo "$ok ok, $bad failed, $skipped skipped"; else echo "$ok ok, $bad failed"; fi
((bad == 0))
