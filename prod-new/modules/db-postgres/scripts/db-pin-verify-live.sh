#!/usr/bin/env bash
# db-pin-verify-live.sh — OPT-IN check of db/image.lock against the REAL images.
#
#   db-pin-verify-live.sh [--pull] [lockfile]
#
# db-pin-check.sh is the offline gate and never touches Docker. This is the other
# half: for each image in the lock it resolves the image by `repo:tag@digest`,
# starts it (one at a time, `--cpus 1 --memory 1g`, no ports, no volumes), and
# compares what the running server reports with what the lock claims:
#
#   postgres     SHOW server_version  == postgres.server_version
#                SHOW data_directory  == postgres.data_directory
#   timescaledb  SHOW server_version  == timescaledb.pg_server_version
#                SHOW data_directory  == timescaledb.data_directory
#                default_version (pg_available_extensions) == timescaledb.extversion
#
# NOT part of `make gates` (it needs Docker and a few seconds per image). A human
# runs it when bumping the pair (see the README), on the platform they care about:
# it prints the platform of the image it ran, because the facts in the lock were
# observed on linux/arm64 only.
#
# The image must already be local; `--pull` opts into `docker pull`. The container
# is named dbpin-<pid>-<key> and is removed on every path (EXIT trap), by that
# exact name only.
#
# Exit: 0 every fact matches · 1 one or more mismatches (one line each) ·
#       2 cannot answer (docker absent, image not local without --pull, lock
#         unreadable, container did not start or did not answer).
set -uo pipefail

pull=0
lock=""
while (($#)); do
  case "$1" in
    --pull) pull=1 ;;
    -*) echo "FAIL USAGE: unknown option $1" >&2; exit 2 ;;
    *) if [[ -z $lock ]]; then lock="$1"; else echo "FAIL USAGE: one lockfile only" >&2; exit 2; fi ;;
  esac
  shift
done
if [[ -z $lock ]]; then
  src="${BASH_SOURCE[0]}"; [[ $src == */* ]] || src="./$src"
  lock="${src%/*}/../db/image.lock"
fi

cname=""
cleanup() {
  if [[ -n $cname ]]; then docker rm -f "$cname" >/dev/null 2>&1; cname=""; fi
}
trap cleanup EXIT
trap 'exit 2' INT TERM

command -v docker >/dev/null 2>&1 || { echo "FAIL DOCKER: docker is not on PATH — nothing verified"; exit 2; }
[[ -s $lock ]] || { echo "FAIL LOCK: $lock is missing or empty — nothing verified"; exit 2; }

# ---- minimal lock read: `key = value`, `#` comments (db-pin-check.sh owns the strict grammar)
while IFS= read -r line || [[ -n $line ]]; do
  line="${line#"${line%%[![:space:]]*}"}"
  [[ -z $line || $line == \#* || $line != *=* ]] && continue
  k="${line%%=*}"; v="${line#*=}"
  k="${k%"${k##*[![:space:]]}"}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  printf -v "v_${k//[.\/]/_}" '%s' "$v"
done < "$lock"
g() { local n="v_${1//[.\/]/_}"; printf '%s' "${!n-}"; }
for k in postgres.image postgres.tag postgres.digest postgres.server_version postgres.data_directory \
         timescaledb.image timescaledb.tag timescaledb.digest timescaledb.pg_server_version timescaledb.data_directory timescaledb.extversion; do
  [[ -n $(g "$k") ]] || { echo "FAIL LOCK: $lock has no value for $k — nothing verified"; exit 2; }
done

mismatches=0
mismatch() { echo "MISMATCH $1: lock '$2' live '$3'"; mismatches=$((mismatches + 1)); }

verify() { # key  expected-server-version-key  [expected-extversion]
  local key="$1" svkey="$2" extv="${3:-}"
  local ref
  ref="$(g "$key.image"):$(g "$key.tag")@$(g "$key.digest")"
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    if ((pull == 1)); then
      docker pull "$ref" >/dev/null 2>&1 || { echo "FAIL DOCKER: cannot pull $ref"; exit 2; }
    else
      echo "FAIL DOCKER: $ref is not in the local image store — pull it yourself or re-run with --pull"; exit 2
    fi
  fi
  local plat
  plat="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$ref" 2>/dev/null)" || plat="unknown"
  cname="dbpin-$$-$key"
  docker run -d --name "$cname" --cpus 1 --memory 1g -e POSTGRES_PASSWORD=dbpin "$ref" >/dev/null 2>&1 \
    || { echo "FAIL DOCKER: $ref did not start"; exit 2; }
  # Ready = the entrypoint finished its init phase AND the final server answers
  # (pg_isready alone also succeeds on the throwaway init server).
  local i logs ready=0
  for ((i = 0; i < ${DB_PIN_READY_TRIES:-60}; i++)); do
    logs="$(docker logs "$cname" 2>&1)"
    if [[ $logs == *"ready for start up"* ]] && docker exec "$cname" pg_isready -U postgres -q >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  ((ready == 1)) || { echo "FAIL DOCKER: $ref never became ready"; exit 2; }
  local sql=(-c "SHOW server_version" -c "SHOW data_directory")
  [[ -n $extv ]] && sql+=(-c "SELECT default_version FROM pg_available_extensions WHERE name='timescaledb'")
  local out
  out="$(docker exec "$cname" psql -U postgres -At "${sql[@]}" 2>&1)" || { echo "FAIL DOCKER: $ref: psql failed: ${out##*$'\n'}"; exit 2; }
  local live_sv live_dd live_ext
  { IFS= read -r live_sv; IFS= read -r live_dd; IFS= read -r live_ext; } <<< "$out"
  # server_version may carry a distribution suffix on other builds ("18.7 (Debian ...)"):
  # compare the leading version token only.
  live_sv="${live_sv%% *}"
  echo "ran $ref ($plat): server_version=$live_sv data_directory=$live_dd${extv:+ timescaledb=$live_ext}"
  [[ $live_sv == "$(g "$svkey")" ]] || mismatch "$svkey" "$(g "$svkey")" "$live_sv"
  [[ $live_dd == "$(g "$key.data_directory")" ]] || mismatch "$key.data_directory" "$(g "$key.data_directory")" "$live_dd"
  if [[ -n $extv ]]; then
    [[ $live_ext == "$extv" ]] || mismatch "timescaledb.extversion" "$extv" "$live_ext"
  fi
  cleanup
}

verify postgres postgres.server_version
verify timescaledb timescaledb.pg_server_version "$(g timescaledb.extversion)"

if ((mismatches > 0)); then echo "FAIL $mismatches mismatch(es) between the lock and the live images"; exit 1; fi
echo "OK db-pin-verify-live: both images match the lock"
exit 0
