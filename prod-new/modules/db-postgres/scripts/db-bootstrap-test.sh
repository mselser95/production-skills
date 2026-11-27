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
# removed on every exit path (plus one short `dbboot-tls-<pid>` container for the
# certificate-renewal unit test). Passwords are random, written as files into a
# scratch dir that is mounted as the compose `secrets:`; the containers read them
# from /run/secrets, so they are in no environment and on no command line.
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
secdir="$scratch/secrets"
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
# Secret files: 0644 inside a 0700 directory. The container reads them as uid 70
# (a bind mount keeps the host file's mode), so 0600 would be unreadable there.
mkdir -m 700 "$secdir" || exit 2
printf '%s' "$pw_su" > "$secdir/db_superuser_password"
printf '%s' "$pw_mig" > "$secdir/db_migrator_password"
printf '%s' "$pw_app" > "$secdir/db_app_password"
printf '%s' "$pw_ro" > "$secdir/db_readonly_password"
printf '%s' "$pw_mon" > "$secdir/db_monitor_password"
chmod 644 "$secdir"/db_*_password
printf 'DB_SECRETS_DIR=%s\n' "$secdir" > "$envf"

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
# run <session> <user> <secret-file> <sslmode> [host] — executes $S, then resets it.
# The superuser sessions use the unix socket (no TLS) so that a TLS regression shows up
# as the assertions that name it, not as a connection failure of the whole session.
run() {
  local out
  out="$(docker exec -i "$cid" sh -c "PGPASSWORD=\"\$(cat /run/secrets/$3)\" PGSSLMODE=$4 PGCONNECT_TIMEOUT=5 exec psql -X -q -At -h ${5:-127.0.0.1} -U $2 -d app" <<<"$S" 2>&1)"
  collect "$1" "$S_n" "$out"
  S=""; S_n=0
}

# leakcheck <label> <expected-user> <secret-file> <sslmode> <host> — connects as that user and reads the
# statistics views ONLY through that role's own visibility; the password values never enter SQL text (the
# patterns are read from the secret files inside the container and matched with grep -F). It emits:
#   <label>-stats-check-ran-as-the-intended-role : current_user is right, pg_stat_statements has rows and
#       holds the marker statement (so "no leak" below is not "saw nothing")
#   <label>-no-password-in-pg_stat_statements    : no password value in any query text, and no
#       `PASSWORD '<literal>'` that is not a SCRAM verifier
#   <label>-no-password-in-pg_stat_activity
#   <label>-utility-text-is-not-in-pg_stat_statements : the marker of a utility statement is absent
leakcheck() {
  local label="$1" user="$2" out who="" rows=0 marker=0 hits=-1 lit=-1 ahits=-1 util=-1 l
  out="$(docker exec -i "$cid" sh -s -- "$3" "$4" "$5" "$user" "$util_marker" <<'EOP' 2>&1
umask 077
export PGPASSWORD="$(cat "/run/secrets/$1")" PGSSLMODE="$2" PGCONNECT_TIMEOUT=5
h="$3"; u="$4"; mk="$5"
q() { psql -X -At -h "$h" -U "$u" -d app "$@"; }
for n in superuser migrator app readonly monitor; do cat "/run/secrets/db_${n}_password"; echo; done | grep -v '^$' > /tmp/dbboot_pwpat
echo "who=$(q -c 'SELECT current_user')"
echo "rows=$(q -c 'SELECT count(*) FROM pg_stat_statements')"
echo "marker=$(q -c "SELECT count(*) FROM pg_stat_statements WHERE query LIKE '%dbboot_marker%'")"
echo "hits=$(q -c 'SELECT query FROM pg_stat_statements' | grep -cF -f /tmp/dbboot_pwpat)"
echo "lit=$(q <<'SQL'
SELECT count(*) FROM pg_stat_statements WHERE query ~* 'password\s+''' AND query !~* 'password\s+''SCRAM-SHA-256\$';
SQL
)"
echo "ahits=$(q -c 'SELECT query FROM pg_stat_activity' | grep -cF -f /tmp/dbboot_pwpat)"
echo "util=$(q -c "SELECT count(*) FROM pg_stat_statements WHERE query LIKE '%$mk%'")"
: > /tmp/dbboot_pwpat
EOP
)"
  while IFS= read -r l; do
    case "$l" in
      who=*) who="${l#who=}" ;; rows=*) rows="${l#rows=}" ;; marker=*) marker="${l#marker=}" ;;
      hits=*) hits="${l#hits=}" ;; lit=*) lit="${l#lit=}" ;; ahits=*) ahits="${l#ahits=}" ;; util=*) util="${l#util=}" ;;
    esac
  done <<<"$out"
  expected=$((expected + 4))
  if [[ $who == "$user" && $rows =~ ^[0-9]+$ && $rows -gt 0 && $marker =~ ^[0-9]+$ && $marker -ge 1 ]]; then emit PASS "$label-stats-check-ran-as-the-intended-role" "user=$who rows=$rows"
  else emit FAIL "$label-stats-check-ran-as-the-intended-role" "user='$who' rows=$rows marker=$marker; ${out:0:160}"; fi
  if [[ $hits == 0 && $lit == 0 ]]; then emit PASS "$label-no-password-in-pg_stat_statements"
  else emit FAIL "$label-no-password-in-pg_stat_statements" "password values in query text: $hits; PASSWORD literals that are not a verifier: $lit"; fi
  if [[ $ahits == 0 ]]; then emit PASS "$label-no-password-in-pg_stat_activity"; else emit FAIL "$label-no-password-in-pg_stat_activity" "password values in pg_stat_activity: $ahits"; fi
  if [[ $util == 0 ]]; then emit PASS "$label-utility-text-is-not-in-pg_stat_statements"; else emit FAIL "$label-utility-text-is-not-in-pg_stat_statements" "utility marker rows: $util"; fi
}

