#!/usr/bin/env bash
# probe-false-fail-selftest.sh -- the three false FAILs verify-standard.sh gave
# falcon-xyz-perps-service, each with a fixture that reproduces it AND a
# negative fixture that must still FAIL.
#
# provenance: candidate
# ttl: 2027-01-20
# (A candidate until a human ratifies the probe contract it pins. Behaviour is
# asserted on fixtures, not on exact evidence strings, except where noted.)
#
#   1. RATIFIED REGISTRY. A repo keeping ratified tests in their own packages
#      and listing them in verification/ratified/invariants.tsv got
#      invariants-ratified/-non-vacuity/ratification-packages/-citations FAIL
#      although every invariant ran and was mutation-proven. The registry must
#      be accepted AND held to the same bar: a row naming a missing test, a test
#      that does not pass, a vacuous test, a row with no mutation or a stale
#      patch must each FAIL.
#   2. SLOG TRIGGER. `grep -rql 'log/slog'` was satisfied by a COMMENT, so a zap
#      repo was failed on slog rows. Only a real import counts.
#   3. REVISION STAMP. Looked for `-X pkg.Var=` / GIT_SHA only under docker/; a
#      root Dockerfile with `-X ${VERSION_PKG}.Commit=${GIT_SHA}` was "no stamp".
#
# HOW: lifts each function OUT of verify-standard.sh by anchor (house rule: a
# selftest that restates the logic tests the restatement) and fails loudly if an
# anchor stops matching. VS_PROBE overrides the probe path (mutation proofs).
#
# Usage: bash <this>   Exit: 0 all cases behaved, 1 a case did not, 2 cannot run.
set -uo pipefail
if (( BASH_VERSINFO[0] < 4 )); then echo "probe-false-fail selftest: needs bash >= 4 (running ${BASH_VERSION})" >&2; exit 2; fi
command -v go >/dev/null 2>&1 || { echo "probe-false-fail selftest: go is required for the registry fixtures" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "probe-false-fail selftest: git is required" >&2; exit 2; }

CASES=0
FAILED=0
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || { echo "probe-false-fail selftest: cannot reach the repo root" >&2; exit 2; }
PROBE="${VS_PROBE:-}"
[ -n "$PROBE" ] || PROBE="_shared/probes/verify-standard.sh"
[ -f "$PROBE" ] || PROBE="scripts/verify-standard.sh"
[ -f "$PROBE" ] || { echo "probe-false-fail selftest: no verify-standard.sh found" >&2; exit 2; }
PROBE="$(cd "$(dirname "$PROBE")" && pwd)/$(basename "$PROBE")"

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

lift() {   # lift <outfile> <sed-script> <must-contain>
  sed -n "$2" "$PROBE" > "$TMP/$1"
  [ -s "$TMP/$1" ] || { echo "FAIL: anchor for $1 matched nothing -- the probe changed shape" >&2; exit 2; }
  grep -q -- "$3" "$TMP/$1" || { echo "FAIL: extraction of $1 truncated" >&2; exit 2; }
}
lift reg.sh      '/^REG_TSV=/,/^if shard_run dynamic/p' 'registry_prove()'
sed '$d' "$TMP/reg.sh" > "$TMP/reg2.sh" && mv "$TMP/reg2.sh" "$TMP/reg.sh"   # drop the `if shard_run` anchor line
lift classify.sh '/^classify_mutation_result() {/,/^}/p' 'DETECTED'
lift imports.sh  '/^imports_pkg() {/,/^}/p' 'grep -rlE'
lift grepx.sh    '/^grep_x() {/,/^}/p' 'stripped'
lift stamp.sh    '/^revision_stamp_kind() {/,/^}/p' 'ldflags'
lift codelines.sh '/^code_lines_only() {/,/^}/p' 'grep -vE'
lift tracer.sh   '/^tracer_call_sites() {/,/^}/p' 'cmd/'
lift lockregen.sh '/^lockfile_makefile_regen() {/,/^}/p' 'queue'
lift rbtok.sh    '/^RUNBOOK_METRIC_SUFFIXES=/p;/^runbook_token_is_series_ref() {/,/^}/p' 'defined'
lift lanetag.sh  '/^lane_tagonly_stats() {/,/^}/p' 'comm -23'
lift laneverdict.sh '/^lane_verdict() {/,/^}/p' 'no tag-only tests'
lift lanerow.sh  '/^lane_row_verdict() {/,/^}/p' 'gating env'
# shellcheck disable=SC2034  # read by the lifted imports_pkg
PROBE_GREP_EXCLUDES=(--exclude-dir=.claude --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor)
for f in classify grepx imports stamp codelines tracer lanetag laneverdict lanerow lockregen rbtok reg; do
  # shellcheck disable=SC1090  # lifted from the probe at runtime
  . "$TMP/$f.sh"
done

check() {   # label expected actual
  CASES=$((CASES+1))
  if [ "$2" = "$3" ]; then printf '  ok   %-66s %s\n' "$1" "$3"
  else printf '  FAIL %-66s expected=%s actual=%s\n' "$1" "$2" "$3"; FAILED=$((FAILED+1)); fi
}
check_has() {   # label needle haystack  (needle must be non-empty)
  CASES=$((CASES+1))
  if [ -n "$2" ] && [[ "$3" == *"$2"* ]]; then printf '  ok   %-66s %s\n' "$1" "$2"
  else printf '  FAIL %-66s wanted=%s in=%s\n' "$1" "$2" "$3"; FAILED=$((FAILED+1)); fi
}

# ============================ 2. real import vs comment ======================
imp() { ( cd "$1" && imports_pkg "$2" && echo yes || echo no ); }
mkgo() { mkdir -p "$1"; printf '%s\n' "$2" > "$1/$3"; }

d="$TMP/imp-comment"; mkgo "$d" 'package x
// adapts zap to the temporal log.Logger, not log/slog "log/slog"
func f() {}' log.go
check "slog: string only inside a COMMENT is not an import" no "$(imp "$d" log/slog)"
d="$TMP/imp-single"; mkgo "$d" 'package x
import "log/slog"
func f() { _ = slog.Default() }' log.go
check "slog: single-line import counts" yes "$(imp "$d" log/slog)"
d="$TMP/imp-group"; mkgo "$d" 'package x
import (
	"fmt"
	"log/slog"
)' log.go
check "slog: grouped import counts" yes "$(imp "$d" log/slog)"
d="$TMP/imp-alias"; mkgo "$d" 'package x
import (
	sl "log/slog" // structured
)' log.go
check "slog: aliased import with trailing comment counts" yes "$(imp "$d" log/slog)"
d="$TMP/imp-zap"; mkgo "$d" 'package x
import "go.uber.org/zap"
// not log/slog' log.go
check "zap repo: slog NOT imported (the perps shape)" no "$(imp "$d" log/slog)"
check "zap repo: zap IS imported" yes "$(imp "$d" go.uber.org/zap)"
d="$TMP/imp-blockcmt-line"; mkgo "$d" 'package x
// import "log/slog"
func f() {}' log.go
check "slog: a commented-out import is not an import" no "$(imp "$d" log/slog)"
d="$TMP/imp-concat"; mkgo "$d" 'package x
var s = "a" +
	"log/slog"
