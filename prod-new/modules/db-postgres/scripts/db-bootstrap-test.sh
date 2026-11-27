#!/usr/bin/env bash
# db-bootstrap-test.sh — start the module's database from its compose file in a
# throwaway project and prove the bootstrap with SQL assertions against the REAL
# server: roles, authentication, TLS, settings, extensions, timeouts, health,
# persistence. One PASS/FAIL line per assertion.
#
#   db-bootstrap-test.sh [--variant plain|timescale] [--db-dir DIR]
#
#   --variant   plain (default) = compose.yml; timescale = + compose.timescale.yml
#   --db-dir    the directory holding compose.yml and conf/, bootstrap/ (default
#               ../db next to this script; point it at a scratch COPY to test a
#               mutation)
#
# Docker: every container, network and volume belongs to a compose project named
# `dbboot-<pid>` (so each is named with the `dbboot-` prefix), runs with the
# compose file's `cpus: 1`/`mem_limit: 1g`, publishes no host port, and is
# removed on every exit path. Passwords are random, written to a 0600 file in a
# scratch dir, and read by the containers from their own environment: they are
# never put on a command line.
#
# Exit: 0 every assertion passed and the count matches what was generated ·
#       1 at least one FAIL · 2 the database could not be started (nothing
#       asserted; never "0 assertions = pass").
set -uo pipefail

variant=plain
here="${BASH_SOURCE[0]%/*}"; [[ $here == "${BASH_SOURCE[0]}" ]] && here="."
dbdir="$here/../db"
while (($#)); do
  case "$1" in
    --variant) variant="${2:-}"; shift ;;
    --db-dir) dbdir="${2:-}"; shift ;;
    *) echo "usage: db-bootstrap-test.sh [--variant plain|timescale] [--db-dir DIR]" >&2; exit 2 ;;
  esac
  shift
done
case "$variant" in plain | timescale) ;; *) echo "FAIL USAGE: --variant must be plain or timescale" >&2; exit 2 ;; esac
dbdir="$(cd "$dbdir" 2>/dev/null && pwd)" || { echo "FAIL USAGE: db dir not found" >&2; exit 2; }
files=(-f "$dbdir/compose.yml")
[[ $variant == timescale ]] && files+=(-f "$dbdir/compose.timescale.yml")
for f in "${files[@]}"; do [[ $f == -f ]] || [[ -r $f ]] || { echo "FAIL START: cannot read $f" >&2; exit 2; }; done
command -v docker >/dev/null || { echo "FAIL START: docker not found" >&2; exit 2; }

