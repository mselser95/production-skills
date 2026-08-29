#!/usr/bin/env bash
# skills-static.sh — structural validity of the nine skills, checked LOCALLY.
#
# WHY THIS EXISTS
#
# NOT because the documented gate is missing. An earlier version of this header
# said `skill-optimizer doctor --static` was "a third-party install" absent from
# this machine, and cited `error: unknown command 'skill'` as proof. That was
# wrong, and wrong in the way this repo exists to refuse: the tool IS installed
# (/opt/homebrew/bin/skill-optimizer, v1.1.0), and the error I cited came from
# `claude plugin skill doctor` -- a different, mistyped command. I asserted a
# measurement I had taken of something else. The correction is kept here rather
# than quietly deleted, because the claim shipped.
#
# The real reason, measured 2026-08-29 by mutating a copy of prod-ops and
# running each tool against the same fixtures:
#
#   mutation to SKILL.md            | skill-optimizer doctor --static | this probe
#   --------------------------------|---------------------------------|-----------
#   description: present but empty  | rc=0, "0 error(s)"              | FAILS
#   frontmatter invalid YAML        | rc=0, "0 error(s)"              | FAILS
#   SKILL.md deleted entirely       | rc=1  (caught)                  | FAILS
#
# `doctor --static` validates the .skill-optimizer/ CONFIG -- authModes, task
# freezing, benchmark wiring -- which is a different and useful question. It is
# not a frontmatter check, and it reports "0 error(s)" on a skill whose
# description is empty, which is the state that makes a skill unreachable in
# practice while every other check stays green. So the two are complementary,
# and README asks for both.
#
# The nearest built-in is no substitute either. `claude plugin validate
# <skills-dir>` PASSED all three mutations above when applied to a NESTED skill:
# it does not descend into nested skill directories.
#
# One thing the wrong version got right and is worth keeping: a gate can report
# success having done nothing, and `skill-optimizer doctor --static` run from
# the wrong directory prints `ERROR: Cannot read config` AND EXITS 0. Check the
# output, not only the status, whichever tool you run.
#
# Usage: skills-static.sh [skills-root]   (default: the repo this file lives in)
# Exit:  0 all checks pass · 1 a check failed · 2 nothing was checked
set -uo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
skills=(prod-spec prod-review prod-incident prod-implement prod-test-synth
        prod-ops prod-curate prod-bootstrap prod-new)

fails=0 checked=0
fail() { printf '  FAIL  %-16s %s\n' "$1" "$2"; fails=$((fails + 1)); }

# NO LENGTH CHECK ON name/description, deliberately.
#
# The first draft of this file failed any description over 1024 chars, and it
# fired on six of the nine. The number was mine -- I asserted a loader limit I
# had not measured. The disproof was in the same session: Claude Code's own
# skill listing printed prod-ops's description ending "...or the ask is feature
# work." and prod-curate's ending "...this skill only ever proposes)." Measured
# against the files, those are chars 1075 and 1043 -- delivered whole, past the
# bound I had invented, so nothing was being truncated.
#
# Six confident FAILs on healthy skills is worse than not checking length at
# all: it is exactly the assertion that fires when nothing is wrong, and the
# way out people take is to widen the bound until it never fires again. If a
# real limit is ever established BY MEASUREMENT (feed a known-length
# description in and observe where the loader cuts), add the check back with
# that evidence cited here. Until then this probe stays silent about length,
# because an unmeasured bound is a guess wearing a gate's clothes.