func f() {}' log.go
check "NEG slog: a concatenated string continuation line is not an import" no "$(imp "$d" log/slog)"
d="$TMP/imp-callarg"; mkgo "$d" 'package x
import "fmt"
func f() {
	fmt.Println(
		"a",
		"log/slog"
	)
}' log.go
check "NEG slog: a multi-line call argument after an import is not an import" no "$(imp "$d" log/slog)"
d="$TMP/imp-block-then-concat"; mkgo "$d" 'package x
import (
	"fmt"
)
var s = "a" +
	"log/slog"' log.go
check "NEG slog: a continuation line after a CLOSED import block is not an import" no "$(imp "$d" log/slog)"
d="$TMP/imp-slice"; mkgo "$d" 'package x
var pkgs = []string{
	"fmt",
	"log/slog",
}
func f() {}' log.go
check "NEG slog: a valid multi-line slice element is not an import" no "$(imp "$d" log/slog)"
# The probe wiring: zap-only repos must get an explicit NA, never a slog FAIL.
check "probe: zap-only repo emits explicit NA rows (not FAIL, not PASS)" 2 "$(grep -cE 'row "observability:(logs_correlate|log_handler_installed)" NA "zap: ' "$PROBE")"

# ============================ 3. revision stamp ==============================
stamp() { ( cd "$1" && revision_stamp_kind ); }
RX='RUN go build -ldflags="-s -w -X ${VERSION_PKG}.Version=${VERSION} -X ${VERSION_PKG}.Commit=${GIT_SHA}" -o /out ./cmd/x'
d="$TMP/st-root"; mkdir -p "$d"; printf 'ARG GIT_SHA=unknown\n%s\n' "$RX" > "$d/Dockerfile"
check "stamp: ROOT Dockerfile with -X \${VERSION_PKG}.Commit=\${GIT_SHA}" ldflags "$(stamp "$d")"
d="$TMP/st-docker"; mkdir -p "$d/docker"; printf 'RUN go build -ldflags "-X main.Commit=$GIT_SHA" .\n' > "$d/docker/Dockerfile"
check "stamp: docker/Dockerfile (the old only-place) still found" ldflags "$(stamp "$d")"
d="$TMP/st-build"; mkdir -p "$d/build"; printf 'RUN go build -ldflags "-X main.Commit=$GIT_SHA" .\n' > "$d/build/Dockerfile.api"
check "stamp: build/Dockerfile.api found" ldflags "$(stamp "$d")"
d="$TMP/st-named"; mkdir -p "$d/deploy"; printf 'RUN go build -ldflags "-X main.Commit=$GIT_SHA" .\n' > "$d/deploy/api.Dockerfile"
check "stamp: deploy/api.Dockerfile found" ldflags "$(stamp "$d")"
d="$TMP/st-strip"; mkdir -p "$d"; printf 'RUN go build -ldflags="-s -w" -o /out .\n' > "$d/Dockerfile"
check "NEG stamp: -ldflags=\"-s -w\" alone is NOT a stamp" no "$(stamp "$d")"
d="$TMP/st-comment"; mkdir -p "$d"; printf '# RUN go build -ldflags "-X main.Commit=$GIT_SHA"\nRUN go build -o /out .\n' > "$d/Dockerfile"
check "NEG stamp: a commented-out stamp is NOT a stamp" no "$(stamp "$d")"
d="$TMP/st-none"; mkdir -p "$d"
check "NEG stamp: no Dockerfile, no Makefile -> no" no "$(stamp "$d")"
d="$TMP/st-arg"; mkdir -p "$d"; printf 'ARG GIT_SHA\nENV GIT_SHA=$GIT_SHA\n' > "$d/Dockerfile"
check "stamp: GIT_SHA build-arg path" build-arg "$(stamp "$d")"
d="$TMP/st-make"; mkdir -p "$d"; printf 'LDFLAGS := -X $(PKG).Commit=$(COMMIT)\n' > "$d/Makefile"
check "stamp: Makefile -X with no Dockerfile at all" makefile "$(stamp "$d")"
d="$TMP/st-make-img"; mkdir -p "$d"; printf 'LDFLAGS := -X $(PKG).Commit=$(COMMIT)\n' > "$d/Makefile"; printf 'RUN go build -o /out .\n' > "$d/Dockerfile"
check "NEG stamp: Makefile -X does NOT excuse an image Dockerfile that stamps nothing" no "$(stamp "$d")"

# ============================ 1. ratified registry ===========================
# A Go fixture repo: pkg/a has Add (+ tests); the registry lives in
# verification/ratified/invariants.tsv with patches under mutations/.
mkfx() {   # mkfx <dir> -> git repo, one commit
  local d="$1"; mkdir -p "$d/pkg/a" "$d/verification/ratified/mutations"
  ( cd "$d" || exit 2
    printf 'module fx\n\ngo 1.21\n' > go.mod
    printf 'package a\n\nfunc Add(x, y int) int { return x + y }\n' > pkg/a/a.go
    cat > pkg/a/a_test.go <<'EOF'
package a

import "testing"

func TestAdd(t *testing.T) {
	if Add(2, 3) != 5 {
		t.Fatal("bad add")
	}
}

func TestVacuous(t *testing.T) {}

func TestRed(t *testing.T) { t.Fatal("always red") }
EOF
    git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm base
    # I01.patch: Add -> subtraction (TestAdd must go red)
    sed -i.bak 's/x + y/x - y/' pkg/a/a.go && rm -f pkg/a/a.go.bak
    git diff > verification/ratified/mutations/I01.patch
    git checkout -q pkg/a/a.go
    printf 'this is not a patch that applies\n' > verification/ratified/mutations/stale.patch
    git add -A && git -c user.email=t@t -c user.name=t commit -qm fixtures )
}
reg() {   # reg <dir> <tsv-body> <fn...> -> runs fns inside dir, prints a summary
  local d="$1" body="$2"; shift 2
  printf '# comment\n%b' "$body" > "$d/verification/ratified/invariants.tsv"
  ( cd "$d" || exit 2; unset DATABASE_URL
    # shellcheck disable=SC2034  # read by the lifted registry_* functions
    REG_TSV="$d/verification/ratified/invariants.tsv"
    "$@" )
}
summ_cite()  { registry_cite;  printf 'rows=%s bad=[%s]' "$REG_ROWS" "${REG_BAD# }"; }
summ_ids()   { registry_cite;  printf 'ids=%s' "$REG_ID_COUNT"; }
summ_run()   { registry_run;   printf 'rows=%s ran=%s pass=%s dbskip=%s bad=[%s]' "$REG_ROWS" "$REG_RAN" "$REG_PASS" "$REG_DB_SKIPPED" "${REG_BAD# }"; }
summ_prove() { registry_prove; printf 'proven=%s/%s dbskip=%s bad=[%s]' "$REG_PROVEN" "$REG_PROVE_TOTAL" "$REG_PROVE_SKIPPED" "${REG_BAD# }"; }

