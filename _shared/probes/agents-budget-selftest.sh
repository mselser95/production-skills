#!/usr/bin/env bash
# agents-budget-selftest.sh — every rule in agents-budget.sh shown firing on a
# fixture where its property is false, plus the real repo passing.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="$here/agents-budget.sh"
real_root="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/agents-budget-selftest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pass=0 bad=0

run_case() { # name want_rc want_substring root
  local out rc
  out="$(bash "$probe" "$4" 2>&1)"; rc=$?
  if [[ $rc -eq $2 && "$out" == *"$3"* ]]; then pass=$((pass + 1))
  else echo "FAIL [$1]: rc=$rc want=$2, wanted '$3' in: $out"; bad=$((bad + 1)); fi
}
mk() { # mk <name> ; copy of the real agents into a fresh root
  local r="$tmp/$1"; mkdir -p "$r/agents"; cp "$real_root"/agents/prod-*.md "$r/agents/"; echo "$r"
}

run_case "the real repo passes" 0 "agents-budget: ok" "$real_root"

r=$(mk no-tools); sed -i.bak '/^tools:/d' "$r/agents/prod-implementer.md"
run_case "a missing tools: restriction fails" 1 "no tools: restriction" "$r"

r=$(mk spawn); sed -i.bak 's/^tools: \(.*\)$/tools: \1, Agent/' "$r/agents/prod-mechanic.md"
run_case "Agent in tools: fails" 1 "includes Agent/Task" "$r"

r=$(mk no-onetask); sed -i.bak 's/ONE-TASK/ONE-THING/g' "$r/agents/prod-implementer.md"
run_case "the ONE-TASK rule removed fails" 1 "rule 'ONE-TASK'" "$r"

r=$(mk no-polling); sed -i.bak 's/NO-POLLING/WAITING/g' "$r/agents/prod-mechanic.md"
run_case "the NO-POLLING rule removed fails" 1 "rule 'NO-POLLING'" "$r"

r=$(mk author); sed -i.bak 's/APPROVED-ONLY/WHENEVER/g' "$r/agents/prod-acceptance-author.md"
run_case "the author's APPROVED-ONLY rule removed fails" 1 "rule 'APPROVED-ONLY'" "$r"

r=$(mk no-focus); sed -i.bak 's/FOCUSED-READ/SKIMMING/g' "$r/agents/prod-mechanic.md"
run_case "the FOCUSED-READ rule removed fails" 1 "rule 'FOCUSED-READ'" "$r"

r=$(mk drift); sed -i.bak 's/over 500 characters/over 5000 characters/' "$r/agents/prod-implementer.md"
run_case "the 500-char rule drifting to 5000 fails" 1 "numeric budget literal 'over 500 characters'" "$r"

r=$(mk tail400); sed -i.bak 's/tail -n 40/tail -n 400/g' "$r/agents/prod-implementer.md"
run_case "tail -n 40 drifting to 400 fails" 1 "numeric budget literal 'tail -n 40'" "$r"

r=$(mk no-bounded); sed -i.bak 's/BOUNDED-OUTPUT/UNBOUNDED/g' "$r/agents/prod-mechanic.md"
run_case "BOUNDED-OUTPUT removed from the mechanic fails" 1 "rule 'BOUNDED-OUTPUT'" "$r"

r=$(mk heading); sed -i.bak 's/\*\*BOUNDED-OUTPUT:\*\*/**BOUNDED-OUT:**/' "$r/agents/prod-mechanic.md"
run_case "only the heading renamed (cross-refs kept) fails" 1 "heading **BOUNDED-OUTPUT:** not found" "$r"

r=$(mk validator); sed -i.bak 's/\*\*READ-ONLY:\*\*/**WRITE-OK:**/' "$r/agents/prod-validator.md"
run_case "the validator's READ-ONLY rule removed fails" 1 "rule 'READ-ONLY'" "$r"

r=$(mk missing); rm "$r/agents/prod-scout.md"
run_case "a pinned agent missing fails" 1 "no agents/prod-scout.md" "$r"

mkdir -p "$tmp/empty"
run_case "no agents at all is not a pass" 2 "nothing checked is not a pass" "$tmp/empty"

if (( pass == 0 )); then echo "agents-budget selftest: ZERO cases ran"; exit 1; fi
if (( bad )); then echo "agents-budget selftest: $bad of $((pass + bad)) case(s) failed"; exit 1; fi
echo "agents-budget selftest: ok -- $pass case(s)"
