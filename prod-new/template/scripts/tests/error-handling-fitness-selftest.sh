#!/usr/bin/env bash
# error-handling-fitness-selftest.sh — prove the error-handling gate can FAIL,
# and prove it stays quiet on the correct form of the same code.
#
# scripts/error-handling-fitness.sh is a text pass over Go sources, and a text
# pass is exactly the kind of check that goes silently green: a regex that
# stopped matching, an awk function whose local variable was not declared and
# now leaks across calls, a file-set glob that quietly narrowed to nothing.
# None of those announce themselves. `error-handling-fitness: clean` is the
# same line whether the gate read 82 files or misparsed all of them.
#
# So this selftest drives the REAL script -- never a reimplementation of its
# logic, which would test the copy -- against a scratch tree of crafted Go
# fixtures, and asserts BOTH directions for every rule:
#
#   1. empty error branch            -> RED, naming EMPTY-ERROR-BRANCH
#   2. TODO inside an error branch   -> RED, naming TODO-IN-ERROR-BRANCH
#   3. log-only, func returns error  -> RED, naming LOG-AND-CONTINUE
#   4. log THEN return               -> GREEN (the correct form of case 3)
#   5. log-only, func returns NOTHING-> GREEN (a documented false negative,
#                                      asserted rather than asserted-about, so
#                                      the header's scope section is measured)
#   6. handler with a real body      -> GREEN (the control)
#   7. no Go files at all            -> RED (the zero-inputs rule)
#
# Cases 4 and 5 carry as much weight as 1-3. A gate that fires on correct code
# gets widened until it is gone, and a "false negative" the header claims but
# nobody measured is a claim, not a scope.
#
# Usage: bash scripts/tests/error-handling-fitness-selftest.sh
# Exit:  0 every case behaved; 1 a case did not.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

GATE="scripts/error-handling-fitness.sh"
[[ -f "$GATE" ]] || { printf 'selftest: %s not found -- nothing to test.\n' "$GATE" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fails=0
ok=0

# expect <label> <dir> <RED|GREEN> [required-substring]
#
# The required substring is checked ONLY on RED, and it is not optional there:
# a gate that exits 1 for the wrong reason -- a stray `set -u` unbound
# variable, say -- would satisfy a bare exit-code assertion while detecting
# nothing. The rule name in the output is what proves WHICH rule fired.
expect() {
  local label="$1" dir="$2" want="$3" needle="${4:-}"
  local out code got
  out="$(bash "$GATE" "$dir" 2>&1)"; code=$?
  if ((code == 0)); then got=GREEN; else got=RED; fi
  if [[ "$got" != "$want" ]]; then
    printf '  FAIL  %-44s got %s, want %s\n' "$label" "$got" "$want"
    printf '%s\n' "$out" | sed 's/^/          /'
    fails=$((fails + 1))
    return
  fi
  # Match a VARIABLE, not a pipeline. `printf ... | grep -qF` under `set -o
  # pipefail` inverts this assertion exactly when it succeeds: grep -q exits 0 on
  # the first match, printf takes SIGPIPE (141), pipefail makes that the
  # pipeline's status, and the leading `!` turns a found needle into "went RED
  # but never named it". Flagged as GREPQ-UNDER-PIPEFAIL by this repo's own
  # gate-hygiene fitness and left advisory for weeks; it was the ONE true
  # positive among eleven, the other ten being quoted fixtures.
  if [[ "$want" == RED && -n "$needle" ]] && [[ "$out" != *"$needle"* ]]; then
    printf '  FAIL  %-44s went RED but never named %s\n' "$label" "$needle"
    printf '%s\n' "$out" | sed 's/^/          /'
    fails=$((fails + 1))
    return
  fi
  printf '  ok    %-44s %s\n' "$label" "$got"
  ok=$((ok + 1))
}

# fixture <name> <<'EOF' ... EOF  -- one scratch directory holding one .go file.
# One file per directory so each case is scanned in isolation: a fixture tree
# where one file is RED makes every other case in it RED too, and the selftest
# would then pass on the strength of a single working rule.
fixture() {
  local name="$1"
  mkdir -p "${WORK}/${name}"
  cat >"${WORK}/${name}/fixture.go"
}

printf 'error-handling-fitness selftest\n'

fixture empty <<'EOF'
package fixture

func Load(path string) error {
	err := doIt(path)
	if err != nil {
	}
	return nil
}
EOF
expect "empty error branch" "${WORK}/empty" RED "EMPTY-ERROR-BRANCH"

fixture todo <<'EOF'
package fixture

func Load(path string) error {
	err := doIt(path)
	if err != nil {
		// FIXME: retry once the backoff lands
		_ = err
	}
	return nil
}
EOF
expect "TODO/FIXME in an error branch" "${WORK}/todo" RED "TODO-IN-ERROR-BRANCH"

fixture logcontinue <<'EOF'
package fixture

func Load(path string) error {
	err := doIt(path)
	if err != nil {
		logger.Error("load failed", "error", err)
	}
	return nil
}
EOF
expect "log-and-continue, func returns error" "${WORK}/logcontinue" RED "LOG-AND-CONTINUE"

fixture logthenreturn <<'EOF'
package fixture

func Load(path string) error {
	err := doIt(path)
	if err != nil {
		logger.Error("load failed", "error", err)
		return err
	}
	return nil
}
EOF
expect "log THEN return (the correct form)" "${WORK}/logthenreturn" GREEN

fixture novoid <<'EOF'
package fixture

func Load(path string) {
	err := doIt(path)
	if err != nil {
		logger.Error("load failed", "error", err)
	}
}
EOF
expect "log-only, func returns nothing (known FN)" "${WORK}/novoid" GREEN

fixture control <<'EOF'
package fixture

import "fmt"

func Load(path string) (int, error) {
	n, err := doIt(path)
	if err != nil {
		return 0, fmt.Errorf("loading %s: %w", path, err)
	}
	if err := validate(n); err != nil {
		return 0, fmt.Errorf("validating %s: %w", path, err)
	}
	return n, nil
}
EOF
expect "wrapped-and-returned handlers (control)" "${WORK}/control" GREEN

mkdir -p "${WORK}/nogo"
printf 'this directory has no Go in it\n' >"${WORK}/nogo/README.md"
expect "zero inputs" "${WORK}/nogo" RED "NO Go sources found"

printf '\n%d ok, %d failed\n' "$ok" "$fails"
((fails == 0)) || exit 1