FX="$TMP/fx"; mkfx "$FX"
T='\t'
GOOD="I01${T}./pkg/a${T}TestAdd${T}-${T}I01.patch\n"
check "registry: good row -> cited test and patch exist" "rows=1 bad=[]" "$(reg "$FX" "$GOOD" summ_cite)"
check "registry: good row -> test RUNS and PASSES" "rows=1 ran=1 pass=1 dbskip=0 bad=[]" "$(reg "$FX" "$GOOD" summ_run)"
check "registry: good row -> mutation turns ITS test red" "proven=1/1 dbskip=0 bad=[]" "$(reg "$FX" "$GOOD" summ_prove)"
check "registry: prove restores the tree byte-for-byte" "" "$(cd "$FX" && git status --porcelain --untracked-files=no)"

check_has "NEG registry: row naming a NON-EXISTENT test FAILS (cite)" "no-such-test" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestGone${T}-${T}I01.patch\n" summ_cite)"
check_has "NEG registry: row naming a NON-EXISTENT test FAILS (run)" "did-not-run-green" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestGone${T}-${T}I01.patch\n" summ_run)"
check_has "NEG registry: a RED test FAILS (run)" "I01/TestRed:did-not-run-green" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestRed${T}-${T}I01.patch\n" summ_run)"
check_has "NEG registry: VACUOUS test survives its mutation -> FAILS" "I01/TestVacuous:STAYED-GREEN" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestVacuous${T}-${T}I01.patch\n" summ_prove)"
check_has "NEG registry: row with no mutation recorded FAILS" "no-mutation-recorded" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestAdd${T}-${T}-\n" summ_prove)"
check_has "NEG registry: patch that does not apply FAILS" "patch-does-not-apply(stale.patch)" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestAdd${T}-${T}stale.patch\n" summ_prove)"
check_has "NEG registry: patch file that does not exist FAILS (cite)" "patch-missing(nope.patch)" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestAdd${T}-${T}nope.patch\n" summ_cite)"
check_has "NEG registry: unknown lane (typo) FAILS" "unknown-lane" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestAdd${T}-${T}I01.patch${T}DB\n" summ_run)"
check "NEG registry: empty registry has zero rows (the row FAILS on this)" "rows=0 bad=[]" "$(reg "$FX" "" summ_cite)"
check "registry: distinct-id count is exact (2 ids over 3 rows -> 2, not 1)" "ids=2" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestAdd${T}-${T}I01.patch\nI01${T}./pkg/a${T}TestVacuous${T}-${T}I01.patch\nI02${T}./pkg/a${T}TestAdd${T}-${T}I01.patch\n" summ_ids)"
check "registry: id count of an empty registry is 0" "ids=0" "$(reg "$FX" "" summ_ids)"
check "registry: db-lane row without DATABASE_URL is COUNTED as not run" "rows=1 ran=0 pass=0 dbskip=1 bad=[]" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestAdd${T}-${T}I01.patch${T}db\n" summ_run)"
check "registry: db-lane row is COUNTED as not mutation-proven" "proven=0/0 dbskip=1 bad=[]" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestAdd${T}-${T}I01.patch${T}db\n" summ_prove)"
check "registry: prove after the negatives still leaves the tree clean" "" "$(cd "$FX" && git status --porcelain --untracked-files=no)"

# --- the rows' DECISION logic (lifted: registry_run_verdict & co) --------------
rvd() { registry_run_verdict "$@" | cut -f1; }
check "NEG registry verdict: zero rows -> FAIL (invariants-ratified)" FAIL "$(rvd 0 "" 0 0)"
check_has "NEG registry verdict: zero rows reason says so" "zero rows" "$(registry_run_verdict 0 "" 0 0)"
check "NEG registry verdict: a bad row -> FAIL" FAIL "$(rvd 2 " I01/T:did-not-run-green" 1 0)"
check "NEG registry verdict: nothing runnable -> FAIL" FAIL "$(rvd 1 "" 0 1)"
check "registry verdict: rows ran green -> OK" OK "$(rvd 2 "" 2 0)"
check "NEG registry citations: zero rows -> FAIL (ratification-citations)" FAIL "$(registry_cites_verdict 0 "" | cut -f1)"
check "NEG registry citations: a missing cite -> FAIL" FAIL "$(registry_cites_verdict 1 " I01/T:no-such-test-in-p" | cut -f1)"
check "registry citations: all cites resolve -> OK" OK "$(registry_cites_verdict 1 "" | cut -f1)"
check "evidence: skipped db rows say DATABASE_URL unset" "2 db-lane row(s) NOT run: DATABASE_URL unset" "$(registry_skip_note 2)"
check "evidence: zero skipped never claims 'NOT run' / 'unset'" "no db-lane row skipped (DATABASE_URL set or no db-lane rows)" "$(registry_skip_note 0)"
check "NEG ratification-packages: pkgs=0 -> FAIL" FAIL "$(ratification_pkgs_verdict 0 0 "")"
check "NEG ratification-packages: pkgs < inv -> FAIL" FAIL "$(ratification_pkgs_verdict 2 3 "")"
check "ratification-packages: pkgs == inv -> PASS" PASS "$(ratification_pkgs_verdict 3 3 "")"
check "ratification-packages: pkgs > inv -> PASS" PASS "$(ratification_pkgs_verdict 4 3 "")"
check "NEG ratification-packages: enough ids but a spec id has no row -> FAIL" FAIL "$(ratification_pkgs_verdict 4 3 " I03")"
SPECF="$TMP/spec.yaml"
printf 'invariants:\n  - id: I01\n    text: a\n    examples:\n      - one\n      - two\n  - id: "I02"\n    text: b\n  - id: I03\ninvariants_pending_ratification:\n  - id: P1\n' > "$SPECF"
check "spec ids: ids read from the invariants block only, quotes stripped" "I01 I02 I03" "$(registry_spec_ids "$SPECF" | tr '\n' ' ' | sed 's/ $//')"
check "inv recount: nested sub-list dash lines are NOT counted (3, not 5)" 3 "$(registry_inv_count "$SPECF")"
printf 'invariants:\n  - plain text one\n  - plain text two\nother: x\n' > "$SPECF"
check "inv recount: no readable ids -> falls back to the dash-line count" 2 "$(registry_inv_count "$SPECF")"
printf 'name: x\n' > "$SPECF"
check "inv recount: no invariants block -> 0" 0 "$(registry_inv_count "$SPECF")"
printf 'invariants:\n  - id: I01\n  - id: I02\n  - id: I03\n' > "$SPECF"
check "NEG packages vs spec: 2 registry ids for 3 spec invariants -> FAIL" FAIL "$(ratification_pkgs_verdict 2 "$(registry_inv_count "$SPECF")" "")"
check "packages vs spec: 3 registry ids for 3 spec invariants -> PASS" PASS "$(ratification_pkgs_verdict 3 "$(registry_inv_count "$SPECF")" "")"
check "count_distinct_lines: no trailing newline, one item -> 1" 1 "$(count_distinct_lines "a")"
check "count_distinct_lines: no trailing newline, dup + blank lines -> 2" 2 "$(count_distinct_lines "a
b

