#!/usr/bin/env bash
# diagnostic-evidence-selftest.sh -- a FAIL row must name its defect.
#
# The `lint` row used to discard golangci-lint's output (`>/dev/null 2>&1`) and
# report "reported issues"; the `vuln-scan` row kept only the "affected by N
# vulnerabilities" line. Both sent the reader off to re-run the tool to learn
# what was wrong -- and a stale cache or environment fault looked identical to a
# finding. This lifts both rows' real code by anchor and drives them with fake
# tools:
#   A  lint FAIL carries the first issue lines (file:line:col)
#   B  lint FAIL with no parseable issue carries the last non-noise line
#   C  vuln-scan FAIL carries the called-vulnerability IDs
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe=""
for c in "${here}/verify-standard.sh" "${here}/../verify-standard.sh"; do [[ -f "$c" ]] && { probe="$c"; break; }; done
[[ -n "$probe" ]] || { echo "diagnostic-evidence-selftest: FAIL -- cannot locate verify-standard.sh" >&2; exit 1; }
lift() { # lift <start-regex> <end-regex>
  LIFT_S="$1" LIFT_E="$2" awk '$0 ~ ENVIRON["LIFT_S"] {on=1} on{print} on && $0 ~ ENVIRON["LIFT_E"] {seen=1; exit} END{exit seen ? 0 : 1}' "$probe"
}
lint_block="$(lift '^if have golangci-lint \|\| ' '^else row "lint" FAIL "golangci-lint not installed"; fi$')" || { echo "diagnostic-evidence-selftest: FAIL -- lint block anchors gone" >&2; exit 1; }
vuln_block="$(lift '^if \[\[ -x "\$\(gobin\)/govulncheck" \]\] \|\| have govulncheck; then$' '^else row "vuln-scan" FAIL "govulncheck not installed')" || { echo "diagnostic-evidence-selftest: FAIL -- vuln block anchors gone" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"; cd "$work" || exit 2
have() { command -v "$1" >/dev/null 2>&1; }
gobin() { echo "$work/bin"; }
toolchain_note() { echo "(under test)"; }
ROW=""; row() { ROW="$1|$2|$3"; }
failures=0; CASES=0
expect() { # expect <label> <verdict> <substring>
  if [[ "${ROW#*|}" != "$2|"* ]] || ! grep -qF -- "$3" <<<"$ROW"; then
    echo "  FAIL $1: want $2 containing '$3', got: ${ROW:-<none>}" >&2; failures=$((failures+1)); return; fi
  CASES=$((CASES+1)); echo "  ok   $1"
}
fake() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$work/bin/$1"; chmod +x "$work/bin/$1"; }

echo "A. lint FAIL carries the first issue lines"
fake golangci-lint 'printf "level=warning msg=noise\ninternal/a/a.go:10:3: unused variable x (unused)\ninternal/b/b.go:7:1: exported thing should have comment (revive)\n6 issues:\n" ; exit 1'
eval "$lint_block"; expect "A names the first issue" FAIL "internal/a/a.go:10:3"
expect "A names the second" FAIL "internal/b/b.go:7:1"

echo "B. lint FAIL with no parseable issue still says something"
fake golangci-lint 'printf "level=warning msg=noise\nERRO Running error: context loading failed\n" ; exit 3'
eval "$lint_block"; expect "B carries the last non-noise line" FAIL "context loading failed"

echo "C. vuln-scan FAIL carries the called-vulnerability IDs"
fake govulncheck 'printf "=== Symbol Results ===\n\nVulnerability #1: GO-2024-1111\n    desc\nVulnerability #2: GO-2025-2222\n\nYour code is affected by 2 vulnerabilities.\n" ; exit 3'
eval "$vuln_block"; expect "C lists both IDs" FAIL "GO-2024-1111 GO-2025-2222"

if [[ "$failures" -ne 0 ]]; then echo "diagnostic-evidence-selftest: FAIL -- ${failures} assertion(s) failed" >&2; exit 1; fi
echo "diagnostic-evidence-selftest: PASS -- ${CASES} case(s) against the probe's real lint and vuln-scan rows"
