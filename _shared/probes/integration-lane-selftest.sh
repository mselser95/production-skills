#!/usr/bin/env bash
# integration-lane-selftest.sh -- verifier of verify-standard.sh's two lane rows,
# `integration-real-lane` and `ci-runs-integration-lane` (PS-7).
# provenance: derived -- guards "every real build tag is a lane: run it, and find it wired in CI".
#
# THE DEFECT SHAPE. Both rows took the FIRST build tag alphabetically as THE lane. A repo with
# `//go:build dbisolation` and `//go:build integration` was scored on `dbisolation` alone: the
# integration lane was never run and never looked for in the Makefile/CI, yet both rows PASSed.
#
# SCENARIOS (ci-runs-integration-lane, over scratch Makefiles; integration-real-lane, over a go stub)
#   a  two tags, only one wired                           FAIL naming the other
#   b  both wired                                         PASS naming both
#   c  alphabetical trap: `aaa` + `integration`, only `aaa` wired   FAIL naming integration
#   d  a tag mentioned only in a comment is not wired     FAIL
#   e  real-lane: the go stub is invoked once per tag     both -tags seen; a red lane FAILs naming it
# PROBE_SRC=<file> points at another verify-standard.sh (used to show RED against the old probe).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="${PROBE_SRC:-}"
if [[ -z "$probe" ]]; then
  for c in "${here}/verify-standard.sh" "${here}/../verify-standard.sh"; do [[ -f "$c" ]] && { probe="$c"; break; }; done
fi
[[ -f "$probe" ]] || { echo "integration-lane-selftest: FAIL -- cannot locate verify-standard.sh" >&2; exit 1; }
tmp="$(mktemp -d)" || exit 1
[[ -n "$tmp" && -d "$tmp" ]] || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0; n=0
bad() { echo "integration-lane-selftest: FAIL -- $*" >&2; fails=$((fails+1)); }

# --- lift the programs ------------------------------------------------------
fn_src() { sed -n "/^$1() {/,/^}/p" "$probe"; }
{ fn_src extract_real_tag; fn_src extract_real_tags; fn_src extract_real_lanes; fn_src go_fail_evidence; } >"$tmp/fns.sh"
grep -q '^extract_real_tag()' "$tmp/fns.sh" || { echo "integration-lane-selftest: FAIL -- extract_real_tag not found" >&2; exit 1; }
sed -n '/^if \[\[ -n "\${real_tags\{0,1\}:-}" \]\]; then$/,/^fi$/p' "$probe" >"$tmp/ci.sh"
sed -n '/^if \[\[ -n "\$real_tags\{0,1\}" \]\]; then$/,/^else row "integration-real-lane" FAIL/p' "$probe" >"$tmp/lane.sh"
[[ $(wc -l <"$tmp/ci.sh") -gt 8 ]] || { echo "integration-lane-selftest: FAIL -- ci row block not found" >&2; exit 1; }
[[ $(wc -l <"$tmp/lane.sh") -gt 8 ]] || { echo "integration-lane-selftest: FAIL -- real-lane block not found" >&2; exit 1; }
grep -q 'ci-runs-integration-lane' "$tmp/ci.sh" && grep -q 'integration-real-lane' "$tmp/lane.sh" || { echo "integration-lane-selftest: FAIL -- blocks lack their rows" >&2; exit 1; }

# fixture: <dir> <tag...> -> a package per tag with a `//go:build <tag>` test file
mkfx() { local d="$1"; shift; rm -rf "$d"; mkdir -p "$d"; local t
  for t in "$@"; do mkdir -p "$d/$t"; printf '//go:build %s\n\npackage %s\n' "$t" "$t" > "$d/$t/x_test.go"; done; }

# harness: run a lifted block in a fixture dir; prints "<ROW> <STATUS> <text>"
harness() { # $1 dir  $2 block file  [$3 stub rc for the tag named in STUB_RED]
  ( cd "$1" || exit 2
    row() { echo "$1 $2 $3"; }
    shard_run() { return 0; }
    # shellcheck disable=SC2034
    PROBE_GREP_EXCLUDES=(--exclude-dir=.git)
    # shellcheck disable=SC1090
    . "$tmp/fns.sh"
    if declare -F extract_real_tags >/dev/null; then real_tags=$(extract_real_tags .); real_tag=$(printf '%s\n' "$real_tags" | head -1)
    else real_tag=$(extract_real_tag .); real_tags=$real_tag; fi
    # shellcheck disable=SC2034
    live_gate=""
    # shellcheck disable=SC2034
    wf=".github/workflows/ci.yml"
    # shellcheck disable=SC1090
    . "$2" ) 2>&1
}

