#!/usr/bin/env bash
# check-registries-selftest.sh — prove scripts/check-registries.sh's parser
# actually enforces expiry, instead of assuming it does.
#
# The gate's whole value is that an entry cannot silently escape enforcement.
# Each case here is a way that used to happen (or could easily happen again
# in a rewrite):
#
#   1. id-not-first    -- an entry whose `id:` key is not the first line of
#                          the entry used to be invisible to the gate: the
#                          old parser only started a new entry on a literal
#                          "- id:" line, so a continuation-line `id:` was
#                          never captured and the whole entry (including an
#                          EXPIRED date) was silently dropped by flush()'s
#                          `[[ -z "$id" ]] && return`.
#   2. missing expires -- every entry needs an expires: key; omitting it
#                          must be MALFORMED, not silently uncounted.
#   3. expired entry   -- a past date must be EXPIRED and fail the gate.
#   4. expires: never  -- the one legal non-date value; must NOT be flagged.
#   5. malformed date  -- a value that is neither `never` nor YYYY-MM-DD
#                          must be MALFORMED, not silently accepted.
#
# This runs the REAL script end-to-end against scratch fixture directories
# (via REGISTRIES_DIR) rather than re-implementing the parser: a selftest
# that reimplements the logic under test only ever tests the copy.
#
# Usage: bash scripts/tests/check-registries-selftest.sh
# Exit:  0 all cases behaved; 1 a case did not.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

SCRIPT=scripts/check-registries.sh
[[ -r "$SCRIPT" ]] || { echo "selftest: no $SCRIPT" >&2; exit 2; }

fails=0

# run_empty_case exercises the one path run_case structurally cannot: a
# registries directory with no .yaml in it. run_case always writes a fixture,
# so the fail-closed exit added for "deleting the registries must not pass this
# gate" had no case in the selftest that exists to verify exactly this parser.
# A guard whose own selftest cannot reach it is the shape this file is for.
run_empty_case() {
  local name="$1" want_rc="$2" want_substr="$3"
  local dir out rc

  dir="$(mktemp -d)"   # deliberately left empty
  set +e
  out="$(REGISTRIES_DIR="${dir}" bash "$SCRIPT" 2>&1)"
  rc=$?
  set -e
  rmdir "$dir"

  if [[ "$rc" -ne "$want_rc" ]]; then
    echo "  FAIL ${name} — expected exit ${want_rc}, got ${rc}. output: ${out}" >&2
    fails=$((fails+1))
    return
  fi
  if [[ -n "$want_substr" ]] && [[ "$out" != *"$want_substr"* ]]; then
    echo "  FAIL ${name} — expected to see '${want_substr}', got: ${out}" >&2
    fails=$((fails+1))
    return
  fi
  echo "  ok   ${name}"
}

run_case() {
  # run_case <name> <fixture-yaml> <expected-exit> <expected-output-substring>
  local name="$1" fixture="$2" want_rc="$3" want_substr="$4"
  local dir out rc

  dir="$(mktemp -d)"
  printf '%s\n' "$fixture" > "${dir}/fixture.yaml"

  set +e
  out="$(REGISTRIES_DIR="${dir}" bash "$SCRIPT" 2>&1)"
  rc=$?
  set -e
  rm -rf "$dir"

  if [[ "$rc" -ne "$want_rc" ]]; then
    echo "  FAIL ${name} — expected exit ${want_rc}, got ${rc}. output: ${out}" >&2
    fails=$((fails+1))
    return
  fi
  if [[ -n "$want_substr" ]] && [[ "$out" != *"$want_substr"* ]]; then
    echo "  FAIL ${name} — expected to see '${want_substr}', got: ${out}" >&2
    fails=$((fails+1))
    return
  fi
  echo "  ok   ${name}"
}

echo "check-registries selftest: start"

# 1. id-not-first: expires is written BEFORE id in the entry. A past date
# means this must be reported EXPIRED and must fail the gate -- if the
# parser regresses to only recognizing "- id:" as the entry boundary, this
# entry goes invisible (0 entries counted, exit 0) instead.
run_case "id-not-first is still enforced (expired)" \
'entries:
  - owner: someone
    expires: 2020-01-01
    id: reordered-entry' \
  1 "EXPIRED"

run_case "id-not-first is counted, not silently dropped" \
'entries:
  - owner: someone
    expires: 2099-01-01
    id: reordered-entry-future' \
  0 "1 entries checked"