a")"
check "count_distinct_lines: empty -> 0" 0 "$(count_distinct_lines "")"
check "wiring: ratification-packages takes pkgs from REG_ID_COUNT" 1 "$(grep -c '^  pkgs=\$REG_ID_COUNT$' "$PROBE")"
check "wiring: ratification-packages verdict via ratification_pkgs_verdict" 1 "$(grep -c 'ratification_pkgs_verdict "\$pkgs" "\$inv" "\$reg_unbacked"' "$PROBE")"
check "wiring: ratification-packages inv from registry_inv_count" 1 "$(grep -c 'inv=\$(registry_inv_count "\$SPEC")' "$PROBE")"
check "wiring: invariants-ratified uses registry_run_verdict" 1 "$(grep -c 'registry_run_verdict "\$REG_ROWS"' "$PROBE")"
check "wiring: invariants-ratified evidence uses registry_skip_note" 1 "$(grep -c 'registry_skip_note "\$REG_DB_SKIPPED"' "$PROBE")"
check "wiring: ratification-citations uses registry_cites_verdict" 1 "$(grep -c 'registry_cites_verdict "\$REG_ROWS" "\$REG_BAD"' "$PROBE")"
check "wiring: integration-real-lane distinct count via count_distinct_lines" 1 "$(grep -c 'rl_npkg=\$(count_distinct_lines "\$rl_allpkgs")' "$PROBE")"
check "wiring: REG_ID_COUNT counted via count_distinct_lines" 1 "$(grep -c 'REG_ID_COUNT=\$(count_distinct_lines "\$REG_IDS")' "$PROBE")"

# ============================ 4. tracing-wired-in-prod call sites ============
# provenance: candidate (pinning: true) -- ttl 2027-01-20
tsites() { ( cd "$1" && tracer_call_sites | wc -l | tr -d ' ' ); }
d="$TMP/tr-with"; mkgo "$d/cmd/app" 'package main
func main() {
	app := build(withTracers(deps.Tel.Tracers)); _ = app
}' main.go
check "tracer: unexported plural option withTracers(x) counts" 1 "$(tsites "$d")"
d="$TMP/tr-field"; mkgo "$d/cmd/app" 'package main
func main() { c := Config{
	Tracers: tracers,
}; _ = c }' main.go
check "tracer: struct field Tracers: x counts" 1 "$(tsites "$d")"
d="$TMP/tr-tp"; mkgo "$d/cmd/app" 'package main
func main() {
	c := Config{TracerProvider: tp}; _ = c
}' main.go
check "tracer: TracerProvider: x counts" 1 "$(tsites "$d")"
d="$TMP/tr-arg"; mkgo "$d/cmd/app" 'package main
func main() {
	run(ctx, cfg, tracers)
}' main.go
check "tracer: tracers) as last argument counts" 1 "$(tsites "$d")"
d="$TMP/tr-old"; mkgo "$d/cmd/app" 'package main
func main() {
	l.SetTracer(adapt(t)); x := New(WithTracer(t)); _ = x
}' main.go
check "tracer: classic SetTracer( / WithTracer( still count" 1 "$(tsites "$d")"
d="$TMP/tr-neg-decor"; mkgo "$d/cmd/app" 'package main
func main() {
	tp := sdktrace.NewTracerProvider(); _ = tp
}' main.go
check "NEG tracer: constructed-and-discarded NewTracerProvider does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-decl"; mkgo "$d/cmd/app" 'package main
func main() {
	tracer := newTracer()
	_ = tracer
}
func withTracers(t Tracers) Option { return nil }' main.go
check "NEG tracer: := declaration, _ = discard and func decl do NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-comment"; mkgo "$d/cmd/app" 'package main
// wire it with WithTracer(t) and Tracers: x
func main() {}' main.go
check "NEG tracer: a comment mentioning WithTracer does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-lit-fatal"; mkgo "$d/cmd/app" 'package main
func main() {
	tp, err := sdktrace.NewTracerProvider()
	if err != nil { log.Fatalf("tracer: %v", err) }
	_ = tp
}' main.go
check "NEG tracer: string literal tracer-colon in log.Fatalf does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-lit-errorf"; mkgo "$d/cmd/app" 'package main
func f() error {
	return fmt.Errorf("init tracer: %w", err)
}' main.go
check "NEG tracer: string literal init-tracer in Errorf does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-lit-println"; mkgo "$d/cmd/app" 'package main
func main() {
	log.Println("disabled (tracer)")
}' main.go
check "NEG tracer: string literal (tracer) in Println does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-multi-tp"; mkgo "$d/cmd/app" 'package main
func main() {
	tp, tracerProvider, err := setup()
	_ = err
}' main.go
check "NEG tracer: multi-assign tp, tracerProvider, err := setup() does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-multi-t"; mkgo "$d/cmd/app" 'package main
func main() {
	tp, tracer, err := setup()
	_ = err
}' main.go
check "NEG tracer: multi-assign tp, tracer, err := setup() does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-case"; mkgo "$d/cmd/app" 'package main
func f(k string) {
	switch k {
	case tracer:
	}
}' main.go
check "NEG tracer: switch arm case tracer: does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-short"; mkgo "$d/cmd/app" 'package main
func main() {
	tracer:=x
	_ = tracer
}' main.go
check "NEG tracer: tracer:=x short declaration does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-var"; mkgo "$d/cmd/app" 'package main
func main() {
	var a, tracer = setup()
	_, _ = a, tracer
}' main.go
check "NEG tracer: var a, tracer = setup() does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-trail"; mkgo "$d/cmd/app" 'package main
func main() {
	tp, err := sdktrace.NewTracerProvider() // tracer: wired later
	_, _ = tp, err
}' main.go
check "NEG tracer: trailing // comment mentioning tracer: does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-escq"; mkgo "$d/cmd/app" 'package main
func main() {
	log.Printf("q\" tracer: %v", err)
}' main.go
check "NEG tracer: escaped quote inside string literal does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-bt"; mkgo "$d/cmd/app" 'package main
func main() {
	x := `tracer: y`
	_ = x
}' main.go
check "NEG tracer: backtick raw string does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-rune"; mkgo "$d/cmd/app" 'package main
func main() {
	x := '"'tracer: y'"'
	_ = x
}' main.go
# NOTE: not valid Go (multi-char rune) on purpose. In valid Go a rune is one char and
# its closing quote always separates it from any identifier, so the rune strip is only
# observable on an apostrophe-delimited span; this pins that the strip still removes it.
check "NEG tracer: apostrophe-delimited span with tracer-colon does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-massign"; mkgo "$d/cmd/app" 'package main
func main() {
	tp, tracer = setup()
}' main.go
check "NEG tracer: plain multi-assign tp, tracer = setup() does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-massign3"; mkgo "$d/cmd/app" 'package main
func main() {
	tp, tracer, err = setup()
}' main.go
check "NEG tracer: plain multi-assign tp, tracer, err = setup() (assign branch only) does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-vartyped"; mkgo "$d/cmd/app" 'package main
func main() {
	var tracer trace.Tracer = x
}' main.go
check "NEG tracer: var tracer trace.Tracer = x does NOT count" 0 "$(tsites "$d")"
d="$TMP/tr-neg-vararr"; mkgo "$d/cmd/app" 'package main
func main() {
	var a, tracer, b []int = f()
}' main.go
check "NEG tracer: var a, tracer, b []int = f() (var branch only) does NOT count" 0 "$(tsites "$d")"
check "wiring: tracing row counts via tracer_call_sites" 1 "$(grep -c '^tracer_sites=\$(tracer_call_sites' "$PROBE")"

