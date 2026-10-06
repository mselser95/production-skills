#!/usr/bin/env bash
# check-template-drift.sh — answer the question a scaffolded repo cannot answer
# about itself: are the files it VENDORED from the standard still the files the
# standard has?
#
# WHY THIS EXISTS. This repo did not import the framework; it COPIED parts of
# it. scripts/verify-standard.sh, the selftests beside it, the fitness gates,
# the load generator — every one is a copy that was correct on the day it was
# made and is correct on no day after that by construction. The framework's own
# history has this defect twice: a scaffold shipped a probe 186 lines behind the
# source, so it enforced a `driven:` block it could not read; and an installed
# skill tree ran 112 lines behind while `--verify` reported a spotless TCB,
# because integrity and CURRENCY are different questions and only the first had
# a check.
#
# TWO CHECKS, and the difference is the whole design:
#
#   LOCAL DRIFT     the repo's copy no longer matches the hash recorded when it
#                   was scaffolded. Somebody edited a vendored file HERE. This
#                   needs no access to the template, so it works in CI, on a
#                   clean clone, anywhere — and it is the dangerous one: a
#                   locally-edited gate is a fork of the standard that still
#                   carries the standard's name, and the edit that weakens a
#                   threshold looks exactly like the edit that fixes a typo.
#
#   UPSTREAM DRIFT  the TEMPLATE's copy no longer matches that same recorded
#                   hash. The standard moved and this repo is behind. Needs the
#                   installed template, so it is reported as UNKNOWN where the
#                   template is not reachable (CI) rather than as clean --
#                   "could not check" and "checked and fine" are different
#                   verdicts, and collapsing them is how a currency check turns
#                   into a green light for a repo nobody has updated in a year.
#
# WHAT IT DELIBERATELY DOES NOT DO: update anything. A vendored file is part of
# this repo's trusted set, and a script that silently pulled a new gate in would
# be a supply-chain hole wearing a maintenance chore's clothes. It reports; a
# human or prod-implement lands the update under review.
#
# ACCEPTED DRIFT is not silence. A repo that has deliberately diverged records
# it in registries/contract-debt.yaml with an owner and an expiry, the same way
# every other liability in this framework is carried, and the expiry is what
# stops "we will update it later" from becoming the permanent state.
#
#   check-template-drift.sh              both checks, template auto-located
#   check-template-drift.sh --local      local drift only (the CI-safe half; needs no template,
#                                        and says nothing about files the template added/retired)
#   TEMPLATE_DIR=/path check-template-drift.sh   explicit template location
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

PROV=".prod/template-provenance.yaml"
local_only=0
[[ "${1:-}" == "--local" ]] && local_only=1

if [[ ! -f "$PROV" ]]; then
  # NOT a pass. A repo with no provenance cannot be told from a repo that was
  # never scaffolded from the template, and both owe the same next step.
  printf 'template-drift: no %s -- this repo records no scaffold provenance, so nothing here can be compared.\n' "$PROV" >&2
  printf '  If it was scaffolded from prod-new, regenerate the stamp; if it was not, this check is N/A and should be declined in the spec.\n' >&2
  exit 2
fi

# Locate the template. The installed skills copy is the honest source on a
# developer machine: it is hash-verified by install.sh --verify, so comparing
# against it means comparing against a tree somebody has attested.
TEMPLATE_DIR="${TEMPLATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/prod-new/template}"

recorded=0; local_drift=0; upstream_drift=0; unknown=0
declare -a L_LINES=() U_LINES=() UNK_LINES=() PROV_PATHS=() M_LINES=() R_LINES=()
missing_upstream=0; retired_upstream=0

while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^[[:space:]]*-[[:space:]]*path:[[:space:]]*(.+)$ ]] || continue
  path="${BASH_REMATCH[1]}"; path="${path%\"}"; path="${path#\"}"
  # the sha line is the next non-comment line
  IFS= read -r shaline
  [[ "$shaline" =~ sha256:[[:space:]]*([0-9a-f]{64}) ]] || continue
  want="${BASH_REMATCH[1]}"
  # The template-side hash, recorded at scaffold time from the UNINSTANTIATED
  # file. Absent (older stamp) means the upstream half cannot be judged, and
  # this reports that rather than comparing the two sides of a substitution.
  IFS= read -r tshaline
  want_tpl=""
  [[ "$tshaline" =~ template_sha256:[[:space:]]*([0-9a-f]{64}) ]] && want_tpl="${BASH_REMATCH[1]}"
  recorded=$((recorded+1))
  PROV_PATHS+=("$path")

  if [[ -f "$path" ]]; then
    have="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ "$have" != "$want" ]]; then
      local_drift=$((local_drift+1))
      L_LINES+=("  $path -- edited here since scaffold (recorded ${want:0:12}, now ${have:0:12})")
    fi
  else
    local_drift=$((local_drift+1))
    L_LINES+=("  $path -- vendored at scaffold time and now ABSENT; a gate that was removed rather than declined")
  fi

  (( local_only )) && continue
  if [[ -z "$want_tpl" ]]; then
    unknown=$((unknown+1))
    UNK_LINES+=("  $path -- stamp predates template_sha256; the upstream half cannot be judged without comparing across a slot substitution")
  elif [[ -f "$TEMPLATE_DIR/$path" ]]; then
    up="$(shasum -a 256 "$TEMPLATE_DIR/$path" | awk '{print $1}')"
    if [[ "$up" != "$want_tpl" ]]; then
      upstream_drift=$((upstream_drift+1))
      U_LINES+=("  $path -- the standard moved (template was ${want_tpl:0:12} at scaffold, now ${up:0:12})")
    fi
  else
    unknown=$((unknown+1))
    UNK_LINES+=("  $path -- not present in $TEMPLATE_DIR (template unreachable or file retired upstream)")
  fi
