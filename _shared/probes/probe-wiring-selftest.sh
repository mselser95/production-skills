#!/usr/bin/env bash
# probe-wiring-selftest.sh — the verifier of probe-wiring.sh.
#
# Every case below is a state this repo actually reached on 2026-08-29, not an
# imagined one. Two of them are regressions caught by review AFTER the probe was
# written and mutation-tested by hand, which is the argument for this file
# existing at all: hand-mutation proves a gate once, on the day someone
# remembers. Cases 3 and 4 are the ones a reading would never have produced.
#
# Fixtures are built OUTSIDE this repository on purpose. probe-wiring resolves
# its root with `git rev-parse --show-toplevel`, so a fixture built inside the
# working tree would make the probe walk the real repo and every case would
# measure production instead of the fixture.
set -uo pipefail

PROBE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/probe-wiring.sh"
[[ -r "$PROBE" ]] || { echo "selftest: cannot read $PROBE" >&2; exit 2; }

ok=0; failed=0
work="$(mktemp -d)" || exit 2
trap 'rm -rf "$work"' EXIT

# Build a fixture repo: a Makefile invoking the probes named in $@, plus a
# probe file for each name given after the '--'.
fixture() {
  local dir="$work/$1"; shift
  local -a invoked=() present=()
  local seen_sep=0
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen_sep=1; continue; fi
    if (( seen_sep )); then present+=("$a"); else invoked+=("$a"); fi
  done
  rm -rf "$dir"; mkdir -p "$dir/_shared/probes"
  { echo "PROBES := _shared/probes"
    echo "gates:"
    for i in "${invoked[@]}"; do echo -e "\t@bash \$(PROBES)/$i"; done
  } > "$dir/Makefile"
  for p in "${present[@]}"; do printf '#!/usr/bin/env bash\necho stub\n' > "$dir/_shared/probes/$p"; done
  # the declared exception must exist or the probe exits 2 by design
  printf '#!/usr/bin/env bash\necho stub\n' > "$dir/_shared/probes/verify-standard.sh"
  echo "$dir"
}

check() { # name expected-rc dir [extra-grep]
  local name="$1" want="$2" dir="$3" needle="${4:-}"
  local out rc
  out=$( cd "$dir" && bash "$PROBE" 2>&1 ); rc=$?
  local why=""
  (( rc == want )) || why="rc=$rc want=$want"
  if [[ -z "$why" && -n "$needle" ]] && ! grep -qF "$needle" <<<"$out"; then
    why="output did not mention '$needle'"
  fi
  if [[ -z "$why" ]]; then
    printf '  ok    %-58s\n' "$name"; ok=$((ok+1))
  else
    printf '  FAIL  %-58s %s\n' "$name" "$why"; printf '%s\n' "$out" | sed 's/^/          /'; failed=$((failed+1))
  fi
}

echo "probe-wiring selftest"

# 1. GREEN BASELINE. Without it every case below could "pass" because the probe
#    fails on everything, which is the classic selftest that proves nothing.
d=$(fixture green a.sh b.sh -- a.sh b.sh)
check "all probes wired -> 0" 0 "$d"

# 2. An orphan is found and NAMED. A count alone cannot be acted on.
d=$(fixture orphan a.sh -- a.sh b.sh)
check "an unwired probe -> 1, named" 1 "$d" "orphaned: _shared/probes/b.sh"

# 3. THE SUBSTRING REGRESSION, found by review on 2026-08-29. `grep -F` on the
#    bare basename reported `wiring.sh` as wired because the Makefile contained
#    `probe-wiring.sh`. An unwired gate reported as covered is strictly worse
#    than an absent one.
d=$(fixture substring probe-wiring.sh -- probe-wiring.sh wiring.sh)
check "orphan whose name is a substring of a wired one -> 1" 1 "$d" "orphaned: _shared/probes/wiring.sh"

# 4. And the other direction of the same fix: a genuinely wired probe must still
#    be recognised through \$(PROBES)/ and through a plain bash invocation. A
#    delimiter fix that over-tightens turns every probe into an orphan.
d=$(fixture stillwired probe-wiring.sh -- probe-wiring.sh)
check "a wired probe reached via \$(PROBES)/ -> 0" 0 "$d"

