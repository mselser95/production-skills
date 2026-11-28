#!/usr/bin/env bash
# monorepo-run.sh <target> -- run <target> in every unit of repo.yaml that has it; one line per
# unit; the first failure stops the run (exit 1). "Has it" is monorepo_check.py's one answer (it asks
# make -n for a service/database, which evaluates the unit Makefile but runs no target recipe; it reads
# package.json scripts for an app/package). A unit without an OPTIONAL target is `skip`; a unit without a
# MANDATORY one for its kind (monorepo_check.py MANDATORY) is a FAIL before any unit TARGET is run. The unit list is read fully before anything runs, each unit gets
# stdin from /dev/null, and the run asserts it ran as many units as it announced.
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