# ===== integration-real-lane: a lane whose TAG-ONLY tests all skip is not green ======
# derived-from: none (candidate; TTL 2027-01-20) -- perps replaygen lane measured PASS with 16 skipped generators
lane_fix() {   # lane_fix <dir> <tagged-test-body>   (module with one untagged passing test)
  mkdir -p "$1"; printf 'module lanefix\n\ngo 1.21\n' > "$1/go.mod"
  printf 'package p\nimport "testing"\nfunc TestUntagged(t *testing.T) {}\n' > "$1/a_test.go"
  printf '//go:build lane\n\npackage p\nimport "testing"\nfunc TestTagged(t *testing.T) {\n%s\n}\n' "$2" > "$1/b_test.go"
}
lane_stats() { ( cd "$1" && o=$(go test -v -tags=lane . -count=1 2>&1); lane_tagonly_stats lane "$o" . ); }
lane_fix "$TMP/ln-skip" '	t.Skip("REPLAYGEN_OUT not set")'
check "lane: tag-only test skips -> total 1 ran 0 skipped 1, skip message kept" "1 0 1 0	b_test.go:6: REPLAYGEN_OUT not set" "$(lane_stats "$TMP/ln-skip")"
lane_fix "$TMP/ln-pass" '	_ = 1'
check "lane: tag-only test passes -> ran 1" "1 1 0 0	" "$(lane_stats "$TMP/ln-pass")"
lane_fix "$TMP/ln-fail" '	t.Fatal("boom")'
check "lane: tag-only test fails -> failed 1" "1 1 0 1	" "$(lane_stats "$TMP/ln-fail")"
check "wiring: lane run is -v and all-skipped lane lands in rl_na" 1 "$(grep -c 'rl_na+=' "$PROBE")"
check "wiring: lane run uses -v (the stats parse its --- SKIP lines)" 1 "$(grep -c 'rl_out=$(go test -v -tags="$rt"' "$PROBE")"
check "wiring: the all-skipped NA row is emitted by lane_row_verdict" 1 "$(grep -c "printf 'NA" "$TMP/lanerow.sh")"
# extra fixtures: subtests, non-Test tag-only items, skip-message selection
lane_fix "$TMP/ln-subskip" '	t.Run("a", func(t *testing.T) { t.Skip("sub a off") })
	t.Run("b", func(t *testing.T) { t.Skip("sub b off") })'
check "lane: parent whose subtests ALL skip counts as skipped, reason from the Skip line" "1 0 1 0	b_test.go:7: sub b off" "$(lane_stats "$TMP/ln-subskip")"
lane_fix "$TMP/ln-submix" '	t.Run("a", func(t *testing.T) { t.Skip("sub a off") })
	t.Run("b", func(t *testing.T) {})'
check "lane: parent with one subtest that ran counts as ran" "1 1 0 0	" "$(lane_stats "$TMP/ln-submix")"
# nested (depth 2): TestTagged -> a -> x. A depth-1-only count saw "a" PASS with no skipped child and
# said ran; a node is skipped iff SKIP, or PASS with children that are ALL skipped, at any depth.
lane_fix "$TMP/ln-nested" '	t.Run("a", func(t *testing.T) {
		t.Run("x", func(t *testing.T) { t.Skip("deep off") })
	})'
check "lane: depth-2 subtests all skipped -> parent counts as skipped" "1 0 1 0	b_test.go:7: deep off" "$(lane_stats "$TMP/ln-nested")"
lane_fix "$TMP/ln-nested-mixed" '	t.Run("a", func(t *testing.T) {
		t.Run("x", func(t *testing.T) { t.Skip("deep off") })
		t.Run("y", func(t *testing.T) {})
	})'
check "lane: one depth-2 leaf that runs -> parent counts as ran" "1 1 0 0	" "$(lane_stats "$TMP/ln-nested-mixed")"
lane_fix "$TMP/ln-nested-fail" '	t.Run("a", func(t *testing.T) {
		t.Run("x", func(t *testing.T) { t.Skip("deep off") })
		t.Error("mid-level failure")
	})'
check "lane: failing middle node with an all-skipped child is ran+failed, not skipped" "1 1 0 1	" "$(lane_stats "$TMP/ln-nested-fail")"
d="$TMP/ln-bench"; lane_fix "$d" '	_ = 1'
printf '//go:build lane\n\npackage p\nimport "testing"\nfunc BenchmarkOnly(b *testing.B) {}\nfunc Only() {}\nfunc ExampleOnly() {}\n' > "$d/c_test.go"
check "lane: tag-only Benchmark/Example are not counted (tot stays 1)" "1 1 0 0	" "$(lane_stats "$d")"
d="$TMP/ln-benchonly"; mkdir -p "$d"; printf 'module lanefix\n\ngo 1.21\n' > "$d/go.mod"
printf 'package p\nimport "testing"\nfunc TestUntagged(t *testing.T) {}\n' > "$d/a_test.go"
printf '//go:build lane\n\npackage p\nimport "testing"\nfunc BenchmarkOnly(b *testing.B) {}\n' > "$d/c_test.go"
check "lane: lane with only a tag-only Benchmark has zero tag-only tests" "0 0 0 0	" "$(lane_stats "$d")"
lane_fix "$TMP/ln-msg" '	t.Log("noise before")
	t.Skip("the real reason")
	t.Log("never printed")'
