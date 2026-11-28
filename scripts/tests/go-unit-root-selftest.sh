#!/usr/bin/env bash
# go-unit-root-selftest.sh -- the Go service template's gate scripts operate on the UNIT root
# (PROD_UNIT_ROOT) when it is set, and on today's root (git top-level, else pwd) when it is not.
#
# WHY. In a monorepo the service lives in services/<id>/, and `git rev-parse --show-toplevel`
# is the MONOREPO root: a gate that cd'd there scanned every unit's files (and stamp wrote its
# provenance into the monorepo root). This builds a scratch monorepo by hand (two assembled
# services, svc-a and svc-b, in one git repo; the assembler's monorepo layout is not used),
# plants a violation in svc-b ONLY, and requires: with PROD_UNIT_ROOT=svc-a every hermetic
# script is GREEN for a and RED for b; invalid values exit 2 with one line; `make -C` on a unit
# hands the scripts that unit; and each root expression has the new form (the Go-toolchain
# scripts verify-standard and kill-durability are checked by that form and their early exit 2,
# never run for real here).
#
# UNIT_ROOT_TEMPLATE_DIR=<dir> overlays <dir>/scripts/** and <dir>/Makefile onto both assembled
# units (the mutation harness: a mutant copy of the template, same selftest, must go RED).
# provenance: candidate
# ttl: 2027-01-20
# Usage: bash scripts/tests/go-unit-root-selftest.sh
# Exit:  0 all cases behaved; 1 a case failed; 2 cannot run.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tpl="$repo/prod-new/template"
ovr="${UNIT_ROOT_TEMPLATE_DIR:-}"
sc="$tpl/scripts"; mk="$tpl/Makefile"
if [[ -n "$ovr" ]]; then sc="$ovr/scripts"; mk="$ovr/Makefile"; fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/go-unit-root.XXXXXX")" || exit 2
trap 'rm -rf "$tmp"' EXIT
command -v python3 >/dev/null && command -v git >/dev/null && command -v make >/dev/null \
  || { echo "go-unit-root: python3, git and make are required"; exit 2; }

CASES=0; FAILED=0; SKIPPED=0
ok()   { CASES=$((CASES+1)); printf '  ok   %s\n' "$1"; }
fail() { CASES=$((CASES+1)); FAILED=$((FAILED+1)); printf '  FAIL %s\n' "$1"; }
# check <name> <want_rc> <needle|-> <cwd> <unit-root|-> cmd...   (OUT/RC kept for follow-ups)
check() {
  local name="$1" want="$2" needle="$3" cwd="$4" unit="$5"; shift 5
  if [[ "$unit" == "-" ]]; then OUT=$(cd "$cwd" && env -u PROD_UNIT_ROOT "$@" 2>&1); RC=$?
  else OUT=$(cd "$cwd" && PROD_UNIT_ROOT="$unit" "$@" 2>&1); RC=$?; fi
  if [[ "$RC" == "$want" && ( "$needle" == "-" || "$OUT" == *"$needle"* ) ]]; then ok "$name"
  else fail "$name (rc=$RC want=$want needle='$needle'): $(printf '%s' "$OUT" | head -n 3 | tr '\n' '|' | cut -c1-200)"; fi
}

# --- scratch monorepo: two assembled services in ONE git repo ------------------------------
mono="$tmp/mono"; mkdir "$mono" && git -C "$mono" init -q || exit 2
for s in svc-a svc-b; do
  bash "$repo/scripts/instantiate-template.sh" "$mono/$s" "$s" owner >/dev/null 2>&1 \
    || { echo "go-unit-root: cannot assemble $s"; exit 2; }
  if [[ -n "$ovr" ]]; then # the overlay is raw template text: fill the slots the way the assembler did
    cp -R "$sc/." "$mono/$s/scripts/" && cp "$mk" "$mono/$s/Makefile" || exit 2
    find "$mono/$s/scripts" "$mono/$s/Makefile" -type f -exec sed -i.bak -e "s/<SERVICE>/$s/g" -e 's/<OWNER>/owner/g' {} + \
      && find "$mono/$s" -name '*.bak' -type f -delete || exit 2
  fi
done
a="$mono/svc-a"; b="$mono/svc-b"
# acceptance spec + citing test in each unit (valid), written BEFORE the plants
ROWS="happy_path input_classes declared_errors authorization idempotency_retry state_transitions ordering_concurrency durability_restart compatibility feature_interaction"
for u in "$a" "$b"; do
  mkdir -p "$u/acceptance" "$u/verification/t"
  {
    printf 'feature: unitroot\nintent: move funds\napproved_by: mati\napproved_at: 2026-10-02\nsurface: [POST /v1/unitroot]\nmatrix:\n'
    for r in $ROWS; do printf '  %s: [AC-01]\n' "$r"; done
    printf '  observability: [AC-02]\ncases:\n'
    for n in 01 02; do
      printf '  - id: AC-%s\n    lane: %s\n    given: g\n    when: w\n    then: t\n    observe: response\n    mutation: m\n' \
        "$n" "$([[ $n == 01 ]] && echo visible || echo held_out)"
    done
  } > "$u/acceptance/unitroot.yaml"
  printf '// acceptance:unitroot/AC-01 acceptance:unitroot/AC-02\n' > "$u/verification/t/x.txt"