# ---- static: nothing secret in the module ------------------------------------
expected=$((expected + 1))
if grep -rIlE 'PRIVATE KEY|PASSWORD[[:space:]]+'"'" "$dbdir/bootstrap" "$dbdir/conf" "$dbdir/compose.yml" "$dbdir/compose.timescale.yml" >/dev/null 2>&1; then
  emit FAIL no-secret-literal-in-module "a private key or PASSWORD '<literal>' is committed"
else
  emit PASS no-secret-literal-in-module
fi
expected=$((expected + 1))
pwenv="$(grep -hE '^[[:space:]]+[A-Z0-9_]*PASSWORD[A-Z0-9_]*:' "$dbdir/compose.yml" "$dbdir/compose.timescale.yml" 2>/dev/null | grep -v 'PASSWORD_FILE:')"
if [[ -z $pwenv ]]; then emit PASS compose-environment-carries-no-password-value; else emit FAIL compose-environment-carries-no-password-value "a *PASSWORD* variable that is not a *_FILE path: ${pwenv:0:100}"; fi

# ---- S0: structure, as the bootstrap superuser --------------------------------
# hba
# hba_file reports source=override (set from the command-line config_file), so it is
# checked by value, and the rules by the file they were read from.
chk setting-hba_file "current_setting('hba_file') = '/etc/postgresql/pg_hba.conf' AND (SELECT count(*) FROM pg_hba_file_rules WHERE file_name <> '/etc/postgresql/pg_hba.conf') = 0"
chk hba-has-rules "(SELECT count(*) FROM pg_hba_file_rules) > 0"
chk hba-no-parse-errors "(SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL) = 0"
chk hba-every-allow-rule-is-scram-sha-256 "(SELECT count(*) FROM pg_hba_file_rules WHERE auth_method NOT IN ('scram-sha-256','reject')) = 0 AND (SELECT count(*) FROM pg_hba_file_rules WHERE auth_method = 'scram-sha-256') > 0"
# the EXACT rule table, in order (type|database|user|address|netmask|method): a new rule, a
# reorder, a widened address or a dropped reject is red, not only a weaker method
chk hba-rule-table-is-exactly-the-expected-list "(SELECT string_agg(format('%s|%s|%s|%s|%s|%s', type, array_to_string(database,','), array_to_string(user_name,','), address, netmask, auth_method), ';' ORDER BY line_number) FROM pg_hba_file_rules) = 'local|replication|all|||reject;hostssl|replication|all|0.0.0.0|0.0.0.0|reject;hostssl|replication|all|::|::|reject;hostssl|all|postgres|0.0.0.0|0.0.0.0|reject;hostssl|all|postgres|::|::|reject;local|all|all|||scram-sha-256;hostssl|all|all|127.0.0.1|255.255.255.255|scram-sha-256;hostssl|all|all|::1|ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff|scram-sha-256;hostssl|all|all|samenet||scram-sha-256'"
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
# the exact membership set of each role (enumerated from pg_auth_members, not a deny-list): any
# extra predefined-role membership (pg_read_server_files, pg_write_server_files, ...) is red
chk memberships-of-app_owner-are-exactly-none "COALESCE((SELECT string_agg(m.roleid::regrole::text, ',' ORDER BY m.roleid::regrole::text) FROM pg_auth_members m WHERE m.member = 'app_owner'::regrole), '') = ''"
chk memberships-of-app_migrator-are-exactly-app_owner "COALESCE((SELECT string_agg(m.roleid::regrole::text, ',' ORDER BY m.roleid::regrole::text) FROM pg_auth_members m WHERE m.member = 'app_migrator'::regrole), '') = 'app_owner'"
chk memberships-of-app_rw-are-exactly-none "COALESCE((SELECT string_agg(m.roleid::regrole::text, ',' ORDER BY m.roleid::regrole::text) FROM pg_auth_members m WHERE m.member = 'app_rw'::regrole), '') = ''"
chk memberships-of-app_ro-are-exactly-none "COALESCE((SELECT string_agg(m.roleid::regrole::text, ',' ORDER BY m.roleid::regrole::text) FROM pg_auth_members m WHERE m.member = 'app_ro'::regrole), '') = ''"
chk memberships-of-app_monitor-are-exactly-pg_monitor "COALESCE((SELECT string_agg(m.roleid::regrole::text, ',' ORDER BY m.roleid::regrole::text) FROM pg_auth_members m WHERE m.member = 'app_monitor'::regrole), '') = 'pg_monitor'"
chk connection-limit-per-role-is-exact "(SELECT string_agg(rolname || '=' || rolconnlimit, ',' ORDER BY rolname) FROM pg_roles WHERE rolname LIKE 'app\_%') = 'app_migrator=5,app_monitor=5,app_owner=-1,app_ro=20,app_rw=50'"
chk connection-limits-plus-reserved-fit-max_connections "(SELECT sum(rolconnlimit) FROM pg_roles WHERE rolcanlogin AND rolname LIKE 'app\_%') + current_setting('superuser_reserved_connections')::int <= current_setting('max_connections')::int AND NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolcanlogin AND rolname LIKE 'app\_%' AND rolconnlimit < 0)"
chk app-schema-is-owned-by-the-owner "(SELECT nspowner::regrole::text FROM pg_namespace WHERE nspname = 'app') = 'app_owner'"
# schema and database privileges
chk public-has-no-create-on-schema-public "NOT EXISTS (SELECT 1 FROM pg_namespace n, aclexplode(n.nspacl) a WHERE n.nspname = 'public' AND a.grantee = 0 AND a.privilege_type = 'CREATE')"
chk no-app-role-can-create-in-public "NOT (has_schema_privilege('app_rw','public','CREATE') OR has_schema_privilege('app_ro','public','CREATE') OR has_schema_privilege('app_migrator','public','CREATE') OR has_schema_privilege('app_monitor','public','CREATE') OR has_schema_privilege('app_owner','public','CREATE'))"
chk app-roles-cannot-create-in-the-database "NOT (has_database_privilege('app_rw','app','CREATE') OR has_database_privilege('app_ro','app','CREATE') OR has_database_privilege('app_migrator','app','CREATE') OR has_database_privilege('app_monitor','app','CREATE'))"
chk public-has-no-database-privileges "NOT EXISTS (SELECT 1 FROM pg_database d, aclexplode(d.datacl) a WHERE d.datname = 'app' AND a.grantee = 0)"
# the other two databases: PUBLIC must hold nothing, no app role may connect or create temp objects
chk public-has-no-privileges-on-postgres-and-template1 "NOT EXISTS (SELECT 1 FROM pg_database d, aclexplode(d.datacl) a WHERE d.datname IN ('postgres','template1') AND a.grantee = 0) AND (SELECT count(*) FROM pg_database WHERE datname IN ('postgres','template1') AND datacl IS NOT NULL) = 2"
chk no-app-role-has-connect-or-temp-on-postgres-or-template1 "NOT EXISTS (SELECT 1 FROM pg_roles r, unnest(ARRAY['postgres','template1']) AS d(n), unnest(ARRAY['CONNECT','TEMP']) AS p(n) WHERE r.rolname LIKE 'app\_%' AND has_database_privilege(r.rolname, d.n, p.n))"
# a role-level timeout is a DEFAULT any role may override (see app-timeout-is-a-default-not-a-control)
chk statement_timeout-is-user-context "(SELECT context FROM pg_settings WHERE name = 'statement_timeout') = 'user'"
# settings: value AND origin (our config file), so a default can not pass by accident
settings=(
  "password_encryption=scram-sha-256" "ssl=on" "ssl_min_protocol_version=TLSv1.3"
  "ssl_cert_file=/tls/server.crt" "ssl_key_file=/tls/server.key" "listen_addresses=*"
  "compute_query_id=on" "track_io_timing=on"
  "pg_stat_statements.track=top" "log_lock_waits=on" "log_temp_files=10240"
  "log_min_duration_statement=250" "log_checkpoints=on" "log_autovacuum_min_duration=1000"
  "log_statement=none" "log_min_error_statement=panic" "pg_stat_statements.track_utility=off"
  "log_parameter_max_length=0" "log_parameter_max_length_on_error=0"
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
# a utility statement with a marker literal (must NOT reach pg_stat_statements: track_utility = off) and a
# password set the OBVIOUS way, cleartext in SQL, twice (must reach neither the log nor the statistics:
# log_statement = none, track_utility = off). These are throwaway random values, not a role password.
util_marker="dbboot_util_marker"; rot1="dbboot_rot1_$(rnd)"; rot2="dbboot_rot2_$(rnd)"
S+="COMMENT ON SCHEMA dbboot_other IS '$util_marker';"$'\n'
S+="CREATE ROLE dbboot_tmp LOGIN PASSWORD '$rot1'; ALTER ROLE dbboot_tmp PASSWORD '$rot2'; DROP ROLE dbboot_tmp;"$'\n'
run structure postgres db_superuser_password disable /var/run/postgresql

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
# top level on purpose: a DO block is a utility statement and is not tracked (track_utility = off)
S+="SELECT 7 * 6 AS dbboot_marker;"$'\n'
run migrator app_migrator db_migrator_password require

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
# The timeouts are role DEFAULTS, not a control: statement_timeout is a `user`-context setting, so the
# role may override it in-session and may persist its own default with ALTER ROLE ... SET (PostgreSQL
# lets every role change its own session defaults and nothing can revoke that). The ALTER is undone by
# a rolled-back subtransaction so later sessions keep the real defaults.
S_n=$((S_n + 1))
S+="DO \$x\$ DECLARE a boolean := false; b boolean := false; BEGIN BEGIN SET statement_timeout = 0; a := current_setting('statement_timeout') = '0'; RESET statement_timeout; EXCEPTION WHEN OTHERS THEN a := false; END; BEGIN EXECUTE 'ALTER ROLE app_rw SET statement_timeout = 0'; b := true; RAISE EXCEPTION USING ERRCODE = 'XX999', MESSAGE = 'undo'; EXCEPTION WHEN SQLSTATE 'XX999' THEN NULL; WHEN OTHERS THEN b := false; END; RAISE NOTICE '%', CASE WHEN a AND b THEN 'PASS app-timeout-is-a-default-not-a-control' ELSE 'FAIL app-timeout-is-a-default-not-a-control: in-session override=' || a || ' own ALTER ROLE SET=' || b END; END \$x\$;"$'\n'
run app app_rw db_app_password require

# ---- S3: read-only --------------------------------------------------------------
chk readonly-search_path "current_setting('search_path') = 'app'"
chk readonly-statement_timeout "current_setting('statement_timeout') = '30s'"
allow readonly-can-select "SELECT count(*) FROM app.widgets"
deny readonly-cannot-insert "INSERT INTO app.widgets(v) VALUES ('no')"
deny readonly-cannot-update "UPDATE app.widgets SET v = 'no'"
deny readonly-cannot-delete "DELETE FROM app.widgets"
deny readonly-cannot-create-table "CREATE TABLE app.nope(i int)"
deny readonly-cannot-read-another-schema "SELECT * FROM dbboot_other.secret"
run readonly app_ro db_readonly_password require

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
run monitor app_monitor db_monitor_password require

# ---- S5: transport and health, from outside psql sessions ------------------------------
# non-TLS TCP must be refused (hba has hostssl only)
out="$(docker exec "$cid" sh -c 'PGPASSWORD="$(cat /run/secrets/db_app_password)" PGSSLMODE=disable PGCONNECT_TIMEOUT=5 psql -X -At -h 127.0.0.1 -U app_rw -d app -c "SELECT 1"' 2>&1)"; rc=$?
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
# the healthcheck reads the monitor password from its secret file; point the same command at
# a file holding a wrong one (the replacement must change the command, else the probe is vacuous)
docker exec "$cid" sh -c 'echo wrong-password > /tmp/dbboot_wrongpw' >/dev/null 2>&1
hc_wrong="${hc//\/run\/secrets\/db_monitor_password//tmp/dbboot_wrongpw}"
if [[ -n $hc && $hc_wrong != "$hc" ]] && ! docker exec "$cid" sh -c "$hc_wrong" >/dev/null 2>&1; then emit PASS healthcheck-fails-with-a-wrong-password; else emit FAIL healthcheck-fails-with-a-wrong-password "the healthcheck does not check credentials or does not read the secret file: ${hc:-none}"; fi
# the app role's statement_timeout is enforced: a longer sleep is cancelled
t0=$SECONDS
out="$(docker exec "$cid" sh -c 'PGPASSWORD="$(cat /run/secrets/db_app_password)" PGSSLMODE=require psql -X -At -h 127.0.0.1 -U app_rw -d app -c "SELECT pg_sleep(8)"' 2>&1)"
el=$((SECONDS - t0))
expected=$((expected + 1))
if [[ $out == *"statement timeout"* ]] && ((el < 8)); then emit PASS app-statement_timeout-cancels-a-long-statement "cancelled after ${el}s"; else emit FAIL app-statement_timeout-cancels-a-long-statement "after ${el}s: ${out:0:100}"; fi

# ---- S5b: who may connect where, and how the container is built ---------------------------
# the superuser is refused over TCP even with the RIGHT password (it logs in only on the unix socket)
out="$(docker exec "$cid" sh -c 'PGPASSWORD="$(cat /run/secrets/db_superuser_password)" PGSSLMODE=require PGCONNECT_TIMEOUT=5 psql -X -At -h 127.0.0.1 -U postgres -d app -c "SELECT 1"' 2>&1)"; rc=$?
expected=$((expected + 1))
if ((rc != 0)) && [[ $out == *"pg_hba.conf rejects connection"* ]]; then emit PASS superuser-over-tcp-is-refused-with-the-right-password; else emit FAIL superuser-over-tcp-is-refused-with-the-right-password "rc=$rc ${out:0:140}"; fi
# a physical replication connection is refused by hba for everyone; a logical one (replication=database)
# by the missing REPLICATION attribute
out="$(docker exec "$cid" sh -c 'PGPASSWORD="$(cat /run/secrets/db_migrator_password)" PGSSLMODE=require PGCONNECT_TIMEOUT=5 psql -X -At "host=127.0.0.1 user=app_migrator dbname=app replication=true" -c IDENTIFY_SYSTEM' 2>&1)"; rc=$?
expected=$((expected + 1))
if ((rc != 0)) && [[ $out == *"pg_hba.conf rejects replication connection"* ]]; then emit PASS replication-connection-as-migrator-is-refused; else emit FAIL replication-connection-as-migrator-is-refused "rc=$rc ${out:0:140}"; fi
out="$(docker exec "$cid" sh -c 'PGPASSWORD="$(cat /run/secrets/db_migrator_password)" PGSSLMODE=require PGCONNECT_TIMEOUT=5 psql -X -At "host=127.0.0.1 user=app_migrator dbname=app replication=database" -c IDENTIFY_SYSTEM' 2>&1)"; rc=$?
expected=$((expected + 1))
if ((rc != 0)) && [[ $out == *"permission denied to start WAL sender"* ]]; then emit PASS logical-replication-connection-as-migrator-is-refused; else emit FAIL logical-replication-connection-as-migrator-is-refused "rc=$rc ${out:0:140}"; fi
# no application role can open a connection to postgres or template1 (8 real connection attempts, one exec)
out="$(docker exec "$cid" sh -c '
for pair in app_migrator:db_migrator_password app_rw:db_app_password app_ro:db_readonly_password app_monitor:db_monitor_password; do
  u="${pair%%:*}"; f="${pair#*:}"
  for d in postgres template1; do
    r="$(PGPASSWORD="$(cat /run/secrets/$f)" PGSSLMODE=require PGCONNECT_TIMEOUT=5 psql -X -At -h 127.0.0.1 -U "$u" -d "$d" -c "SELECT 1" 2>&1)"
    case "$r" in *"permission denied for database"*) echo "$u $d denied" ;; "1") echo "$u $d CONNECTED" ;; *) echo "$u $d error: $r" ;; esac
  done
