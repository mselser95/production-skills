#!/usr/bin/env bash
# agents-budget.sh — the pinned agents keep their token budget.
#
# WHY THIS EXISTS. Measured 2026-10-02 over 672 subagent transcripts: an agent
# definition WITHOUT `tools:` starts every run at 45-57k tokens of context (the
# whole tool roster), one with a restricted list at 17-20k, and every turn
# re-reads that prefix. And one agent handed a whole plan instead of one task
# was 64% of all implementer spend. Both protections live in the agents'
# definitions as one frontmatter key and a few rule lines -- exactly the kind of
# thing a well-meant edit deletes without anything going red. This makes it red.
#
# What it can and cannot see: it checks the DEFINITION (the restriction exists,
# Agent is not in it, the rules are present). It cannot see whether a model
# OBEYS the rules; the transcript measurement is the evidence for that.
#
# Usage: agents-budget.sh [repo-root]
# Exit:  0 ok · 1 a check failed · 2 nothing was checked
set -uo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
fails=0 checked=0
fail() { printf '  FAIL  %-18s %s\n' "$1" "$2"; fails=$((fails + 1)); }

# rules every pinned execution agent must carry, and the extra ones per agent
common_rules=("NO SPAWNING" "NO-POLLING")
implementer_rules=("ONE-TASK" "multi-task-dispatch" "BOUNDED-OUTPUT")

for a in prod-implementer prod-mechanic prod-scout; do
  f="$root/agents/$a.md"
  if [[ ! -r "$f" ]]; then fail "$a" "no agents/$a.md -- a pinned agent missing is a hole"; continue; fi
  checked=$((checked + 1))
  close=$(awk 'NR>1 && /^---[[:space:]]*$/ {print NR; exit}' "$f")
  if [[ "$(head -1 "$f")" != "---" || -z "$close" ]]; then fail "$a" "no closed frontmatter block"; continue; fi
  tools=$(sed -n "2,$((close - 1))p" "$f" | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin.read()) or {}
t = d.get("tools")
if isinstance(t, list): t = ", ".join(map(str, t))
print("" if t is None else str(t))
' 2>&1) || { fail "$a" "frontmatter does not parse: $tools"; continue; }
  if [[ -z "$tools" ]]; then
    fail "$a" "no tools: restriction -- the full roster costs ~25-35k extra tokens of context on EVERY turn"
  elif printf '%s\n' "$tools" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -qxE 'Agent|Task'; then
    fail "$a" "tools: includes Agent/Task -- a pinned agent never spawns (NO SPAWNING)"
  fi
  [[ "$a" == prod-scout ]] && continue   # read-only and short-lived: tools only
  rules=("${common_rules[@]}")
  [[ "$a" == prod-implementer ]] && rules+=("${implementer_rules[@]}")
  for r in "${rules[@]}"; do
    grep -qF -- "$r" "$f" || fail "$a" "rule '$r' is missing from the definition"
  done
done

if (( checked == 0 )); then echo "agents-budget: FAIL -- no agent definitions under $root/agents; nothing checked is not a pass" >&2; exit 2; fi
if (( fails )); then echo "agents-budget: $fails failure(s) across $checked agent(s)" >&2; exit 1; fi
echo "agents-budget: ok -- $checked agent(s): tools restricted, no spawning, budget rules present"
