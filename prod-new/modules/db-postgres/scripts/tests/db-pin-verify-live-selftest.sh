#!/usr/bin/env bash
# db-pin-verify-live-selftest.sh — hermetic selftest for db-pin-verify-live.sh.
# NO real Docker: a fake `docker` on PATH answers from environment variables and
# logs every call. Asserts exit code, one MISMATCH line per mismatch, that the
# container is removed (by its own name only) on every path that started one, and
# — by mutation of a scratch copy — that those assertions can go RED.
# Final line: `N ok, M failed`. Exit 1 if any failed.
set -uo pipefail
src="${BASH_SOURCE[0]}"; [[ $src == */* ]] || src="./$src"
here="$(cd "${src%/*}" && pwd)"
script="$here/../db-pin-verify-live.sh"
real_lock="$here/../../db/image.lock"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ok=0; bad=0

mkdir -p "$tmp/bin" "$tmp/empty"
cat > "$tmp/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$1" in
  image)
    if [[ $2 == inspect ]]; then
      [[ ${FAKE_PRESENT:-1} == 1 || -e $FAKE_LOG.pulled ]] || exit 1
      [[ $* == *--format* ]] && echo "linux/fake"
      exit 0
    fi ;;
  pull) : > "$FAKE_LOG.pulled"; [[ ${FAKE_PULL_FAIL:-0} == 1 ]] && exit 1; exit 0 ;;
  run) [[ ${FAKE_RUN_FAIL:-0} == 1 ]] && exit 125; echo fakeid; exit 0 ;;
  logs) echo "PostgreSQL init process complete; ready for start up."; exit 0 ;;
  rm) exit 0 ;;
  exec)
    if [[ $* == *pg_isready* ]]; then exit 0; fi
    [[ ${FAKE_PSQL_FAIL:-0} == 1 ]] && { echo "psql: connection refused" >&2; exit 2; }
    ts=0; [[ $* == *dbpin-*-timescaledb* ]] && ts=1
    for a in "$@"; do
      case "$a" in
        "SHOW server_version") if ((ts)); then echo "${FAKE_TS_SV:-18.7}"; else echo "${FAKE_SV:-18.7}"; fi ;;
        "SHOW data_directory") if ((ts)); then echo "${FAKE_TS_DD:-/var/lib/postgresql/18/docker}"; else echo "${FAKE_DD:-/var/lib/postgresql/18/docker}"; fi ;;
        *pg_available_extensions*) echo "${FAKE_EXT:-2.32.1}" ;;
      esac
    done
    exit 0 ;;
esac
exit 0
FAKE
chmod +x "$tmp/bin/docker"
# `exec` calls carry the container name as an argument: make it visible to the fake.

# runv <script> <name> <rc> <substr|-> <rm-expected 0|1|n> [VAR=val...] -- args...
runv() {
  local s="$1" name="$2" erc="$3" esub="$4" erm="$5"; shift 5
  local envs=()
  while (($#)) && [[ $1 != -- ]]; do envs+=("$1"); shift; done
  shift
  : > "$tmp/log"
  local out rc
  out="$(env PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" ${envs[@]+"${envs[@]}"} bash "$s" "$@" 2>&1)"; rc=$?
  rm -f "$tmp/log.pulled"
  local good=1
  [[ $rc == "$erc" ]] || good=0
  [[ $esub == - || $out == *"$esub"* ]] || good=0
  if [[ $erm == 1 ]]; then
    local runs rms; runs="$(grep -c '^run ' "$tmp/log")"; rms="$(grep -c '^rm -f dbpin-' "$tmp/log")"
    ((runs >= 1 && rms >= runs)) || good=0
  elif [[ $erm == 0 ]]; then
    grep -q '^run ' "$tmp/log" && good=0
  fi
  if ((good)); then return 0; fi
  echo "     (rc=$rc) $(printf '%s' "$out" | tail -n 3 | tr '\n' '|')"
  return 1
}
case_() { # name ... (same args as runv after the script)
  local name="$1"; shift
  if runv "$script" "$name" "$@"; then echo "ok   $name"; ok=$((ok + 1)); else echo "FAIL $name"; bad=$((bad + 1)); fi
}

case_ "all facts match: exit 0, both removed"     0 "OK db-pin-verify-live" 1 -- "$real_lock"
case_ "prints the platform it ran"                0 "ran postgres:18.7-alpine@sha256:" 1 -- "$real_lock"
case_ "postgres server_version mismatch"          1 "MISMATCH postgres.server_version: lock '18.7' live '18.6'" 1 FAKE_SV=18.6 -- "$real_lock"
case_ "postgres data_directory mismatch"          1 "MISMATCH postgres.data_directory" 1 FAKE_DD=/var/lib/postgresql/data -- "$real_lock"
case_ "timescale pg_server_version mismatch"      1 "MISMATCH timescaledb.pg_server_version" 1 FAKE_TS_SV=18.6 -- "$real_lock"
case_ "timescale data_directory mismatch"         1 "MISMATCH timescaledb.data_directory" 1 FAKE_TS_DD=/x -- "$real_lock"
case_ "timescale extension default_version"       1 "MISMATCH timescaledb.extversion: lock '2.32.1' live '2.32.0'" 1 FAKE_EXT=2.32.0 -- "$real_lock"
out="$(env PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" FAKE_SV=18.6 FAKE_EXT=2.32.0 FAKE_TS_DD=/x bash "$script" "$real_lock" 2>&1)"
n="$(grep -c '^MISMATCH' <<<"$out")"
if [[ $n == 3 ]]; then echo "ok   one MISMATCH line per mismatch (3)"; ok=$((ok + 1)); else echo "FAIL one MISMATCH line per mismatch (got $n)"; bad=$((bad + 1)); fi
case_ "image absent without --pull: exit 2, nothing started" 2 "not in the local image store" 0 FAKE_PRESENT=0 -- "$real_lock"
case_ "--pull fetches an absent image"            0 "OK db-pin-verify-live" 1 FAKE_PRESENT=0 -- --pull "$real_lock"
case_ "--pull that fails: exit 2"                 2 "cannot pull" 0 FAKE_PRESENT=0 FAKE_PULL_FAIL=1 -- --pull "$real_lock"
case_ "container that will not start: exit 2"     2 "did not start" n FAKE_RUN_FAIL=1 -- "$real_lock"
case_ "psql failing: exit 2, container removed"   2 "psql failed" 1 FAKE_PSQL_FAIL=1 -- "$real_lock"
case_ "missing lock: exit 2"                      2 "missing or empty" 0 -- "$tmp/nope.lock"
printf 'postgres.image = postgres\n' > "$tmp/partial.lock"
case_ "lock without the needed keys: exit 2"      2 "has no value for" 0 -- "$tmp/partial.lock"
case_ "unknown option: exit 2"                    2 "unknown option" n -- --bogus

# docker absent: PATH holds nothing, the script is pure bash
out="$(env PATH="$tmp/empty" "$BASH" "$script" "$real_lock" 2>&1)"; rc=$?
if [[ $rc == 2 && $out == *"docker is not on PATH"* ]]; then echo "ok   docker missing: exit 2"; ok=$((ok + 1)); else echo "FAIL docker missing (rc=$rc)"; bad=$((bad + 1)); fi

# the mismatch container is removed BEFORE the next starts (one at a time)
: > "$tmp/log"; env PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" bash "$script" "$real_lock" >/dev/null 2>&1
order="$(grep -E '^(run|rm -f) ' "$tmp/log" | cut -c1-3 | tr '\n' ' ')"
if [[ $order == "run rm  run rm  " || $order == "run rm run rm " ]]; then echo "ok   containers run one at a time"; ok=$((ok + 1)); else echo "FAIL containers run one at a time ('$order')"; bad=$((bad + 1)); fi
# limits and isolation on the run line
runline="$(grep '^run ' "$tmp/log" | head -n 1)"
if [[ $runline == *"--cpus 1"* && $runline == *"--memory 1g"* && $runline != *" -p "* && $runline != *" -v "* && $runline == *"--name dbpin-"* ]]; then
  echo "ok   run line: dbpin- name, --cpus 1, --memory 1g, no ports/volumes"; ok=$((ok + 1)); else echo "FAIL run line shape: $runline"; bad=$((bad + 1)); fi

# ---- mutations: the cases above must notice each break -------------------------
mutate() { # name anchor replacement rc substr rm-expected env... -- args
  local name="$1" anchor="$2" repl="$3" erc="$4" esub="$5" erm="$6"; shift 6
  local body; body="$(cat "$script")"
  if [[ $body != *"$anchor"* ]]; then echo "FAIL mutation $name: anchor not found"; bad=$((bad + 1)); return; fi
  printf '%s\n' "${body//"$anchor"/"$repl"}" > "$tmp/mut.sh"
  if runv "$tmp/mut.sh" "$name" "$erc" "$esub" "$erm" "$@" >/dev/null; then
    echo "FAIL mutation $name: GREEN (the cases did not notice)"; bad=$((bad + 1))
  else echo "RED  mutation $name"; ok=$((ok + 1)); fi
}
mutate "cleanup trap removed"       'trap cleanup EXIT' ':' 2 "psql failed" 1 FAKE_PSQL_FAIL=1 -- "$real_lock"
mutate "cleanup after verify removed" '  cleanup
}' '  :
}' 1 "MISMATCH" 1 FAKE_SV=18.6 -- "$real_lock"
mutate "server_version compare removed" '[[ $live_sv == "$(g "$svkey")" ]] ||' 'true ||' 1 "MISMATCH postgres.server_version" 1 FAKE_SV=18.6 -- "$real_lock"
mutate "data_directory compare removed" '[[ $live_dd == "$(g "$key.data_directory")" ]] ||' 'true ||' 1 "MISMATCH postgres.data_directory" 1 FAKE_DD=/x -- "$real_lock"
mutate "extversion compare removed"     '[[ $live_ext == "$extv" ]] ||' 'true ||' 1 "MISMATCH timescaledb.extversion" 1 FAKE_EXT=2.32.0 -- "$real_lock"
mutate "mismatch exit code dropped"     'if ((mismatches > 0)); then' 'if false; then' 1 "MISMATCH" 1 FAKE_SV=18.6 -- "$real_lock"
mutate "absent image is pulled silently" 'echo "FAIL DOCKER: $ref is not in the local image store — pull it yourself or re-run with --pull"; exit 2' ':' 2 "not in the local image store" 0 FAKE_PRESENT=0 -- "$real_lock"
# docker-missing check: needs an empty PATH, so it is mutated by hand
body="$(cat "$script")"; anchor='command -v docker >/dev/null 2>&1 ||'
if [[ $body == *"$anchor"* ]]; then
  printf '%s\n' "${body//"$anchor"/'true ||'}" > "$tmp/mut.sh"
  out="$(env PATH="$tmp/empty" "$BASH" "$tmp/mut.sh" "$real_lock" 2>&1)"; rc=$?
  if [[ $rc == 2 && $out == *"docker is not on PATH"* ]]; then echo "FAIL mutation docker-missing check removed: GREEN"; bad=$((bad + 1)); else echo "RED  mutation docker-missing check removed"; ok=$((ok + 1)); fi
else echo "FAIL mutation docker-missing check removed: anchor not found"; bad=$((bad + 1)); fi

echo "$ok ok, $bad failed"
((bad == 0))
