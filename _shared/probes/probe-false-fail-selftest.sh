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
lift imports.sh  '/^imports_pkg() {/,/^}/p' 'grep -rqE'
lift grepx.sh    '/^grep_x() {/,/^}/p' 'stripped'
lift stamp.sh    '/^revision_stamp_kind() {/,/^}/p' 'ldflags'
# shellcheck disable=SC2034  # read by the lifted imports_pkg
PROBE_GREP_EXCLUDES=(--exclude-dir=.claude --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor)
for f in classify grepx imports stamp reg; do
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
check "registry: db-lane row without DATABASE_URL is COUNTED as not run" "rows=1 ran=0 pass=0 dbskip=1 bad=[]" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestAdd${T}-${T}I01.patch${T}db\n" summ_run)"
check "registry: db-lane row is COUNTED as not mutation-proven" "proven=0/0 dbskip=1 bad=[]" \
  "$(reg "$FX" "I01${T}./pkg/a${T}TestAdd${T}-${T}I01.patch${T}db\n" summ_prove)"
check "registry: prove after the negatives still leaves the tree clean" "" "$(cd "$FX" && git status --porcelain --untracked-files=no)"

# --- the probe really consumes these functions (wiring, not just definitions) --
check_has "wiring: invariants-ratified registry branch calls registry_run" "1" "$(grep -c '^  registry_run$' "$PROBE")"
check_has "wiring: invariants-non-vacuity registry branch calls registry_prove" "1" "$(grep -c '^  registry_prove$' "$PROBE")"
check_has "wiring: ratification rows call registry_cite" "1" "$(grep -c '^  registry_cite$' "$PROBE")"
check_has "wiring: operational-determinism calls revision_stamp_kind" "1" "$(grep -c 'stampable=\$(revision_stamp_kind)' "$PROBE")"
check_has "wiring: slog rows are gated by imports_pkg, not a bare grep" "1" "$(grep -c "^if imports_pkg 'log/slog'; then" "$PROBE")"

if [ "$CASES" -eq 0 ]; then echo "probe-false-fail selftest: ZERO cases ran" >&2; exit 2; fi
if [ "$FAILED" -ne 0 ]; then echo "probe-false-fail selftest: $FAILED of $CASES case(s) FAILED" >&2; exit 1; fi
echo "probe-false-fail selftest: $CASES cases passed"