# --- ci-runs-integration-lane ------------------------------------------------
ci() { # ci <name> <tags...> -- reads $MK / $CIYML
  local d="$tmp/ci-$1"; shift; mkfx "$d" "$@"
  printf '%s\n' "$MK" > "$d/Makefile"; mkdir -p "$d/.github/workflows"; printf '%s\n' "$CIYML" > "$d/.github/workflows/ci.yml"
  harness "$d" "$tmp/ci.sh"; }
MK=$'test-a:\n\tgo test -tags=dbisolation ./...'; CIYML='name: ci'
n=$((n+1)); o=$(ci a dbisolation integration)
[[ "$o" == *"ci-runs-integration-lane FAIL"* && "$o" == *"'integration' lane exists but no make target"* ]] || bad "a: expected FAIL naming integration, got: $o"
MK=$'test-a:\n\tgo test -tags=dbisolation ./...\ntest-b:\n\tgo test -tags=integration ./...'
n=$((n+1)); o=$(ci b dbisolation integration)
[[ "$o" == *"ci-runs-integration-lane PASS"* && "$o" == *dbisolation* && "$o" == *integration* ]] || bad "b: expected PASS naming both, got: $o"
MK=$'test-a:\n\tgo test -tags=aaa ./...'
n=$((n+1)); o=$(ci c aaa integration)
[[ "$o" == *"ci-runs-integration-lane FAIL"* && "$o" == *"'integration'"* ]] || bad "c: alphabetical trap -- expected FAIL naming integration, got: $o"
MK=$'test-a:\n\tgo test -tags=aaa ./...\n# integration: go test -tags=integration'
n=$((n+1)); o=$(ci d aaa integration)
[[ "$o" == *"ci-runs-integration-lane FAIL"* && "$o" == *"'integration'"* ]] || bad "d: comment-only mention must not wire the lane, got: $o"

