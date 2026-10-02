#!/usr/bin/env bash
# prove-mutation-selftest.sh — prove prove-mutation.sh can say every verdict,
# and that the tree is byte-identical afterwards in every one of them.
#
# The cases are the ways a mutation proof goes silently wrong:
#   1. test detects the mutation                 -> RED, exit 0
#   2. test does not detect it                   -> GREEN, exit 1
#   3. test already red before mutating          -> ERROR (would be a vacuous RED)
#   4. mutation breaks the build, --expect given -> ERROR, not RED
#   5. patch does not apply                      -> ERROR
#   6. after each of the above, the tree is clean (the revert really ran)
#
# Usage: bash _shared/probes/prove-mutation-selftest.sh
# Exit:  0 all cases behaved; 1 a case did not.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="$here/prove-mutation.sh"
CASES=0 FAILS=0
tmp="$(mktemp -d "${TMPDIR:-/tmp}/prove-mutation-selftest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo" && cd "$repo" || exit 2
git init -q . && git config user.email t@t && git config user.name t
printf 'value=1\n' > lib.txt
# The "test": passes iff lib.txt says value=1; prints a recognisable name.
cat > check.sh <<'EOF'
#!/usr/bin/env bash
if grep -q '^value=1$' lib.txt; then echo "TestValue ok"; exit 0; fi
echo "--- FAIL: TestValue"; exit 1
EOF
chmod +x check.sh
printf 'note\n' > other.txt
git add -A && git commit -qm init

mkpatch() { # $1 file  $2 old  $3 new  $4 out
  cp "$1" "$tmp/orig" && sed "s/$2/$3/" "$tmp/orig" > "$1"
  git diff -- "$1" > "$4"; git checkout -q -- "$1"
}
mkpatch lib.txt 'value=1' 'value=2' "$tmp/detected.patch"
mkpatch other.txt 'note' 'changed' "$tmp/survives.patch"
mkpatch check.sh 'exit 0' 'exit 3' "$tmp/breaks.patch"
printf 'garbage\n' > "$tmp/bad.patch"

expect_case() { # name want_rc want_prefix -- args...
  local name="$1" want_rc="$2" want_prefix="$3"; shift 3
  local out rc
  # Bounded: a hang must be a FAIL, not a stuck suite. Portable watchdog --
  # macOS ships no `timeout`.
  bash "$probe" "$@" >"$tmp/out" 2>/dev/null & local pid=$!
  ( sleep 20; kill "$pid" 2>/dev/null ) & local dog=$!
  wait "$pid"; rc=$?
  kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  out="$(cat "$tmp/out")"
  CASES=$((CASES + 1))
  if [[ $rc -ne $want_rc || "$out" != "$want_prefix"* ]]; then
    echo "FAIL $name: rc=$rc (want $want_rc) out=[$out] (want prefix $want_prefix)"
    FAILS=$((FAILS + 1))
  fi
  CASES=$((CASES + 1))
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "FAIL $name: tree left dirty:"; git status --porcelain
    FAILS=$((FAILS + 1)); git checkout -q -- .
  fi
}

expect_case detected     0 "RED"   "$tmp/detected.patch" -- ./check.sh
expect_case detected-exp 0 "RED"   --expect 'FAIL: TestValue' "$tmp/detected.patch" -- ./check.sh
expect_case survives     1 "GREEN" "$tmp/survives.patch" -- ./check.sh
expect_case build-break  2 "ERROR" --expect 'FAIL: TestValue' "$tmp/breaks.patch" -- ./check.sh
expect_case bad-patch    2 "ERROR" "$tmp/bad.patch" -- ./check.sh
expect_case no-command   2 "ERROR" "$tmp/detected.patch"
# --expect with no value used to spin forever; the timeout makes a hang a FAIL.
expect_case expect-noval 2 "ERROR" --expect
# Interrupted mid-run: the test command TERMs the probe itself. The run has no
# verdict, so it must be ERROR -- before the fix the trap reverted and the
# script carried on to grade the cut-short run as RED.
expect_case interrupted  2 "ERROR" "$tmp/detected.patch" -- bash -c 'grep -q value=1 lib.txt || kill -TERM $PPID; sleep 1; grep -q value=1 lib.txt'

# Baseline red: break the tree in a COMMITTED way, so the command fails before
# any mutation, then restore.
sed -i.bak 's/value=1/value=9/' lib.txt && rm -f lib.txt.bak && git commit -qam red
expect_case baseline-red 2 "ERROR" "$tmp/survives.patch" -- ./check.sh
git reset -q --hard HEAD~1

if (( CASES == 0 )); then echo "prove-mutation-selftest: ZERO cases ran -- refusing to pass"; exit 1; fi
if (( FAILS )); then echo "prove-mutation-selftest: $FAILS of $CASES checks failed"; exit 1; fi
echo "prove-mutation-selftest: ok -- $CASES case(s)"
