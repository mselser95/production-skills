# Proposed rows for _shared/probes/verify-standard.sh (and its vendored copy
# prod-new/template/scripts/verify-standard.sh, which must stay byte-identical
# to it).
#
# FILED AS A FRAGMENT RATHER THAN APPLIED, and the reason is collision, not
# scope: verify-standard.sh is a 185KB file that three other agents in this
# roadmap are editing concurrently for dimensions 25, 26 and 27. Two agents
# splicing rows into the same section is precisely how a clean three-way merge
# composes two halves of two different fixes -- which is a defect class that
# file's own comments already document happening to it twice.
#
# WHY THESE ROWS ARE NEEDED AT ALL, since `cheap-gate` already exists. That row
# greps for `^check-fast:` in the Makefile. It answers "is there a cheap gate",
# never "does the cheap gate still run the checks people believe it runs" -- so
# deleting the two `$(MAKE)` lines from check-fast's recipe leaves `cheap-gate`
# PASSing, and both new gates would be gone with nothing red. That is the exact
# shape this probe exists to refuse everywhere else.
#
# Each row below PROBES THE EFFECT: it runs the thing, or greps the recipe for
# the wiring. None of them is satisfied by a file existing.

# --- INSERT AFTER this existing line in section 15 (CI lanes) -------------
#
#   ls $wf/nightly* >/dev/null 2>&1 && row "nightly-trends" PASS "nightly workflow present" || row "nightly-trends" FAIL "no scheduled trend lane"

# Error-handling fitness (Yuan et al., OSDI 2014). TWO rows, because the two
# failure modes are independent: the gate can be missing, and the gate can be
# present but unwired -- and the second one is the quiet one, since the script
# still exists in the tree for anyone who greps for it.
if [[ -f scripts/error-handling-fitness.sh ]]; then
  # CHECK-FAST'S OWN RECIPE, extracted first, and NOT a grep over the whole
  # Makefile. Measured while writing this row: the whole-file grep passed after
  # `$(MAKE) error-handling-fitness` was deleted from check-fast, because the
  # standalone `error-handling-fitness:` target's own recipe line still matched.
  # The row certified "wired into the cheap gate" over a gate the cheap gate no
  # longer ran -- which is this file's defining defect, committed by a row added
  # to prevent it.
  #
  # awk from `^check-fast:` to the first line that is neither blank nor
  # tab-indented, which is exactly where a make recipe ends.
  _cf="$(awk '/^check-fast:/{f=1;next} f && /^[^\t]/ && NF{f=0} f' Makefile 2>/dev/null)"
  if grep -qE '(\$\(MAKE\) error-handling-fitness|scripts/error-handling-fitness\.sh)' <<<"$_cf"; then
    row "error-handling-fitness" PASS "check-fast's own recipe invokes it"
  else
    row "error-handling-fitness" FAIL "scripts/error-handling-fitness.sh exists but check-fast does not run it -- a fitness function nothing invokes is a file, not a gate"
  fi
  # NON-VACUITY, probed rather than trusted. The gate is a text pass, so a
  # regex that stopped matching prints the same "clean" line as one that
  # matched everything. Its selftest asserts both directions; running it here
  # is what makes the row above mean the gate can still FAIL.
  if [[ -f scripts/tests/error-handling-fitness-selftest.sh ]]; then
    if bash scripts/tests/error-handling-fitness-selftest.sh >/dev/null 2>&1; then
      row "error-handling-fitness-non-vacuous" PASS "the selftest drives the real script and it goes RED on all three shapes"
    else
      row "error-handling-fitness-non-vacuous" FAIL "the selftest failed -- the gate cannot be shown to detect the shapes it claims"
    fi
  else
    row "error-handling-fitness-non-vacuous" FAIL "no selftest -- 'clean' from a text pass is indistinguishable from 'read nothing'"
  fi
else
  row "error-handling-fitness" FAIL "no error-handling fitness gate (Yuan et al., OSDI 2014: 35% of catastrophic failures come from three greppable handler shapes)"
fi

