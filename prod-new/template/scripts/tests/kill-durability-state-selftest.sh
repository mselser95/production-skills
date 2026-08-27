#!/usr/bin/env bash
# kill-durability-state-selftest.sh — prove the crash-only LEDGER STATE
# assertion can fail, on a machine that cannot run the scenario it belongs to.
#
# scripts/kill-durability.sh needs a docker daemon and builds an image, so it
# runs in exactly one place: its own CI job. That makes its newest assertion
# the kind of code that is only ever executed by the environment least able to
# debug it, and the kind that decays silently -- a renamed /healthz field, a
# `diff` whose arguments got swapped, a denominator guard that stopped reading
# the right file. None of those announce themselves; they present as a green
# scenario, which is the same output as a working one.
#
# So this drives the REAL functions -- sourced out of the real script via its
# KILL_DURABILITY_LIB seam, never reimplemented here -- against crafted
# captures, and asserts both directions:
#
#   1. two identical, populated captures    -> PASS
#   2. the balance moved                    -> FAIL
#   3. the applied-set digest moved         -> FAIL
#   4. the applied-set SIZE moved           -> FAIL
#   5. both captures read known=false       -> FAIL (the denominator)
#   6. both captures read applied_count=0   -> FAIL (the other denominator)
#
# Cases 5 and 6 are the ones that matter most and the reason this file exists
# at all. They are IDENTICAL captures, so an assertion that only diffed would
# pass them and the scenario would report crash-only recovery proven from two
# readings of nothing -- the vacuous pass this standard keeps finding, in the
# one check whose whole job is to refuse it.
#
# Case 7 covers the capture side: ledger_state must FAIL, not print an empty
# capture, when /healthz carries no `state` key. An empty capture compares
# equal to another empty capture, so a renamed field would otherwise turn this
# assertion off in a way that looks exactly like success.
#
# Usage: bash scripts/tests/kill-durability-state-selftest.sh
# Exit:  0 every case behaved; 1 a case did not.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

SCRIPT="scripts/kill-durability.sh"
[[ -f "$SCRIPT" ]] || { printf 'selftest: %s not found.\n' "$SCRIPT" >&2; exit 1; }

# THE REAL FUNCTIONS. The seam returns before the docker preflight, so this
# works with no daemon.
# shellcheck source=/dev/null
KILL_DURABILITY_LIB=1 . "$SCRIPT" || { printf 'selftest: sourcing %s failed.\n' "$SCRIPT" >&2; exit 1; }

# THE MARKER CHECK IS NOT PARANOIA, it is a measured defect. This file first
# claimed that a broken seam "runs the whole scenario and fails loudly". It
# does not: measured 2026-08-27 by deleting the seam, sourcing ran the ENTIRE
# docker scenario, the scenario PASSED, and this selftest then went on to
# report 9 ok / 0 failed -- a green that had just built a container image for
# no reason and proved nothing about the seam it depends on. `declare -f`
# alone would not have caught it either: the helpers are defined ABOVE the
# seam, so they exist in both worlds.
if [[ "${KILL_DURABILITY_LIB_LOADED:-}" != "1" ]]; then
  printf 'selftest: %s did not stop at its library seam -- sourcing it ran (or tried to run) the real scenario.\n' "$SCRIPT" >&2
  exit 1
fi

if ! declare -f assert_state_identical >/dev/null || ! declare -f ledger_state >/dev/null; then
  printf 'selftest: the library seam did not define the state helpers -- nothing under test.\n' >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fails=0
ok=0

capture() { # capture <file> <known> <balance> <count> <digest>
  {
    printf 'known=%s\n' "$2"
    printf 'balance=%s\n' "$3"
    printf 'applied_count=%s\n' "$4"
    printf 'applied_digest=%s\n' "$5"
  } >"${WORK}/$1"
}

expect() { # expect <label> <before-file> <after-file> <PASS|FAIL>
  local label="$1" want="$4" out code got
  out="$(assert_state_identical "${WORK}/$2" "${WORK}/$3" 2>&1)"; code=$?
  if ((code == 0)); then got=PASS; else got=FAIL; fi
  if [[ "$got" == "$want" ]]; then
    printf '  ok    %-46s %s\n' "$label" "$got"
    ok=$((ok + 1))
  else
    printf '  FAIL  %-46s got %s, want %s\n' "$label" "$got" "$want"
    printf '%s\n' "$out" | sed 's/^/          /'
    fails=$((fails + 1))
  fi
}

printf 'kill-durability state-assertion selftest\n'

