#!/usr/bin/env bash
# monorepo-run.sh <target> -- run <target> in every unit of repo.yaml that has it; one line per
# unit; the first failure stops the run (exit 1). A unit without the target is `skip`, never silent.
# PYTHON / PNPM override the interpreters (tests use fakes).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
target="${1:?usage: monorepo-run.sh <target>}"
py="${PYTHON:-python3}"
pnpm_bin="${PNPM:-pnpm}"
listing="$("$py" -B "$here/monorepo_check.py" units "$root" "$target")" || { echo "monorepo-run: cannot read repo.yaml" >&2; exit 2; }
n=0
while IFS=$'\t' read -r id kind path has; do
  [[ -n "$id" ]] || continue
  n=$((n + 1))
  if [[ "$has" != "1" ]]; then echo "$target $id: skip (no $target)"; continue; fi
  if [[ "$kind" == "service" || "$kind" == "database" ]]; then
    make -C "$root/$path" "$target"
  else
    "$pnpm_bin" --dir "$root/$path" run "$target"
  fi
  rc=$?
  if [[ $rc -ne 0 ]]; then echo "$target $id: FAIL ($rc)"; exit 1; fi
  echo "$target $id: ok"
done <<<"$listing"
echo "monorepo-run: $target over $n unit(s)"
