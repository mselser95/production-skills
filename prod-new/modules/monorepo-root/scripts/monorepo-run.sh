#!/usr/bin/env bash
# monorepo-run.sh <target> -- run <target> in every unit of repo.yaml that has it; one line per
# unit; the first failure stops the run (exit 1). "Has it" is monorepo_check.py's one answer: for a service/database it is
# make's exit status for `make -C <unit> -q <target>`, nothing it prints; it reads package.json scripts for an app/package.
# The inspection asks make -C <unit> -q <target>; only if that answers 0 does it ask make -C <unit> -q -B <target> (the same question with every file considered out of date, so the verdict does not depend on whether the unit's outputs are fresh); only if the last question asked answered 2 does it ask make -C <unit> -n <target> (exit status only; output discarded). Verdict: -q 1 = present; -q 0 and -q -B 1 = present (the target was only up to date), unless a file or directory named like the target sits beside the Makefile and the rule is not .PHONY (the real run says up to date: idle, with a .PHONY hint); -q -B 0 = idle (nothing to run even with everything out of date); an answer of 2 asks -n: 0 = present, 2 = missing. First question: make parses the unit's Makefile (a parse-time $(shell ...) runs; an included file that has a rule may be remade, its recipe IN FULL, plain lines too). Under -q make executes the recipe lines marked + or containing $(MAKE) of the target and of its prerequisites, each recipe at most up to its first line that is neither (an upper bound: it stops at the first out-of-date prerequisite whose recipe starts with a plain line; a file target that a + line just created may be deleted again). The -B question executes the same classes of lines, passed on to sub-makes in question mode as well, but MORE of them, since nothing counts as up to date: the + / $(MAKE) lines of prerequisites and sub-make targets that were up to date run too, and an included file that has a rule is remade every time, its recipe IN FULL. Under -n make walks the WHOLE recipe, so every + / $(MAKE) line of the target and of all its out-of-date prerequisites runs (a sub-make in dry-run mode runs its + lines and not its plain lines). Apart from that remake, no plain recipe line runs under any question. On GNU make 3.81 and 4.3 the judgment is the same, and the same before and after a real run, for every shape measured, except a recipe made only of + / $(MAKE) lines that run nothing (verify: with +true, +@echo ok, or $(MAKE) check-fast with check-fast: ;): 3.81 answers 1 to -q (present), 4.3 answers 0 to -q and to -q -B (idle, fail-closed: such a recipe verifies nothing); verify: +false differs too (3.81: -q 2 and -n 2 = missing; 4.3: -q 1 = present) and on both the root make verify ends non-zero. What runs during the inspection was measured on GNU make 3.81 and 4.3.
# A unit without an OPTIONAL target is `skip`; a unit without a MANDATORY one for its kind (monorepo_check.py MANDATORY) is
# a FAIL before any unit TARGET is run. The unit list is read fully before anything runs, each unit gets stdin from /dev/null,
# and the run asserts it ran as many units as it announced.
# PYTHON / PNPM override the interpreters (tests use fakes).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
target="${1:?usage: monorepo-run.sh <target>}"
py="${PYTHON:-python3}"
pnpm_bin="${PNPM:-pnpm}"
listing="$("$py" -B "$here/monorepo_check.py" units "$root" "$target")" || { echo "monorepo-run: cannot read repo.yaml or refused a unit path (see above)" >&2; exit 2; }
rows=()
while IFS= read -r row; do [[ -n "$row" ]] && rows+=("$row"); done <<<"$listing"
total=${#rows[@]}
will=0; missing=0
for row in ${rows[@]+"${rows[@]}"}; do
  IFS=$'\t' read -r id _kind path has must <<<"$row"
  if [[ "$has" == "1" ]]; then will=$((will + 1))
  elif [[ "$must" == "1" ]]; then echo "$target $id: FAIL (mandatory target $target missing in $path)"; missing=$((missing + 1)); fi
done
[[ $missing -eq 0 ]] || { echo "monorepo-run: $target refused, $missing unit(s) lack a mandatory target; no unit target was run" >&2; exit 1; }
echo "monorepo-run: $target will run in $will of $total unit(s)"
ran=0
for row in ${rows[@]+"${rows[@]}"}; do
  IFS=$'\t' read -r id kind path has _must <<<"$row"
  if [[ "$has" != "1" ]]; then echo "$target $id: skip (no $target)"; continue; fi
  if [[ "$kind" == "service" || "$kind" == "database" ]]; then
    make -C "$root/$path" "$target" </dev/null
  else
    "$pnpm_bin" --dir "$root/$path" run "$target" </dev/null
  fi
  rc=$?
  if [[ $rc -ne 0 ]]; then echo "$target $id: FAIL ($rc)"; exit 1; fi
  ran=$((ran + 1))
  echo "$target $id: ok"
done
[[ $ran -eq $will ]] || { echo "monorepo-run: ran $ran unit(s), announced $will" >&2; exit 1; }
echo "monorepo-run: $target over $total unit(s)"