done' 2>&1)"
for u in app_migrator app_rw app_ro app_monitor; do
  for d in postgres template1; do
    expected=$((expected + 1))
    if [[ $out == *"$u $d denied"* ]]; then emit PASS "$u-cannot-connect-to-$d"; else emit FAIL "$u-cannot-connect-to-$d" "$(tr '\n' ';' <<<"$out" | cut -c1-200)"; fi
  done
done
# container hardening, read from the running container
dbinsp() { docker inspect -f "$1" "$cid" 2>/dev/null; }
expected=$((expected + 1))
caps="$(docker exec "$cid" sh -c 'grep -E "^Cap(Eff|Prm|Inh|Bnd|Amb):" /proc/1/status | tr -d "\t " | tr "\n" " "' 2>&1)"
if [[ $caps == "CapInh:0000000000000000 CapPrm:0000000000000000 CapEff:0000000000000000 CapBnd:0000000000000000 CapAmb:0000000000000000 " && $(dbinsp '{{json .HostConfig.CapDrop}}') == '["ALL"]' && $(dbinsp '{{json .HostConfig.CapAdd}}') == 'null' ]]; then
  emit PASS db-container-has-no-capabilities
else emit FAIL db-container-has-no-capabilities "caps: ${caps:0:160}; cap_drop=$(dbinsp '{{json .HostConfig.CapDrop}}') cap_add=$(dbinsp '{{json .HostConfig.CapAdd}}')"; fi
expected=$((expected + 1))
ro="$(docker exec "$cid" sh -c 'touch /dbboot_rw_probe 2>&1; id -u' 2>&1)"
if [[ $(dbinsp '{{.HostConfig.ReadonlyRootfs}}') == true && $ro == *"Read-only file system"* && $ro == *70 && $(dbinsp '{{.Config.User}}') == 70:70 ]]; then
  emit PASS db-container-is-read-only-and-runs-as-uid-70
