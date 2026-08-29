#!/usr/bin/env bash
# validate-demo.sh — promote a demo from `pushed` to `validated`, mechanically.
#
# WHY THIS EXISTS
#
# demos/INDEX.md defines the two states and the gap between them: `pushed` means
# the repo exists and its happy path ran ONCE on the machine that built it;
# `validated` means the NEGATIVE path was proven to fail and the whole thing was
# re-run FROM A CLEAN CLONE. Twenty-four rows still sit in the first state, and
# the first three were promoted by hand -- six runs each, about twenty minutes.
#
# Doing that twenty-four more times by hand is how the column silently becomes a
# formality: the third repetition is where someone starts trusting the last
# result instead of running it. So the procedure becomes a script.
#
# WHAT IT ENFORCES, and each clause is one of the ways a demo can look validated
# without being:
#
#   1. CLEAN CLONE, always. A demo that only runs where it was written has an
#      undeclared dependency on that machine, and nobody finds out until someone
#      else tries it. It clones from the public URL every time, into a fresh
#      directory it creates -- never the working copy.
#   2. THE HAPPY PATH MUST EXIT 0.
#   3. EVERY CONTROL THE RUNNER DECLARES must exit exactly 1. Not "at least one
#      control", not "the ones that are quick": a demo whose failing case was
#      never exercised proves the harness runs, not that the mechanism matters.
#   4. ZERO CONTROLS IS A FAILURE, not a pass. A runner that declares no control
#      cannot be validated by this definition, and reporting that as green would
#      be the empty-input shape the whole framework refuses.
#
# The controls are read from the runner's own header, which every demo writes in
# the same shape (the variable name differs per demo, deliberately, since each
# names its own axis):
#
#   #   ./run-demo.sh                       the validated run; exits 0
#   #   USL_CONTROL=short-range  ./...      exits 1  (...)
#
# Usage:  validate-demo.sh <demo-repo-name> [github-owner]
# Exit:   0 validated · 1 a run disagreed with the contract · 2 could not run
set -uo pipefail

demo="${1:-}"
owner="${2:-mselser95}"
[[ -n "$demo" ]] || { echo "usage: validate-demo.sh <demo-repo-name> [owner]" >&2; exit 2; }

work="$(mktemp -d)" || exit 2
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
clone="$work/$demo"

# DEMO_REPO_URL exists so this script can be shown FAILING. A validator nobody
# has watched reject anything is indistinguishable from one that always says
# yes, and that is the exact shape it was written to catch in the demos. It
# overrides only the clone SOURCE -- the clone still happens, into a fresh
# directory, so the clean-clone guarantee is untouched.
_src="${DEMO_REPO_URL:-https://github.com/$owner/$demo.git}"
echo "== $demo: cloning fresh from $_src"
git clone -q --depth 1 "$_src" "$clone" 2>/dev/null || {
  echo "  CANNOT VALIDATE: clone failed -- the repo is not reachable, which is itself a finding about a demo the index links to" >&2
  exit 2
}

runner="$clone/run-demo.sh"
[[ -x "$runner" || -r "$runner" ]] || {
  echo "  CANNOT VALIDATE: no run-demo.sh in the clone" >&2; exit 2; }

# Controls declared in the runner's header. TWO filters, and the second was
# learned the hard way.
#
# Comment lines only: a control named in executable code is the demo running it,
# not documenting it.
#
# AND the line must say `exits 1`. A header lists more than controls -- it also
# lists alternative supported MODES, which exit 0 because they work. Measured
# 2026-08-29 on crypto-shredding-demo: its header declares three controls
# (CS_CONTROL=plaintext-omit / plaintext-snapshot / shred-noop, each "exits 1")
# and one mode (CS_KEYMODE=envelope, "the fallback construction"). Without this
# filter the mode was swept in as a control, ran, exited 0 because it is
# supposed to, and the tool reported a HEALTHY demo as NOT validated.
#
# That is the assertion that fires when nothing is wrong, in the validator built
# to catch exactly that. Shipped as-is, the next person "fixes" a correct demo.
# The demos' own vocabulary is the discriminator: a control declares its exit.
mapfile -t controls < <(grep -E '^#[[:space:]]+[A-Z][A-Z0-9_]*=[A-Za-z0-9._-]+[[:space:]]+\./.*exits?[[:space:]]+1' "$runner" \
  | sed -E 's/^#[[:space:]]+//; s/[[:space:]]+\..*$//' | sort -u)

if (( ${#controls[@]} == 0 )); then
  echo "  CANNOT VALIDATE: the runner declares NO control in its header." >&2
  echo "  A demo with no failing case proves its harness runs, not that its mechanism matters." >&2
  echo "  Zero controls is not a clean validation -- it is a demo that cannot be validated as written." >&2
  exit 2
fi

fails=0
declare -a _rcs=()
echo "== happy path"
if ( cd "$clone" && ./run-demo.sh >"$work/happy.log" 2>&1 ); then
  echo "  ok    ./run-demo.sh -> exit 0"
  _happy_rc=0
else
  _happy_rc=$?
  echo "  FAIL  ./run-demo.sh -> exit $_happy_rc, expected 0"
  tail -5 "$work/happy.log" | sed 's/^/        /'
  fails=$((fails + 1))
fi

echo "== ${#controls[@]} declared control(s), each must exit 1"
for c in "${controls[@]}"; do
  ( cd "$clone" && env "$c" ./run-demo.sh >"$work/ctl.log" 2>&1 )
  rc=$?
  _rcs+=("$rc")
  if (( rc == 1 )); then
    echo "  ok    $c -> exit 1"
  else
    echo "  FAIL  $c -> exit $rc, expected 1"
    tail -3 "$work/ctl.log" | sed 's/^/        /'
    fails=$((fails + 1))
  fi
done

# COULD-NOT-RUN IS NOT DISAGREED-WITH. If the happy path failed AND every
# control failed with the SAME non-1 code, nothing was measured about the demo:
# the harness never got far enough. Reporting that as "disagreed with its
# contract" blames the demo for the machine, and the person who reads it goes
# looking for a bug that is not there.
#
# Measured 2026-08-29 on expand-contract-live-demo: all five runs exited 125 --
# docker's "container failed to start" -- with
# "failed to set up container networking: driver failed programming external
# connectivity" underneath. A port already in use on this laptop, not a defect
# in the demo. The first version of this script called that NOT VALIDATED.
_uniform=""
if (( _happy_rc != 0 && ${#_rcs[@]} > 0 )); then
  _uniform="$_happy_rc"
  for r in "${_rcs[@]}"; do [[ "$r" == "$_happy_rc" ]] || { _uniform=""; break; }; done
  [[ "$_uniform" == "1" ]] && _uniform=""   # all-1 is a real (if odd) contract result
fi

echo
if [[ -n "$_uniform" ]]; then
  echo "$demo: CANNOT VALIDATE -- every run, happy path included, exited $_uniform." >&2
  echo "  A uniform non-contract exit code across every run is the harness failing, not the demo:" >&2
  echo "  nothing about the mechanism was measured. Fix the environment and re-run." >&2
  tail -4 "$work/happy.log" | sed 's/^/    /' >&2
  exit 2
fi
if (( fails > 0 )); then
  echo "$demo: NOT validated -- ${fails} run(s) disagreed with the contract the runner publishes." >&2
  exit 1
fi
echo "$demo: VALIDATED -- happy path exit 0 and all ${#controls[@]} control(s) exit 1, from a clean clone."
echo "  Promote its row in demos/INDEX.md and recount the legend."
exit 0
