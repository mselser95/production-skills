#!/usr/bin/env bash
# check-registries.sh — the liability registries' teeth.
#
# Four registries record live exceptions: waived obligations, feature
# flags, quarantined tests, contract-migration debt. Recording them is
# worthless without expiry enforcement: a waiver nobody revisits is a
# permanent silent exemption, which is how a "temporary" gate suppression
# becomes policy.
#
# This script fails when ANY entry's `expires:` date is in the past, naming
# the entry and its owner. Wired into presubmit (make check-fast / verify):
# at expiry the obligation returns to force and the build reddens on its
# own, with no human remembering to check.
#
#   check-registries.sh            fail on expired entries
#   check-registries.sh --warn     report but exit 0 (grace period)
#   check-registries.sh --soon N   also warn on entries expiring within N days
#
# `expires: never` is legal ONLY for permanent operational levers (a kill
# switch is not debt); every other value must be a YYYY-MM-DD date.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

mode="fail"; soon_days=14
while (($#)); do
  case "$1" in
    --warn) mode="warn" ;;
    --soon) shift; soon_days="${1:-14}" ;;
  esac
  shift
done

today_s=$(date -u +%s)
expired=0; soon=0; total=0; malformed=0

for reg in registries/*.yaml; do
  [[ -f "$reg" ]] || continue
  id=""; owner=""; expires=""
  flush() {
    [[ -z "$id" ]] && return
    total=$((total+1))
    if [[ -z "$expires" ]]; then
      echo "MALFORMED  ${reg}: entry '${id}' has no expires: — every entry needs one ('never' only for permanent levers)" >&2
      malformed=$((malformed+1))
    elif [[ "$expires" != "never" ]]; then
      if ! exp_s=$(date -j -f "%Y-%m-%d" "$expires" +%s 2>/dev/null || date -d "$expires" +%s 2>/dev/null); then
        echo "MALFORMED  ${reg}: entry '${id}' has expires='${expires}' which is not YYYY-MM-DD" >&2
        malformed=$((malformed+1))
      elif (( exp_s < today_s )); then
        echo "EXPIRED    ${reg}: '${id}' expired ${expires} (owner: ${owner:-unassigned}) — the obligation is back in force" >&2
        expired=$((expired+1))
      elif (( (exp_s - today_s) / 86400 <= soon_days )); then
        echo "EXPIRING   ${reg}: '${id}' expires ${expires} in $(( (exp_s - today_s) / 86400 ))d (owner: ${owner:-unassigned})"
        soon=$((soon+1))
      fi
    fi
    id=""; owner=""; expires=""
  }
  while IFS= read -r line; do
    # Skip comment lines FIRST. The patterns below match anywhere on the
    # line, so a commented-out entry -- the natural way to record what a
    # registry used to hold, or to stage one before it is real -- was parsed
    # as a LIVE entry. Its long-past expiry then failed the build, and the
    # only way to describe a retired waiver was to delete every trace of it.
    # Trailing comments after a value are already handled per-field.
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    case "$line" in
      *-\ id:*)      flush; id="${line#*id:}";      id="${id// /}" ;;
      *owner:*)      owner="${line#*owner:}";      owner="${owner// /}" ;;
      *expires:*)    expires="${line#*expires:}";  expires="${expires%%#*}"; expires="${expires// /}" ;;
    esac
  done < "$reg"
  flush
done

echo "registries: ${total} entries checked, ${expired} expired, ${soon} expiring within ${soon_days}d, ${malformed} malformed"
if (( expired > 0 || malformed > 0 )); then
  if [[ "$mode" == "warn" ]]; then
    echo "(--warn: reporting only. Remove --warn to make expiry gate the build.)"
    exit 0
  fi
  echo "An expired waiver is a silent permanent exemption. Renew it with a reason, or meet the obligation." >&2
  exit 1
fi
exit 0
