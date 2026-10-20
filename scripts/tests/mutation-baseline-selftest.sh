#!/usr/bin/env bash
# mutation-baseline-selftest.sh -- scripts/mutation-baseline.sh check mode must fail when the
# recorded **total** line differs from the sum of the recorded rows (it used to compare rows only).
# provenance: candidate
# ttl: 2027-01-20
# Drives the script through its MUTATION_BASELINE_FILE / MUTATION_BASELINE_SUITES overrides with a
# tiny fake suite, so it does not re-run the repo's selftests.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MB="${MB_SCRIPT:-$root/scripts/mutation-baseline.sh}"
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
printf '#!/usr/bin/env bash\necho "fake selftest: 3 case(s) passed"\n' > "$TMP/a-selftest.sh"
printf '#!/usr/bin/env bash\necho "fake selftest: 4 case(s) passed"\n' > "$TMP/b-selftest.sh"
export MUTATION_BASELINE_SUITES="$TMP/a-selftest.sh $TMP/b-selftest.sh" MUTATION_BASELINE_FILE="$TMP/base.md"

CASES=0; FAILED=0
check() { CASES=$((CASES+1)); if [ "$2" = "$3" ]; then printf '  ok   %-62s %s\n' "$1" "$3"
  else printf '  FAIL %-62s expected=%s actual=%s\n' "$1" "$2" "$3"; FAILED=$((FAILED+1)); fi; }
run() { bash "$MB" "$@" >"$TMP/out" 2>&1; echo $?; }

check "--write records a baseline" 0 "$(run --write)"
check "check mode on a fresh baseline passes" 0 "$(run)"
check "recorded total equals the row sum (7)" 7 "$(grep -E '^\| \*\*total\*\*' "$TMP/base.md" | grep -oE '[0-9]+' | head -1)"

cp "$TMP/base.md" "$TMP/good.md"
sed 's/^| \*\*total\*\* | \*\*7\*\* |/| **total** | **9** |/' "$TMP/good.md" > "$TMP/base.md"
check "NEG: total inflated above the row sum -> FAIL" 1 "$(run)"
grep -q 'recorded \*\*total\*\* (9) != sum' "$TMP/out" && r=named || r=unnamed
check "NEG: the failure names total vs sum" named "$r"
sed 's/^| \*\*total\*\* | \*\*7\*\* |/| **total** | **5** |/' "$TMP/good.md" > "$TMP/base.md"
check "NEG: total deflated below the row sum -> FAIL" 1 "$(run)"
grep -v '^| \*\*total\*\*' "$TMP/good.md" > "$TMP/base.md"
check "NEG: missing total line -> FAIL" 1 "$(run)"
sed -e 's/^| `a-selftest.sh` | 3 |/| `a-selftest.sh` | 5 |/' -e 's/^| \*\*total\*\* | \*\*7\*\* |/| **total** | **9** |/' "$TMP/good.md" > "$TMP/base.md"
check "a consistent baseline whose row FELL still FAILs (existing gate kept)" 1 "$(run)"

if (( FAILED > 0 )); then echo "mutation-baseline selftest: $FAILED of $CASES case(s) FAILED"; exit 1; fi
echo "mutation-baseline selftest: $CASES case(s) passed"
