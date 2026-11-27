#!/usr/bin/env bash
# Regenerate <task-dir>/expected.diffhash: copy fixture/ to a scratch git repo,
# commit it, run fixture.setup.sh, hash the resulting tree.
# usage: regen_expected.sh <task-dir>
set -eu
task=$(cd "$1" && pwd)
lib=$(cd "$(dirname "$0")" && pwd)
d=$(mktemp -d "${TMPDIR:-/tmp}/regen.XXXXXX")
trap 'rm -rf "$d"' EXIT
cp -R "$task/fixture/." "$d/"
cd "$d"
git init -q
git add -A
git -c user.name=corpus -c user.email=corpus@example.invalid commit -qm fixture
bash "$task/fixture.setup.sh"
python3 -I "$lib/grade_findings.py" --workdir "$d" --print-hash > "$task/expected.diffhash"