done
# PLANTS: every violation lives in svc-b only
printf 'oops <SERVICE> left unfilled\n' >> "$b/README.md"
printf 'entries:\n  - id: planted-expired\n    owner: someone\n    expires: 2020-01-01\n' > "$b/registries/contract-debt.yaml"
killer=pkill   # held in a variable so THIS file does not itself carry the planted shape
printf '#!/usr/bin/env bash\n%s -x worker\n' "$killer" > "$b/scripts/planted-hygiene.sh"
mkdir -p "$b/internal/planted"
printf 'package planted\n\nfunc g() error { return nil }\n\nfunc F() {\n\terr := g()\n\tif err != nil {\n\t}\n}\n' > "$b/internal/planted/p.go"
printf '// acceptance:unitroot/AC-09\n' > "$b/verification/t/stray.txt"
git -C "$mono" add -A >/dev/null 2>&1
git -C "$mono" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm scratch || exit 2
export TEMPLATE_DIGEST_FILE="$repo/prod-new/TEMPLATE-DIGEST" TEMPLATE_DIR="$tpl"

# --- 1. each hermetic script: a GREEN, b RED, from a cwd that is NOT the unit ---------------
echo "1. unit-scoped: svc-a green, svc-b red (cwd = monorepo root)"
for pair in "no-unfilled-slots:unfilled" "check-registries:EXPIRED" "gate-hygiene-fitness:PKILL" "error-handling-fitness:planted"; do
  s="${pair%%:*}"; needle="${pair#*:}"
  check "$s: svc-a green" 0 - "$mono" "$a" bash "$a/scripts/$s.sh"
  check "$s: svc-b red" 1 "$needle" "$mono" "$b" bash "$b/scripts/$s.sh"
done
if python3 -c 'import yaml' 2>/dev/null; then
  check "acceptance-coverage: svc-a green" 0 "traced" "$mono" "$a" bash "$a/scripts/acceptance-coverage.sh" "$a/acceptance/unitroot.yaml"
  check "acceptance-coverage: svc-b red" 1 "AC-09" "$mono" "$b" bash "$b/scripts/acceptance-coverage.sh" "$b/acceptance/unitroot.yaml"
else
  SKIPPED=$((SKIPPED+2)); echo "  skip acceptance-coverage (PyYAML unavailable): 2 cases"
fi
# stamp + drift: the stamp lands in the unit, never in the monorepo root or the sibling
check "stamp: svc-a stamps" 0 "stamped" "$mono" "$a" bash "$a/scripts/stamp-template-provenance.sh"
[[ -f "$a/.prod/template-provenance.yaml" ]] && ok "stamp: written under svc-a/.prod" || fail "stamp: svc-a/.prod/template-provenance.yaml missing"
[[ ! -e "$mono/.prod" && ! -e "$b/.prod/template-provenance.yaml" ]] && ok "stamp: nothing written at the monorepo root or in svc-b" || fail "stamp: wrote outside the unit"
check "template-drift --local: svc-a (stamped) green" 0 - "$mono" "$a" bash "$a/scripts/check-template-drift.sh" --local
check "template-drift --local: svc-b (unstamped) red" 2 "no .prod/template-provenance.yaml" "$mono" "$b" bash "$b/scripts/check-template-drift.sh" --local

# --- 1b. the bug being fixed: without the variable the root is the monorepo root -------------
echo "1b. without PROD_UNIT_ROOT the root is today's (git top-level)"
check "no-unfilled-slots: unset, run from the monorepo root, sees svc-b's plant" 1 "unfilled" "$mono" - bash "$a/scripts/no-unfilled-slots.sh"
check "check-registries: unset, run from the monorepo root, finds no registries there" 1 "NO registry files" "$mono" - bash "$a/scripts/check-registries.sh"

# --- 1c. through make: the Makefile hands every script the unit -----------------------------
echo "1c. make -C <unit>"
check "make -C svc-a check-registries green" 0 "EXPLICITLY empty" "$mono" - make -C "$a" check-registries
check "make -C svc-b check-registries red" 2 "EXPIRED" "$mono" - make -C "$b" check-registries
check "make -C svc-a gate-hygiene-fitness green" 0 "clean" "$mono" - make -C "$a" gate-hygiene-fitness
check "make -C svc-b gate-hygiene-fitness red" 2 "PKILL" "$mono" - make -C "$b" gate-hygiene-fitness
check "make: a wrong PROD_UNIT_ROOT in the environment cannot redirect a unit's gates" 0 "EXPLICITLY empty" "$mono" "$b" make -C "$a" check-registries

