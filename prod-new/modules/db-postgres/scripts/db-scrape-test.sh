#!/usr/bin/env bash
# db-scrape-test.sh - prove the database is MONITORED: bring up the pinned database and
# its exporter (compose.yml + compose.observability.yml) in a throwaway project, scrape
# the exporter from inside the compose network and assert, one PASS/FAIL line each:
#
#   scrape-fetched              the exporter answered /metrics from another container
#   pg-up                       pg_up is 1 (the exporter logs in over verify-full TLS)
#   collectors-succeed          no pg_scrape_collector_success is 0
#   required-metric <name>      every name in observability/required-metrics.txt is present
#   exporter-tls-verify-full    the RUNNING exporter's DATA_SOURCE_URI (docker inspect of its
#                               own container) has exactly one sslmode, verify-full, and one
#                               non-empty sslrootcert; only those two parameters are read
#                               into a variable and printed, never the whole value
#   exporter-args-allowlisted   the RUNNING exporter's command and entrypoint are exactly
#   exporter-env-allowlisted    allowed by observability/exporter-allowlist.txt (the same file
#   exporter-mounts-expected    parity-check.sh reads): every argument, every variable NAME (never
#                               a value) and the set of mount destinations. A flag such as
#                               --datasource.uri, a DATA_SOURCE_URI_FILE or a mounted config file
#                               would downgrade the connection where tls-verify-full cannot look.
#   exporter-session-encrypted  from the database side: every app_monitor TCP session
#                               (the exporter's) has pg_stat_ssl.ssl = true, and there is one
#   exporter-not-published      the exporter port is not mapped to the host
#   monitor-not-superuser       app_monitor is not superuser / createrole / createdb
#   monitor-cannot-create       a CREATE TABLE as app_monitor is refused
#   monitor-cannot-write        an INSERT as app_monitor is refused
#
#   db-scrape-test.sh [--db-dir DIR] [--mutate revoke-monitor] [--promtool]
#
#   --db-dir    the db directory (compose.yml, observability/); default ../db next to
#               this script. Point it at a scratch COPY to test a mutation.
#   --mutate revoke-monitor
#               revoke pg_monitor from app_monitor before the scrape and EXPECT it to go
#               RED (the wal collector needs pg_ls_waldir, which pg_monitor grants).
#               The mutation is judged by its SPECIFIC effect: exit 1 only when the scrape
#               was fetched, pg_up is 1, ONLY the collectors `wal` and `database` fail, the
#               metric pg_wal_size_bytes is absent and NO other assertion failed
#               (pg_wal_segments and pg_database_size_bytes are explained too: measured on
#               the pinned images). Any other failure pattern is exit 3. Nothing is
#               restored: the project is torn down.
#   --promtool  also run `promtool test rules` in the pinned Prometheus image
#               (observability/image.lock `prometheus.*`), --network none, read-only.
#               Off by default: it may pull ~100 MB, which is not part of the 60 s
#               scrape budget. Without Docker the same file is run by
#               db-observability-selftest.sh when a local promtool exists.
#
# Bounds: every docker call is killed after min(its own cap, what is left of
# DB_SCRAPE_BUDGET_S, default 60 s for the whole run). Teardown has its own cap,
# DB_SCRAPE_CLEANUP_S (default 20 s). There is no wait loop: `compose up --wait` waits.
#
# Docker: one compose project `dbscrape-<pid>` (every container, network and volume
# carries that prefix), containers use the compose file's cpus/mem limits, no host
# port, torn down on every exit path with `down -v` of THAT project only (plus
# `rm -f dbscrape-<pid>-promtool` for the optional container). Nothing else is ever
# stopped, removed or pruned. Passwords are random files in a 0700 scratch dir.
#
# Exit codes:
#   0  every assertion passed (no --mutate)
#   1  at least one assertion FAILED (no --mutate), or with --mutate: RED exactly as intended
#   2  nothing could be asserted: usage, no docker, the stack did not start, a docker call
#      timed out while starting, the revoke itself failed
#   3  --mutate only: assertions failed, but not the ones the revoke explains (the run broke
#      for another reason: scrape not fetched, pg_up 0, an unrelated assertion)
#   4  --mutate only: the mutation SURVIVED, every assertion stayed green (a vacuous test)
set -uo pipefail