else emit FAIL db-container-is-read-only-and-runs-as-uid-70 "readonly=$(dbinsp '{{.HostConfig.ReadonlyRootfs}}') user=$(dbinsp '{{.Config.User}}') probe: ${ro:0:100}"; fi
expected=$((expected + 1))
tcid="$(dc ps -aq tls-init 2>/dev/null)"
tinsp() { docker inspect -f "$1" "$tcid" 2>/dev/null; }
if [[ -n $tcid && $(tinsp '{{json .HostConfig.CapDrop}}') == '["ALL"]' && $(tinsp '{{json .HostConfig.CapAdd}}') == '["CAP_CHOWN"]' && $(tinsp '{{.HostConfig.ReadonlyRootfs}}') == true ]]; then
  emit PASS tls-init-has-only-the-chown-capability-and-a-read-only-root
else emit FAIL tls-init-has-only-the-chown-capability-and-a-read-only-root "cap_drop=$(tinsp '{{json .HostConfig.CapDrop}}') cap_add=$(tinsp '{{json .HostConfig.CapAdd}}') readonly=$(tinsp '{{.HostConfig.ReadonlyRootfs}}')"; fi
# no password anywhere docker (or a process in the container) can show: inspect, and every process' environment
inspect_json="$(docker inspect "$cid" 2>/dev/null)"
leak=""; for p in "$pw_su" "$pw_mig" "$pw_app" "$pw_ro" "$pw_mon"; do [[ $inspect_json == *"$p"* ]] && leak="yes"; done
expected=$((expected + 1))
if [[ -z $leak && $inspect_json == *"POSTGRES_PASSWORD_FILE=/run/secrets/db_superuser_password"* ]]; then emit PASS docker-inspect-contains-no-password
else emit FAIL docker-inspect-contains-no-password "leak=${leak:-none} (or the secret-file variable is absent: the check would be vacuous)"; fi
expected=$((expected + 1))
envhits="$(docker exec "$cid" sh -c '
umask 077; for n in superuser migrator app readonly monitor; do cat /run/secrets/db_${n}_password; echo; done | grep -v "^$" > /tmp/dbboot_pwpat
n=$(grep -c . /tmp/dbboot_pwpat); h=$(grep -lF -f /tmp/dbboot_pwpat /proc/[0-9]*/environ 2>/dev/null | wc -l); procs=$(ls -d /proc/[0-9]* | wc -l)
: > /tmp/dbboot_pwpat; echo "patterns=$n hits=$h procs=$procs"' 2>&1)"
if [[ $envhits == "patterns=5 hits=0 procs="* ]]; then emit PASS no-password-in-any-process-environment "$envhits"; else emit FAIL no-password-in-any-process-environment "$envhits"; fi