# Crash-only state identity (Candea & Fox, HotOS IX 2003). The scenario itself
# needs docker and cannot run from this probe, so what is probed is the two
# things that CAN be checked here: that the assertion is present in the
# scenario at all, and that its logic can still fail. The second is the one
# that decays silently -- the scenario runs in exactly one CI job, so a
# renamed /healthz field shows up there and nowhere else.
if [[ -f scripts/kill-durability.sh ]]; then
  if grep -q 'assert_state_identical' scripts/kill-durability.sh 2>/dev/null; then
    row "crash-only-state-identity" PASS "the kill scenario compares reconstructed state across the crash, not only durable records"
  else
    row "crash-only-state-identity" FAIL "the kill scenario asserts records survived but never that replaying them reconstructs the same state -- a boot that read every byte back and rebuilt the state wrong passes it"
  fi
  if [[ -f scripts/tests/kill-durability-state-selftest.sh ]]; then
    if bash scripts/tests/kill-durability-state-selftest.sh >/dev/null 2>&1; then
      row "crash-only-state-non-vacuous" PASS "the comparison goes RED on a moved balance/digest and on an empty or unknown capture"
    else
      row "crash-only-state-non-vacuous" FAIL "the state-assertion selftest failed"
    fi
  else
    row "crash-only-state-non-vacuous" FAIL "no selftest for an assertion that only ever executes inside a docker-only job"
  fi
fi

# Differential observability (Huang et al., HotOS 2017). The alert is the
# artifact; what makes it REAL is that its client half is a series this service
# does not emit. That is the property to check, and it is the one that will be
# got wrong -- substituting a self-emitted series for the client vantage
# produces an expression that parses, evaluates, and never fires.
#
# NO `WARN` VERDICT, deliberately: row() tallies PASS, FAIL and NA and nothing
# else, so a WARN would render in the table and be counted in none of them --
# invisible under this probe's own `FAIL 0` bar. A verdict the summary cannot
# see is the vacuous form of a row.
#
# The test below is mechanical and fails CLOSED: it requires the alert's
# expression to cite at least one metric identifier that is NOT in
# emitted-metrics.yaml. An extractor that stopped matching finds no external
# series and the row FAILs, rather than passing over an expression it never
# read.
if [[ -f observability/alerts.md && -f observability/emitted-metrics.yaml ]]; then
  # the alert's own section, from its heading to the next one
  _gray="$(awk '/^## .*([Gg]ray.?[Ff]ail|DifferentialObservability)/{f=1;print;next} /^## /{f=0} f' observability/alerts.md)"
  _declared="$(grep -oE '^[[:space:]]*-[[:space:]]*name:[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*' observability/emitted-metrics.yaml | awk '{print $NF}' | sort -u)"
  _external=0
  if [[ -n "$_gray" ]]; then
    # Identifiers inside the fenced expression only -- prose names series too,
    # and counting those would let a paragraph satisfy the row.
    #
    # AND NOT FUNCTION NAMES. Measured while writing this: without the
    # trailing-paren filter, `min_over_time` and `avg_over_time` counted as
    # "series this service does not emit", so the row PASSED on an expression
    # whose every actual series was self-emitted -- the exact substitution it
    # exists to catch, certified green by two PromQL builtins.
    #
    # AND NOT COMMENTS INSIDE THE FENCE, for the same reason and found the same
    # way: with the `#` lines left in, swapping the live client series for a
    # self-emitted one still PASSED, because the comment ABOVE it still named
    # the external series it no longer used. A mention is not a citation.
    while read -r _m; do
      [[ -n "$_m" ]] || continue
      [[ "$_m" == *"(" ]] && continue          # a call, not a series
      grep -qxF "$_m" <<<"$_declared" || _external=$((_external+1))
    done < <(awk '/^```/{f=!f;next} f' <<<"$_gray" | sed 's/#.*$//' \
             | grep -oE '\b[a-z][a-z0-9]*_[a-z0-9_]+\b\(?' | sort -u)
  fi
  if [[ -n "$_gray" && $_external -gt 0 ]]; then
    row "differential-observability" PASS "gray-failure alert present and citing $_external series this service does not emit (the client vantage)"
  elif [[ -n "$_gray" ]]; then
    row "differential-observability" FAIL "the gray-failure alert cites ONLY series this service emits -- a self-reported client view executes in the same process and goes quiet in exactly the failure the alert exists for"
  elif waived gray-failure-no-external-vantage; then
    row "differential-observability" NA "live waiver with owner+expiry in registries/waivers.yaml"
  else
    row "differential-observability" FAIL "no alert on the DISAGREEMENT between a client vantage and self-reported readiness, and no live waiver (Huang et al., HotOS 2017: the detectable quantity is the gap, not either view)"
  fi
fi
