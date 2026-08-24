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
# 5d-bis. A BLOCK SCALAR IS PROSE, NOT KEYS.
#
# `evidence: |` opens a literal block; everything indented deeper is the string.
# The key regexes are anchored at start-of-line, which stops a body line that
# CONTAINS "expires:" -- but not one that STARTS with it. And since each key
# assignment overwrites, the prose line REPLACED the real value rather than
# competing with it.
#
# Both of these exited 0 on the parser before the fix, which is a live expired
# waiver and an unowned entry passing the build. Each is paired with the same
# entry minus the block, so a case that goes green for the wrong reason (a
# parser that stopped seeing entries at all) shows up as the control moving too.
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

run_case "an owner: inside a block scalar does not satisfy the owner rule" \
"entries:
  - id: unowned
    expires: 2099-01-01
    evidence: |
      - owner: not-a-real-owner
      more prose" \
  1 "owner"

run_case "control: a real owner outside the block still passes" \
"entries:
  - id: owned
    owner: someone
    expires: 2099-01-01
    evidence: |
      - owner: not-a-real-owner
      more prose" \
  0 "0 malformed"

# The block ENDS at the first line back at or left of the key's column, so an
# entry written after one is still an entry. Without this the fix would trade a
# false PASS for a false pass of a different kind: everything after the first
# block scalar in the file silently unread.
# THE REGRESSION THE GUARD ITSELF INTRODUCED, AND THE ONE CASE THAT WOULD HAVE
# CAUGHT IT. `- evidence: |` opens an entry AND opens a block. With the opener
# checked first, its `continue` jumped the flush, the previous entry was never
# closed and its expiry vanished -- `1 entries checked, 0 expired`, exit 0,
# where the unpatched parser gives `2 entries checked, 1 expired`, exit 1. The
# same fail-open the guard exists to close. Found by fd1az on marketdata#35.
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

# THE TERMINATION COLUMN, PINNED. The dedent case above passes whether the
# comparison is `>` or `>=`, so it never asserted WHERE the block ends. This one
# does: at `>=` the `id:` line at the key's own column is read as block content,
# the entry loses its id and the file reports MALFORMED instead of EXPIRED.
run_case "a key at the block's own column ends the block, not deeper" \
"entries:
  - id: uno
    owner: someone
    evidence: |
      prosa
    expires: 2020-01-01" \
  1 "EXPIRED"

# `>` AND THE INDICATORS. Every case above uses `|` with no chomping or indent
# indicator, so `[|>]` -> `[|]` and deleting `[0-9]*[+-]?` both survived.
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

run_case "an explicit indent indicator does not break the opener" \
"entries:
  - id: indicado
    owner: someone
    expires: 2020-01-01
    evidence: |2
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
