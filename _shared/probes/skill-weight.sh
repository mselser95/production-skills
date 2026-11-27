#!/usr/bin/env bash
# skill-weight.sh — the nine skills keep their context weight, and cannot change
# WHAT they load without a reviewed diff.
#
# WHY THIS EXISTS. When an agent invokes a skill it loads SKILL.md and then the
# files that SKILL.md sends it to. That context is paid on every run, and nothing
# gated it: skills-static.sh checks frontmatter and description length,
# agents-budget.sh checks agent definitions, and scripts/token-report.sh is a
# trend over transcripts wired to no gate. This does not make any skill lighter;
# it measures and blocks growth.
#
# TWO SETS per skill, both recorded in benchmarks/skill-weight-baseline.md:
#   EAGER      SKILL.md + the references its opening paragraph orders read first
#              ("must be read before any work"). Wording-sensitive, see below.
#   REACHABLE  SKILL.md + every file under references/ that SKILL.md mentions
#              ANYWHERE, in any form (backticked, bare, ./references/, a markdown
#              link target, with or without a <skill>/ prefix): one regex over the
#              whole body, no sentence or paragraph parsing. references/probes/
#              scripts count like any other file and are also reported as a
#              sub-total ("of which probes") so the number is interpretable.
#              Files are de-duplicated by real path, symlinks dereferenced.
#
# CHECKS, per skill
#   (a) SKILL.md has <= 500 lines (agentskills.io/specification).
#   (b) every references/ mention resolves to a readable file (a dangling
#       mention, or a directory, FAILS); the eager rule matched something.
#   (c) EAGER RULE: the backticked `references/<path>` tokens of the first
#       blank-line-delimited paragraph containing
#       "Read `references/preamble.md` first", minus CONDITIONAL units. A UNIT ends
#       at . ! ? followed by whitespace, or at ';' (line breaks are joined; "e.g."
#       and "i.e." do not end one). Dashes do NOT end a unit. A unit is conditional
#       when it begins with "If ", contains "also read" or contains "only where",
#       and then EVERY reference in it is dropped, on either side of a dash.
#       Because ';' ends a unit, a conditional clause joined to an unconditional one
#       by ';' drops only its own references. A references/ mention in that
#       paragraph that is NOT exactly a backticked `references/<path>` (bare, link,
#       ./, <skill>/ prefix) FAILS with an order to backtick it, so the rule cannot
#       silently skip it.
#   (d) FILE-LIST RATCHET. The baseline records, per skill, the sorted file list
#       of EAGER and of REACHABLE. The probe FAILS when a measured list differs
#       from the recorded one in EITHER direction, a file ADDED or REMOVED, naming
#       the files: re-record with `make skill-weight-baseline` if intended. A
#       size-only ratchet cannot tell "the skill got lighter" from "the rule
#       stopped seeing a file", and a shrink would never fail; forcing a
#       re-record makes every change of what a skill loads a reviewed diff of the
#       baseline file. Byte growth > 5 % also fails for both sets when the lists
#       are equal (a referenced file grew). A skill absent from the baseline FAILS.
#   (e) CEILINGS: EAGER <= 64000 bytes (~16k tokens), REACHABLE <= 128000 (~32k),
#       unless the (skill, set) has a live liability in registries/waivers.yaml:
#       `obligation: skill-weight`, `skill`, `set: eager|reachable` (default
#       eager), `ceiling_bytes`, `owner`, `expires` (YYYY-MM-DD). One entry per
#       (skill, set); two for the same pair FAIL. The liability excuses the
#       ceiling, not growth past its own ceiling_bytes; a waived set is bounded by
#       the ratchet (+5 %) and by ceiling_bytes, whichever is lower. An EXPIRED
#       one excuses nothing; one for a set now under its ceiling, or for an
#       unknown skill, is stale and FAILS.
#   (f) the baseline is checked as data: duplicate rows for a skill, a row for a
#       skill that does not exist, a malformed row, and a table that does not
#       match its final `checksum: <sha256>` line all FAIL.
#
# What it can and cannot see.
#   EAGER is wording-sensitive: a rewording can change what the rule finds. It is
#   protected by the file-list ratchet (any change of the list is red until
#   re-recorded and reviewed) and by the no-unbackticked-reference rule. REACHABLE
#   is wording-insensitive but an UPPER bound: a skill may not read every
#   reachable file in one run, and it cannot see a file named by a path the regex
#   does not match (for example one assembled in prose). Neither can see whether
#   a model obeys the order, reads a file partly, or reads more than named. Tokens
#   are bytes/4, an approximation. The baseline checksum only makes a casual
#   hand-edit red: an editor who recomputes it is not stopped by the checksum,
#   and the file-list ratchet plus the review of the baseline diff cover that.
#
# The measuring core is skill-weight.py (python3 + PyYAML), beside this file.
#
# Usage: skill-weight.sh [repo-root]        check (default root: this repo)
#        skill-weight.sh --write [repo-root] re-record benchmarks/skill-weight-baseline.md
# Exit:  0 ok · 1 a check failed · 2 nothing was checked
set -uo pipefail

mode="check"
if [[ "${1:-}" == "--write" ]]; then mode="write"; shift; fi
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# The parser is required, never skipped: a liability file read by nothing would
# excuse every skill silently.
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' 2>/dev/null; then
  echo "skill-weight: FAIL -- python3 with PyYAML is unavailable, so the liability registry could not be parsed; unparsed is not valid" >&2
  exit 1
fi

exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/skill-weight.py" "$mode" "$root"
