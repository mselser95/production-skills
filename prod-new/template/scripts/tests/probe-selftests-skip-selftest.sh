#!/usr/bin/env bash
# provenance: candidate (ttl: 2027-04-06); derived-from: invariant a-gate-never-reports-green-over-something-it-did-not-measure
# pinning: true   (exact message wording and exit codes; no ratified property names them yet)
#
# probe-selftests-skip-selftest.sh -- drives the template Makefile's
# `acceptance-audit-selftest-run` target (the acceptance-audit step of `probe-selftests`) against
# a STUB selftest that just exits with a chosen code, so the real selftest never runs here.
# The rule shown firing: rc 0 passes; rc 3 (SKIPPED, customised changed-line-coverage.sh) passes
# ONLY when registries/contract-debt.yaml has an entry whose evidence/path field names the script,
# and says which entry honoured it; rc 3 without one fails; rc 1 and rc 2 fail whatever the registry holds.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mk="$here/../../Makefile"
grep -q '^acceptance-audit-selftest-run:' "$mk" || { echo "probe-selftests-skip selftest: target not found in $mk"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/probe-selftests-skip.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
pass=0 bad=0

# mk <name> <stub-exit-code> : scratch repo whose stub selftest exits with that code
mkr() { local r="$tmp/$1"; mkdir -p "$r/registries"; cp "$mk" "$r/Makefile"; printf '#!/bin/sh\necho "stub selftest ran"\nexit %s\n' "$2" > "$r/stub.sh"; echo "$r"; }
# run <name> <want-rc> <want-substr> <repo> ; "!x" as substr = must be ABSENT
run() {
  local name="$1" wrc="$2" want="$3" r="$4" out rc ok=1
  out="$(cd "$r" && make --no-print-directory acceptance-audit-selftest-run ACCEPTANCE_AUDIT_SELFTEST=stub.sh 2>&1)"; rc=$?
  if [[ "$want" == '!'* ]]; then [[ "$out" != *"${want#!}"* ]] || ok=0; else [[ "$out" == *"$want"* ]] || ok=0; fi
  if [[ "$rc" -eq "$wrc" && "$ok" = 1 ]]; then pass=$((pass+1)); echo "  ok   $name"
  else bad=$((bad+1)); echo "  FAIL $name (rc=$rc want $wrc, wanted '$want')"; echo "$out" | sed 's/^/       /'; fi
}
SKIPPED='SKIPPED, honoured by contract-debt entry'
NOENTRY='probe-selftests: FAIL -- acceptance-audit selftest skipped (customised scripts/changed-line-coverage.sh) and registries/contract-debt.yaml does not record it'

r="$(mkr rc0 0)"
run "rc 0 passes" 0 '!probe-selftests:' "$r"
run "rc 0 passes and the stub ran" 0 "stub selftest ran" "$r"

r="$(mkr rc3entry 3)"
cat > "$r/registries/contract-debt.yaml" <<'YAML'
# a comment that names scripts/changed-line-coverage.sh must not count
entries:
  - id: other-debt
    owner: team-a
    created: 2026-10-01
    expires: 2027-01-01
    evidence: "an unrelated shim"
  - id: customised-clc
    owner: team-b
    created: 2026-10-01
    expires: 2027-01-01
    evidence: >
      scripts/changed-line-coverage.sh is repo-customised, so the template-format
      acceptance-audit selftest cannot drive it.
YAML
run "rc 3 with an entry naming the script passes, naming the entry id" 0 "probe-selftests: acceptance-audit selftest SKIPPED, honoured by contract-debt entry customised-clc" "$r"
run "rc 3 honoured: does not name the unrelated entry" 0 '!entry other-debt' "$r"

r="$(mkr rc3path 3)"
printf 'entries:\n  - id: by-path\n    owner: o\n    created: 2026-10-01\n    expires: 2027-01-01\n    path: scripts/changed-line-coverage.sh\n' > "$r/registries/contract-debt.yaml"
run "rc 3 with an entry whose path field names the script passes" 0 "$SKIPPED by-path" "$r"

r="$(mkr rc3none 3)"; rm -rf "$r/registries"
run "rc 3 with no registry file fails" 2 "$NOENTRY" "$r"

r="$(mkr rc3empty 3)"; printf 'entries: []\n' > "$r/registries/contract-debt.yaml"
run "rc 3 with an empty registry fails" 2 "$NOENTRY" "$r"

r="$(mkr rc3other 3)"
printf 'entries:\n  - id: other-debt\n    owner: o\n    created: 2026-10-01\n    expires: 2027-01-01\n    evidence: "scripts/some-other-script.sh is customised"\n' > "$r/registries/contract-debt.yaml"
run "rc 3 with an entry about a different script fails" 2 "$NOENTRY" "$r"

r="$(mkr rc3comment 3)"
printf '# - id: retired\n#   evidence: scripts/changed-line-coverage.sh\nentries: []\n' > "$r/registries/contract-debt.yaml"
run "rc 3 with the script named only in a comment fails" 2 "$NOENTRY" "$r"

r="$(mkr rc3owner 3)"
printf 'entries:\n  - id: wrong-field\n    owner: scripts/changed-line-coverage.sh\n    created: 2026-10-01\n    expires: 2027-01-01\n    evidence: "x"\n' > "$r/registries/contract-debt.yaml"
run "rc 3 with the script named only in the owner field fails" 2 "$NOENTRY" "$r"

r="$(mkr rc3unrelated 3)"
printf 'entries:\n  - id: first-debt\n    owner: o\n    summary: "see scripts/changed-line-coverage.sh"\n    evidence: "x"\n  - id: unrelated-debt\n    owner: o\n    evidence: "y"\n' > "$r/registries/contract-debt.yaml"
run "rc 3 with the script mentioned only in an unrelated entry's other field fails" 2 "$NOENTRY" "$r"

r="$(mkr rc3notes 3)"
printf 'entries:\n  - id: notes-debt\n    owner: o\n    notes: |\n      evidence: scripts/changed-line-coverage.sh\n      path: scripts/changed-line-coverage.sh\n    evidence: "x"\n' > "$r/registries/contract-debt.yaml"
run "rc 3 with evidence: inside a notes block scalar fails" 2 "$NOENTRY" "$r"

r="$(mkr rc3bak 3)"
printf 'entries:\n  - id: bak-debt\n    owner: o\n    evidence: "scripts/changed-line-coverage.sh.bak"\n    path: scripts/changed-line-coverage.sh.bak\n' > "$r/registries/contract-debt.yaml"
run "rc 3 with a .bak path fails" 2 "$NOENTRY" "$r"

r="$(mkr rc3id2 3)"
printf 'entries:\n  - owner: o\n    id: second-key-id\n    created: 2026-10-01\n    evidence: "scripts/changed-line-coverage.sh"\n  - id: later\n    evidence: "x"\n' > "$r/registries/contract-debt.yaml"
run "rc 3 with id as the second key names that entry's id" 0 "$SKIPPED second-key-id" "$r"

r="$(mkr rc3incomment 3)"
printf 'entries:\n  - id: commented\n    owner: o\n    # evidence: scripts/changed-line-coverage.sh\n    evidence: "x"\n      # evidence: scripts/changed-line-coverage.sh\n' > "$r/registries/contract-debt.yaml"
run "rc 3 with the script named only in an in-entry comment fails" 2 "$NOENTRY" "$r"

for code in 1 2; do
  r="$(mkr "rc$code" "$code")"
  printf 'entries:\n  - id: customised-clc\n    owner: o\n    created: 2026-10-01\n    expires: 2027-01-01\n    evidence: "scripts/changed-line-coverage.sh"\n' > "$r/registries/contract-debt.yaml"
  run "rc $code fails even with a matching registry entry" 2 "probe-selftests: FAIL -- acceptance-audit selftest exited $code" "$r"
  run "rc $code is never reported as honoured" 2 "!honoured" "$r"
done

if (( pass == 0 )); then echo "probe-selftests-skip selftest: ZERO cases ran"; exit 1; fi
if (( bad )); then echo "probe-selftests-skip selftest: $bad of $((pass + bad)) case(s) failed"; exit 1; fi
echo "probe-selftests-skip selftest: ok -- $pass case(s)"