# 2. missing expires: -- must be MALFORMED and fail the gate.
run_case "missing expires is malformed" \
'entries:
  - id: no-expiry-field
    owner: someone' \
  1 "MALFORMED"

# 3. expired entry (ordinary id-first form) -- must fail the gate.
run_case "expired entry fails the gate" \
'entries:
  - id: long-expired
    owner: someone
    expires: 2020-06-15' \
  1 "EXPIRED"

# 4. expires: never -- the one legal non-date value; must pass.
run_case "expires never is legal" \
'entries:
  - id: permanent-lever
    owner: someone
    expires: never' \
  0 "0 expired, 0 expiring"

# 5. malformed date -- neither "never" nor YYYY-MM-DD.
run_case "malformed date is malformed" \
'entries:
  - id: bad-date-format
    owner: someone
    expires: next-tuesday' \
  1 "MALFORMED"

# 5b. A date that is malformed ONLY by shape, chosen so the case reds on BOTH
# platforms if the shape gate is removed.
#
# Case 5 above uses `next-tuesday`, and that case is VACUOUS on macOS: BSD
# `date` rejects relative English on its own, so it stays green there with the
# shape gate reverted and only reds on Linux -- i.e. it has no regression guard
# on the platform `make check-fast` runs on before a push, which is exactly the
# platform split that produced the bug.
#
# `2026-2-3` is unpadded but unambiguous, and both implementations accept it:
# BSD `date -j -f "%Y-%m-%d" 2026-2-3` yields 2026-02-03 (gate exits 0), GNU
# `date -d` reads it as a past date (EXPIRED -- wrong message, wrong exit
# reason). With the shape gate in place both say MALFORMED and exit 1, so
# removing the gate reds this case on any machine.
run_case "unpadded date is malformed on every platform" \
'entries:
  - id: unpadded-date
    owner: someone
    expires: 2026-2-3' \
  1 "MALFORMED"

# 5c. An IMPOSSIBLE date. BSD date normalises 2027-02-30 to 2027-03-02 and
# accepts it; GNU date rejects it. Same input, opposite verdict -- the platform
# split the shape gate could not close, because the shape is valid. Closed by
# rendering the parsed timestamp back and requiring it to equal the input.
run_case "an impossible date is malformed on every platform" \
'entries:
  - id: impossible-date
    owner: someone
    expires: 2027-02-30' \
  1 "MALFORMED"

# 5d. The expiry-day boundary. This is the case that made the same entry read
# EXPIRED on Linux (exit 1) and EXPIRING in 0d (exit 0) on macOS: GNU date
# returns the day's midnight while BSD date fills H:M:S from the current time,
# so after 00:00 the BSD value was "in the future" relative to a `date -u +%s`
# taken as "now". Both sides are UTC midnights now, so today is not yet expired
# on either.
run_case "an entry expiring TODAY is expiring, not expired" \
"entries:
  - id: expires-today
    owner: someone
    expires: $(date -u +%Y-%m-%d)" \
  0 "EXPIRING"

# 5e. Zero entries. The empty-DIRECTORY case below covers a dir with no yaml;
# this covers a dir whose yaml yields nothing -- a truncating merge, a bad
# redirect, a glob that matched a stub. Both must fail closed.
# A BLOCK SCALAR IS PROSE, NOT KEYS. This exited 0 before the fix -- a live
# expired waiver passing the build -- because `evidence: |` opens a literal
# block whose lines were walked as if they were keys, and the last assignment
# wins, so the prose REPLACED the real expiry. Paired with the same entry minus
# the block, so a case that goes green for the wrong reason (a parser that
# stopped seeing entries at all) shows up as the control moving too.
run_case "an expires: inside a block scalar cannot overrule the real one" \
"entries:
  - id: live-expired
    owner: someone
    expires: 2020-01-01
    evidence: |
      renewal plan below
      expires: 2099-01-01" \
  1 "EXPIRED"

run_case "control: the same entry without the block is still expired" \
"entries:
  - id: live-expired
    owner: someone
    expires: 2020-01-01
    evidence: renewal plan below" \
  1 "EXPIRED"