# 5. COMMENTS ARE NOT INVOCATIONS. The defect this repo has now recorded six
#    times: a presence check satisfied by prose.
d=$(fixture commented a.sh -- a.sh b.sh)
printf '# b.sh runs elsewhere: $(PROBES)/b.sh\n' >> "$d/Makefile"
check "probe named only in a comment -> 1" 1 "$d" "orphaned: _shared/probes/b.sh"

# 6. A STALE EXCEPTION IS AN ERROR, not a silent excuse. The declared exception
#    names verify-standard.sh; remove it and the list is excusing something that
#    no longer exists.
d=$(fixture staleexc a.sh -- a.sh)
rm -f "$d/_shared/probes/verify-standard.sh"
check "exception naming a missing probe -> 2" 2 "$d" "does not exist"

# 7. ZERO PROBES is a refusal. "All zero probes are wired" is true and useless.
d=$(fixture noprobes a.sh --)
rm -f "$d/_shared/probes/verify-standard.sh"
check "zero probes -> 2, not 0" 2 "$d" "ZERO probes"

# 8. ZERO SURFACES is a refusal too. With no Makefile, no workflow and no hook,
#    every probe would be reported orphaned -- a result that measures the
#    fixture, not the repo.
d=$(fixture nosurfaces a.sh -- a.sh)
rm -f "$d/Makefile"
check "zero invoker surfaces -> 2, not a wall of orphans" 2 "$d" "ZERO invoker surfaces"

# 9. A GLOB IS AN INVOCATION. `make selftests` runs $(PROBES)/*-selftest.sh
#    deliberately, so that a selftest added tomorrow cannot be omitted from a
#    hand-kept list. A literal-only matcher called every one of those an orphan
#    -- measured 2026-08-29, when this probe reported its own new selftest
#    unwired while make was running it. False orphans are the expensive
#    direction: a gate that cries wolf gets deleted, not fixed.
d=$(fixture globbed 'a.sh' -- a.sh x-selftest.sh)
printf '\t@for t in $(PROBES)/*-selftest.sh; do bash "$$t"; done\n' >> "$d/Makefile"
check "probe covered by a *-selftest.sh glob -> 0" 0 "$d"

# 10. AND THE GLOB MUST NOT BECOME A RUBBER STAMP. A probe the glob does not
#     match is still an orphan; if this case ever passes as 0, the glob logic
#     has widened into an excuse for everything.
d=$(fixture globbed_narrow 'a.sh' -- a.sh x-selftest.sh unrelated.sh)
printf '\t@for t in $(PROBES)/*-selftest.sh; do bash "$$t"; done\n' >> "$d/Makefile"
check "glob does not excuse a non-matching orphan -> 1" 1 "$d" "orphaned: _shared/probes/unrelated.sh"

# 11. A BARE *.sh MUST NOT EXCUSE EVERYTHING. The literal-character floor exists
#     so that one sloppy glob in a workflow cannot silently retire this gate.
d=$(fixture globbed_bare 'a.sh' -- a.sh lonely.sh)
printf '\t@echo $(PROBES)/*.sh\n' >> "$d/Makefile"
check "a bare *.sh does not excuse an orphan -> 1" 1 "$d" "orphaned: _shared/probes/lonely.sh"

# 12. AN EXCEPTION BELONGS TO A DIRECTORY, and forgetting that made the tool
#     refuse an argument it advertises. Found by review on 2026-08-29: the
#     declared exception was keyed by BASENAME, so `probe-wiring.sh scripts`
#     exited 2 complaining that verify-standard.sh "does not exist in scripts/"
#     -- true, and not a finding, because that excuse was never about scripts/.
#     Keys are paths now, and an exception for another tree is out of scope
#     rather than stale.
d=$(fixture otherdir a.sh -- a.sh)
mkdir -p "$d/scripts"
printf '#!/usr/bin/env bash\necho stub\n' > "$d/scripts/tool.sh"
printf '\t@bash scripts/tool.sh\n' >> "$d/Makefile"
out=$( cd "$d" && bash "$PROBE" scripts 2>&1 ); rc=$?
if (( rc == 0 )) && ! grep -qF "verify-standard.sh" <<<"$out"; then
  printf '  ok    %-58s\n' "scanning another dir: out-of-scope exception ignored"; ok=$((ok+1))
else
  printf '  FAIL  %-58s rc=%s\n' "scanning another dir: out-of-scope exception ignored" "$rc"
  printf '%s\n' "$out" | sed 's/^/          /'; failed=$((failed+1))
fi

echo
echo "$ok ok, $failed failed"
(( failed == 0 )) || exit 1