# Was an explicit root given? Against the DEFAULT root -- this repo -- the nine
# are a fixed, known list and a missing one is a failure. Against an explicit
# root the caller may legitimately be pointing at a subset (every selftest
# fixture holds exactly one skill), so absence there is not this probe's
# business to invent.
#
# The first version skipped a missing directory unconditionally, which meant
# deleting prod-ops outright produced "ok -- 8 skill(s) structurally valid" and
# exit 0. That is checked-and-none confused with nothing-checked, reintroduced
# in a file written to enforce the distinction: 8 of 9 present is not a subset
# the caller chose, it is a hole.
# SKILLS_STATIC_REQUIRE_ALL=1 forces the strict reading on an explicit root.
# Without it this branch would be unreachable from the selftest -- every fixture
# passes a root, so it would take the lenient path every time and the rule could
# never be shown firing. A rule with no fixture where its property is false is
# the thing this repo calls decoration.
subset_root=0
[[ $# -ge 1 ]] && subset_root=1
[[ "${SKILLS_STATIC_REQUIRE_ALL:-0}" == "1" ]] && subset_root=0

for s in "${skills[@]}"; do
  dir="$root/$s"
  if [[ ! -d "$dir" ]]; then
    if (( subset_root )); then
      continue
    fi
    fail "$s" "no directory at $s/ -- the nine are a fixed list, so a skill missing from this repo is a hole, not a subset the caller asked for"
    continue
  fi
  checked=$((checked + 1))
  md="$dir/SKILL.md"

  if [[ ! -r "$md" ]]; then
    fail "$s" "no readable SKILL.md at $s/SKILL.md -- a skill directory without its entrypoint loads as nothing"
    continue
  fi

  # Frontmatter must be delimited, and the FIRST line must be the opening
  # delimiter: a --- that appears later in the body is a horizontal rule, not
  # frontmatter, and the loader will not read it as metadata.
  if [[ "$(head -1 "$md")" != "---" ]]; then
    fail "$s" "SKILL.md does not open with a --- frontmatter delimiter on line 1"
    continue
  fi
  # Line number of the CLOSING delimiter (first --- at or after line 2).
  close=$(awk 'NR>1 && /^---[[:space:]]*$/ {print NR; exit}' "$md")
  if [[ -z "$close" ]]; then
    fail "$s" "SKILL.md opens a frontmatter block that is never closed by a second ---"
    continue
  fi

  fm=$(sed -n "2,$((close - 1))p" "$md")

  # Parse as real YAML rather than grepping keys: an unquoted colon or an
  # unclosed bracket makes the block unloadable while a grep for `name:` still
  # matches happily. Absence of python3 must not silently downgrade the check.
  if ! command -v python3 >/dev/null 2>&1; then
    fail "$s" "python3 is unavailable, so the frontmatter could not be parsed -- unparsed is not valid"
    continue
  fi
  parsed=$(printf '%s\n' "$fm" | python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(sys.stdin.read())
except Exception as e:
    print("ERR " + str(e).replace("\n", " ")); raise SystemExit(0)
if d is None:
    print("ERR frontmatter block is empty"); raise SystemExit(0)
if not isinstance(d, dict):
    print("ERR frontmatter is a %s, not a mapping" % type(d).__name__); raise SystemExit(0)
n, s_ = d.get("name"), d.get("description")
print("NAME %s" % ("" if n is None else str(n)))
print("DESC %s" % ("" if s_ is None else str(s_).replace("\n", " ")))
' 2>&1)

  if [[ "$parsed" == ERR\ * ]]; then
    fail "$s" "frontmatter does not parse as YAML: ${parsed#ERR }"
    continue
  fi

  name=$(printf '%s\n' "$parsed" | sed -n 's/^NAME //p')
  desc=$(printf '%s\n' "$parsed" | sed -n 's/^DESC //p')

  [[ -n "$name" ]] || fail "$s" "frontmatter has no non-empty name: -- the loader has nothing to register the skill under"
  [[ -n "$desc" ]] || fail "$s" "frontmatter has no non-empty description: -- the description is the ONLY text the model sees when deciding whether to invoke this skill, so an empty one makes the skill unreachable in practice while every structural check still passes"

  if [[ -n "$name" && "$name" != "$s" ]]; then
    fail "$s" "frontmatter name '$name' does not match its directory '$s' -- invocation resolves by directory, so the two disagreeing means one of them is a lie"
  fi

  # references/ reaches _shared through symlinks in the source repo. A dangling
  # one is invisible until a skill run tries to read the file and finds nothing,
  # which is a failure at USE time rather than at check time.
  while IFS= read -r link; do
    [[ -e "$link" ]] || fail "$s" "dangling symlink ${link#"$root/"} -- points at a file that does not exist, and a reference resolves to nothing only when a run needs it"
  done < <(find "$dir" -type l 2>/dev/null)
done

# Zero-inputs: a sweep whose subject list came back empty must not report clean.
if (( checked == 0 )); then
  echo "skills-static: FAIL -- no skill directories found under $root; a check with no subjects is not a pass" >&2
  exit 2
fi

if (( fails > 0 )); then
  echo "skills-static: ${fails} failure(s) across ${checked} skill(s) under $root" >&2
  exit 1
fi
# The success line names exactly what was checked and nothing more. It said
# "description present and within limits" for one commit after the length check
# had been removed -- a green verdict claiming a check that no longer existed,
# which is the same defect this probe was written to catch, in its own output.
echo "skills-static: ok -- ${checked} skill(s) structurally valid (SKILL.md present, frontmatter parses as YAML, name matches dir, description non-empty, no dangling symlinks). Length is NOT checked -- see the note above."
