#!/usr/bin/env bash
# skills-static.sh — structural validity of the nine skills, checked LOCALLY.
#
# WHY THIS EXISTS
#
# README documents the structural gate as `skill-optimizer doctor --static`.
# That tool is real (github.com/fastxyz/skill-optimizer) and richer than this
# file, but it is a third-party install: on a machine that does not have it the
# documented gate does not fail, it simply never runs. Measured 2026-08-29 on
# this laptop, `claude plugin skill doctor --static <s>` printed
# `error: unknown command 'skill'` AND EXITED 0 -- for nine skills in a row --
# while the closing checklist recorded "doctor --static: 0 errors on all nine".
# Nine green verdicts about a command that does not exist. That is the exact
# shape rule 1 warns about: ask of every gate what would go red if it could not
# run at all, and the answer here was nothing.
#
# The nearest built-in is no substitute. `claude plugin validate <skills-dir>`
# was mutation-probed the same day against a copy of two real skills:
#
#   mutation applied to a NESTED skill        | verdict
#   -----------------------------------------|-------------------------
#   description: present but empty            | PASSED
#   frontmatter YAML syntactically invalid    | PASSED
#   SKILL.md deleted entirely                 | PASSED
#   frontmatter block removed                 | passed WITH WARNING
#
# It does not descend into nested skill directories, so for this repo's layout
# it is close to vacuous. Hence a local probe that goes RED.
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

for s in "${skills[@]}"; do
  dir="$root/$s"
  # A skill absent from the root is not this probe's business to invent: the
  # caller may legitimately point at a subset (the selftest does). But a skill
  # whose DIRECTORY exists and whose SKILL.md does not is a hard failure -- that
  # is the case `claude plugin validate` passes silently.
  [[ -d "$dir" ]] || continue
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