proj="dbboot-$$"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/dbboot.XXXXXX")" || exit 2
envf="$scratch/env"
pass=0; fail=0; expected=0
dc() { docker compose -p "$proj" --env-file "$envf" "${files[@]}" "$@"; }
cleanup() {
  dc down -v --remove-orphans >/dev/null 2>&1
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

rnd() { head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
pw_su="su$(rnd)"; pw_mig="mg$(rnd)"; pw_app="ap$(rnd)"; pw_ro="ro$(rnd)"; pw_mon="mo$(rnd)"
(
  umask 077
  printf 'DB_SUPERUSER_PASSWORD=%s\nDB_MIGRATOR_PASSWORD=%s\nDB_APP_PASSWORD=%s\nDB_READONLY_PASSWORD=%s\nDB_MONITOR_PASSWORD=%s\n' \
    "$pw_su" "$pw_mig" "$pw_app" "$pw_ro" "$pw_mon" > "$envf"
)

emit() { # PASS|FAIL name [detail]
  if [[ $1 == PASS ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
  echo "$1 $2${3:+: $3}"
}

# ---- start -------------------------------------------------------------------
# `up -d` pulls an image that is absent (compose's default policy is "missing"; no
# `--pull never` anywhere), and that happens HERE, before the health wait below, so a
# fresh runner's first pull is bounded by the caller's timeout, never by the wait.
cid=""
if ! dc up -d >"$scratch/up.log" 2>&1; then
  echo "FAIL START: docker compose up failed:"; tail -n 8 "$scratch/up.log"; exit 2
fi
cid="$(dc ps -aq db 2>/dev/null)"
[[ -n $cid ]] || { echo "FAIL START: no db container"; exit 2; }

# 0 healthy · 1 timed out (still running) · 2 exited
wait_healthy() {
  local i st
  for ((i = 0; i < 60; i++)); do
    st="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" 2>/dev/null)"
    case "$st" in
      "running healthy") return 0 ;;
      exited* | dead*) return 2 ;;
    esac
    sleep 0.5
  done
  return 1
}
wait_healthy; rc=$?
if ((rc == 2)); then
  echo "FAIL START: the database container exited before becoming healthy; last log lines:"
  docker logs --tail 15 "$cid" 2>&1
  exit 2
fi
unhealthy=0
image="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)"; image="${image:-unknown}"
if ((rc == 1)); then
  unhealthy=1
  expected=$((expected + 1))
  emit FAIL healthcheck-reaches-healthy "not healthy within 30s; health log: $(docker inspect -f '{{if .State.Health}}{{range .State.Health.Log}}{{.Output}}{{end}}{{end}}' "$cid" 2>/dev/null | tail -n 3 | tr '\n' ' ')"
  # Fail fast: every later session needs a healthy server and would only add
  # connection timeouts (the run used to take ~90 s here). The wait is 30 s; the
  # teardown comes on top, so a never-healthy run ends well inside 45 s.
  echo "db-bootstrap-test: $((pass + fail)) assertions, $pass ok, $fail failed ($image)"
  exit 1
else
  expected=$((expected + 1)); emit PASS healthcheck-reaches-healthy
fi

# ---- assertion machinery ------------------------------------------------------
# A session is a bash string of DO blocks; each block RAISEs one NOTICE line
# `PASS name` / `FAIL name`. chk: boolean SQL expression must be true.
# deny: the statement must fail with insufficient_privilege. allow: must succeed.
S=""; S_n=0
chk() {
  S_n=$((S_n + 1))
  S+="DO \$x\$ DECLARE ok boolean; BEGIN EXECUTE \$s\$SELECT coalesce(($2), false)\$s\$ INTO ok; RAISE NOTICE '%', CASE WHEN ok THEN 'PASS $1' ELSE 'FAIL $1' END; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'FAIL $1: %', SQLERRM; END \$x\$;"$'\n'
}
deny() {
  S_n=$((S_n + 1))
  S+="DO \$x\$ BEGIN EXECUTE \$s\$$2\$s\$; RAISE NOTICE 'FAIL $1: the statement succeeded'; EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'PASS $1'; WHEN OTHERS THEN RAISE NOTICE 'FAIL $1: %', SQLERRM; END \$x\$;"$'\n'
}
allow() {
  S_n=$((S_n + 1))
  S+="DO \$x\$ BEGIN EXECUTE \$s\$$2\$s\$; RAISE NOTICE 'PASS $1'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'FAIL $1: %', SQLERRM; END \$x\$;"$'\n'
}
# collect <session> <expected-count> <output>
collect() {
  local name="$1" want="$2" out="$3" l got=0 first=""
  while IFS= read -r l; do
    [[ -z $first && -n $l ]] && first="$l"
    case "$l" in
      *"NOTICE:  PASS "*) l="${l#*NOTICE:  PASS }"; emit PASS "$l"; got=$((got + 1)) ;;
      *"NOTICE:  FAIL "*) l="${l#*NOTICE:  FAIL }"; emit FAIL "$l"; got=$((got + 1)) ;;
    esac
  done <<<"$out"
  expected=$((expected + want))
  if ((got != want)); then
    emit FAIL "$name-assertions-ran" "expected $want assertion lines, got $got; first output line: ${first:-none}"
  fi
}
# run <session> <user> <password-env-var> <sslmode> [host] — executes $S, then resets it.
# The superuser sessions use the unix socket (no TLS) so that a TLS regression shows up
# as the assertions that name it, not as a connection failure of the whole session.
run() {
  local out
  out="$(docker exec -i "$cid" sh -c "PGPASSWORD=\"\$$3\" PGSSLMODE=$4 PGCONNECT_TIMEOUT=5 exec psql -X -q -At -h ${5:-127.0.0.1} -U $2 -d app" <<<"$S" 2>&1)"
  collect "$1" "$S_n" "$out"
  S=""; S_n=0
}

