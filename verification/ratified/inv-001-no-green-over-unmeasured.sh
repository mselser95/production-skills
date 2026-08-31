#!/usr/bin/env bash
# inv-001 — A GATE NEVER REPORTS GREEN OVER SOMETHING IT DID NOT MEASURE.
#
# Ratified 2026-08-31. This is the property the whole framework exists to enforce
# in other repos, and on 2026-08-29 this repo violated it seven times in its own
# probe. If it does not hold HERE, every repo the framework touches inherits a
# lie.
#
# WHAT RATIFICATION MEANT, since it is not a status field. The standard is
# explicit (prod-new/SKILL.md): a ratified invariant needs an EXECUTABLE test
# whose failure is the detection, not a YAML key flipped to `ratified`. Writing
# the key without the test "launders scaffold-time authorship into ratification,
# which is the one thing the human gate exists to prevent."
#
# So each case below takes a gate and REMOVES ITS SUBJECT -- no policy keys, no
# probes, no registries, no vendored files, no invoker surfaces -- and requires
# the gate to refuse. Exit 0 over an absent subject is the violation; any
# non-zero exit is the invariant holding.
#
# It deliberately does NOT assert a particular exit code. 1 and 2 mean different
# things to these gates (a finding vs a refusal) and pinning one here would make
# this test fail on a correct change to that distinction.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2

ok=0; failed=0
work="$(mktemp -d)" || exit 2
trap 'rm -rf "$work"' EXIT

refuses() { # refuses <name> <dir-to-run-in> <command...>
  local name="$1" dir="$2"; shift 2
  local out rc
  out=$( cd "$dir" && "$@" 2>&1 ); rc=$?
  if (( rc != 0 )); then
    printf '  ok    %-56s refused (rc=%s)\n' "$name" "$rc"; ok=$((ok+1))
  else
    printf '  FAIL  %-56s REPORTED GREEN over an absent subject\n' "$name"
    printf '%s\n' "$out" | sed 's/^/          /'; failed=$((failed+1))
  fi
}

echo "inv-001: a gate never reports green over something it did not measure"

# Each fixture is a tree shaped like this repo with exactly one thing missing.
# Copying the script into the fixture matters: these gates resolve their root
# from their own location, so one run in place would measure production.

# 1. policy-coverage with a policy that declares no keys.
d="$work/nokeys"; mkdir -p "$d/_shared/probes"
cp _shared/probes/policy-coverage.sh "$d/_shared/probes/"
printf 'tiers:\n' > "$d/_shared/tier-policy.yaml"
printf '#!/usr/bin/env bash\nrow "x" PASS "y"\n' > "$d/_shared/probes/verify-standard.sh"
refuses "policy-coverage over zero declared keys" "$d" bash _shared/probes/policy-coverage.sh

# 2. policy-coverage with a probe that emits no rows.
d="$work/norows"; mkdir -p "$d/_shared/probes"
cp _shared/probes/policy-coverage.sh "$d/_shared/probes/"
printf 'defaults: &defaults\n  alfa: required\ntiers:\n' > "$d/_shared/tier-policy.yaml"
printf '#!/usr/bin/env bash\n' > "$d/_shared/probes/verify-standard.sh"
refuses "policy-coverage over zero emitted rows" "$d" bash _shared/probes/policy-coverage.sh

# 3. probe-wiring with no probes to check.
d="$work/noprobes"; mkdir -p "$d/_shared/probes" "$d/scripts"
cp _shared/probes/probe-wiring.sh "$d/scripts/pw.sh"
printf 'gates:\n\t@true\n' > "$d/Makefile"
refuses "probe-wiring over zero probes" "$d" bash scripts/pw.sh _shared/probes

# 4. probe-wiring with no invoker surface at all -- every probe would read as an
#    orphan, which measures the fixture rather than the repo.
d="$work/nosurface"; mkdir -p "$d/_shared/probes"
cp _shared/probes/probe-wiring.sh "$d/_shared/probes/"
printf '#!/usr/bin/env bash\necho x\n' > "$d/_shared/probes/a.sh"
refuses "probe-wiring over zero invoker surfaces" "$d" bash _shared/probes/probe-wiring.sh

# 5. template-digest over an empty vendored list -- a digest of nothing is a
#    constant, and a constant reports "in step" for every future edit forever.
d="$work/novendored"; mkdir -p "$d/scripts" "$d/prod-new/template/scripts"
cp scripts/template-digest.sh "$d/scripts/"
printf 'VENDORED=(\n)\n' > "$d/prod-new/template/scripts/stamp-template-provenance.sh"
refuses "template-digest over an empty vendored list" "$d" bash scripts/template-digest.sh

# 6. template-digest when a declared file does not exist -- hashing what remains
#    yields a value that looks fine and describes a set nobody has.
d="$work/missingvendored"; mkdir -p "$d/scripts" "$d/prod-new/template/scripts"
cp scripts/template-digest.sh "$d/scripts/"
printf 'VENDORED=(\n  scripts/ausente.sh\n)\n' > "$d/prod-new/template/scripts/stamp-template-provenance.sh"
refuses "template-digest over a declared file that is absent" "$d" bash scripts/template-digest.sh

# 7. mutation-baseline with no baseline recorded.
d="$work/nobaseline"; mkdir -p "$d/scripts" "$d/_shared/probes" "$d/benchmarks"
cp scripts/mutation-baseline.sh "$d/scripts/"
printf '#!/usr/bin/env bash\necho "x selftest: ok -- 1 case(s)"\n' > "$d/_shared/probes/x-selftest.sh"
refuses "mutation-baseline with nothing recorded" "$d" bash scripts/mutation-baseline.sh

# 8. mutation-baseline with no selftests to count.
#
#    ISOLATED ON PURPOSE, and this is the case the ratification package cites.
#    The fixture carries a VALID baseline file, so the "nothing to compare
#    against" path cannot fire and the zero-suites guard is the only thing
#    standing between an empty tree and a green report. Every other case here is
#    protected by more than one guard -- measured 2026-08-31 by removing each in
#    turn and watching this test stay green -- which is fine for the property and
#    useless as evidence: a case nothing can break demonstrates nothing.
d="$work/nosuites"; mkdir -p "$d/scripts" "$d/_shared/probes" "$d/benchmarks"
cp scripts/mutation-baseline.sh "$d/scripts/"
printf '# Mutation baseline\n\n| selftest | cases |\n|---|---|\n| `x-selftest.sh` | 1 |\n' \
  > "$d/benchmarks/mutation-baseline.md"
refuses "mutation-baseline over zero suites (isolated)" "$d" bash scripts/mutation-baseline.sh

# 9. gap-report-consistency with no table rows to derive from.
d="$work/notable"; mkdir -p "$d/scripts" "$d/.prod"
cp scripts/gap-report-consistency.sh "$d/scripts/"
printf '# Gap report\n\nsin tablas.\n' > "$d/.prod/gap-report.md"
refuses "gap-report-consistency over zero table rows" "$d" bash scripts/gap-report-consistency.sh

# 10. check-registries when the registries are absent entirely -- distinct from
#     present-and-empty, which is a legal state this repo is IN.
d="$work/noregistries"; mkdir -p "$d/_shared/probes"
cp _shared/probes/check-registries.sh "$d/_shared/probes/"
refuses "check-registries with no registries at all" "$d" bash _shared/probes/check-registries.sh

echo
echo "$ok ok, $failed failed"
(( failed == 0 )) || exit 1