# --- integration-real-lane (go stub records -tags; RED_TAG makes that lane fail) ------------
mkdir -p "$tmp/bin"
cat > "$tmp/bin/go" <<'EOS'
#!/bin/sh
echo "go $*" >> "$STUB_LOG"
[ -n "${STUB_NOTEST:-}" ] && { echo "?   	pkg	[no test files]"; exit 0; }
for a in "$@"; do case "$a" in -tags=*) echo "tags ${a#-tags=}" >> "$STUB_LOG"; [ "${a#-tags=}" = "${RED_TAG:-}" ] && { echo "--- FAIL: TestX"; exit 1; };; esac; done
exit 0
EOS
chmod +x "$tmp/bin/go"
lane() { local d="$tmp/lane-$1"; shift; mkfx "$d" "$@"; : > "$tmp/stub.log"
  PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/stub.log" RED_TAG="${RED_TAG:-}" harness "$d" "$tmp/lane.sh"; }
n=$((n+1)); RED_TAG='' o=$(lane e1 aaa integration)
[[ "$o" == *"integration-real-lane PASS"* && "$o" == *aaa* && "$o" == *integration* ]] || bad "e1: expected PASS naming both lanes, got: $o"
grep -q '^tags integration$' "$tmp/stub.log" || bad "e1: the integration lane was never run (stub saw: $(tr '\n' ' ' <"$tmp/stub.log"))"
n=$((n+1)); RED_TAG=integration o=$(lane e2 aaa integration)
[[ "$o" == *"integration-real-lane FAIL"* && "$o" == *"-tags=integration"* ]] || bad "e2: a red integration lane must FAIL naming it, got: $o"


# --- PS-7b: parsing, anchoring, distinct packages ------------------------------
tags_of() { # tags_of <constraint...> -> extract_real_tags over a fixture with those //go:build lines
  local d="$tmp/tags"; rm -rf "$d"; mkdir -p "$d"; local i=0 c
  for c in "$@"; do i=$((i+1)); printf '//go:build %s\n\npackage p\n' "$c" > "$d/f${i}_test.go"; done
  ( cd "$d" || exit 2
    # shellcheck disable=SC2034
    PROBE_GREP_EXCLUDES=(--exclude-dir=.git)
    # shellcheck disable=SC1090
    . "$tmp/fns.sh"
    if declare -F extract_real_tags >/dev/null; then extract_real_tags . | tr '\n' ' ' | sed 's/ $//'; else extract_real_tag .; fi ); }
n=$((n+1)); o=$(tags_of '(chaos || soak)')
[[ "$o" == "chaos soak" ]] || bad "f1: '(chaos || soak)' must yield 'chaos soak', got: '$o'"
n=$((n+1)); o=$(tags_of 'integration && !unit')
[[ "$o" == "integration" ]] || bad "f2: 'integration && !unit' must yield 'integration', got: '$o'"
n=$((n+1)); o=$(tags_of 'linux && integration' 'go1.21 && amd64')
[[ "$o" == "integration" ]] || bad "f3: platform and go1.N terms are not lanes, got: '$o'"
MK=$'test-a:\n\tgo test -tags=dbisolation,integration ./...'
n=$((n+1)); o=$(ci g1 dbisolation integration)
[[ "$o" == *"ci-runs-integration-lane PASS"* && "$o" == *"'dbisolation'"* && "$o" == *"'integration'"* ]] || bad "g1: -tags=a,b must wire both, got: $o"
MK=$'test-a:\n\tgo test -tags=integration_soak ./...'
n=$((n+1)); o=$(ci g2 integration)
[[ "$o" == *"ci-runs-integration-lane FAIL"* && "$o" == *"'integration'"* ]] || bad "g2: -tags=integration_soak must not wire 'integration', got: $o"
# h: two lanes in ONE package directory are one distinct package, printed without ./././
hd="$tmp/lane-h"; rm -rf "$hd"; mkdir -p "$hd/pkg"
printf '//go:build aaa\n\npackage pkg\n' > "$hd/pkg/a_test.go"; printf '//go:build integration\n\npackage pkg\n' > "$hd/pkg/b_test.go"
: > "$tmp/stub.log"; n=$((n+1)); o=$(PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/stub.log" RED_TAG='' harness "$hd" "$tmp/lane.sh")
[[ "$o" == *"integration-real-lane PASS"* && "$o" == *"in 1 distinct pkg(s)"* ]] || bad "h: two lanes in one package must count 1 distinct pkg, got: $o"
grep -q '^tags integration$' "$tmp/stub.log" && ! grep -q '\./\./' "$tmp/stub.log" || bad "h: lane run missing or path not clean"

# PS-7c: a negated-only package is not in the lane; the space forms of -tags wire the lane
hd="$tmp/lane-k"; rm -rf "$hd"; mkdir -p "$hd/a" "$hd/h" "$hd/k"
printf '//go:build integration\n\npackage a\n' > "$hd/a/x_test.go"; printf '//go:build !integration\n\npackage h\n' > "$hd/h/x_test.go"
printf '//go:build integration && linux\n\npackage k\n' > "$hd/k/x_test.go"
: > "$tmp/stub.log"; n=$((n+1)); o=$(PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/stub.log" RED_TAG='' harness "$hd" "$tmp/lane.sh")
[[ "$o" == *"in 2 distinct pkg(s)"* ]] || bad "k1: !integration package must not count, got: $o"
grep -q '\./h' "$tmp/stub.log" && bad "k2: ./h (build !integration) was put into the integration lane: $(cat "$tmp/stub.log")"
MK=$'t:\n\tgo test -tags integration ./...'
n=$((n+1)); o=$(ci m1 integration); [[ "$o" == *"ci-runs-integration-lane PASS"* ]] || bad "m1: '-tags integration' must wire the lane, got: $o"
MK=$'t:\n\tgo test -tags "unit integration" ./...'
n=$((n+1)); o=$(ci m2 integration); [[ "$o" == *"ci-runs-integration-lane PASS"* ]] || bad "m2: -tags \"unit integration\" must wire the lane, got: $o"
MK=$'t:\n\tgo test -tags \'a integration\' ./...'
n=$((n+1)); o=$(ci m3 integration); [[ "$o" == *"ci-runs-integration-lane PASS"* ]] || bad "m3: -tags 'a integration' must wire the lane, got: $o"
MK=$'t:\n\tgo test -tags integration_soak ./...'
n=$((n+1)); o=$(ci m4 integration); [[ "$o" == *"ci-runs-integration-lane FAIL"* ]] || bad "m4: '-tags integration_soak' must not wire 'integration', got: $o"

# PS-7d: a lane is the SET of tags that compiles its files, never one conjunct of it
# (a) only `integration && acceptance && heldout` files: ONE lane run with all three tags
hd="$tmp/lane-p"; rm -rf "$hd"; mkdir -p "$hd/internal/e2e"
printf '//go:build integration && acceptance && heldout\n\npackage e2e\n' > "$hd/internal/e2e/a_test.go"
: > "$tmp/stub.log"; n=$((n+1)); o=$(PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/stub.log" RED_TAG='' harness "$hd" "$tmp/lane.sh")
[[ "$o" == *"integration-real-lane PASS"* && "$o" == *"acceptance,heldout,integration"* ]] || bad "p1: expected PASS on the full tag set, got: $o"
[[ "$(grep -c '^tags ' "$tmp/stub.log")" == 1 ]] && grep -q '^tags acceptance,heldout,integration$' "$tmp/stub.log" || bad "p2: expected exactly one run with all three tags, stub saw: $(tr '\n' ' ' <"$tmp/stub.log")"
# (a') a REAL go toolchain (when present) compiles and executes that package under the lane
if command -v go >/dev/null 2>&1; then
  rd="$tmp/lane-real"; rm -rf "$rd"; mkdir -p "$rd/internal/e2e"; printf 'module lanefx\n\ngo 1.21\n' > "$rd/go.mod"
  printf '//go:build integration && acceptance && heldout\n\npackage e2e\n\nimport "testing"\n\nfunc TestRan(t *testing.T) { t.Log("ran") }\n' > "$rd/internal/e2e/a_test.go"
  n=$((n+1)); o=$(harness "$rd" "$tmp/lane.sh")
  [[ "$o" == *"integration-real-lane PASS"* ]] || bad "p3: real go: expected PASS, got: $o"
  o=$( cd "$rd" && go test -tags=acceptance,heldout,integration -count=1 -v ./internal/e2e 2>&1 ); [[ "$o" == *"--- PASS: TestRan"* ]] || bad "p4: real go did not execute TestRan under the full tag set"
  # (b) the doc.go trick: the old per-conjunct lane `-tags=acceptance` would say "[no test files]" and look green
  printf 'package e2e\n' > "$rd/internal/e2e/doc.go"
  o=$( cd "$rd" && go test -tags=acceptance -count=1 ./internal/e2e 2>&1 ); [[ "$o" == *"no test files"* ]] || bad "q0: fixture invalid -- doc.go did not produce 'no test files' under a partial lane"
  n=$((n+1)); o=$(harness "$rd" "$tmp/lane.sh")
  [[ "$o" == *"integration-real-lane PASS"* && "$o" == *"acceptance,heldout,integration"* ]] || bad "q1: doc.go + full-lane run must still execute the tests, got: $o"
fi
# (b) a declared lane whose go run reports "[no test files]" is a FAIL, never a PASS
hd="$tmp/lane-q"; rm -rf "$hd"; mkdir -p "$hd/internal/e2e"
printf '//go:build integration && acceptance && heldout\n\npackage e2e\n' > "$hd/internal/e2e/a_test.go"; printf 'package e2e\n' > "$hd/internal/e2e/doc.go"
: > "$tmp/stub.log"; n=$((n+1)); o=$(PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/stub.log" STUB_NOTEST=1 harness "$hd" "$tmp/lane.sh")
[[ "$o" == *"integration-real-lane FAIL"* && "$o" == *"ran NO test"* ]] || bad "q2: '[no test files]' on a declared lane must FAIL, got: $o"
# (c) single-tag lanes are unchanged: one run per tag, `||` is separate lanes, `(a || b) && c` expands
hd="$tmp/lane-r"; rm -rf "$hd"; mkdir -p "$hd/a" "$hd/b" "$hd/c"
printf '//go:build integration\n\npackage a\n' > "$hd/a/x_test.go"; printf '//go:build chaos || soak\n\npackage b\n' > "$hd/b/x_test.go"
printf '//go:build (x1 || x2) && y && !unit && linux\n\npackage c\n' > "$hd/c/x_test.go"
: > "$tmp/stub.log"; n=$((n+1)); o=$(PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/stub.log" RED_TAG='' harness "$hd" "$tmp/lane.sh")
[[ "$(grep '^tags ' "$tmp/stub.log" | sort | tr '\n' ' ')" == "tags chaos tags integration tags soak tags x1,y tags x2,y " ]] || bad "r1: lane set wrong, stub saw: $(grep '^tags ' "$tmp/stub.log" | sort | tr '\n' ' ')"

[[ $n -ge 17 ]] || { echo "integration-lane-selftest: FAIL -- only $n checks ran" >&2; exit 1; }
if (( fails )); then echo "integration-lane-selftest: $fails FAIL" >&2; exit 1; fi
echo "integration-lane-selftest: ok -- $n case(s)"
