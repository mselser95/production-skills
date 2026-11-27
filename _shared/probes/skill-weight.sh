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
#              whole body, no sentence or paragraph parsing. Files are
#              de-duplicated by real path, symlinks dereferenced.
#   PROBES     A PROBE is a script a skill RUNS: the model reads its output, not its
#              source. A mention is a probe only if ALL hold: it is under
#              references/probes/ with no `.`/`..` segment; its REAL path (links
#              resolved) is inside a probe HOME; and it is an executable regular
#              file named *.sh. Two homes, by layout: <root>/_shared/probes/ always;
#              the skill's own references/probes/ ONLY when <root>/_shared/probes
#              does not exist (an installed copy, where those are real files). In
#              the source repo every entry there is a link into _shared/probes/, so
#              a real file there is an ordinary reference: counted. Anything else under references/probes/ is an
#              ordinary reference, counted, with a note. A probe mentioned in the
#              read-first paragraph FAILS ("read first" is not "run"). Probes stay
#              in the FILE LISTS of whichever set mentions them (adding or removing
#              a probe mention is a reviewed baseline diff) and are REPORTED as a
#              sub-total ("+ probes N not gated"), but their bytes are EXCLUDED from
#              the gated byte total, the +5 % byte ratchet and the ceiling, in both
#              sets. Routine churn in a script nobody reads must not turn the gate
#              red. Why executable: a skill that says to run `references/probes/x.sh`
#              runs it directly, so a script without its exec bit is a defect, and
#              the gate reports it rather than silently excusing its bytes.
#
# CHECKS, per skill
#   (a) SKILL.md has <= 500 lines (agentskills.io/specification).
#   (b) every references/ mention resolves to a readable file. A dangling mention,
#       a directory (`references/probes/`), the bare `references/`, a backticked
#       token or link target (plain, <angle-bracketed> or titled, any case) that is just `references` (or ends in `/references`),
#       and any glob (`references/*.md`, `{a,b}`, `?`, `[x]`) FAIL, in both sets,
#       with an order to name the files explicitly: a directory or glob orders
#       every file in it read, which cannot be measured. A mention with a `.` or
#       `..` segment FAILS too ("name the file by its direct path"). The eager rule
#       must also match at least one reference; the "no references/ mention found"
#       check is defence in depth, since the anchor paragraph itself mentions
#       references/preamble.md, so a skill with no mention at all already fails (c).
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
#   re-recorded and reviewed) and by the no-unbackticked-reference rule.
#   REACHABLE is wording-insensitive, and an UPPER bound ONLY over the files under
#   references/ that SKILL.md names explicitly and the model READS: a run may not
#   read every one of them. It is NOT an upper bound of everything a run loads:
#   (a) Paths outside references/ are invisible to both sets: absolute paths,
#       ../_shared/..., demos/INDEX.md. Measured: demos/INDEX.md (22,075 bytes) is
#       mentioned by prod-test-synth, prod-bootstrap and prod-new and is not counted.
#   (b) Transitive reads are not followed: a referenced file that tells the agent
#       to read another is measured as the one file.
#   (c) Executed probes are listed but not gated (see PROBES above): a script the
#       skill runs costs its output, not its source. A skill that instead READS a
#       probe's source is mis-measured low. A footnote glued to an unbackticked
#       path (`references/a.md[^1]`) reads as a glob and FAILS, on purpose; after a
#       closing backtick it is fine.
#   Nor can it see a file named by a path the regex does not match (one assembled
#   in prose), whether a model obeys the order, reads a file partly, or reads more
#   than named. Tokens are gated bytes/4, an approximation. The baseline checksum
#   only makes a casual hand-edit red: an editor who recomputes it is not stopped
#   by the checksum, and the file-list ratchet plus the review of the baseline
#   diff cover that.
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