# ---- static: nothing secret in the module ------------------------------------
expected=$((expected + 1))
if grep -rIlE 'PRIVATE KEY|PASSWORD[[:space:]]+'"'" "$dbdir/bootstrap" "$dbdir/conf" "$dbdir/compose.yml" "$dbdir/compose.timescale.yml" >/dev/null 2>&1; then
  emit FAIL no-secret-literal-in-module "a private key or PASSWORD '<literal>' is committed"
else
  emit PASS no-secret-literal-in-module
fi

# ---- S0: structure, as the bootstrap superuser --------------------------------
# hba
# hba_file reports source=override (set from the command-line config_file), so it is
# checked by value, and the rules by the file they were read from.
chk setting-hba_file "current_setting('hba_file') = '/etc/postgresql/pg_hba.conf' AND (SELECT count(*) FROM pg_hba_file_rules WHERE file_name <> '/etc/postgresql/pg_hba.conf') = 0"
chk hba-has-rules "(SELECT count(*) FROM pg_hba_file_rules) > 0"
chk hba-no-parse-errors "(SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL) = 0"
chk hba-every-rule-scram-sha-256 "(SELECT count(*) FROM pg_hba_file_rules WHERE auth_method IS DISTINCT FROM 'scram-sha-256') = 0"
chk hba-tcp-rules-are-hostssl-only "(SELECT count(*) FROM pg_hba_file_rules WHERE type IN ('host','hostnossl','hostgssenc','hostnogssenc')) = 0 AND (SELECT count(*) FROM pg_hba_file_rules WHERE type = 'hostssl') > 0"
# roles
chk only-the-bootstrap-superuser-is-superuser "(SELECT array_agg(rolname::text) FROM pg_roles WHERE rolsuper) = ARRAY['postgres']"
chk five-app-roles-exist "(SELECT count(*) FROM pg_roles WHERE rolname IN ('app_owner','app_migrator','app_rw','app_ro','app_monitor')) = 5"
chk no-app-role-has-dangerous-attributes "(SELECT count(*) FROM pg_roles WHERE rolname LIKE 'app\_%' AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) = 0"
chk no-role-but-the-superuser-bypasses-rls "(SELECT count(*) FROM pg_roles WHERE rolbypassrls AND NOT rolsuper) = 0"
chk owner-cannot-login "NOT (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'app_owner')"
chk the-other-four-can-login "(SELECT count(*) FROM pg_roles WHERE rolname IN ('app_migrator','app_rw','app_ro','app_monitor') AND rolcanlogin) = 4"
chk every-stored-password-is-scram "(SELECT count(*) FROM pg_authid WHERE rolpassword IS NOT NULL) >= 5 AND (SELECT count(*) FROM pg_authid WHERE rolpassword IS NOT NULL AND rolpassword NOT LIKE 'SCRAM-SHA-256\$%') = 0"
chk monitor-is-member-of-pg_monitor-only "(SELECT array_agg(g.rolname::text ORDER BY g.rolname) FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid WHERE m.member = 'app_monitor'::regrole) = ARRAY['pg_monitor']"
chk only-the-migrator-is-member-of-owner "(SELECT array_agg(m.member::regrole::text) FROM pg_auth_members m WHERE m.roleid = 'app_owner'::regrole) = ARRAY['app_migrator']"
chk app-schema-is-owned-by-the-owner "(SELECT nspowner::regrole::text FROM pg_namespace WHERE nspname = 'app') = 'app_owner'"
# schema and database privileges
chk public-has-no-create-on-schema-public "NOT EXISTS (SELECT 1 FROM pg_namespace n, aclexplode(n.nspacl) a WHERE n.nspname = 'public' AND a.grantee = 0 AND a.privilege_type = 'CREATE')"
chk no-app-role-can-create-in-public "NOT (has_schema_privilege('app_rw','public','CREATE') OR has_schema_privilege('app_ro','public','CREATE') OR has_schema_privilege('app_migrator','public','CREATE') OR has_schema_privilege('app_monitor','public','CREATE') OR has_schema_privilege('app_owner','public','CREATE'))"
chk app-roles-cannot-create-in-the-database "NOT (has_database_privilege('app_rw','app','CREATE') OR has_database_privilege('app_ro','app','CREATE') OR has_database_privilege('app_migrator','app','CREATE') OR has_database_privilege('app_monitor','app','CREATE'))"
chk public-has-no-database-privileges "NOT EXISTS (SELECT 1 FROM pg_database d, aclexplode(d.datacl) a WHERE d.datname = 'app' AND a.grantee = 0)"
# settings: value AND origin (our config file), so a default can not pass by accident
settings=(
  "password_encryption=scram-sha-256" "ssl=on" "ssl_min_protocol_version=TLSv1.3"
  "ssl_cert_file=/tls/server.crt" "ssl_key_file=/tls/server.key" "listen_addresses=*"
  "compute_query_id=on" "track_io_timing=on"
  "pg_stat_statements.track=top" "log_lock_waits=on" "log_temp_files=10240"
  "log_min_duration_statement=250" "log_checkpoints=on" "log_autovacuum_min_duration=1000"
  "log_statement=ddl" "log_parameter_max_length=0" "log_parameter_max_length_on_error=0"
  "log_connections=receipt,authentication,authorization" "log_disconnections=on"
)
for kv in "${settings[@]}"; do
  k="${kv%%=*}"; v="${kv#*=}"
  chk "setting-$k" "(SELECT setting = '$v' AND source = 'configuration file' AND sourcefile LIKE '/etc/postgresql/%' FROM pg_settings WHERE name = '$k')"