check "lane: skip reason is the t.Skip line, not merely the last indented line" "1 0 1 0	b_test.go:7: the real reason" "$(lane_stats "$TMP/ln-msg")"
# a t.Cleanup t.Log PRINTS after the skip line and ends in a bare continuation line: the reason must be a
# file:line header (the regex), never the last indented line (a bare `prev = l` would pick "continuation")
lane_fix "$TMP/ln-msg-after" '	t.Cleanup(func() { t.Log("cleanup\ncontinuation") })
	t.Skip("the real reason")'
check "lane: a log printed after the skip keeps a file:line header, never a bare continuation line" "1 0 1 0	b_test.go:6: cleanup" "$(lane_stats "$TMP/ln-msg-after")"
# go test -list failing is a failed listing, not "0 tag-only tests"
d="$TMP/ln-listfail"; lane_fix "$d" '	_ = 1'; printf 'package p\nfunc broken( {\n' > "$d/z.go"
r="$(lane_stats "$d")"; check "lane: go test -list failing -> list-failed marker, not a zero count" "list-failed" "${r%%	*}"

# lane_verdict: the row's per-lane decision (verdict<TAB>reason)
lv() { lane_verdict lane "$1" "$2" "$3" | cut -f1; }
lvr() { lane_verdict lane "$1" "$2" "$3" | cut -f2; }
SK=$(printf '1 0 1 0\tb_test.go:6: REPLAYGEN_OUT not set')
check "verdict: all tag-only skipped (rc 0) -> NA" NA "$(lv 0 'ok  p 0.1s' "$SK")"
check "verdict: NA carries count and skip reason" "lane '-tags=lane': all 1 tag-only tests skipped: b_test.go:6: REPLAYGEN_OUT not set" "$(lvr 0 'ok  p 0.1s' "$SK")"
check "verdict: tag-only test ran green -> PASS" PASS "$(lv 0 'ok  p 0.1s' "$(printf '1 1 0 0\t')")"
check "verdict: some skipped some ran -> PASS" PASS "$(lv 0 'ok  p 0.1s' "$(printf '3 1 2 0\t')")"
check "verdict: tag-only test failed (rc 1) -> FAIL" FAIL "$(lv 1 $'--- FAIL: TestTagged\nFAIL' "$(printf '1 1 0 1\t')")"
check "verdict: build break (rc 1, no stats) -> FAIL, never NA" FAIL "$(lv 1 $'# p\nb_test.go:3: syntax error\nFAIL\tp [build failed]' '')"
check "verdict: rc 1 even when stats say all skipped -> FAIL, never NA" FAIL "$(lv 1 'FAIL p' "$SK")"
check "verdict: rc 0 but [no test files] -> FAIL" FAIL "$(lv 0 '?   p [no test files]' '')"
# decision (a): zero tag-only Test* functions was NA; it is now FAIL (consistent with [no test files]):
# a lane holding only benchmarks/helpers proves nothing, and NA would hide a lane that never tests.
check "verdict: zero tag-only tests -> FAIL no tag-only tests" "FAIL|lane '-tags=lane': no tag-only tests under -tags=lane: a lane holding only benchmarks/helpers proves nothing" "$(lv 0 'ok p' "$(printf '0 0 0 0\t')")|$(lvr 0 'ok p' "$(printf '0 0 0 0\t')")"
# decision (b): a failed listing is FAIL carrying its tail
check "verdict: go test -list failed -> FAIL with its output" "FAIL|lane '-tags=lane': go test -list failed: boom tail" "$(lv 0 'ok p' "$(printf 'list-failed\tboom tail')")|$(lvr 0 'ok p' "$(printf 'list-failed\tboom tail')")"
# decision (c): listed but nothing ran or skipped is never PASS
check "verdict: tag-only tests listed but none ran -> FAIL" "FAIL|lane '-tags=lane': listed 4 tag-only tests but none ran" "$(lv 0 'ok p' "$(printf '4 0 0 0\t')")|$(lvr 0 'ok p' "$(printf '4 0 0 0\t')")"
# mixed lanes through the row's REAL aggregation function (lane_row_verdict, lifted from the probe)
agg() {   # agg <green> <red> <na>  -> "STATUS|detail"
  local r; r=$(lane_row_verdict "$1" "$2" "$3" 2 "${4:-}"); printf '%s|%s' "${r%%	*}" "${r#*	}"
}
check "mixed lanes: one NA one green -> row PASS carrying the NA note" "PASS|lane(s) 'g' run green in 2 distinct pkg(s) (NA: x)" "$(agg "'g'" '' 'x')"
check "mixed lanes: all NA -> row NA" "NA|x; y -- the lane's own tests did not execute (set its gating env to run them)" "$(agg '' '' 'x; y')"
check "mixed lanes: one FAIL one NA -> row FAIL" "FAIL|z" "$(agg '' 'z' 'y')"
check "mixed lanes: FAIL plus a green lane names the green one" "FAIL|z (green: 'g')" "$(agg "'g'" 'z' '')"
check "mixed lanes: env-gated live lane noted on PASS" "PASS|lane(s) 'g' run green in 2 distinct pkg(s) + env-gated live lane" "$(agg "'g'" '' '' 'x_test.go')"
lane_fix "$TMP/ln-multiline" '	t.Skip("line one\nline two")'
check "lane: multi-line skip message keeps the file:line header, not the trailing indented line" "1 0 1 0	b_test.go:6: line one" "$(lane_stats "$TMP/ln-multiline")"
check "wiring: row feeds lane_verdict from lane_tagonly_stats" 1 "$(grep -c 'rl_st=$(lane_tagonly_stats "$rt" "$rl_out" $real_pkgs)' "$PROBE")"
check "wiring: row calls lane_verdict with the lane stats" 1 "$(grep -c 'rl_v=$(lane_verdict "$rt" "$rl_rc" "$rl_out" "$rl_st")' "$PROBE")"
check "wiring: row routes NA verdicts to rl_na and FAIL to rl_red" 1 "$(grep -c '^      NA)   rl_na+=' "$PROBE")"
check "wiring: row delegates its aggregation to lane_row_verdict (the function the mixed-lane cases execute)" 1 "$(grep -c 'rl_rv=$(lane_row_verdict "$rl_green" "$rl_red" "$rl_na" "$rl_npkg" "$live_gate")' "$PROBE")"
check "wiring: row status comes from lane_row_verdict's output" 1 "$(grep -cF 'row "integration-real-lane" "$rl_rs" "$rl_rd"' "$PROBE")"