# --- 2. invalid PROD_UNIT_ROOT: exit 2, one line, every script -----------------------------
echo "2. invalid PROD_UNIT_ROOT"
: > "$tmp/afile"
tests="error-handling-fitness-selftest check-registries-selftest non-vacuity-selftest kill-durability-state-selftest"
for s in acceptance-coverage check-registries check-template-drift gate-hygiene-fitness stamp-template-provenance \
         kill-durability error-handling-fitness no-unfilled-slots verify-standard; do
  for bad in "relative/dir" "$tmp/missing-dir" "$tmp/afile"; do
    check "$s: '${bad##*/}' -> exit 2" 2 "PROD_UNIT_ROOT is not a directory: $bad" "$a" "$bad" bash "$a/scripts/$s.sh" "$a/acceptance/unitroot.yaml"
  done
done
for s in $tests; do
  for bad in "relative/dir" "$tmp/missing-dir" "$tmp/afile"; do
    check "tests/$s: '${bad##*/}' -> exit 2" 2 "PROD_UNIT_ROOT is not a directory: $bad" "$a" "$bad" bash "$a/scripts/tests/$s.sh"
  done
done
check "empty PROD_UNIT_ROOT counts as unset (git top-level: sees svc-b)" 1 "unfilled" "$a" "" bash "$a/scripts/no-unfilled-slots.sh"

# --- 3. the forms: the scripts the host cannot run for real, and the git calls --------------
echo "3. source forms"
form() { # <name> <file> <fixed string>
  if grep -qF -- "$3" "$2"; then ok "$1"; else fail "$1 (missing in ${2#"$repo"/})"; fi
}
for s in acceptance-coverage check-registries check-template-drift gate-hygiene-fitness stamp-template-provenance \
         kill-durability error-handling-fitness no-unfilled-slots verify-standard \
         tests/error-handling-fitness-selftest tests/check-registries-selftest tests/non-vacuity-selftest tests/kill-durability-state-selftest; do
  form "$s: validates PROD_UNIT_ROOT" "$sc/$s.sh" 'PROD_UNIT_ROOT is not a directory: $PROD_UNIT_ROOT'
  case "$s" in
    verify-standard) rootform='root="${1:-${PROD_UNIT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"' ;;
    acceptance-coverage) rootform='root="${2:-${PROD_UNIT_ROOT:-$(cd "$(dirname "$spec")" && git rev-parse --show-toplevel 2>/dev/null || dirname "$spec")}}"' ;;
    *) rootform='cd "${PROD_UNIT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" || exit 2' ;;
  esac
  form "$s: resolves the root from PROD_UNIT_ROOT first" "$sc/$s.sh" "$rootform"
done
form "verify-standard: provenance diff is unit-relative" "$sc/verify-standard.sh" 'diff -U0 --relative --src-prefix=a/'
form "verify-standard: provenance reads the file unit-relative" "$sc/verify-standard.sh" 'git show "HEAD:./$prov_file"'
form "verify-standard: registry tree hash is unit-scoped" "$sc/verify-standard.sh" '{ git diff -- .; git diff --cached -- .; }'
form "Makefile exports the unit root" "$mk" 'export PROD_UNIT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))'
wf="${ovr:-$tpl}/.github/workflows/pr.yaml"
n=$(grep -c 'PROD_UNIT_ROOT: ${{ github.workspace }}' "$wf" 2>/dev/null); [[ "$n" == 2 ]] && ok "pr.yaml: both direct verify-standard steps carry PROD_UNIT_ROOT" || fail "pr.yaml: want 2 PROD_UNIT_ROOT env entries, found ${n:-0}"
# the git forms the scripts rely on, measured in the scratch monorepo (unit-relative output)
printf 'x\n' >> "$a/README.md"; printf 'x\n' >> "$b/README.md"
OUT=$(cd "$a" && git diff --name-only --relative); [[ "$OUT" == "README.md" ]] && ok "git diff --name-only --relative in svc-a: unit-relative, svc-a only" || fail "git diff --relative: '$OUT'"
OUT=$(cd "$a" && git diff --name-only); [[ "$OUT" == *svc-a/README.md* && "$OUT" == *svc-b/README.md* ]] && ok "git diff --name-only without --relative: top-level paths, both units (why --relative is needed)" || fail "git diff without --relative: '$OUT'"
OUT=$(cd "$a" && git ls-files -- . | grep -c '^svc-'); [[ "$OUT" == 0 ]] && ok "git ls-files -- . in svc-a: unit-relative" || fail "git ls-files -- . yields top-level paths"
OUT=$(cd "$a" && git show HEAD:./README.md | grep -c 'unfilled'); [[ "$OUT" == 0 ]] && ok "git show HEAD:./f in svc-a reads svc-a's file" || fail "git show HEAD:./README.md"

echo "$((CASES - FAILED)) ok, $FAILED failed${SKIPPED:+$([[ $SKIPPED -gt 0 ]] && echo ", $SKIPPED skipped")}"
[[ "$FAILED" -eq 0 ]]