done
want_spl="pg_stat_statements"; [[ $variant == timescale ]] && want_spl="timescaledb,pg_stat_statements"
chk "setting-shared_preload_libraries" "(SELECT setting = '$want_spl' AND sourcefile LIKE '/etc/postgresql/%' FROM pg_settings WHERE name = 'shared_preload_libraries')"
chk "setting-data_directory-is-the-pg18-layout" "current_setting('data_directory') = '/var/lib/postgresql/18/docker'"
chk "setting-data_checksums" "current_setting('data_checksums') = 'on'"
chk "setting-server_version" "current_setting('server_version') LIKE '18.%'"
chk "no-setting-is-pending-restart" "NOT EXISTS (SELECT 1 FROM pg_settings WHERE pending_restart)"
chk "parameter-values-are-not-logged" "current_setting('log_parameter_max_length') = '0' AND current_setting('log_parameter_max_length_on_error') = '0' AND current_setting('log_statement') <> 'all'"
# extensions
chk "extension-pg_stat_statements-installed" "EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')"
if [[ $variant == timescale ]]; then
  chk "extension-timescaledb-installed" "EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb')"
else
  chk "extension-timescaledb-absent-in-the-plain-variant" "NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb')"
fi
# fixtures for the other sessions
S+="CREATE SCHEMA IF NOT EXISTS dbboot_other; CREATE TABLE IF NOT EXISTS dbboot_other.secret(v int); INSERT INTO dbboot_other.secret VALUES (1);"$'\n'
run structure postgres POSTGRES_PASSWORD disable /var/run/postgresql

# ---- S1: migrator --------------------------------------------------------------
chk migrator-connection-is-encrypted "(SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid())"
chk migrator-tls-version-is-1.3 "(SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()) = 'TLSv1.3'"
chk migrator-is-not-superuser "current_setting('is_superuser') = 'off'"
chk migrator-search_path "current_setting('search_path') = 'app'"
chk migrator-statement_timeout "current_setting('statement_timeout') = '10min'"
chk migrator-lock_timeout "current_setting('lock_timeout') = '5s'"
chk migrator-idle_in_transaction_session_timeout "current_setting('idle_in_transaction_session_timeout') = '5min'"
allow migrator-can-create-table-in-app "CREATE TABLE app.widgets(id bigserial PRIMARY KEY, v text NOT NULL)"
deny migrator-cannot-create-in-public "CREATE TABLE public.nope(i int)"
deny migrator-cannot-create-role "CREATE ROLE nope_role"
deny migrator-cannot-grant-itself-superuser "ALTER ROLE app_migrator SUPERUSER"
allow migrator-statistics-marker "SELECT 7 * 6 AS dbboot_marker"
run migrator app_migrator DB_MIGRATOR_PASSWORD require

