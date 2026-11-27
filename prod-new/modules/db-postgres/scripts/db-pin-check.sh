#!/usr/bin/env bash
# db-pin-check.sh — static gate for the database image pair.
#
#   db-pin-check.sh [lockfile] [--compose <file>...] [--non-db-build <service>...]
#
# Reads db/image.lock (default: ../db/image.lock next to this script) and,
# optionally, compose files / Dockerfiles. No network, no Docker. The lock is
# read in pure bash; each compose file is PARSED (not grepped) by one
# `python3 -B db_pin_compose.py` call (PyYAML; rules are in that file's
# docstring); a Dockerfile (basename Dockerfile*, *.Dockerfile) is read by its
# FROM lines. One `date` call (none when DB_PIN_TODAY is set). Constant cost,
# well under a second. The runtime facts the lock records are checked against
# the real images by scripts/db-pin-verify-live.sh, which needs Docker and is
# NOT part of this gate.
#
# FAILS (exit 1) when:
#   LOCK-PARSE   the lock has a line that is not `key = value`, an unknown or
#                duplicate key, or a required key is missing
#   LATEST       any image reference (lock or compose) uses `latest`, has no tag
#   DIGEST       a digest is not `sha256:` + 64 lowercase hex (an inline
#                `#...` after it included), two of the six lock digests are
#                equal, or a reference has a tag without a digest
#   PIN          (compose / Dockerfile) a database image differs from the
#                lock's tag AND INDEX digest (a per-platform digest is refused),
#                the file runs no lock image at all (zero is a FAIL, not a
#                WARN), or it has build:/extends:/include:/a `$` variable the
#                parser cannot resolve offline (see db_pin_compose.py)
#   MAJOR        the PostgreSQL major is not 18 (server_version, tag, -pgNN)
#   FORMAT       server_version / extversion are not strict numeric versions,
#                postgres.tag does not start with the server_version, the
#                Timescale tag is not `<extversion>-pg<major>`, or a
#                data_directory is not the official image's layout
#   PAIR         the Timescale entry's recorded PostgreSQL minor differs from
#                the plain PostgreSQL entry's minor, unless the lock carries
#                `pair_exception_until = YYYY-MM-DD` and a non-empty
#                `pair_exception_reason`; the exception itself expires (the
#                date is inclusive: it is dead the day after)
#   STALE        verified_utc is a bad or future date, or is >= DB_PIN_FAIL_DAYS
#                old. At >= DB_PIN_WARN_DAYS it prints a WARN line and exits 0.
#
# Thresholds (the choice): warn at 180 days, fail at 365. Half a year without
# re-running the observation is a nudge; a year is a lock nobody owns. Override
# with DB_PIN_WARN_DAYS / DB_PIN_FAIL_DAYS. "Today" is DB_PIN_TODAY (YYYY-MM-DD)
# when set, else `date -u +%F`.
#
# Exit: 0 ok · 1 failed · 2 nothing checked (lock missing or empty, `--compose`
# without a file, PyYAML or python3 missing when a compose file is given).
set -uo pipefail

warn_days="${DB_PIN_WARN_DAYS:-180}"
fail_days="${DB_PIN_FAIL_DAYS:-365}"

lock=""
compose=()
nodb=()
mode="lock"
compose_flag=0
while (($#)); do
  case "$1" in
    --compose) mode="compose"; compose_flag=1 ;;
    --non-db-build)
      if (($# < 2)); then echo "FAIL USAGE: --non-db-build needs a service name" >&2; exit 2; fi
      nodb+=("$2"); shift ;;
    -*) echo "FAIL USAGE: unknown option $1" >&2; exit 1 ;;
    *) if [[ $mode == compose ]]; then compose+=("$1"); elif [[ -z $lock ]]; then lock="$1"; else compose+=("$1"); fi ;;
  esac
  shift
