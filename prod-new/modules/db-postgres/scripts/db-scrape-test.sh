#!/usr/bin/env bash
# db-scrape-test.sh - prove the database is MONITORED: bring up the pinned database and
# its exporter (compose.yml + compose.observability.yml) in a throwaway project, scrape
# the exporter from inside the compose network and assert, one PASS/FAIL line each:
#
#   scrape-fetched              the exporter answered /metrics from another container
#   pg-up                       pg_up is 1 (the exporter logs in over verify-full TLS)
#   collectors-succeed          no pg_scrape_collector_success is 0
#   required-metric <name>      every name in observability/required-metrics.txt is present
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
#               Exit 1 = RED as intended; exit 4 = the mutation SURVIVED (a vacuous
#               test). Nothing is restored: the project is torn down.
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
# Exit: 0 every assertion passed · 1 at least one FAIL (or the mutation went RED as
# intended) · 2 nothing could be asserted (usage, no docker, stack did not start) ·
# 4 the mutation survived.
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
: > "$last"
DC=(docker compose -p "$proj" --env-file "$envf" -f "$dbdir/compose.yml" -f "$dbdir/compose.observability.yml")
deadline=$((SECONDS + budget))
pass=0; fail=0

# bounded SECS CMD... : run CMD (an executable, never a shell function, so the pid we
# kill IS the process), output to $last, killed after SECS. rc 124 = timed out.
bounded() {
  local secs="$1" pid wd rc; shift
  "$@" >"$last" 2>&1 &
  pid=$!
  (
    sleep "$secs" & sp=$!
    trap 'kill "$sp" 2>/dev/null; exit 0' TERM
    wait "$sp"
    kill -KILL "$pid" 2>/dev/null
  ) &
  wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  ((rc == 137)) && rc=124
  return "$rc"
}
cap() { # CAP -> min(CAP, seconds left, at least 1)
  local l=$((deadline - SECONDS)); ((l > $1)) && l=$1; ((l < 1)) && l=1; echo "$l"
}

cleanup() {
  bounded "$cleanup_s" "${DC[@]}" down -v --remove-orphans
  ((promtool)) && bounded "$cleanup_s" docker rm -f "$proj-promtool"
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

emit() { # PASS|FAIL name [detail]
  if [[ $1 == PASS ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
  echo "$1 $2${3:+: $3}"
}
finish() {
  local n=$((pass + fail))
  echo "db-scrape-test: $n assertions, $pass ok, $fail failed ($proj${mutate:+, mutation $mutate})"
  if [[ -n $mutate ]]; then
    if ((fail > 0)); then echo "RED as intended: --mutate $mutate was detected"; exit 1; fi
    echo "MUTATION SURVIVED: --mutate $mutate left every assertion green, so the test is vacuous"; exit 4
  fi
  ((fail == 0)) && exit 0
  exit 1
}

rnd() { head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
mkdir -m 700 "$secdir" || exit 2
for n in superuser migrator app readonly monitor; do printf '%s' "$n$(rnd)" > "$secdir/db_${n}_password"; done
chmod 644 "$secdir"/db_*_password
printf 'DB_SECRETS_DIR=%s\n' "$secdir" > "$envf"

# ---- start --------------------------------------------------------------------------
# `up -d --wait` returns when db and exporter are healthy (the exporter's healthcheck is
# `pg_up 1`), or fails. The pull of an absent image happens here too, inside the budget.
t="$(cap 45)"
bounded "$t" "${DC[@]}" up -d --wait --wait-timeout "$((t > 3 ? t - 2 : 1))"; rc=$?
if ((rc != 0)); then
  echo "FAIL START: compose up --wait failed or timed out after ${t}s (rc $rc); last lines:"; tail -n 8 "$last"
  bounded "$(cap 8)" "${DC[@]}" logs --tail 12 exporter db && tail -n 24 "$last"
  exit 2
fi

sup_psql() { # SQL as the superuser over the container's unix socket (never over TCP)
  bounded "$(cap 10)" "${DC[@]}" exec -T db sh -c 'PGPASSWORD="$(cat /run/secrets/db_superuser_password)" PGCONNECT_TIMEOUT=5 exec psql -X -q -At -U postgres -d app -c "$1"' sh "$1"
}
mon_psql() { # SQL as app_monitor over TLS
  bounded "$(cap 10)" "${DC[@]}" exec -T db sh -c 'PGPASSWORD="$(cat /run/secrets/db_monitor_password)" PGSSLMODE=require PGCONNECT_TIMEOUT=5 exec psql -X -q -At -h 127.0.0.1 -U app_monitor -d app -c "$1"' sh "$1"
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
if bounded "$(cap 10)" "${DC[@]}" exec -T db wget -q -O - http://exporter:9187/metrics && [[ -s $last ]]; then
  cp "$last" "$metrics"
  emit PASS scrape-fetched "$(wc -l < "$metrics" | tr -d ' ') lines"
else
  : > "$metrics"
  emit FAIL scrape-fetched "the exporter did not answer from inside the compose network: $(tail -n 2 "$last" | tr '\n' ' ')"
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

# Published on the host? `port` succeeds with a mapping only when one exists.
if bounded "$(cap 8)" "${DC[@]}" port exporter 9187 && grep -Eq ':[1-9][0-9]*[[:space:]]*$' "$last"; then
  emit FAIL exporter-not-published "port 9187 is mapped to the host: $(tr '\n' ' ' < "$last")"
else
  emit PASS exporter-not-published
fi

if mon_psql "SELECT rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication FROM pg_roles WHERE rolname = current_user" && [[ $(tr -d ' \n' < "$last") == f ]]; then
  emit PASS monitor-not-superuser
else
  emit FAIL monitor-not-superuser "app_monitor has an elevated attribute or could not be read: $(tail -n 2 "$last" | tr '\n' ' ')"
fi
if mon_psql 'CREATE TABLE public.monitor_write_probe (i int)'; then
  emit FAIL monitor-cannot-create "app_monitor created a table"
elif [[ $(cat "$last") == *"permission denied"* ]]; then emit PASS monitor-cannot-create
else emit FAIL monitor-cannot-create "refused, but not with permission denied: $(tail -n 2 "$last" | tr '\n' ' ')"; fi
if mon_psql 'INSERT INTO public.scrape_probe VALUES (2)'; then
  emit FAIL monitor-cannot-write "app_monitor inserted a row"
elif [[ $(cat "$last") == *"permission denied"* ]]; then emit PASS monitor-cannot-write
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