capture good-before true 12 12 aabbccddeeff
capture good-after  true 12 12 aabbccddeeff
expect "identical populated captures" good-before good-after PASS

capture bal-after   true 11 12 aabbccddeeff
expect "balance moved across the restart" good-before bal-after FAIL

capture dig-after   true 12 12 ffeeddccbbaa
expect "applied-set digest moved" good-before dig-after FAIL

capture cnt-after   true 12 11 aabbccddeeff
expect "applied-set size moved" good-before cnt-after FAIL

capture unk-before  false "" 0 ""
capture unk-after   false "" 0 ""
expect "two identical UNKNOWN captures" unk-before unk-after FAIL

capture zero-before true 0 0 000000000000
capture zero-after  true 0 0 000000000000
expect "two identical EMPTY applied sets" zero-before zero-after FAIL

# The `known` guard, made INDIVIDUALLY load-bearing. Measured 2026-08-27:
# deleting it left this selftest green, because the two cases above happen to
# carry applied_count=0 and the second denominator caught them -- so the guard
# could be removed and nothing would say so. This fixture is the shape that
# only the `known` guard rejects: a POPULATED capture whose known field is
# missing, which is exactly what a renamed or dropped field on /healthz
# produces once the rest of the object still parses.
capture nok-before "" 12 12 aabbccddeeff
capture nok-after  "" 12 12 aabbccddeeff
expect "populated captures with no known field" nok-before nok-after FAIL
# --- the capture side ------------------------------------------------------
# ledger_state's transport is `curl -sf`, so the double is a shell function
# named curl, which shadows the binary for the duration of the call. A LOCAL
# HTTP SERVER WAS TRIED FIRST AND ABANDONED: `nc -l` differs between the BSD
# and GNU builds, the listener has to be reaped, and a selftest that hangs on
# some hosts is worse than one that does not run there -- measured here, the
# nc version wedged for three minutes on macOS.
#
# What this substitutes is the TRANSPORT, not the thing under test. The
# parsing -- finding the nested `state` object, pulling four values out of it,
# refusing a body that has no such key -- is the real ledger_state running.
curl() {
  # ledger_state calls `curl -sf <url>`; every argument is ignored on purpose,
  # because what is being exercised is what ledger_state does with the BODY.
  [[ -n "${FAKE_HEALTHZ_BODY:-}" ]] || return 22   # curl's own "HTTP error" code
  printf '%s' "$FAKE_HEALTHZ_BODY"
}

FAKE_HEALTHZ_BODY='{"status":"ok","pod_id":"p1","config":{"digest":"abc"},"state":{"known":true,"balance":"7","applied_count":3,"applied_digest":"0123456789ab"}}'
if out="$(ledger_state 2>/dev/null)"; then
  want=$'known=true\nbalance=7\napplied_count=3\napplied_digest=0123456789ab'
  if [[ "$out" == "$want" ]]; then
    printf '  ok    %-46s %s\n' "parses a real /healthz body" PASS
    ok=$((ok + 1))
  else
    printf '  FAIL  %-46s parsed %q, want %q\n' "parses a real /healthz body" "$out" "$want"
    fails=$((fails + 1))
  fi
else
  printf '  FAIL  %-46s returned non-zero on a valid body\n' "parses a real /healthz body"
  fails=$((fails + 1))
fi

# A body with no `state` key at all -- the shape a renamed or deleted field
# produces. ledger_state must FAIL rather than print an empty capture: an
# empty capture compares equal to another empty capture, so this is the exact
# path by which a field rename would switch the whole assertion off while
# leaving the scenario green.
FAKE_HEALTHZ_BODY='{"status":"ok","pod_id":"p1","config":{"digest":"abc"}}'
if ledger_state >/dev/null 2>&1; then
  printf '  FAIL  %-46s a body with no state key produced a capture\n' "refuses a renamed/removed state field"
  fails=$((fails + 1))
else
  printf '  ok    %-46s %s\n' "refuses a renamed/removed state field" FAIL
  ok=$((ok + 1))
fi

# The transport itself failing (container gone, port closed) must also be a
# non-zero return and not an empty capture, for the same reason.
FAKE_HEALTHZ_BODY=''
if ledger_state >/dev/null 2>&1; then
  printf '  FAIL  %-46s a failed request produced a capture\n' "refuses an unreachable endpoint"
  fails=$((fails + 1))
else
  printf '  ok    %-46s %s\n' "refuses an unreachable endpoint" FAIL
  ok=$((ok + 1))
fi

unset -f curl

printf '\n%d ok, %d failed\n' "$ok" "$fails"
((fails == 0)) || exit 1
