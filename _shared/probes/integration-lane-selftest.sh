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
{ fn_src extract_real_tag; fn_src extract_real_tags; fn_src go_fail_evidence; } >"$tmp/fns.sh"
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

[[ $n -ge 6 ]] || { echo "integration-lane-selftest: FAIL -- only $n checks ran" >&2; exit 1; }
if (( fails )); then echo "integration-lane-selftest: $fails FAIL" >&2; exit 1; fi
echo "integration-lane-selftest: ok -- $n case(s)"