# ---- S2: app (DML only) ---------------------------------------------------------
chk app-connection-is-encrypted "(SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid())"
chk app-search_path "current_setting('search_path') = 'app'"
chk app-statement_timeout "current_setting('statement_timeout') = '5s'"
chk app-lock_timeout "current_setting('lock_timeout') = '2s'"
chk app-idle_in_transaction_session_timeout "current_setting('idle_in_transaction_session_timeout') = '10s'"
allow app-can-insert-in-app "INSERT INTO app.widgets(v) VALUES ('x')"
allow app-can-select-in-app "SELECT count(*) FROM app.widgets"
allow app-can-update-and-delete-in-app "UPDATE app.widgets SET v = 'x'; DELETE FROM app.widgets WHERE v = 'never'"
allow app-can-use-the-sequence "SELECT nextval('app.widgets_id_seq')"
deny app-cannot-create-table-in-app "CREATE TABLE app.nope(i int)"
deny app-cannot-create-table-in-public "CREATE TABLE public.nope(i int)"
deny app-cannot-create-temp-table "CREATE TEMP TABLE nope(i int)"
deny app-cannot-read-another-schema "SELECT * FROM dbboot_other.secret"
deny app-cannot-truncate "TRUNCATE app.widgets"
deny app-cannot-drop-the-table "DROP TABLE app.widgets"
deny app-cannot-grant-itself-superuser "ALTER ROLE app_rw SUPERUSER"
deny app-cannot-read-password-hashes "SELECT rolpassword FROM pg_authid"
run app app_rw DB_APP_PASSWORD require

# ---- S3: read-only --------------------------------------------------------------
chk readonly-search_path "current_setting('search_path') = 'app'"
chk readonly-statement_timeout "current_setting('statement_timeout') = '30s'"
allow readonly-can-select "SELECT count(*) FROM app.widgets"
deny readonly-cannot-insert "INSERT INTO app.widgets(v) VALUES ('no')"
deny readonly-cannot-update "UPDATE app.widgets SET v = 'no'"
deny readonly-cannot-delete "DELETE FROM app.widgets"
deny readonly-cannot-create-table "CREATE TABLE app.nope(i int)"
deny readonly-cannot-read-another-schema "SELECT * FROM dbboot_other.secret"
run readonly app_ro DB_READONLY_PASSWORD require

# ---- S4: monitoring ---------------------------------------------------------------
chk monitor-is-pg_monitor-member "pg_has_role(current_user, 'pg_monitor', 'MEMBER')"
chk monitor-is-not-superuser "current_setting('is_superuser') = 'off'"
chk monitor-search_path "current_setting('search_path') = 'public'"
chk monitor-statement_timeout "current_setting('statement_timeout') = '5s'"
allow monitor-can-read-pg_stat_activity "SELECT count(*) FROM pg_stat_activity"
allow monitor-can-read-pg_stat_statements "SELECT count(*) FROM pg_stat_statements"
chk monitor-sees-other-roles-statement-text "EXISTS (SELECT 1 FROM pg_stat_statements s WHERE s.userid <> (SELECT oid FROM pg_roles WHERE rolname = current_user) AND s.query LIKE '%dbboot_marker%')"
allow monitor-can-read-pg_stat_database "SELECT count(*) FROM pg_stat_database"
allow monitor-can-read-pg_stat_ssl "SELECT count(*) FROM pg_stat_ssl"
deny monitor-cannot-read-app-data "SELECT * FROM app.widgets"
deny monitor-cannot-create-table "CREATE TABLE public.nope(i int)"
deny monitor-cannot-read-password-hashes "SELECT rolpassword FROM pg_authid"
run monitor app_monitor DB_MONITOR_PASSWORD require

