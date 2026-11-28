#!/usr/bin/env bash
# monorepo-settings-check.sh [ROOT] -- the monorepo root's settings gate. Exit 0 clean, 1 findings
# (one `file:line: RULE message` per finding), 2 cannot run (no PyYAML, no python3).
# PYTHON=<interpreter> overrides python3. No network, no pnpm. "Unit has target T" is make's exit status for
# `make -C <unit> -q <target>`, nothing it prints. The inspection asks make -C <unit> -q <target> and, only if that answers 2, make -C <unit> -n <target> (exit status only; output discarded). First question: make parses the unit's Makefile (a parse-time $(shell) runs; an included file that has a rule may be remade, its recipe IN FULL, plain lines too). Under -q make executes the recipe lines marked + or containing $(MAKE) of the target and of its prerequisites, each recipe at most up to its first line that is neither (an upper bound: it stops at the first out-of-date prerequisite whose recipe starts with a plain line; a file target that a + line just created may be deleted again). Only when that answers 2 does it ask the SECOND question, make -C <unit> -n <target>, same scrubbed environment, output discarded: 0 = present, 2 = missing. Under -n make walks the WHOLE recipe, so every + / $(MAKE) line of the target and of all its out-of-date prerequisites runs (a sub-make in dry-run mode runs its + lines and not its plain lines). Apart from that remake, no plain recipe line runs under either question. GNU make 4 answers 1 where 3.81 answers 2 to -q for a recipe that starts with a $(MAKE) or + line, and the judgment is the same (verify: $(MAKE) check-fast is present on both); verify: +false differs (3.81: -q 2 and -n 2 = missing; 4.3: -q 1 = present) and on both the root make verify ends non-zero. What runs during the inspection was measured on GNU make 3.81 and 4.3.
# (the units are the repository's own trusted code).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$(cd "$here/.." && pwd)}"
py="${PYTHON:-python3}"
# Layout guard: this module is monorepo-only (its manifest cannot say so), so a root without the pair is no monorepo.
if [[ ! -f "$root/pnpm-workspace.yaml" || ! -f "$root/repo.yaml" ]]; then
  echo "FAIL monorepo-settings-check: $root has no pnpm-workspace.yaml + repo.yaml pair; this module is for layout monorepo only"
  exit 1
fi
exec "$py" -B "$here/monorepo_check.py" check "$root"
