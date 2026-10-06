#!/usr/bin/env bash
# provenance: candidate; ttl: 2027-04-01; pinning: true
# template-workflow-pins-selftest.sh — the gate must pass the pinned form and fail,
# naming file:line, on each unpinned-remote-script and floating-version shape; and
# the REAL template must pass, so this goes red if the template regresses.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$here/../template-workflow-pins.sh"
REAL="$here/../../prod-new/template/.github/workflows"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
n=0; fail=0
SHA=b254e6d92f28c3868a755f62fb3ca8f26e9fee76
check() { n=$((n+1)); if [[ "$2" != 0 ]]; then echo "FAIL: $1" >&2; fail=$((fail+1)); fi; }

# fixture NAME LINE... -> dir with one workflow whose step run is LINE
fixture() { mkdir -p "$T/$1"; printf 'jobs:\n  j:\n    steps:\n      - name: x\n        run: %s\n' "$2" > "$T/$1/w.yaml"; }
expect_fail() { # name, run-line, expected line number
  fixture "$1" "$2"; local o rc; o="$(bash "$GATE" "$T/$1" 2>&1)"; rc=$?
  [[ $rc == 1 ]] && grep -qF "w.yaml:$3:" <<<"$o" && grep -qF -- "${4:-$2}" <<<"$o"; check "$1 fails rc=1 naming w.yaml:$3" $?
}

fixture pinned "curl -sSfL https://raw.githubusercontent.com/o/r/$SHA/install.sh | sh -s -- -b /usr/local/bin v1.0.0"
o="$(bash "$GATE" "$T/pinned" 2>&1)"; rc=$?
[[ $rc == 0 ]] && grep -qF "remote_steps=1" <<<"$o"; check "pinned commit passes and counts one remote step" $?

expect_fail main   "curl -sSfL https://raw.githubusercontent.com/o/r/main/install.sh | sh" 5
expect_fail master "bash <(curl -sSfL https://raw.githubusercontent.com/o/r/master/install.sh)" 5
expect_fail short  "curl -sSfL https://raw.githubusercontent.com/o/r/abc1234/i.sh | bash" 5
expect_fail other  "curl -sSfL https://example.invalid/i.sh | sh" 5
expect_fail subst  'sh -c "$(curl -fsSL https://github.com/o/r/raw/HEAD/i.sh)"' 5
expect_fail golatest "go install example.invalid/x@latest" 5
expect_fail gomain   "go install example.invalid/x@main" 5

fixture sumok "curl -sSfL https://example.invalid/i.sh | sh; sha256sum -c i.sum"
bash "$GATE" "$T/sumok" >/dev/null 2>&1; check "other host with checksum in the same step passes" $?

mkdir -p "$T/comment"; printf 'steps:\n  # run: curl https://raw.githubusercontent.com/o/r/main/i.sh | sh\n  - run: echo ok\n' > "$T/comment/w.yaml"
bash "$GATE" "$T/comment" >/dev/null 2>&1; check "commented-out offending line passes" $?

mkdir -p "$T/empty"; bash "$GATE" "$T/empty" >/dev/null 2>&1; rc=$?
[[ $rc == 2 ]]; check "empty directory exits 2" $?

bash "$GATE" "$REAL" >/dev/null 2>&1; check "the real template workflows pass" $?

if (( fail )); then echo "template-workflow-pins selftest: $fail FAILED of $n case(s)" >&2; exit 1; fi
echo "template-workflow-pins selftest: ok -- $n case(s)"