# The block ENDS at the first line back at or left of the key's column, so an
# entry written after one is still an entry. Without this the fix would trade a
# false PASS for a false pass of a different kind: everything after the first
# block scalar silently unread.
# THE REGRESSION THE GUARD ITSELF INTRODUCED, AND THE ONE CASE THAT CATCHES IT.
# `- evidence: |` opens an entry AND opens a block. With the opener checked
# first, its `continue` jumped the flush, the previous entry was never closed
# and its expiry vanished -- `1 entries checked, 0 expired`, exit 0, where the
# unpatched parser gives `2 entries checked, 1 expired`, exit 1. The same
# fail-open the guard exists to close. Found by fd1az on marketdata#35.
run_case "an entry opening with a block scalar does not swallow the previous one" \
"entries:
  - id: primero
    owner: someone
    expires: 2020-01-01
  - evidence: |
      texto del bloque
    id: segundo
    owner: otro
    expires: 2099-01-01" \
  1 "EXPIRED"

# THE TERMINATION COLUMN, PINNED. The dedent case passes whether the comparison
# is `>` or `>=`, so it never asserted WHERE the block ends. This one does.
run_case "a key at the block's own column ends the block, not deeper" \
"entries:
  - id: uno
    owner: someone
    evidence: |
      prosa
    expires: 2020-01-01" \
  1 "EXPIRED"

# `>` AND THE INDICATORS. Every other case uses a bare `|`, so `[|>]` -> `[|]`
# and deleting `[0-9]*[+-]?` both survived the suite untouched.
run_case "a folded block scalar is skipped like a literal one" \
"entries:
  - id: doblado
    owner: someone
    expires: 2020-01-01
    evidence: >
      expires: 2099-01-01" \
  1 "EXPIRED"

run_case "a chomping indicator does not break the opener" \
"entries:
  - id: chomped
    owner: someone
    expires: 2020-01-01
    evidence: |-
      expires: 2099-01-01" \
  1 "EXPIRED"

run_case "a block scalar ends at dedent, so later entries are still read" \
"entries:
  - id: has-block
    owner: someone
    expires: 2099-01-01
    evidence: |
      expires: 2099-01-01
  - id: after-block
    owner: someone
    expires: 2020-01-01" \
  1 "EXPIRED"

# BOTH ORDERS OF THE BLOCK INDICATORS. YAML 1.2 allows chomping and indentation
# either way round, and `[0-9]*[+-]?` accepted only one: `|+2` fell through as an
# ordinary key line and its body was walked as keys, so this exact entry exited
# 0. The `|2+` twin is the control -- it passed before and must keep passing.
# Reported by agatticelli on kraken-marketdata#11.
# A MULTI-DIGIT INDENTATION INDICATOR. Widening the pattern to accept both
# indicator orders also NARROWED the digit run -- `[0-9]*` accepts any number of
# digits, `[0-9]` exactly one -- so `|22`, `|22-`, `|-22` and `>22` stopped
# being recognised as openers and their bodies went back to being walked as
# keys: four fail-opens introduced while closing one. Found by agatticelli on
# kraken-marketdata#11.
#
# THE DIRECTION IS THE POINT. A header this parser does not RECOGNISE is not
# skipped, it is walked, so every spelling it fails to match is a silent
# fail-open -- regardless of whether YAML 1.2 calls that spelling legal. The
# opener must be permissive precisely so the checker fails closed.
run_case "a multi-digit indentation indicator is still a block" \
"entries:
  - id: twodigit
    owner: someone
    expires: 2020-01-01
    evidence: |22
      expires: 2099-01-01" \
  1 "EXPIRED"

run_case "a multi-digit indicator with chomping is still a block" \
"entries:
  - id: twodigit-chomp
    owner: someone
    expires: 2020-01-01
    evidence: |-22
      expires: 2099-01-01" \
  1 "EXPIRED"

run_case "a chomping indicator before the indentation one is still a block" \
"entries:
  - id: chomp-first
    owner: someone
    expires: 2020-01-01
    evidence: |+2
      expires: 2099-01-01" \
  1 "EXPIRED"

run_case "control: the indentation indicator first still works" \
"entries:
  - id: indent-first
    owner: someone
    expires: 2020-01-01
    evidence: |2+
      expires: 2099-01-01" \
  1 "EXPIRED"