# ---- W9: certificate renewal, unit-tested on tls-init.sh itself ------------------------------
# One short container from the same image as the tls-init service (read from it), a scratch TLS_DIR
# inside it: an absent certificate is generated, one with 1 day left is REPLACED, one with 100 days left
# is KEPT, an unparseable one is replaced. Output: one `case=result` line per case.
tlsimg="$(docker inspect -f '{{.Config.Image}}' "$tcid" 2>/dev/null)"
tlsout="$(docker run --rm --name "dbboot-tls-$$" --cpus 1 --memory 128m --network none --entrypoint sh \
  -v "$dbdir/bootstrap/tls-init.sh:/t.sh:ro" "$tlsimg" -c '
export TLS_DIR=/tmp/tls; mkdir -p "$TLS_DIR"
fp() { openssl x509 -in "$TLS_DIR/server.crt" -noout -fingerprint -sha256 2>/dev/null; }
plant() { openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days "$1" -subj /CN=planted -keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.crt" 2>/dev/null; }
valid() { openssl x509 -in "$TLS_DIR/server.crt" -noout -checkend $((300 * 86400)) >/dev/null 2>&1 && echo yes || echo no; }
sh /t.sh >/dev/null 2>&1; [ -s "$TLS_DIR/server.crt" ] && [ -s "$TLS_DIR/server.key" ] && echo "generated-when-absent=yes" || echo "generated-when-absent=no"
plant 1; a="$(fp)"; sh /t.sh >/dev/null 2>&1; b="$(fp)"
[ -n "$a" ] && [ "$a" != "$b" ] && [ "$(valid)" = yes ] && echo "replaced-when-1-day-left=yes" || echo "replaced-when-1-day-left=no"
plant 100; a="$(fp)"; sh /t.sh >/dev/null 2>&1; b="$(fp)"
[ -n "$a" ] && [ "$a" = "$b" ] && echo "kept-when-100-days-left=yes" || echo "kept-when-100-days-left=no"
echo garbage > "$TLS_DIR/server.crt"; sh /t.sh >/dev/null 2>&1
[ "$(valid)" = yes ] && echo "replaced-when-unparseable=yes" || echo "replaced-when-unparseable=no"
' 2>&1)"
for c in generated-when-absent replaced-when-1-day-left kept-when-100-days-left replaced-when-unparseable; do
  expected=$((expected + 1))
  if [[ $tlsout == *"$c=yes"* ]]; then emit PASS "tls-init-$c"; else emit FAIL "tls-init-$c" "${tlsout:0:200}"; fi
done

# ---- W2: failing and slow statements, probed against the log -------------------------------
# a failing statement WITH a marker literal (the error message itself does not echo it), and a slow
# statement whose marker is a BOUND parameter
fail_marker="dbboot_fail_$(rnd)"; slow_marker="dbboot_bound_$(rnd)"
docker exec -i "$cid" sh -s -- "$fail_marker" "$slow_marker" >/dev/null 2>&1 <<'EOP'
export PGPASSWORD="$(cat /run/secrets/db_app_password)" PGSSLMODE=require PGCONNECT_TIMEOUT=5
psql -X -At -h 127.0.0.1 -U app_rw -d app -c "SELECT '$1' || (1/0)"
printf '%s\n' "SELECT pg_sleep(0.4), \$1::text \\bind '$2' \\g" | psql -X -At -h 127.0.0.1 -U app_rw -d app
EOP

# ---- S6: statistics collected, no secret in the log ---------------------------------
chk pg_stat_statements-is-collecting "(SELECT count(*) FROM pg_stat_statements WHERE calls > 0) > 0 AND EXISTS (SELECT 1 FROM pg_stat_statements WHERE query LIKE '%dbboot_marker%' AND calls >= 1)"
run statistics postgres db_superuser_password disable /var/run/postgresql
logs="$(docker logs "$cid" 2>&1)"
expected=$((expected + 1))
leak=""
for p in "$pw_su" "$pw_mig" "$pw_app" "$pw_ro" "$pw_mon"; do [[ $logs == *"$p"* ]] && leak="yes"; done
if [[ -z $leak ]]; then emit PASS no-password-in-the-server-log; else emit FAIL no-password-in-the-server-log "a role password appears in the container log"; fi
# a failing statement's text is not logged (log_min_error_statement = panic); the ERROR line is, so the
# check is not vacuous. A slow statement is logged with its text but never with a bound parameter.
expected=$((expected + 2))
if [[ $logs == *"division by zero"* && $logs != *"$fail_marker"* ]]; then emit PASS failing-statement-text-is-not-in-the-log; else emit FAIL failing-statement-text-is-not-in-the-log "error logged: $([[ $logs == *'division by zero'* ]] && echo yes || echo NO); marker in log: $([[ $logs == *"$fail_marker"* ]] && echo YES || echo no)"; fi
if [[ $logs == *"pg_sleep(0.4)"* && $logs != *"$slow_marker"* ]]; then emit PASS slow-statement-bound-parameter-is-not-in-the-log; else emit FAIL slow-statement-bound-parameter-is-not-in-the-log "slow statement logged: $([[ $logs == *'pg_sleep(0.4)'* ]] && echo yes || echo NO); parameter in log: $([[ $logs == *"$slow_marker"* ]] && echo YES || echo no)"; fi
# a password set the obvious way (cleartext ALTER ROLE) reaches neither the log nor the statistics
expected=$((expected + 1))
if [[ $logs != *"$rot1"* && $logs != *"$rot2"* ]]; then emit PASS cleartext-rotation-is-not-in-the-log; else emit FAIL cleartext-rotation-is-not-in-the-log "a cleartext password set with ALTER ROLE was logged"; fi
chk cleartext-rotation-is-not-in-pg_stat_statements "(SELECT count(*) FROM pg_stat_statements) > 0 AND NOT EXISTS (SELECT 1 FROM pg_stat_statements WHERE query LIKE '%dbboot_rot%')"
run rotation postgres db_superuser_password disable /var/run/postgresql
# the stored passwords never existed in SQL text: no cleartext in pg_stat_statements / pg_stat_activity,
# as the monitor role (the one that can read other roles' statements) and as the superuser
leakcheck su-live postgres db_superuser_password disable /var/run/postgresql
leakcheck monitor-live app_monitor db_monitor_password require 127.0.0.1

# ---- S7: data survives down + up (no -v) -----------------------------------------------
expected=$((expected + 1))
if ((unhealthy)); then
  emit FAIL data-survived-down-and-up "skipped: the database never became healthy"
elif dc down >"$scratch/down.log" 2>&1 && dc up -d >"$scratch/up2.log" 2>&1; then
  cid="$(dc ps -aq db 2>/dev/null)"
  wait_healthy; rc=$?
  if ((rc == 0)); then
    chk data-survived-down-and-up "(SELECT count(*) FROM app.widgets WHERE v = 'x') = 1"
    chk tls-still-on-after-recreate "(SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid())"
    expected=$((expected - 1))
    run persistence app_migrator db_migrator_password require
    # the superuser reads data_directory, and only on the unix socket (hba refuses it over TCP)
    chk data-directory-after-recreate "current_setting('data_directory') = '/var/lib/postgresql/18/docker'"
    run persistence-directory postgres db_superuser_password disable /var/run/postgresql
    # after a stop and start the statistics file saved at shutdown is loaded again: the marker must have
    # survived (so the check reads persisted statistics) and still no password may be in it
    leakcheck su-restarted postgres db_superuser_password disable /var/run/postgresql
    leakcheck monitor-restarted app_monitor db_monitor_password require 127.0.0.1
    # and no password value anywhere in the data directory (stats files, WAL, catalogs); the first grep
    # proves the scan can find a string that IS there
    expected=$((expected + 2))
    out="$(docker exec "$cid" sh -c 'umask 077; for n in superuser migrator app readonly monitor; do cat /run/secrets/db_${n}_password; echo; done | grep -v "^$" > /tmp/dbboot_pwpat; echo "known=$(grep -rlF app_monitor /var/lib/postgresql | wc -l)"; echo "found=$(grep -rlF -f /tmp/dbboot_pwpat /var/lib/postgresql | wc -l)"; : > /tmp/dbboot_pwpat' 2>&1)"
    if [[ $out == *"known="[1-9]* ]]; then emit PASS data-directory-scan-finds-a-known-string; else emit FAIL data-directory-scan-finds-a-known-string "$out"; fi
    if [[ $out == *"found=0" ]]; then emit PASS no-password-value-in-the-data-directory; else emit FAIL no-password-value-in-the-data-directory "$out"; fi
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