src="${BASH_SOURCE[0]}"; [[ $src == */* ]] || src="./$src"
here="$(cd "${src%/*}" && pwd)"
dbdir="$here/../db"; mutate=""; promtool=0
while (($#)); do
  case "$1" in
    --db-dir) dbdir="${2:-}"; shift ;;
    --mutate) mutate="${2:-}"; shift ;;
    --promtool) promtool=1 ;;
    *) echo "usage: db-scrape-test.sh [--db-dir DIR] [--mutate revoke-monitor] [--promtool]" >&2; exit 2 ;;
  esac
  shift
done
case "$mutate" in "" | revoke-monitor) ;; *) echo "FAIL USAGE: unknown --mutate '$mutate' (revoke-monitor)" >&2; exit 2 ;; esac
dbdir="$(cd "$dbdir" 2>/dev/null && pwd)" || { echo "FAIL USAGE: db dir not found" >&2; exit 2; }
for f in "$dbdir/compose.yml" "$dbdir/compose.observability.yml" "$dbdir/observability/required-metrics.txt"; do
  [[ -r $f ]] || { echo "FAIL START: cannot read $f" >&2; exit 2; }
done
command -v docker >/dev/null 2>&1 || { echo "FAIL START: docker not found" >&2; exit 2; }
budget="${DB_SCRAPE_BUDGET_S:-60}"; cleanup_s="${DB_SCRAPE_CLEANUP_S:-20}"
[[ $budget =~ ^[0-9]+$ && $cleanup_s =~ ^[0-9]+$ ]] || { echo "FAIL USAGE: budgets must be whole seconds" >&2; exit 2; }

proj="dbscrape-$$"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/dbscrape.XXXXXX")" || exit 2
last="$scratch/last"; metrics="$scratch/metrics"; envf="$scratch/env"; secdir="$scratch/secrets"
mkfifo "$scratch/hold" && exec 3<>"$scratch/hold" || { echo "FAIL START: cannot create the watchdog fifo" >&2; rm -rf "$scratch"; exit 2; }
: > "$last"
DC=(docker compose -p "$proj" --env-file "$envf" -f "$dbdir/compose.yml" -f "$dbdir/compose.observability.yml")
deadline=$((SECONDS + budget))
pass=0; fail=0; failed=()

# bounded SECS CMD... : run CMD (an executable, never a shell function, so the pid we
# kill IS the process), output to $last, killed after SECS. rc 124 = timed out.
bounded() {
  local secs="$1" pid wd rc; shift
  "$@" 3>&- >"$last" 2>&1 &
  pid=$!
  # The watchdog waits with the `read -t` builtin on a fifo nobody writes to (fd 3, opened once
  # below): no `sleep` process per call, and nothing left behind when it is killed. It never
  # holds the caller's output pipe either.
  ( read -t "$secs" -u 3 _; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  ((rc == 137)) && rc=124
  return "$rc"
}
bcap() { # CAP CMD...: bounded, killed after min(CAP, what is left of the budget, at least 1); no subshell
  local c="$1" l=$((deadline - SECONDS)); shift
  ((l < c)) && c=$l; ((c < 1)) && c=1
  bounded "$c" "$@"
}

cleanup() {
  bounded "$cleanup_s" "${DC[@]}" down -v --remove-orphans
  ((promtool)) && bounded "$cleanup_s" docker rm -f "$proj-promtool"
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

emit() { # PASS|FAIL name [detail]
  if [[ $1 == PASS ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); failed+=("$2"); fi
  echo "$1 $2${3:+: $3}"
}
finish() {
  local n=$((pass + fail))
  echo "db-scrape-test: $n assertions, $pass ok, $fail failed ($proj${mutate:+, mutation $mutate})"
  if [[ -n $mutate ]]; then
    if ((fail == 0)); then
      echo "MUTATION SURVIVED: --mutate $mutate left every assertion green, so the test is vacuous"; exit 4
    fi
    # The revoke breaks the wal collector (pg_ls_waldir) and removes pg_wal_size_bytes;
    # nothing else may fail, and the scrape must have been fetched with pg_up 1.
    local f rest broke=0 has_wal=0 has_coll=0
    for f in "${failed[@]}"; do
      case "$f" in
        collectors-succeed) has_coll=1 ;;
        "required-metric pg_wal_size_bytes") has_wal=1 ;;
        "required-metric pg_wal_segments") ;;
        "required-metric pg_database_size_bytes") ;;   # the database collector needs pg_monitor too (measured)
        *) broke=1 ;;
      esac
    done
    [[ $up == 1 ]] || broke=1
    # only the wal and database collectors may fail (a third failing collector is another cause)
    rest="${bad//collector=\"wal\"/}"; rest="${rest//collector=\"database\"/}"; rest="${rest// /}"
    [[ -n $bad && -z $rest ]] || broke=1
    ((has_wal && has_coll)) || broke=1
    if ((broke == 0)); then echo "RED as intended: --mutate $mutate was detected (${failed[*]})"; exit 1; fi
    echo "the run broke for another reason: --mutate $mutate failed [${failed[*]}], pg_up '${up:-absent}', failing collectors '${bad:-none}'; the revoke explains only the wal/database collector and pg_wal_size_bytes"; exit 3
  fi
  ((fail == 0)) && exit 0
  exit 1
}

seed="$(od -An -tx1 -N 60 /dev/urandom | tr -d ' \n')"; si=0   # one read for all five passwords
mkdir -m 700 "$secdir" || exit 2
for n in superuser migrator app readonly monitor; do printf '%s' "$n${seed:$((si * 12)):12}" > "$secdir/db_${n}_password"; si=$((si + 1)); done
chmod 644 "$secdir"/db_*_password
printf 'DB_SECRETS_DIR=%s\n' "$secdir" > "$envf"

# ---- start --------------------------------------------------------------------------
# `up -d --wait` returns when db and exporter are healthy (the exporter's healthcheck is
# `pg_up 1`), or fails. The pull of an absent image happens here too, inside the budget.
t=$((deadline - SECONDS)); ((t > 45)) && t=45; ((t < 1)) && t=1
bounded "$t" "${DC[@]}" up -d --wait --wait-timeout "$((t > 3 ? t - 2 : 1))"; rc=$?
if ((rc != 0)); then
  echo "FAIL START: compose up --wait failed or timed out after ${t}s (rc $rc); last lines:"; tail -n 8 "$last"
  bcap 8 "${DC[@]}" logs --tail 12 exporter db && tail -n 24 "$last"
  exit 2
fi

sup_psql() { # SQL as the superuser over the container's unix socket (never over TCP)
  bcap 10 "${DC[@]}" exec -T db sh -c 'PGPASSWORD="$(cat /run/secrets/db_superuser_password)" PGCONNECT_TIMEOUT=5 exec psql -X -q -At -U postgres -d app -c "$1"' sh "$1"
}
mon_psql() { # SQL as app_monitor over TLS
  bcap 10 "${DC[@]}" exec -T db sh -c 'PGPASSWORD="$(cat /run/secrets/db_monitor_password)" PGSSLMODE=require PGCONNECT_TIMEOUT=5 exec psql -X -q -At -h 127.0.0.1 -U app_monitor -d app -c "$1"' sh "$1"
}

# A user table, so the per-table series exist; the statement also seeds pg_stat_statements.
if ! sup_psql 'CREATE TABLE IF NOT EXISTS public.scrape_probe (i int); INSERT INTO public.scrape_probe VALUES (1)'; then
  echo "FAIL START: could not create the probe table: $(tail -n 3 "$last" | tr '\n' ' ')"; exit 2
fi
if [[ -n $mutate ]]; then
  if ! sup_psql 'REVOKE pg_monitor FROM app_monitor'; then
    echo "FAIL START: the revoke failed: $(tail -n 3 "$last" | tr '\n' ' ')"; exit 2
  fi
fi

# ---- scrape and assert ----------------------------------------------------------------
# From the db container to the exporter by its service name: proves the compose network
# path, not the exporter's own loopback.
if bcap 10 "${DC[@]}" exec -T db wget -q -O - http://exporter:9187/metrics && [[ -s $last ]]; then
  cp "$last" "$metrics"
  nl=0; while IFS= read -r _; do nl=$((nl + 1)); done < "$metrics"
  emit PASS scrape-fetched "$nl lines"
else
  : > "$metrics"
  emit FAIL scrape-fetched "the exporter did not answer from inside the compose network: $(tail -n 2 "$last" | tr '\n' ' ')"
fi

# The RUNNING exporter's own configuration, from ONE docker inspect of its container, judged
# against observability/exporter-allowlist.txt (parity-check.sh reads the same file for the
# overlay as shipped). Printed: flag NAMES, variable NAMES, mount destinations, and the two
# TLS parameters. Never a value: `--datasource.uri=...` or an env value may carry a password.
# `%q` keeps one item on one line, so a value with a newline cannot forge another line.
INSPECT_FMT='{{range .Config.Cmd}}cmd {{printf "%q" .}}{{"\n"}}{{end}}{{range .Config.Entrypoint}}entrypoint {{printf "%q" .}}{{"\n"}}{{end}}{{range .Config.Env}}env {{printf "%q" .}}{{"\n"}}{{end}}{{range .Mounts}}mount {{printf "%q" .Destination}}{{"\n"}}{{end}}'
a_arg=(); a_env=(); a_ienv=(); a_ep=(); a_mount=()
while IFS= read -r l; do
  l="${l%%#*}"; [[ -n ${l//[[:space:]]/} ]] || continue
  read -r k v <<<"$l"
  case "$k" in
    arg) a_arg+=("$v") ;; env) a_env+=("$v") ;; image-env) a_ienv+=("$v") ;;
    entrypoint) a_ep+=("$v") ;; mount) a_mount+=("$v") ;;
  esac
done < "$dbdir/observability/exporter-allowlist.txt"
in_list() { local x="$1"; shift; local y; for y in "$@"; do [[ $x == "$y" ]] && return 0; done; return 1; }

insp_err=""; uri=""; have_uri=0; cmd_args=(); ep_args=(); env_names=(); mounts=()
exporter_inspect() {
  local cid l v
  if ! bcap 8 "${DC[@]}" ps -q exporter; then insp_err="compose ps failed"; return 1; fi
  read -r cid < "$last"
  [[ -n $cid ]] || { insp_err="no exporter container"; return 1; }
  if ! bcap 8 docker inspect -f "$INSPECT_FMT" "$cid"; then insp_err="docker inspect failed"; : > "$last"; return 1; fi
  while IFS= read -r l; do
    v="${l#* \"}"; v="${v%\"}"
    case "$l" in
      'cmd "'*) cmd_args+=("$v") ;;
      'entrypoint "'*) ep_args+=("$v") ;;
      'env "'*) env_names+=("${v%%=*}"); [[ $v == DATA_SOURCE_URI=* ]] && { uri="${v#DATA_SOURCE_URI=}"; have_uri=1; } ;;
      'mount "'*) mounts+=("$v") ;;
    esac
  done < "$last"
  : > "$last"
  return 0
}
exporter_tls() {
  local query p modes="" nmodes=0 nvf=0 nroot=0 root="" kv
  ((have_uri)) || { MSG="FAIL: the exporter has no DATA_SOURCE_URI"; return 1; }
  query=""
  [[ $uri == *\?* ]] && query="${uri#*\?}"
  IFS='&' read -r -a kv <<<"$query"
  for p in ${kv[@]+"${kv[@]}"}; do
    case "$p" in
      sslmode | sslmode=*) nmodes=$((nmodes + 1)); modes="$modes ${p#sslmode}"; [[ $p == sslmode=verify-full ]] && nvf=$((nvf + 1)) ;;
      sslrootcert=*) nroot=$((nroot + 1)); root="${p#sslrootcert=}" ;;
      sslrootcert) nroot=$((nroot + 1)) ;;
    esac
  done
  if ((nmodes == 1 && nvf == 1 && nroot == 1)) && [[ -n $root ]]; then MSG="sslmode=verify-full sslrootcert=$root"; return 0; fi
  MSG="sslmode parameters:${modes:- none} (want exactly sslmode=verify-full), sslrootcert count $nroot value '${root:-empty}'"; return 1
}
exporter_args() { # flag NAMES only, never values
  local a bad="" e="${ep_args[*]-}" w="${a_ep[*]-}"
  for a in ${cmd_args[@]+"${cmd_args[@]}"}; do in_list "$a" ${a_arg[@]+"${a_arg[@]}"} || bad="$bad ${a%%=*}"; done
  [[ -z $bad ]] || { MSG="arguments outside the allowlist (values hidden):$bad"; return 1; }
  [[ $e == "$w" ]] || { MSG="entrypoint is '$e', the allowlist says '$w'"; return 1; }
  MSG="${#cmd_args[@]} arguments, entrypoint $e"
}
exporter_env() { # variable NAMES only
  local n bad=""
  for n in ${env_names[@]+"${env_names[@]}"}; do in_list "$n" ${a_env[@]+"${a_env[@]}"} ${a_ienv[@]+"${a_ienv[@]}"} || bad="$bad $n"; done
  [[ -z $bad ]] || { MSG="variables outside the allowlist (values hidden):$bad"; return 1; }
  MSG="${#env_names[@]} variables"
}
exporter_mounts() {
  local m bad="" miss=""
  for m in ${mounts[@]+"${mounts[@]}"}; do in_list "$m" ${a_mount[@]+"${a_mount[@]}"} || bad="$bad $m"; done
  for m in ${a_mount[@]+"${a_mount[@]}"}; do in_list "$m" ${mounts[@]+"${mounts[@]}"} || miss="$miss $m"; done
  [[ -z $bad && -z $miss ]] || { MSG="mounts: unexpected [${bad# }] missing [${miss# }]"; return 1; }
  MSG="${#mounts[@]} mounts as expected"
}
if exporter_inspect; then
  if exporter_tls; then emit PASS exporter-tls-verify-full "$MSG"; else emit FAIL exporter-tls-verify-full "${MSG#FAIL: }"; fi
  if exporter_args; then emit PASS exporter-args-allowlisted "$MSG"; else emit FAIL exporter-args-allowlisted "$MSG"; fi
  if exporter_env; then emit PASS exporter-env-allowlisted "$MSG"; else emit FAIL exporter-env-allowlisted "$MSG"; fi
  if exporter_mounts; then emit PASS exporter-mounts-expected "$MSG"; else emit FAIL exporter-mounts-expected "$MSG"; fi
else
  for chk in exporter-tls-verify-full exporter-args-allowlisted exporter-env-allowlisted exporter-mounts-expected; do emit FAIL "$chk" "$insp_err"; done
fi

up="$(awk '$1 == "pg_up" { print $2 }' "$metrics")"
if [[ $up == 1 ]]; then emit PASS pg-up; else emit FAIL pg-up "pg_up is '${up:-absent}', want 1"; fi

bad="$(awk '$1 ~ /^pg_scrape_collector_success\{/ && $2 == 0 { sub(/^pg_scrape_collector_success\{/, "", $1); sub(/\}$/, "", $1); printf "%s ", $1 }' "$metrics")"
if [[ -z $bad ]]; then emit PASS collectors-succeed; else emit FAIL collectors-succeed "failing: $bad"; fi

# One awk pass over the contract and the scrape: no per-name process.
missing="$(awk '
  FNR == NR { sub(/#.*/, ""); gsub(/[ \t]/, ""); if ($0 != "") want[++n] = $0; next }
  { name = $1; sub(/\{.*/, "", name); seen[name] = 1 }
  END { for (i = 1; i <= n; i++) print (want[i] in seen ? "PASS " : "FAIL ") want[i] }
' "$dbdir/observability/required-metrics.txt" "$metrics")"
total=0
while IFS= read -r l; do
  [[ -n $l ]] || continue
  total=$((total + 1))
  if [[ $l == "PASS "* ]]; then emit PASS "required-metric ${l#PASS }"; else emit FAIL "required-metric ${l#FAIL }" "absent from the scrape"; fi
done <<<"$missing"
((total > 0)) || emit FAIL required-metrics-listed "required-metrics.txt has no names"

# From the DATABASE side: the exporter's own backend (role app_monitor, over TCP) is encrypted.
# sup_psql runs over the unix socket, so it never counts itself.
if sup_psql "SELECT count(*) FILTER (WHERE s.ssl) || '/' || count(*) FROM pg_stat_activity a JOIN pg_stat_ssl s USING (pid) WHERE a.usename = 'app_monitor' AND a.client_addr IS NOT NULL"; then
  read -r enc < "$last"
  if [[ $enc =~ ^([0-9]+)/([0-9]+)$ ]] && ((BASH_REMATCH[2] >= 1)) && [[ ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" ]]; then
    emit PASS exporter-session-encrypted "$enc sessions encrypted"
  else
    emit FAIL exporter-session-encrypted "app_monitor TCP sessions encrypted/total is '${enc:-none}', want n/n with n >= 1"
  fi
else
  emit FAIL exporter-session-encrypted "could not read pg_stat_ssl: $(tail -n 2 "$last" | tr '\n' ' ')"
fi

# Published on the host? `port` succeeds with a mapping only when one exists.
if bcap 8 "${DC[@]}" port exporter 9187 && grep -Eq ':[1-9][0-9]*[[:space:]]*$' "$last"; then
  emit FAIL exporter-not-published "port 9187 is mapped to the host: $(tr '\n' ' ' < "$last")"
else
  emit PASS exporter-not-published
fi

if mon_psql "SELECT rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication FROM pg_roles WHERE rolname = current_user" && read -r mrs < "$last" && [[ $mrs == f ]]; then
  emit PASS monitor-not-superuser
else
  emit FAIL monitor-not-superuser "app_monitor has an elevated attribute or could not be read: $(tail -n 2 "$last" | tr '\n' ' ')"
fi
if mon_psql 'CREATE TABLE public.monitor_write_probe (i int)'; then
  emit FAIL monitor-cannot-create "app_monitor created a table"
elif [[ $(<"$last") == *"permission denied"* ]]; then emit PASS monitor-cannot-create
else emit FAIL monitor-cannot-create "refused, but not with permission denied: $(tail -n 2 "$last" | tr '\n' ' ')"; fi
if mon_psql 'INSERT INTO public.scrape_probe VALUES (2)'; then
  emit FAIL monitor-cannot-write "app_monitor inserted a row"
elif [[ $(<"$last") == *"permission denied"* ]]; then emit PASS monitor-cannot-write
else emit FAIL monitor-cannot-write "refused, but not with permission denied: $(tail -n 2 "$last" | tr '\n' ' ')"; fi

# ---- the alert tests, in the pinned Prometheus image (opt-in) ---------------------------
if ((promtool)); then
  pimg=""; pk=""
  while IFS= read -r l; do
    [[ $l == \#* || $l != *=* ]] && continue
    k="${l%%=*}"; k="${k// /}"; v="${l#*=}"; v="${v# }"
    case "$k" in prometheus.image) pimg="$v" ;; prometheus.tag) pk="$v" ;; prometheus.digest) pdg="$v" ;; esac
  done < "$dbdir/observability/image.lock"
  if [[ -z $pimg || -z $pk || ${pdg:-} != sha256:* ]]; then
    emit FAIL promtool-test-rules "image.lock has no pinned prometheus image"
  elif bounded 90 docker run --rm --name "$proj-promtool" --cpus 1 --memory 1g --network none --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    --user 65534:65534 --entrypoint promtool -v "$dbdir/observability/alerts:/rules:ro" \
    "$pimg:$pk@$pdg" test rules /rules/postgres.rules.test.yml; then
    emit PASS promtool-test-rules
  else
    emit FAIL promtool-test-rules "$(tail -n 4 "$last" | tr '\n' ' ')"
  fi
fi

finish