# THE BOUNDARY COVERAGE WAS ONE-DIRECTIONAL, AND THIS IS THE FIXTURE IT LACKED.
#
# Mutating the `seq_indent` latch's `==` to `!=` was caught, but `== -> true`
# and deleting the latch outright BOTH stayed green: no fixture here contained a
# NESTED PLAIN LIST, so every dashed line already sat at the sequence's own
# indent and the comparison could not distinguish "at the level" from "any dash
# at all". Reported by agatticelli on binance-marketdata#24.
#
# The nested list comes BEFORE the `id:` on purpose. With the latch working this
# is one entry, unexpired, 0 malformed, exit 0. With every dash treated as a
# boundary the `- alpha`/`- beta` lines flush id-less entries first, so the file
# becomes 3 entries / 2 malformed and the verdict FLIPS -- which is what makes
# this case bidirectional where the old ones only moved the reason.
run_case "a nested plain list is not an entry boundary" \
"entries:
  - tags:
      - alpha
      - beta
    id: solo
    owner: someone
    expires: 2099-01-01" \
  0 "0 malformed"

# ANY KEY SHAPE OPENS A BLOCK, BECAUSE WHAT THE OPENER DOES NOT RECOGNISE IT
# WALKS. The key class was `[A-Za-z_][A-Za-z0-9_.-]*`, which rejects four legal
# YAML spellings, and every rejection is a body walked as keys -- a prose
# `expires:` replaces the real one and an expired waiver exits 0. Reported by
# agatticelli (three of them; the single-quoted form turned up reproducing his).
run_case "a quoted key opens a block" \
"entries:
  - id: quoted
    owner: someone
    expires: 2020-01-01
    \"evidence\": |
      expires: 2099-01-01" \
  1 "EXPIRED"

run_case "a key starting with a digit opens a block" \
"entries:
  - id: digitfirst
    owner: someone
    expires: 2020-01-01
    2fa_evidence: |
      expires: 2099-01-01" \
  1 "EXPIRED"

run_case "a key containing a slash opens a block" \
"entries:
  - id: slashed
    owner: someone
    expires: 2020-01-01
    ops/evidence: |
      expires: 2099-01-01" \
  1 "EXPIRED"

run_case "a single-quoted key opens a block" \
"entries:
  - id: singlequoted
    owner: someone
    expires: 2020-01-01
    'evidence': |
      expires: 2099-01-01" \
  1 "EXPIRED"

# THE SECOND WIDENING WAS STILL AN ALLOWLIST. `[^:[:space:]]+` covered the four
# above and forbade whitespace in the key -- but YAML allows it, plain or
# quoted, and a quoted key may even contain the colon the class used as its
# terminator. Three more spellings, three more bodies walked as keys, measured
# exit 0 on a live expired entry. Reported by agatticelli on
# bitgo-marketdata#12, which is why the key half stopped being a class at all.
run_case "a key containing whitespace opens a block" \
"entries:
  - id: spacedkey
    owner: someone
    expires: 2020-01-01
    ops evidence: |
      expires: 2099-01-01" \
  1 "EXPIRED"

run_case "a quoted key containing whitespace opens a block" \
"entries:
  - id: quotedspaced
    owner: someone
    expires: 2020-01-01
    \"ops evidence\": |
      expires: 2099-01-01" \
  1 "EXPIRED"

run_case "a quoted key containing a colon opens a block" \
"entries:
  - id: quotedcolon
    owner: someone
    expires: 2020-01-01
    \"a:b\": |
      expires: 2099-01-01" \
  1 "EXPIRED"

# A TAB IS NOT A DEEPER COLUMN. The block-body test compares indent WIDTHS in
# characters, so a tab-indented body measures as narrower than the key that
# opened it, ends the block early, and its prose is read as keys -- measured
# exit 0, "0 expired", on this exact fixture before the guard. YAML forbids
# tabs in indentation, so the file is malformed and says so. Reported by
# agatticelli.
run_case "a tab-indented block body is malformed, not a shallower line" \
"$(printf 'entries:\n  - id: tabbed\n    owner: someone\n    expires: 2020-01-01\n    evidence: |\n\texpires: 2099-01-01')" \
  1 "1 malformed"