done < "$PROV"

# THE LIST ITSELF MOVES. The loop above only visits files this repo's own stamp
# records, so a repo stamped from an older template was told "N behind" for the
# files it has and never told about vendored files the newer template has and it
# LACKS. Compare the template's CURRENT vendored list -- read from the template's
# own stamp script, the same list the stamp uses, not a copy kept here -- with the
# stamp's paths. Both directions are upstream-currency facts, so --local (which
# must not need the template) skips them, and neither fails the run (the same
# class as "behind upstream"). Without a readable list the answer is "could not
# compare", never "0 missing".
if (( ! local_only )); then
  tstamp="$TEMPLATE_DIR/scripts/stamp-template-provenance.sh"
  declare -a T_LIST=()
  if [[ -f "$tstamp" ]]; then
    in_list=0
    while IFS= read -r l; do
      if (( ! in_list )); then [[ "$l" =~ ^VENDORED=\( ]] && in_list=1; continue; fi
      [[ "$l" =~ ^[[:space:]]*\) ]] && break
      [[ "$l" =~ ^[[:space:]]*# ]] && continue
      l="${l//[[:space:]]/}"; [[ -n "$l" ]] && T_LIST+=("$l")
    done < "$tstamp"
  fi
  if (( ${#T_LIST[@]} == 0 )); then
    unknown=$((unknown+1))
    UNK_LINES+=("  (vendored-file list) -- could not read the template's list from $tstamp, so files the template vends that this repo lacks, and files it retired, were NOT compared")
  else
    for t in "${T_LIST[@]}"; do
      found=0; for p in "${PROV_PATHS[@]}"; do [[ "$p" == "$t" ]] && { found=1; break; }; done
      if (( ! found )); then
        missing_upstream=$((missing_upstream+1))
        M_LINES+=("  $t -- vended by the template, absent from this repo's provenance (stamped from an older template, or never adopted)")
      fi
    done
    for p in "${PROV_PATHS[@]}"; do
      found=0; for t in "${T_LIST[@]}"; do [[ "$p" == "$t" ]] && { found=1; break; }; done
      if (( ! found )); then
        retired_upstream=$((retired_upstream+1))
        R_LINES+=("  $p -- recorded in this repo's provenance, no longer vended by the template (retired or renamed upstream)")
        # the loop above filed it as "uncomparable"; the list says why, so it is retired, not unknown
        declare -a KEEP=(); for u in "${UNK_LINES[@]}"; do
          if [[ "$u" == "  $p -- not present in "* ]]; then unknown=$((unknown-1)); else KEEP+=("$u"); fi
        done; UNK_LINES=("${KEEP[@]+"${KEEP[@]}"}")
      fi
    done
  fi
fi

# ZERO RECORDED FILES IS A FAILURE. A provenance file that lists nothing
# compares nothing and would otherwise print the same clean line as a repo in
# perfect step -- this framework's oldest defect shape, and the reason every
# gate here is asked what it prints when its input set is empty.
if (( recorded == 0 )); then
  printf 'template-drift: %s records no files -- a comparison over an empty set is not a clean comparison.\n' "$PROV" >&2
  exit 2
fi

printf 'template-drift: %d vendored file(s) recorded\n' "$recorded"
if (( local_drift )); then
  printf '\nLOCAL DRIFT (%d) -- this repo edited files it vendored from the standard:\n' "$local_drift"
  printf '%s\n' "${L_LINES[@]}"
  printf '  A locally-edited gate is a fork of the standard carrying the standard'"'"'s name.\n'
  printf '  Either revert it, or record it in registries/contract-debt.yaml with an owner and an expiry.\n'
fi
if (( upstream_drift )); then
  printf '\nUPSTREAM DRIFT (%d) -- the standard moved and this repo is behind:\n' "$upstream_drift"
  printf '%s\n' "${U_LINES[@]}"
  printf '  Land the update through review (prod-spec -> prod-implement), then re-stamp %s.\n' "$PROV"
fi
if (( missing_upstream )); then
  printf '\nMISSING UPSTREAM FILE (%d) -- the template vends these and this repo'"'"'s provenance lacks them:\n' "$missing_upstream"
  printf '%s\n' "${M_LINES[@]}"
  printf '  Adopt them through review, then re-stamp %s.\n' "$PROV"
fi
if (( retired_upstream )); then
  printf '\nRETIRED UPSTREAM (%d) -- recorded here, no longer vended by the template (reported, not failing):\n' "$retired_upstream"
  printf '%s\n' "${R_LINES[@]}"
fi
if (( unknown )); then
  printf '\nUNKNOWN (%d) -- could not be compared, which is NOT the same as in step:\n' "$unknown"
  printf '%s\n' "${UNK_LINES[@]}"
fi

# Local drift fails; upstream drift and unknown report. The asymmetry is
# deliberate: a repo must not go red because somebody else committed to the
# framework this morning, but a repo whose own copy of a gate was edited has
# changed what it enforces and that is this repo's own doing.
if (( local_drift )); then exit 1; fi
if (( upstream_drift || unknown || missing_upstream || retired_upstream )); then
  printf '\ntemplate-drift: no local edits; %d behind upstream, %d MISSING UPSTREAM FILE(s), %d retired upstream, %d uncomparable (reported, not failing).\n' "$upstream_drift" "$missing_upstream" "$retired_upstream" "$unknown"
  exit 0
fi
printf 'template-drift: in step with the standard -- %d vendored file(s), no local edits, none behind.\n' "$recorded"
