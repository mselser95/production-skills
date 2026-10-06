#!/usr/bin/env bash
# row-vacuity-sweep-selftest.sh -- prove the row-vacuity sweep can judge a pattern
# in the files its OWN probe row searches, and can still fail.
#
# provenance: candidate
# ttl: 2027-01-06
# pinning: true   (exact summary counts and exit codes, no ratified property yet;
#                  the underlying invariant is the one queued as
#                  a-gate-never-reports-green-over-something-it-did-not-measure)
# verifies: the SCOPE and DIRECTIVES rules in row-vacuity-sweep.sh's header
#
# Each case builds a throwaway repo with a stub scripts/verify-standard.sh (the
# sweep reads <repo>/scripts/verify-standard.sh first -- that is the seam) and
# asserts the sweep's exit code AND its summary counts.
#
# Origin: a service scaffolded from the template failed `make check-fast` at the
# sweep because the sweep searched a build-tag pattern in non-test files while
# the probe row searches *_test.go, and called `//go:build` a comment.
#
# Usage: bash _shared/probes/row-vacuity-sweep-selftest.sh
# Exit:  0 all cases behaved; 1 a case did not.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sweep=""
for c in "$here/row-vacuity-sweep.sh" "$here/../row-vacuity-sweep.sh"; do
  [[ -f "$c" ]] && { sweep="$c"; break; }
done
[[ -n "$sweep" ]] || { echo "row-vacuity-sweep-selftest: cannot find row-vacuity-sweep.sh" >&2; exit 2; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
CASES=0 FAILS=0

# mk <name> <probe-line...>   put <name> <relpath> <content>
mk()  { local n="$1"; shift; mkdir -p "$tmp/$n/scripts"; printf '%s\n' "$@" > "$tmp/$n/scripts/verify-standard.sh"; }
put() { mkdir -p "$(dirname "$tmp/$1/$2")"; printf '%s\n' "$3" > "$tmp/$1/$2"; }

# expect <name> <want-rc> <summary-fragment> [output-fragment]
expect() {
  local n="$1" want="$2" frag="$3" ofrag="${4:-}" out rc
  CASES=$((CASES + 1))
  out="$(bash "$sweep" "$tmp/$n" 2>&1)"; rc=$?
  if [[ $rc -ne $want ]] || ! grep -qF -- "$frag" <<<"$out" || { [[ -n "$ofrag" ]] && ! grep -qF -- "$ofrag" <<<"$out"; }; then
    FAILS=$((FAILS + 1))
    echo "FAIL $n: want rc=$want and '$frag'${ofrag:+ and \"$ofrag\"}; got rc=$rc"
    printf '%s\n' "$out" | tail -8 | sed 's/^/    /'
  else
    echo "ok   $n"
  fi
}

TAGROW="grep -rhoE 'go:build [A-Za-z0-9_.]+' --include='*_test.go' \"\${1:-.}\" 2>/dev/null | head -1"
CLEAN1="1 pattern(s) extracted, 1 with matches, 0 with none, 0 satisfied ONLY by comments."
VAC1="1 pattern(s) extracted, 1 with matches, 0 with none, 1 satisfied ONLY by comments."

# (a) the measured defect: tagged _test.go AND tagged non-test file -> not vacuous
mk a "$TAGROW"; put a x_test.go '//go:build integration'; put a h.go '//go:build integration'
expect a 0 "$CLEAN1"
# (a2) scope discriminator: the evidence is only in the _test.go; the non-test file merely mentions it in prose
mk a2 "$TAGROW"; put a2 x_test.go '//go:build integration'; put a2 h.go '// the go:build integration tag is set by the harness'
expect a2 0 "$CLEAN1"
# (b) only a prose comment in a test file -> vacuous
mk b "$TAGROW"; put b x_test.go '// we used to have go:build integration here'
expect b 1 "$VAC1" "COMMENT-ONLY"
# (c)/(d) no scope on the grep: default scope (*.go minus tests), prose vs code
mk c "if grep -rn 'NewTracer' >/dev/null; then :; fi"; put c m.go '// NewTracer is wired later'
expect c 1 "$VAC1"
mk d "if grep -rn 'NewTracer' >/dev/null; then :; fi"; put d m.go 'tracer := NewTracer()'
expect d 0 "$CLEAN1"
# (e) directives are evidence, prose is not
mk e1 "grep -rn 'go:embed [a-z]+' --include='*.go' ."; put e1 m.go '//go:embed x'
expect e1 0 "$CLEAN1"
mk e2 "grep -rn 'go:generate' --include='*.go' ."; put e2 m.go '//go:generate y'
expect e2 0 "$CLEAN1"
mk e3 "grep -rn '[+]build' --include='*.go' ."; put e3 m.go '// +build integration'
expect e3 0 "$CLEAN1"
mk e4 "grep -rn 'nolint' --include='*.go' ."; put e4 m.go '//nolint:errcheck'
expect e4 0 "$CLEAN1"
mk e5 "grep -rn 'go:embed' --include='*.go' ."; put e5 m.go '// go:embed is described here'
expect e5 1 "$VAC1"
# (f) an ERE-only pattern is still found (matches nothing under BRE)
mk f "grep -rnE 'slog\\.(New|Set)Handler' --include='*.go' ."; put f m.go 'slog.NewHandler()'
expect f 0 "$CLEAN1"
# (g) zero patterns extracted: refuses to report clean
mk g 'echo nothing to extract here'
expect g 2 "extracted ZERO patterns"
# (h) a path the sweep cannot read statically: readable globs kept, and it SAYS so
mk h "grep -rn 'NewTracer' --include='*.go' \"\$dir\""; put h m.go '// NewTracer only in prose'
expect h 1 "$VAC1" "scope not fully determinable"
# (i) scope on a backslash continuation line is read
mk i "grep -rn 'NewTracer' \\" "  --include='*_test.go' ."; put i x_test.go 'NewTracer()'; put i m.go '// NewTracer prose'
expect i 0 "$CLEAN1"
# (j) an explicit directory argument is honoured
mk j "grep -rql 'StartSpan' --include='*.go' internal/"; put j internal/a.go '// StartSpan prose'; put j cmd/m.go 'StartSpan()'
expect j 1 "$VAC1"
# (l) a grep the probe itself pipes through code_lines_only is GUARDED, not vacuous
mk l "n=\$(grep -rniE 'retry' --include='*.go' internal/ 2>/dev/null | code_lines_only | wc -l)"; put l internal/a.go '// retry is described here'
expect l 0 "$CLEAN1" "GUARDED"
# (m) the same grep with a different pipe is still reported
mk m "n=\$(grep -rniE 'retry' --include='*.go' internal/ 2>/dev/null | wc -l)"; put m internal/a.go '// retry is described here'
expect m 1 "$VAC1"
# (n) -i on the probe's grep is carried: only a differently-cased identifier matches
mk n "grep -rnEi 'newtracer' --include='*.go' ."; put n m.go 'tracer := NewTracer()'
expect n 0 "$CLEAN1"
# (k) debug mode prints pattern -> scope -> evidence
CASES=$((CASES + 1))
out="$(ROW_VACUITY_DEBUG=1 bash "$sweep" "$tmp/a" 2>&1)"
if grep -qF "DEBUG go:build [A-Za-z0-9_.]+ -> [inc:*_test.go" <<<"$out"; then echo "ok   k"; else FAILS=$((FAILS + 1)); echo "FAIL k: no DEBUG line"; fi

echo "row-vacuity-sweep selftest: $((CASES - FAILS)) ok of $CASES case(s), $FAILS failed"
[[ $FAILS -eq 0 ]]