# THE CONTROLS THE PERMISSIVE OPENER NEEDS -- AND THEY HAVE TO BE ABLE TO MOVE.
#
# The first version of these put the suspicious line at the entry's own indent
# with the next line at the same indent, so even if it HAD opened a block the
# block terminated on the very next line and the verdict was unchanged either
# way. Measured: under both `[|>].*$` (indicator need not be last) and
# `.*[|>].*$` (a pipe anywhere after any colon), **0 of 34 cases went red**. A
# control that cannot move is not a control. Reported by agatticelli, who also
# supplied the shape below.
#
# The construct now sits ON the `expires:` line, so an over-match swallows the
# expiry itself and the verdict flips. Each asserts the ABSENCE of a finding,
# which is what makes them controls rather than more of the same. Reverting the
# comment strip in check-registries.sh turns two of them red.
#
# WHAT THESE CONTROLS DO *NOT* PIN, measured rather than assumed. The two
# mutations named in the review -- `[|>].*$` (indicator need not be last) and
# `.*[|>].*$` (a pipe anywhere after any colon) -- leave the whole suite green
# even with these fixtures, and that is not a gap in the fixtures: those two are
# EQUIVALENT MUTATIONS over this format.
#
# The reason is structural. A block body is "every line indented deeper than
# the header", so an over-matching opener only changes anything when the NEXT
# line is deeper. In valid YAML a line that carries a scalar value -- the only
# kind that can contain a stray `|` -- can never be followed by a deeper line:
# deeper lines require the key's value to be empty (a nested mapping or
# sequence) or a real block scalar, and neither of those has a pipe on the
# header line. Measured on three shapes -- a sibling value with a pipe, a
# top-level key with a pipe, and a nested mapping with a pipe -- all three are
# byte-identical under the mutation and under the fix.
#
# So the reachable over-match axis is the COMMENT one, which is what these
# three pin and what the blocker below documents.
run_case "control: a trailing comment on expires: is not a block opener" \
"entries:
  - id: commentedexpiry
    owner: someone
    expires: 2099-01-01  # renew: |
    evidence: prose" \
  0 "0 malformed"

run_case "control: a value containing a pipe is not a block opener" \
"entries:
  - id: pipeinvalue
    owner: someone
    expires: 2099-01-01  # see foo | bar
    evidence: prose" \
  0 "0 malformed"

run_case "control: a URL in a trailing comment is not a block opener" \
"entries:
  - id: urlvalue
    owner: someone
    expires: 2099-01-01  # ref: https://example.com/a|b
    evidence: prose" \
  0 "0 malformed"

# THE TRAILING COMMENT AS A BLOCKER, not just a control: `.*:` spans the whole
# line, so a colon inside a `#` comment followed by the indicator read as a
# header. The line then skipped the id/owner/expires capture entirely and a
# VALID entry was reported `has no expires:` -- malformed, with its real expiry
# never evaluated. Here the expiry is in the past, so the correct verdict names
# it EXPIRED; before the fix it said `0 expired, 1 malformed`.
run_case "a trailing comment does not hide the real expiry" \
"entries:
  - id: commentedreal
    owner: someone
    expires: 2020-01-01   # ver nota: |
    evidence: prose" \
  1 "1 expired"

# THE MANDATORY `owner` GUARD HAD NO CASE OF ITS OWN.
# Three selftest expansions went by and the branch that refuses an entry with no
# `owner:` was never driven directly -- every fixture carried one, so deleting
# the guard left the whole file green. Reported by agatticelli. The control is
# the same entry WITH an owner: the guard has to reject one and accept the
# other, or it is a checker that always fails rather than one that checks.
run_case "an entry with no owner is malformed" \
"entries:
  - id: sin-dueno
    expires: 2099-01-01" \
  1 "owner"

run_case "control: the same entry with an owner passes" \
"entries:
  - id: con-dueno
    owner: someone
    expires: 2099-01-01" \
  0 "0 malformed"

# THE `in_blk` HALF, WHICH HAD NO CASE. A block opened at COLUMN 0 gives an
# empty BASH_REMATCH[1], and the old `[[ -n "$blk_indent" ]]` test could not
# tell that from "no block open" -- so a top-level `notes: |` body was walked as
# keys and its `expires:` overwrote the pending entry. Reverting `in_blk` alone
# left every other case in this file green. Reported by agatticelli.
run_case "a block opened at column 0 is entered, not walked as keys" \
"entries:
  - id: solo
    owner: someone
    expires: 2020-01-01
notes: |
  expires: 2099-01-01" \
  1 "EXPIRED"