# ===== runbook-citations-resolve: only metric-shaped tokens are citations ==========
# derived-from: none (candidate; TTL 2027-01-20) -- perps /outboxz keys event_broker/event_drain flagged as missing series
rbd="$TMP/rb"; mkdir -p "$rbd"
rbtok() {   # rbtok <body> <token> -> yes/no
  printf '%s\n' "$1" > "$rbd/rbt.md"
  runbook_token_is_series_ref "$2" "$rbd/rbt.md" && echo yes || echo no
}
check "rbtok: JSON key event_broker is NOT a citation" no "$(rbtok '{"event_broker":"ok","event_drain":"ok"}' event_broker)"
check "rbtok: JSON key with spaces before colon is NOT a citation" no "$(rbtok '  "event_broker"   : "ok"' event_broker)"
check "rbtok: quoted string VALUE in a json fence IS a citation (json-fence special-casing removed)" yes "$(rbtok $'```json\n{"check": "event_broker"}\n```' event_broker)"
# perps-shape: real falcon-xyz-perps-service docs/RUNBOOK.md (origin/main) lines 31-36: backticked prose definitions, no json fence, no `"tok":`
rbperps=$'   - `event_broker`: the broker connection\'s status;\n   - `event_drain`: connected and the events stream passing its check (as of\n     its last re-check), whether or not this replica leads;\n   - `snapshot_stream`: an error only after a failed check, at a term\'s start\n     or at a re-check.'
check "rbtok: perps-shape backticked definition event_broker is NOT a citation" no "$(rbtok "$rbperps" event_broker)"
check "rbtok: perps-shape backticked definition event_drain is NOT a citation" no "$(rbtok "$rbperps" event_drain)"
check "rbtok: perps-shape backticked definition snapshot_stream is NOT a citation" no "$(rbtok "$rbperps" snapshot_stream)"
check "rbtok: backticked key with spaces before colon is NOT a citation" no "$(rbtok '- `event_broker`  : ok' event_broker)"
check "rbtok: mismatched delimiters (quote open, backtick close) are NOT a key" yes "$(rbtok '"event_broker`: ok' event_broker)"
check "rbtok: JSON key with string value, key token is NOT a citation" no "$(rbtok '"event_broker": "ok"' event_broker)"
check "rbtok: undeclared token in prose IS a citation" yes "$(rbtok 'we also watch event_made_up_total here' event_made_up_total)"
check "rbtok: key defined once + bare mention elsewhere -> NOT cited (file-level definition)" no "$(rbtok $'- `event_broker`: the status\nread which of `event_broker` / x fails\nand watch event_broker' event_broker)"
check "rbtok: key defined AFTER the bare mention -> NOT cited (order independent)" no "$(rbtok $'watch event_broker\n"event_broker": "ok"' event_broker)"
check "rbtok: key defined + dotted form + JSON value of the defined token -> NOT cited" no "$(rbtok $'`event_drain`: ok\n`event_drain.broker.state`\n{"check": "event_drain"}' event_drain)"
check "rbtok: token only mentioned, never a key -> cited" yes "$(rbtok 'the `event_drain` check is slow' event_drain)"
check "rbtok: backticked mention, colon only after other text, never a key -> cited" yes "$(rbtok 'read `event_drain` first: it fails' event_drain)"
check "rbtok: dotted form of a never-defined token -> cited" yes "$(rbtok '(`snapshot_publisher.stream.state`)' snapshot_publisher)"
check "rbtok: JSON value of an undeclared, never-key token -> cited even beside another defined key" yes "$(rbtok '{"event_broker": "event_foo_total"}' event_foo_total)"
check "rbtok: the defined key does not shelter a DIFFERENT token (event_foo_total cited, event_broker not)" no "$(rbtok '{"expr": "event_foo_total", "event_broker": 1}' event_broker)"
check "rbtok: JSON value {\"expr\": \"tok\"} never a key -> cited" yes "$(rbtok '{"expr": "event_foo_total"}' event_foo_total)"
check "rbtok: quoted string value OUTSIDE a json fence IS a citation" yes "$(rbtok 'set "event_broker" to ok' event_broker)"
check "rbtok: quoted string value in a non-json fence IS a citation" yes "$(rbtok $'```yaml\nname: "event_broker"\n```' event_broker)"
check "rbtok: prose mention IS a citation" yes "$(rbtok 'watch event_drain_backlog today' event_drain_backlog)"
check "rbtok: bash fence grep IS a citation" yes "$(rbtok $'```bash\ncurl :9090/metrics | grep event_drain_backlog\n```' event_drain_backlog)"
check "rbtok: yaml fence expr IS a citation" yes "$(rbtok $'```yaml\nexpr: event_drain_backlog > 100\n```' event_drain_backlog)"
check "rbtok: recording rule name in prose IS a citation" yes "$(rbtok 'see job:event_lagx:rate5m on the board' event_lagx)"
check "rbtok: _ms suffix in prose IS a citation" yes "$(rbtok 'p99 event_latency_ms' event_latency_ms)"
check "rbtok: _created suffix in prose IS a citation" yes "$(rbtok 'event_ts_created' event_ts_created)"
check "rbtok: _percent suffix in prose IS a citation" yes "$(rbtok 'event_cpu_percent' event_cpu_percent)"
check "rbtok: _total suffix is a citation" yes "$(rbtok 'see foo_requests_total' foo_requests_total)"
# metric-shaped tokens get no key exemption (a metric documented as a key must still resolve)
check "rbtok: _total as a JSON key IS a citation (metric-shaped, no key exemption)" yes "$(rbtok '{"foo_requests_total": 1}' foo_requests_total)"
check "rbtok: undeclared {\"event_ghost_total\": 5} IS a citation" yes "$(rbtok '{"event_ghost_total": 5}' event_ghost_total)"
check "rbtok: undeclared backticked key `event_ghost_total`: 5 IS a citation" yes "$(rbtok '- `event_ghost_total`: 5' event_ghost_total)"
check "rbtok: key-defined non-metric event_broker is a term (not cited)" no "$(rbtok '- `event_broker`: the status' event_broker)"
check "rbtok: perps:196 metric-shaped definition-list key snapshot_publisher_stream_state IS a citation" yes "$(rbtok '  - `snapshot_publisher_stream_state`: `unchecked`' snapshot_publisher_stream_state)"
check "rbtok: RESIDUAL HOLE -- suffix-less gauge documented only as key is a term" no "$(rbtok '- `queue_depth`: 3' queue_depth)"
for sfx in _total _seconds _bytes _count _sum _bucket _ratio _state _info _ms _created _percent; do
  check "rbtok: suffix $sfx as backticked key IS a citation" yes "$(rbtok "- \`event_k$sfx\`: x" "event_k$sfx")"
  check "rbtok: suffix $sfx as JSON key IS a citation" yes "$(rbtok "{\"event_k$sfx\": 1}" "event_k$sfx")"
done
check "rbtok: bare suffix-looking token equal to a suffix (_total) is not metric-shaped" no "$(rbtok '- `x`: 1' x)"
check "rbtok: selector with { is a citation" yes "$(rbtok 'event_lag{job="x"}' event_lag)"
check "rbtok: range selector with [ is a citation" yes "$(rbtok 'event_lag[5m]' event_lag)"
check "rbtok: function arg rate(x[5m]) is a citation" yes "$(rbtok 'rate(event_lag[5m])' event_lag)"
check "rbtok: prose (event_drain) IS a citation (operator must name a real thing)" yes "$(rbtok 'the drain (event_drain) is slow' event_drain)"
check "rbtok: bare name inside a promql fence is a citation" yes "$(rbtok $'```promql\nevent_lag\n```' event_lag)"
check "rbtok: bare name in an untagged fence IS a citation" yes "$(rbtok $'```\nevent_lag\n```' event_lag)"
check "rbtok: longer identifier containing the token is NOT an occurrence (prefix side)" no "$(rbtok 'xevent_lag and "event_lag_x": 1' event_lag)"
check "rbtok: longer identifier containing the token is NOT an occurrence (suffix side)" no "$(rbtok 'event_lagx event_lag_x' event_lag)"
check "rbtok: two keys on one line, token only as key -> NOT a citation" no "$(rbtok '{"event_drain": 1, "event_broker": 2}' event_broker)"
check "rbtok: closing quote without opening quote is NOT a key (IS a citation)" yes "$(rbtok 'event_broker": ok' event_broker)"
check "rbtok: opening quote without closing quote is NOT a key (IS a citation)" yes "$(rbtok '"event_broker: ok' event_broker)"
check "rbtok: absent token is NOT a citation" no "$(rbtok 'nothing here' event_broker)"
check "wiring: citations loop skips non-metric-shaped undeclared tokens" 1 "$(grep -c '|| runbook_token_is_series_ref "$m" docs/RUNBOOK.md || continue' "$PROBE")"

# ===== dependency-lockfile: `go mod tidy` only counts where the build/CI can reach it ==
# provenance: candidate; ttl: 2027-01-20; pinning: true -- perps Makefile:64 developer-only `tidy:` target FAILed the row
lrd="$TMP/lr"; mkdir -p "$lrd"
lrg() {   # lrg <makefile-body> [workflow-run-line] -> number of reachable regen lines
  rm -rf "$lrd/fx"; mkdir -p "$lrd/fx/.github/workflows"
  printf '%b' "$1" > "$lrd/fx/Makefile"
  [ -n "${2:-}" ] && printf 'jobs:\n  j:\n    steps:\n      - run: %s\n' "$2" > "$lrd/fx/.github/workflows/ci.yaml"
  ( cd "$lrd/fx" && lockfile_makefile_regen '(go mod tidy|npm install)' | grep -c . )
}
check "lockregen: standalone developer tidy target is NOT reachable" 0 "$(lrg 'build:\n\tgo build ./...\n\ntidy:\n\t@go mod tidy\n')"
check "lockregen: build: tidy prerequisite IS reachable" 1 "$(lrg 'build: tidy\n\tgo build ./...\n\ntidy:\n\t@go mod tidy\n')"
check "lockregen: check-fast recipe calling \$(MAKE) tidy IS reachable" 1 "$(lrg 'check-fast:\n\t$(MAKE) tidy\n\ntidy:\n\tgo mod tidy\n')"
check "lockregen: transitive prerequisite chain IS reachable" 1 "$(lrg 'test: gen\n\tgo test ./...\ngen: tidy\n\ttrue\ntidy:\n\tgo mod tidy\n')"
check "lockregen: target a workflow runs via make IS reachable" 1 "$(lrg 'build:\n\ttrue\n\nrelease-prep:\n\tgo mod tidy\n' 'make release-prep')"
check "lockregen: target no workflow runs and nothing depends on is NOT reachable" 0 "$(lrg 'build:\n\ttrue\n\nrelease-prep:\n\tgo mod tidy\n' 'make build')"
check "lockregen: commented tidy call is ignored" 0 "$(lrg 'build: tidy\n\ttrue\ntidy:\n\t# go mod tidy\n')"
# end-to-end through the real row (lifted block, `row` stubbed to print "STATUS|detail")
lift lockrow.sh '/^_lock_files=""$/,/^# --- chaos engineering/p' 'dependency-lockfile'
sed -i.bak '$d' "$TMP/lockrow.sh" && rm -f "$TMP/lockrow.sh.bak"
lrrow() {   # lrrow <makefile-body> [workflow-run-line] -> "STATUS|detail"
  rm -rf "$lrd/e2e"; mkdir -p "$lrd/e2e/.github/workflows"
  printf 'module x\n\ngo 1.22\n' > "$lrd/e2e/go.mod"; : > "$lrd/e2e/go.sum"; printf '%b' "$1" > "$lrd/e2e/Makefile"
  [ -n "${2:-}" ] && printf 'jobs:\n  j:\n    steps:\n      - run: %s\n' "$2" > "$lrd/e2e/.github/workflows/ci.yaml"
  ( cd "$lrd/e2e" && row() { printf '%s|%s' "$2" "$3"; }; . "$TMP/lockrow.sh" )
}
check "lockrow: developer-only tidy target -> PASS" PASS "$(lrrow 'build:\n\tgo build ./...\n\ntidy:\n\t@go mod tidy\n' | cut -d'|' -f1)"
check_has "lockrow: developer-only PASS carries the developer-only note" "developer-only" "$(lrrow 'build:\n\tgo build ./...\n\ntidy:\n\t@go mod tidy\n')"
check "lockrow: build: tidy -> FAIL" FAIL "$(lrrow 'build: tidy\n\tgo build ./...\n\ntidy:\n\t@go mod tidy\n' | cut -d'|' -f1)"
check "lockrow: check-fast calls \$(MAKE) tidy -> FAIL" FAIL "$(lrrow 'check-fast:\n\t$(MAKE) tidy\n\ntidy:\n\tgo mod tidy\n' | cut -d'|' -f1)"
check "lockrow: workflow run: go mod tidy -> FAIL" FAIL "$(lrrow 'build:\n\tgo build ./...\n' 'go mod tidy' | cut -d'|' -f1)"

# --- the probe really consumes these functions (wiring, not just definitions) --
check "wiring: invariants-ratified registry branch calls registry_run" 1 "$(grep -c '^  registry_run$' "$PROBE")"
check "wiring: invariants-non-vacuity registry branch calls registry_prove" 1 "$(grep -c '^  registry_prove$' "$PROBE")"
check "wiring: ratification rows call registry_cite" 1 "$(grep -c '^  registry_cite$' "$PROBE")"
check "wiring: operational-determinism calls revision_stamp_kind" 1 "$(grep -c 'stampable=\$(revision_stamp_kind)' "$PROBE")"
check "wiring: slog rows are gated by imports_pkg, not a bare grep" 1 "$(grep -c "^if imports_pkg 'log/slog'; then" "$PROBE")"

if [ "$CASES" -eq 0 ]; then echo "probe-false-fail selftest: ZERO cases ran" >&2; exit 2; fi
if [ "$FAILED" -ne 0 ]; then echo "probe-false-fail selftest: $FAILED of $CASES case(s) FAILED" >&2; exit 1; fi
echo "probe-false-fail selftest: $CASES cases passed"