done
if ((compose_flag == 1 && ${#compose[@]} == 0)); then
  echo "FAIL USAGE: --compose needs at least one file — nothing checked" >&2
  exit 2
fi
self_src="${BASH_SOURCE[0]}"; [[ $self_src == */* ]] || self_src="./$self_src"
self_dir="${self_src%/*}"
if [[ -z $lock ]]; then
  here="${BASH_SOURCE[0]%/*}"; [[ $here == "${BASH_SOURCE[0]}" ]] && here="."
  lock="$here/../db/image.lock"
fi

fails=0
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }
warn() { echo "WARN $1: $2"; }

if [[ ! -s $lock ]]; then
  echo "FAIL LOCK-MISSING: $lock is missing or empty — nothing checked"
  exit 2
fi

# ---- parse ----------------------------------------------------------------
required="verified_utc postgres.image postgres.tag postgres.digest postgres.digest.linux/amd64 postgres.digest.linux/arm64 postgres.server_version postgres.data_directory timescaledb.image timescaledb.tag timescaledb.digest timescaledb.digest.linux/amd64 timescaledb.digest.linux/arm64 timescaledb.pg_server_version timescaledb.extversion timescaledb.data_directory"

known=" $required pair_exception_until pair_exception_reason "
# values live in v_<key with . and / replaced by _>
seen=" "
parsed=0
while IFS= read -r line || [[ -n $line ]]; do
  line="${line#"${line%%[![:space:]]*}"}"
  [[ -z $line || $line == \#* ]] && continue
  if [[ $line != *=* ]]; then fail LOCK-PARSE "not 'key = value': $line"; continue; fi
  k="${line%%=*}"; v="${line#*=}"
  k="${k%"${k##*[![:space:]]}"}"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  if [[ $known != *" $k "* ]]; then fail LOCK-PARSE "unknown key: $k"; continue; fi
  if [[ $seen == *" $k "* ]]; then fail LOCK-PARSE "duplicate key: $k"; continue; fi
  seen="$seen$k "
  n="v_${k//[.\/]/_}"
  printf -v "$n" '%s' "$v"
  parsed=$((parsed + 1))
done < "$lock"
if ((parsed == 0 && fails == 0)); then
  echo "FAIL LOCK-MISSING: $lock has no key = value lines — nothing checked"
  exit 2
fi
for k in $required; do
  [[ $seen == *" $k "* ]] || fail LOCK-PARSE "missing key: $k"
done
if ((fails > 0)); then echo "FAIL $fails — lock unparseable"; exit 1; fi

g() { local n="v_${1//[.\/]/_}"; printf '%s' "${!n-}"; }

# ---- date arithmetic (pure bash) --------------------------------------------
days_of() { # YYYY-MM-DD -> days since epoch on stdout; return 1 if not a real date
  [[ $1 =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  ((m >= 1 && m <= 12 && d >= 1)) || return 1
  local -a ml=(0 31 28 31 30 31 30 31 31 30 31 30 31)
  if ((y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))); then ml[2]=29; fi
  ((d <= ml[m])) || return 1
  local yy=$y; ((m <= 2)) && yy=$((y - 1))
  local era=$((yy / 400)) yoe=$((yy - (yy / 400) * 400))
  local mp=$(((m + 9) % 12))
  local doy=$(((153 * mp + 2) / 5 + d - 1))
  local doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  echo $((era * 146097 + doe - 719468))
}
today="${DB_PIN_TODAY:-}"
[[ -z $today ]] && today="$(date -u +%F)"
today_n="$(days_of "$today")" || { echo "FAIL USAGE: bad today '$today'"; exit 1; }

# ---- digest / reference helpers --------------------------------------------
digest_ok() { [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]]; }
check_tag() { # label tag
  if [[ -z $2 ]]; then fail LATEST "$1: no tag"
  elif [[ $2 == latest || $2 == *latest* ]]; then fail LATEST "$1: tag '$2' is a floating tag"; fi
}
check_digest() {
  if [[ $2 == *'#'* ]]; then fail DIGEST "$1: '$2' has trailing text after the digest (an inline comment is part of the value; Docker would refuse it)"
  else digest_ok "$2" || fail DIGEST "$1: malformed digest '$2'"; fi
}
pg_major() { [[ $1 =~ ^([0-9]+)\. ]] && echo "${BASH_REMATCH[1]}"; }

# ---- lock checks -----------------------------------------------------------
for p in postgres timescaledb; do
  check_tag "$p" "$(g $p.tag)"
  for dk in digest digest.linux/amd64 digest.linux/arm64; do check_digest "$p.$dk" "$(g $p.$dk)"; done
done

pg_sv="$(g postgres.server_version)"; ts_sv="$(g timescaledb.pg_server_version)"
ts_ev="$(g timescaledb.extversion)"
for pair in "postgres.server_version:$pg_sv" "timescaledb.pg_server_version:$ts_sv"; do
  maj="$(pg_major "${pair#*:}")"
  [[ $maj == 18 ]] || fail MAJOR "${pair%%:*} '${pair#*:}' is not PostgreSQL 18"
  [[ ${pair#*:} =~ ^[0-9]+\.[0-9]+$ ]] || fail FORMAT "${pair%%:*} '${pair#*:}' is not <major>.<minor> (digits only)"
done
[[ $ts_ev =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail FORMAT "timescaledb.extversion '$ts_ev' is not <a>.<b>.<c> (digits only)"
# The plain image's tag is `<server_version>-alpine`: it must START with the
# recorded server_version, delimited, so 18.6-alpine beside 18.7 and 18.x fail.
# (With the major pinned to 18 above this also makes the tag an 18.x tag.)
pg_tag="$(g postgres.tag)"
[[ $pg_tag == "$pg_sv" || $pg_tag == "$pg_sv"-* ]] || fail FORMAT "postgres.tag '$pg_tag' does not start with postgres.server_version '$pg_sv'"
# The Timescale tag is `<extversion>-pg<major>` exactly (2.32.1-pg18), not a
# floating `2-pg18`, not a `-pg18-oss` variant the lock did not observe.
ts_maj="$(pg_major "$ts_sv")"
[[ $(g timescaledb.tag) == "$ts_ev-pg$ts_maj" ]] || fail FORMAT "timescaledb.tag '$(g timescaledb.tag)' is not '$ts_ev-pg$ts_maj' (<extversion>-pg<major>)"
# data_directory: the official postgres image moved PGDATA to
# /var/lib/postgresql/<major>/docker from major 18 on (docker-library/postgres
# change for 18, so a volume can be mounted one level up and pg_upgrade --link
# works). The timescale image is built FROM the same layout.
for pair in "postgres:$pg_sv" "timescaledb:$ts_sv"; do
  maj="$(pg_major "${pair#*:}")"
  if [[ -n $maj ]] && ((maj >= 18)); then
    [[ $(g "${pair%%:*}.data_directory") == "/var/lib/postgresql/$maj/docker" ]] || fail FORMAT "${pair%%:*}.data_directory '$(g "${pair%%:*}.data_directory")' is not /var/lib/postgresql/$maj/docker"
  fi
done
# The six digests are six different objects: an index digest equal to a
# platform digest, or the Timescale digest pasted into postgres.digest, is a
# copy-paste, not a pin.
dnames=(postgres.digest postgres.digest.linux/amd64 postgres.digest.linux/arm64 timescaledb.digest timescaledb.digest.linux/amd64 timescaledb.digest.linux/arm64)
dvals=()
for dn in "${dnames[@]}"; do dvn="v_${dn//[.\/]/_}"; dvals+=("${!dvn-}"); done
for ((di = 0; di < ${#dnames[@]}; di++)); do
  for ((dj = di + 1; dj < ${#dnames[@]}; dj++)); do
    if [[ -n ${dvals[di]} && ${dvals[di]} == "${dvals[dj]}" ]]; then fail DIGEST "${dnames[di]} and ${dnames[dj]} are the same digest"; fi
  done
done

if [[ $pg_sv != "$ts_sv" ]]; then
  ex_until="$(g pair_exception_until)"; ex_reason="$(g pair_exception_reason)"
  if [[ -z $ex_until ]]; then
    fail PAIR "postgres $pg_sv vs timescaledb bundled PostgreSQL $ts_sv — one tested pair, bump both"
  elif ! ex_n="$(days_of "$ex_until")"; then
    fail PAIR "pair_exception_until '$ex_until' is not a date"
  elif [[ -z $ex_reason ]]; then
    fail PAIR "pair_exception_until given without pair_exception_reason"
  elif ((ex_n < today_n)); then
    fail PAIR "pair_exception expired $ex_until (postgres $pg_sv vs timescaledb $ts_sv)"
  else
    warn PAIR "minor mismatch $pg_sv vs $ts_sv allowed until $ex_until: $ex_reason"
  fi
fi

if ! ver_n="$(days_of "$(g verified_utc)")"; then
  fail STALE "verified_utc '$(g verified_utc)' is not a date"
else
  age=$((today_n - ver_n))
  if ((age < 0)); then fail STALE "verified_utc $(g verified_utc) is in the future"
  elif ((age >= fail_days)); then fail STALE "verified $age days ago (>= $fail_days) — re-run the observation commands in the lock"
  elif ((age >= warn_days)); then warn STALE "verified $age days ago (>= $warn_days) — re-run the observation commands in the lock"; fi
fi

# ---- compose / Dockerfile references ---------------------------------------
# A compose file is parsed by db_pin_compose.py. A Dockerfile is read here by
# its FROM lines (stage names are remembered so `FROM db` is not an image).
norm_repo() { local r="$1"; r="${r#index.docker.io/}"; r="${r#docker.io/}"; r="${r#library/}"; echo "$r"; }
db_refs=0
check_ref() { # file ref
  local f="$1" ref="$2" name tag="" dg="" repo
  if [[ $ref == *'$'* ]]; then fail PIN "$f: '$ref' is a variable — cannot be proven pinned"; return; fi
  name="$ref"
  if [[ $ref == *@* ]]; then name="${ref%%@*}"; dg="${ref#*@}"; fi
  repo="$name"
  if [[ ${name##*/} == *:* ]]; then tag="${name##*:}"; repo="${name%:*}"; fi
  if [[ -z $tag ]]; then fail LATEST "$f: '$ref' has no tag"
  elif [[ $tag == *latest* ]]; then fail LATEST "$f: '$ref' uses a floating tag"; fi
  if [[ -z $dg ]]; then fail DIGEST "$f: '$ref' has no @sha256 digest"
  elif ! digest_ok "$dg"; then fail DIGEST "$f: '$ref' has a malformed digest"; fi
  local p=""
  case "$(norm_repo "$repo")" in postgres) p=postgres ;; timescale/timescaledb) p=timescaledb ;; esac
  if [[ -n $p ]]; then
    db_refs=$((db_refs + 1))
    if [[ -n $dg ]]; then
      [[ $tag == "$(g $p.tag)" ]] || fail PIN "$f: '$ref' tag differs from lock ($(g $p.tag))"
      if [[ $dg == "$(g $p.digest.linux/amd64)" || $dg == "$(g $p.digest.linux/arm64)" ]]; then
        fail PIN "$f: '$ref' uses a per-platform digest; pin the INDEX digest of the lock"
      elif [[ $dg != "$(g $p.digest)" ]]; then
        fail PIN "$f: '$ref' digest is not the lock's $p digest"
      fi
    fi
  fi
}
is_dockerfile() { local b="${1##*/}"; [[ $b == [Dd]ockerfile* || $b == *.[Dd]ockerfile ]]; }