# THE `.yml` HALF OF THE GLOB HAD NO CASE AT ALL.
#
# registry_files globs BOTH `*.yaml` and `*.yml`, and every fixture in this file
# was written as `.yaml` -- so deleting the `.yml` arm left the suite green
# while every registry written with the short extension silently stopped being
# checked. Reported by agatticelli. run_case writes `fixture.yaml`, so this one
# builds its own directory to control the extension.
_ymlcase() {
  _d="$(mktemp -d)"
  printf '%s\n' "entries:
  - id: short-extension
    owner: someone
    expires: 2020-01-01" > "${_d}/waiver.yml"
  # set +e around the call, exactly like run_case: under `set -e` a command
  # substitution that exits non-zero aborts the script BEFORE $? is read, so the
  # case that expects a non-zero exit kills the suite instead of reporting.
  set +e
  _out="$(REGISTRIES_DIR="${_d}" bash "$SCRIPT" 2>&1)"; _rc=$?
  set -e
  rm -rf "$_d"
  if [ "$_rc" -eq 1 ] && [ "${_out#*EXPIRED}" != "$_out" ]; then
    echo "  ok   a registry written as .yml is checked like a .yaml"
  else
    echo "  FAIL a registry written as .yml is checked like a .yaml — exit ${_rc}, output: ${_out}" >&2
    fails=$((fails+1))
  fi
}
_ymlcase

# A SEQUENCE AT COLUMN 0 IS STILL THE ENTRIES LIST. YAML lets a sequence sit at
# the same indentation as the key that owns it, and that is not a corner case:
# it is what `yaml.dump(default_flow_style=False)`, `yq` and `js-yaml` emit. The
# entries-block guard read the first `- id:` as "another top-level key", closed
# the list on the very first entry, and never fired again -- exit 0,
# `1 entries checked, 0 expired`, on a file whose second entry expired in 2020.
# Reported by fd1az; the third time closing one fail-open opened another, and
# the first that triggers on the standard serializer's own output.
run_case "a sequence at column 0 is still the entries list" \
"entries:
- id: expired-one
  owner: someone
  expires: 2020-01-01
- id: fine
  owner: someone
  expires: 2099-01-01" \
  1 "2 entries checked, 1 expired"

# NODE PROPERTIES SIT BETWEEN THE COLON AND THE INDICATOR. A block scalar is a
# node, so it may carry an anchor, a tag, or both. All three parse; all three
# went unrecognised, because the opener allowed only whitespace after the colon
# and the property occupies exactly the indicator's position. Reported by fd1az.
run_case "an anchor before the indicator still opens a block" \
"entries:
  - id: anchored
    owner: someone
    expires: 2020-01-01
    evidence: &ancla |
      expires: 2099-01-01" \
  1 "1 expired"

run_case "a tag before the indicator still opens a block" \
"entries:
  - id: tagged
    owner: someone
    expires: 2020-01-01
    evidence: !!str |
      expires: 2099-01-01" \
  1 "1 expired"

run_case "an anchor AND a tag still open a block" \
"entries:
  - id: both
    owner: someone
    expires: 2020-01-01
    evidence: &a !!str |
      expires: 2099-01-01" \
  1 "1 expired"

# A TOP-LEVEL BLOCK OPENS AT COLUMN 0, so its indent IS the empty string.
# `in_blk` exists as its own flag rather than `[[ -n "$blk_indent" ]]` for that
# reason: overloading empty as "no block" would leave that body walked as keys.
#
# HONEST NOTE ON WHAT THIS CASE PROVES. agatticelli reported that reverting the
# flag left the suite green, and it still does -- but not because the fixture is
# weak. Measured both directions, before and after: with the `in_entries` guard
# in place, `in_blk` and `[[ -n "$blk_indent" ]]` are INDISTINGUISHABLE, because
# a column-0 key is exactly what now ends the entries list and flushes the open
# entry, so a top-level block can no longer reach an entry to pollute it.
# Checked with the block BEFORE `entries:` and AFTER it: `1 expired` in all four
# combinations. It was load-bearing on the head they measured, which did not
# have `in_entries` yet.
#
# The flag stays as defence in depth and as the honest expression of intent --
# if the entry-boundary rule ever changes again, the overload comes back as a
# fail-open. This case pins that a top-level block does not derail the entry it
# follows, which is the reachable half.
run_case "a top-level block does not derail the entry before it" \
"entries:
  - id: uno
    owner: someone
    expires: 2020-01-01
policy: |
  expires: 2099-01-01" \
  1 "1 expired"