# ---- S5: transport and health, from outside psql sessions ------------------------------
# non-TLS TCP must be refused (hba has hostssl only)
out="$(docker exec "$cid" sh -c 'PGPASSWORD="$DB_APP_PASSWORD" PGSSLMODE=disable PGCONNECT_TIMEOUT=5 psql -X -At -h 127.0.0.1 -U app_rw -d app -c "SELECT 1"' 2>&1)"; rc=$?
expected=$((expected + 1))
if ((rc != 0)) && [[ $out == *"no encryption"* ]]; then emit PASS non-tls-tcp-is-refused; else emit FAIL non-tls-tcp-is-refused "rc=$rc ${out:0:120}"; fi
# a wrong password is refused over TLS
out="$(docker exec "$cid" sh -c 'PGPASSWORD=wrong-password PGSSLMODE=require PGCONNECT_TIMEOUT=5 psql -X -At -h 127.0.0.1 -U app_rw -d app -c "SELECT 1"' 2>&1)"; rc=$?
expected=$((expected + 1))
if ((rc != 0)) && [[ $out == *"password authentication failed"* ]]; then emit PASS wrong-password-is-refused; else emit FAIL wrong-password-is-refused "rc=$rc ${out:0:120}"; fi
# the configured healthcheck authenticates: right password ok, wrong password fails
hc="$(docker inspect -f '{{index .Config.Healthcheck.Test 1}}' "$cid" 2>/dev/null)"
expected=$((expected + 2))
if [[ -n $hc ]] && docker exec "$cid" sh -c "$hc" >/dev/null 2>&1; then emit PASS healthcheck-passes-with-the-right-password; else emit FAIL healthcheck-passes-with-the-right-password "healthcheck: ${hc:-none}"; fi
if [[ -n $hc ]] && ! docker exec -e DB_MONITOR_PASSWORD=wrong-password "$cid" sh -c "$hc" >/dev/null 2>&1; then emit PASS healthcheck-fails-with-a-wrong-password; else emit FAIL healthcheck-fails-with-a-wrong-password "the healthcheck does not check credentials: ${hc:-none}"; fi
# the app role's statement_timeout is enforced: a longer sleep is cancelled
t0=$SECONDS
out="$(docker exec "$cid" sh -c 'PGPASSWORD="$DB_APP_PASSWORD" PGSSLMODE=require psql -X -At -h 127.0.0.1 -U app_rw -d app -c "SELECT pg_sleep(8)"' 2>&1)"
el=$((SECONDS - t0))
expected=$((expected + 1))
if [[ $out == *"statement timeout"* ]] && ((el < 8)); then emit PASS app-statement_timeout-cancels-a-long-statement "cancelled after ${el}s"; else emit FAIL app-statement_timeout-cancels-a-long-statement "after ${el}s: ${out:0:100}"; fi

# ---- S6: statistics collected, no secret in the log ---------------------------------
chk pg_stat_statements-is-collecting "(SELECT count(*) FROM pg_stat_statements WHERE calls > 0) > 0 AND EXISTS (SELECT 1 FROM pg_stat_statements WHERE query LIKE '%dbboot_marker%' AND calls >= 1)"
run statistics postgres POSTGRES_PASSWORD disable /var/run/postgresql
logs="$(docker logs "$cid" 2>&1)"
expected=$((expected + 1))
leak=""
for p in "$pw_su" "$pw_mig" "$pw_app" "$pw_ro" "$pw_mon"; do [[ $logs == *"$p"* ]] && leak="yes"; done
if [[ -z $leak ]]; then emit PASS no-password-in-the-server-log; else emit FAIL no-password-in-the-server-log "a role password appears in the container log"; fi

# ---- S7: data survives down + up (no -v) -----------------------------------------------
expected=$((expected + 1))
if ((unhealthy)); then
  emit FAIL data-survived-down-and-up "skipped: the database never became healthy"
elif dc down >"$scratch/down.log" 2>&1 && dc up -d >"$scratch/up2.log" 2>&1; then
  cid="$(dc ps -aq db 2>/dev/null)"
  wait_healthy; rc=$?
  if ((rc == 0)); then
    chk data-survived-down-and-up "(SELECT count(*) FROM app.widgets WHERE v = 'x') = 1"
    chk data-directory-after-recreate "current_setting('data_directory') = '/var/lib/postgresql/18/docker'"
    chk tls-still-on-after-recreate "(SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid())"
    expected=$((expected - 1))
    run persistence postgres POSTGRES_PASSWORD require
  else
    emit FAIL data-survived-down-and-up "the database did not become healthy again after down + up (rc=$rc)"
  fi
else
  emit FAIL data-survived-down-and-up "down + up failed: $(tail -n 3 "$scratch/up2.log" | tr '\n' ' ')"
fi

total=$((pass + fail))
echo "RESULT variant=$variant pass=$pass fail=$fail expected=$expected seconds=$SECONDS"
echo "db-bootstrap-test: $total assertions, $pass ok, $fail failed ($image)"
if ((total == 0 || pass + fail != expected)); then
  echo "FAIL COUNT: $total assertion lines, $expected expected"
  exit 1
fi
((fail == 0)) || exit 1
exit 0