pin_args=(--pin "postgres=$(g postgres.tag)@$(g postgres.digest)" --pin "timescale/timescaledb=$(g timescaledb.tag)@$(g timescaledb.digest)")
for pd in postgres.digest.linux/amd64 postgres.digest.linux/arm64 timescaledb.digest.linux/amd64 timescaledb.digest.linux/arm64; do
  pin_args+=(--platform-digest "$(g $pd)")
done
for nb in ${nodb[@]+"${nodb[@]}"}; do pin_args+=(--non-db-build "$nb"); done

checked_refs=0
for f in ${compose[@]+"${compose[@]}"}; do
  if [[ ! -r $f ]]; then fail USAGE "cannot read $f"; continue; fi
  if is_dockerfile "$f"; then
    stages=" scratch "
    db_before=$db_refs
    while IFS= read -r line || [[ -n $line ]]; do
      line="${line%%#*}"
      if [[ $line =~ ^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+(.+)$ ]]; then
        set -f; read -r -a toks <<< "${BASH_REMATCH[1]}"; set +f
        r=""; as=""; i=0
        while ((i < ${#toks[@]})); do
          t="${toks[$i]}"
          if [[ $t == --* ]]; then :
          elif [[ -z $r ]]; then r="$t"
          elif [[ $t == [Aa][Ss] ]]; then as="${toks[$((i + 1))]-}"; break; fi
          i=$((i + 1))
        done
        if [[ -n $r && $stages != *" $r "* ]]; then check_ref "$f" "$r"; checked_refs=$((checked_refs + 1)); fi
        [[ -n $as ]] && stages="$stages$as "
      fi
    done < "$f"
    ((db_refs == db_before)) && fail PIN "$f: no FROM runs a lock image — the database is not in this file"
  else
    command -v python3 >/dev/null 2>&1 || { echo "FAIL PARSER: python3 is not available — $f cannot be parsed, so it is not proven pinned"; exit 2; }
    pout="$(python3 -B "$self_dir/db_pin_compose.py" "${pin_args[@]}" "$f" 2>&1)"; prc=$?
    if ((prc == 2)); then echo "$pout"; echo "FAIL PARSER: $f could not be checked (exit 2)"; exit 2; fi
    refs_line=""; nfail=0
    while IFS= read -r pl; do
      if [[ $pl == "REFS "* ]]; then refs_line="${pl#REFS }"
      elif [[ $pl == FAIL* ]]; then echo "$pl"; nfail=$((nfail + 1)); fi
    done <<< "$pout"
    if [[ -z $refs_line ]]; then
      echo "$pout" | tail -n 5
      echo "FAIL PARSER: the compose helper gave no verdict for $f"; exit 2
    fi
    ((prc == 1 && nfail == 0)) && nfail=1 && echo "FAIL PIN: $f: helper failed without a finding"
    fails=$((fails + nfail))
    checked_refs=$((checked_refs + refs_line))
  fi
done

if ((fails > 0)); then echo "FAIL $fails"; exit 1; fi
echo "OK db-pin-check: lock $lock (postgres $(g postgres.tag), timescaledb $(g timescaledb.tag)), $checked_refs compose ref(s)"
exit 0