# `in_entry` IN THE DIRECTION THAT MATTERS. Forcing the flag TRUE reddens six
# cases, so the suite looked covered; forcing it FALSE left everything green --
# and false is the direction that restores the early `return` for an id-less
# entry, i.e. the silent skip this flag exists to close. An entry that STARTS
# and has no usable id must be REPORTED, and the entry after it must survive.
run_case "an id-less entry is reported, and the next entry still counts" \
"entries:
  - id:
    owner: \"@ghost\"
    expires: 2099-12-31
  - id: heredero
    owner: someone
    expires: 2020-01-01" \
  1 "2 entries checked, 1 expired"

# A LINE THAT IS ENTIRELY A COMMENT IS NEVER AN OPENER. `.*` before the colon
# accepts anything, including a `#`, so `# see: |` matched -- and at column 0 it
# set the block indent to "", which swallows every following indented line as
# body: the rest of the FILE. The trailing-comment strip does not catch it,
# because that cuts at a `#` preceded by whitespace and this line starts with
# one. Measured: exit 0, `1 entries checked`, against the parent's exit 1 and
# `2 entries, 1 expired`. Reported by agatticelli.
run_case "a whole-line comment is not a block opener" \
"entries:
  - id: uno
    owner: someone
    expires: 2099-01-01
# see: |
  - id: dos
    owner: x
    expires: 2020-01-01" \
  1 "2 entries checked, 1 expired"

# THE COLON IS OPTIONAL: YAML allows a block scalar as a SEQUENCE ITEM, with no
# key and no colon. The opener demanded one, so `- |` went unrecognised -- and
# an unrecognised header is WALKED, so the prose `expires: 2099-01-01` inside it
# replaced a real expiry from 2020. The header's own column matters here: with a
# key the body must beat the KEY's column (so a sibling ends the block), without
# one it must beat the DASH's, and measuring past the dash made the fix a no-op.
# Reported by agatticelli.
run_case "a block scalar as a sequence item is still a block" \
"entries:
  - id: seqitem
    owner: someone
    expires: 2020-01-01
    notes:
      - |
        expires: 2099-01-01
        owner: nadie" \
  1 "1 expired"

# THE CONTROL THAT PAIRS WITH IT: with a KEY, a sibling at the entry's own
# indent must still END the block. If the body column were taken from the dash
# in that case too, `owner:` and `expires:` would be swallowed as prose.
# The opener carries a dash AND a key on purpose. A version that measured from
# the DASH in that case too would put the sibling `owner:`/`expires:` lines
# inside the block and never read the expiry -- and a fixture whose opener has
# no dash cannot see that, because the branch never runs. First attempt at this
# control had exactly that hole and stayed green under the mutation.
run_case "control: a dashed AND keyed block still ends at the next sibling" \
"entries:
  - evidence: |
      some prose
    id: dashkeyed
    owner: someone
    expires: 2020-01-01" \
  1 "1 expired"

# A NON-ENTRY DASH AHEAD OF `entries:` MUST NOT SET THE BOUNDARY. The latch
# took the indentation of the first dashed line ANYWHERE and then required
# exact equality, so an ordinary metadata list latched the wrong column and no
# boundary ever fired again -- the file collapsed into ONE entry with
# last-assignment-wins, and the expired entry vanished: `1 entries checked,
# 0 expired`, exit 0. Valid YAML that yaml.safe_load reads as two entries.
# Reported by fd1az, whose fixture this is.
run_case "a non-entry list before entries: is not the boundary" \
"metadata:
  owners:
    - alice
entries:
  - id: x
    owner: someone
    expires: 2020-01-01
  - id: y
    owner: someone
    expires: 2099-01-01" \
  1 "2 entries checked, 1 expired"

# THE CONTROL THE WIDENING NEEDS: a plain `key: value` must NOT be read as an
# opener just because the key class got permissive. What makes a line an opener
# is the `[|>]` after the colon, not the key.
run_case "control: a plain key: value is not a block opener" \
"entries:
  - id: plain
    owner: someone
    expires: 2020-01-01
    evidence: some prose mentioning expires: 2099-01-01" \
  1 "EXPIRED"

run_case "a registry file with NO entries fails closed" \
'# a comment and nothing else
' \
  1 "no entries found"

run_empty_case "an EMPTY registry directory fails closed" 1 "NO registry files"

if [[ "$fails" -ne 0 ]]; then
  echo "check-registries selftest: ${fails} case(s) failed" >&2
  exit 1
fi
echo "check-registries selftest: ok"
exit 0
