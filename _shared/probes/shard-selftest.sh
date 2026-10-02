#!/usr/bin/env bash
# shard-selftest.sh -- the verifier of verify-standard.sh's SHARDING:
# `--group <name>` (run one group's rows) and `--merge <files>` (the aggregator).
#
# WHAT MUST HOLD, and why each is a case rather than a comment:
#   A  a full run and (every group + --merge) over the SAME commit emit the SAME
#      rows, in the SAME order, with the SAME verdicts and totals, and the merged
#      evidence record has the full run's shape. Sharding that changes the
#      verdict is worse than no sharding.
#   B  a group run really SKIPS other groups' expensive work: the -race suite runs
#      in group `suite` only, and a spec-named `implemented:` test (the fixture
#      names one) runs in group `dynamic` only. Without this the shards are
#      correct but pointless.
#   C  the merge REFUSES, naming the cause, when: a group is missing; a group
#      appears twice; a row is missing from a file; a row is in two files; an
#      unknown row appears; a row comes from a group that does not own it; the
#      files come from another commit, another tree, another working-tree state
#      (each produced FOR REAL by committing / editing the fixture, not only by
#      editing JSON), or another probe; a file's expected list is stale; a file
#      is not a results file; no file is given.
#   D  the merge is green only at zero FAIL; one FAIL in any one group flips it
#      to INCOMPLETE, exit 1.
#   E  the non-vacuity row (which mutates source) is owned by `dynamic`, once; a
#      second probe on the same checkout REFUSES to run while the lock is held.
#   F  bad flags are refused: an unknown group, --group twice.
#   G  contradictory ownership declarations make the probe refuse to shard: a
#      row gated in two groups, an implemented_row outside dynamic, an unclosed
#      region, a marker on a line that gates a different group, a @shard-rows id
#      that is also literal, a row literal that exists only in a comment.
#   H  a row nobody declared fails CLOSED: it reaches the results and the merge
#      refuses it as unknown, rather than vanishing from every shard.
#
# The fixture is a tiny Go module in a throwaway git repo. Most rows FAIL there
# (no spec, no CI, no registries) -- which is fine: the property under test is
# that sharding reproduces the full run, row for row, whatever the verdicts.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe=""
for c in "${here}/verify-standard.sh" "${here}/../verify-standard.sh"; do [[ -f "$c" ]] && { probe="$c"; break; }; done
[[ -n "$probe" ]] || { echo "shard-selftest: FAIL -- cannot locate verify-standard.sh" >&2; exit 1; }
command -v go >/dev/null && command -v git >/dev/null && command -v python3 >/dev/null || { echo "shard-selftest: FAIL -- go, git and python3 are required" >&2; exit 1; }
REAL_GO="$(command -v go)"; export REAL_GO

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fx="$work/fx"; mkdir -p "$fx/p" "$work/shim" "$work/res"
cat > "$work/shim/go" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == test ]]; then echo "$*" >> "$GO_LOG"; fi
exec "$REAL_GO" "$@"
SH
chmod +x "$work/shim/go"
export GO_LOG="$work/go.log"
# A private TMPDIR: the probe's lock lives there, so case E cannot collide with
# a probe some other process is running on this machine.
export TMPDIR="$work/tmp"; mkdir -p "$TMPDIR"
( cd "$fx" \
  && printf 'module example.com/shfix\n\ngo 1.22\n' > go.mod \
  && printf 'package p\n\nfunc Add(a, b int) int { return a + b }\n' > p/p.go \
  && printf 'package p\n\nimport "testing"\n\nfunc TestAdd(t *testing.T) {\n\tif Add(1, 2) != 3 {\n\t\tt.Fatal("x")\n\t}\n}\n' > p/p_test.go \
  && printf 'tier: 2\nimplemented:\n  bounded_boot: ./p TestAdd\n' > production.yaml \
  && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init ) || { echo "shard-selftest: FAIL -- fixture" >&2; exit 1; }

failures=0; CASES=0; SCEN=0
scenario() { SCEN=$((SCEN+1)); echo "$1"; }
ok() { CASES=$((CASES+1)); echo "  ok   $1"; }
bad() { echo "  FAIL $1" >&2; failures=$((failures+1)); }
runp() { ( cd "$fx" && PATH="$work/shim:$PATH" bash "${PROBE:-$probe}" "$@" ); }
clear_records() { rm -rf "$fx/.prod/evidence"; }

# --- produce: a full run, then every group ---------------------------------------
: > "$GO_LOG"
runp > "$work/full.out" 2>&1
full_rec="$(ls -t "$fx"/.prod/evidence/*.json 2>/dev/null | head -1)"
[[ -n "$full_rec" ]] || { echo "shard-selftest: FAIL -- the full run wrote no evidence record" >&2; tail -5 "$work/full.out" >&2; exit 1; }
cp "$full_rec" "$work/full-record.json"
# Removed so a merge that writes NO record cannot be mistaken for one that wrote
# an identical one (a clean tree names both <sha>.json).
clear_records
groups="$(sed -n 's/^# @shard-groups //p' "$probe" | head -1)"
[[ -n "$groups" ]] || { echo "shard-selftest: FAIL -- no '# @shard-groups' declaration in $probe" >&2; exit 1; }
for g in $groups; do
  : > "$GO_LOG"
  runp --group "$g" --out "$work/res/$g.json" > "$work/g-$g.out" 2>&1
  cp "$GO_LOG" "$work/gotest-$g.log"
done
for g in $groups; do [[ -s "$work/res/$g.json" ]] || { echo "shard-selftest: FAIL -- group '$g' wrote no results file" >&2; tail -5 "$work/g-$g.out" >&2; exit 1; }; done
res_files() { for g in $groups; do echo "$work/res/$g.json"; done; }

scenario "A. full run == every group + merge (same rows, order, verdicts, totals)"
clear_records
# shellcheck disable=SC2046  # one argument per results file is the point
runp --merge $(res_files) > "$work/merge.out" 2>&1; mrc=$?
merged_rec="$(ls -t "$fx"/.prod/evidence/*.json 2>/dev/null | head -1)"
if [[ -z "$merged_rec" ]]; then bad "A the merge wrote no evidence record ($(tail -3 "$work/merge.out" | tr '\n' ' '))"; merged_rec="$work/full-record.json"; fi
if why="$(python3 - "$work/full-record.json" "$merged_rec" <<'PY'
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
la=[(r["dimension"],r["verdict"]) for r in a["probes"]]; lb=[(r["dimension"],r["verdict"]) for r in b["probes"]]
if sorted(la)!=sorted(lb): print("row/verdict multisets differ:", sorted(set(la)^set(lb))[:6]); sys.exit(1)
if la!=lb:
    i=next(k for k,(x,y) in enumerate(zip(la,lb)) if x!=y); print("same rows, different ORDER from position",i,la[i],lb[i]); sys.exit(1)
if a["totals"]!=b["totals"]: print("totals differ", a["totals"], b["totals"]); sys.exit(1)
if set(a)!=set(b): print("record keys differ", set(a)^set(b)); sys.exit(1)
print(len(la))
PY
)"; then ok "A rows, order, verdicts, totals and record shape identical ($why rows)"; else bad "A merged run differs from the full run: $why"; fi
# The verdict line must agree too: same FAIL count means the same exit status.
frc_line="$(grep -E '^VERDICT:' "$work/full.out" | cut -c1-22)"; mrc_line="$(grep -E '^VERDICT:' "$work/merge.out" | cut -c1-22)"
if [[ -n "$frc_line" && "$frc_line" == "$mrc_line" ]]; then ok "A same verdict line as the full run ($mrc_line..., merge exit $mrc)"; else bad "A verdict lines differ: full '$frc_line' merge '$mrc_line'"; fi

scenario "B. a group run skips other groups' expensive work"
for g in $groups; do
  n="$(grep -cE '^test \./\.\.\. .*-race' "$work/gotest-$g.log" 2>/dev/null || true)"; n="${n:-0}"
  if [[ "$g" == suite ]]; then
    if (( n >= 1 )); then ok "B suite group ran the -race suite"; else bad "B suite group never ran go test ./... -race"; fi
  else
    if (( n == 0 )); then ok "B group '$g' did NOT run the -race suite"; else bad "B group '$g' ran the Go suite ($n time(s)) -- the shard saves nothing"; fi
  fi
done

for g in $groups; do
  n="$(grep -cF -- '-run ^TestAdd$' "$work/gotest-$g.log" 2>/dev/null || true)"; n="${n:-0}"
  if [[ "$g" == dynamic ]]; then
    if (( n >= 1 )); then ok "B dynamic group executed the spec-named implemented test"; else bad "B dynamic group never executed the implemented: test"; fi
  else
    if (( n == 0 )); then ok "B group '$g' did NOT execute the implemented: test"; else bad "B group '$g' executed the implemented: test ($n time(s))"; fi
  fi
done

# --- C/D: crafted result sets -----------------------------------------------------
mut() { # mut <name> <python-body operating on dict `docs` {group: doc}>  -> dir $work/m-<name>
  local d="$work/m-$1"; rm -rf "$d"; mkdir -p "$d"; cp "$work"/res/*.json "$d/"
  python3 - "$d" "$groups" <<PY
import json,sys,os
d,groups=sys.argv[1],sys.argv[2].split()
docs={g:json.load(open(f"{d}/{g}.json")) for g in groups}
$2
for g in groups:
    if g in docs and docs[g] is not None: json.dump(docs[g],open(f"{d}/{g}.json","w"))
PY
}
refused() { # refused <label> <needle> <files...>
  local label="$1" needle="$2"; shift 2
  clear_records
  local out rc; out="$(runp --merge "$@" 2>&1)"; rc=$?
  if (( rc != 0 )) && grep -qF -- "MERGE REFUSED" <<<"$out" && grep -qF -- "$needle" <<<"$out" \
     && ! ls "$fx"/.prod/evidence/*.json >/dev/null 2>&1; then ok "$label"
  else bad "$label: rc=$rc, wanted a refusal naming '$needle' and no record (got: $(grep -m3 -E 'REFUSED|^  - ' <<<"$out" | tr '\n' ' '))"; fi
}
scenario "C. the merge refuses, naming the cause"
d="$work/m-missing"; rm -rf "$d"; mkdir -p "$d"; cp "$work"/res/*.json "$d/"; rm -f "$d/static.json"
refused "C a missing group" "group 'static' is MISSING" "$d"/*.json
d="$work/m-dupgroup"; rm -rf "$d"; mkdir -p "$d"; cp "$work"/res/*.json "$d/"; cp "$d/suite.json" "$d/suite-again.json"
refused "C a group present twice" "group 'suite' appears 2 times" "$d"/*.json
mut droprow 'docs["fuzzbench"]["rows"]=[r for r in docs["fuzzbench"]["rows"] if r["dimension"]!="fuzz"]'
refused "C a row missing from its group's file" "declared row 'fuzz' (group fuzzbench) is missing" "$work/m-droprow"/*.json
mut dupro 'r=dict([x for x in docs["suite"]["rows"] if x["dimension"]=="build"][0]); docs["static"]["rows"].append(r)'
refused "C a row in two files" "row 'build' appears in 2 files" "$work/m-dupro"/*.json
mut unknown 'docs["static"]["rows"].append({"dimension":"made-up-row","verdict":"PASS","evidence":"x","line":1,"seq":999})'
refused "C an unknown row" "unknown row 'made-up-row'" "$work/m-unknown"/*.json
mut wronggrp 'r=[x for x in docs["fuzzbench"]["rows"] if x["dimension"]=="fuzz"][0]; docs["fuzzbench"]["rows"].remove(r); docs["static"]["rows"].append(r)'
refused "C a row from a group that does not own it" "row 'fuzz' came from group 'static'" "$work/m-wronggrp"/*.json
mut probe 'docs["dynamic"]["probe_sha256"]="0"*64'
refused "C results written by a different probe" "written by a different probe" "$work/m-probe"/*.json
mut skew 'docs["suite"]["expected"]=docs["suite"]["expected"][1:]'
refused "C a stale expected-id list" "expected-id list does not match" "$work/m-skew"/*.json
mut commit 'docs["suite"]["commit"]="0"*40'
refused "C (crafted) a different commit" "results from a different commit" "$work/m-commit"/*.json
mut schema 'docs["suite"]["schema"]=1'
refused "C valid JSON of another schema" "not a verify-standard schema-2 results file" "$work/m-schema"/*.json
printf 'not json\n' > "$work/garbage.json"
# shellcheck disable=SC2046
refused "C a file that is not a results file" "not a verify-standard schema-2 results file" "$work/garbage.json" $(res_files)
refused "C no files at all" "no result files given"
# FOR REAL: the shards ran on commit C1; change the checkout, then merge there.
c1="$(git -C "$fx" rev-parse HEAD)"
printf '\n// drift\n' >> "$fx/p/p.go"
# shellcheck disable=SC2046
refused "C (real) an uncommitted edit since the shards ran" "differs from this checkout's dirty" $(res_files)
git -C "$fx" -c user.email=t@t -c user.name=t commit -qam drift
clear_records
# shellcheck disable=SC2046
out="$(runp --merge $(res_files) 2>&1)"; rc=$?
if (( rc != 0 )) && grep -qF "results from a different commit" <<<"$out" && grep -qF "results from a different tree" <<<"$out"; then ok "C (real) a later commit with a different tree: both named"
else bad "C (real) later commit: rc=$rc ($(grep -m3 -E 'REFUSED|^  - ' <<<"$out" | tr '\n' ' '))"; fi
git -C "$fx" reset -q --hard "$c1"
# Same tree, another commit (an empty commit): the commit check alone must fire.
git -C "$fx" -c user.email=t@t -c user.name=t commit -q --allow-empty -m empty
clear_records
# shellcheck disable=SC2046
out="$(runp --merge $(res_files) 2>&1)"; rc=$?
if (( rc != 0 )) && grep -qF "results from a different commit" <<<"$out" && ! grep -qF "results from a different tree" <<<"$out"; then ok "C (real) same tree, another commit: commit named, tree not"
else bad "C (real) empty commit: rc=$rc ($(grep -m3 -E 'REFUSED|^  - ' <<<"$out" | tr '\n' ' '))"; fi
git -C "$fx" reset -q --hard "$c1"

scenario "D. green only at zero FAIL"
mut allpass 'for g in docs:
    for r in docs[g]["rows"]:
        if r["verdict"]=="FAIL": r["verdict"]="PASS"; r["evidence"]=r["evidence"] or "x"'
clear_records
out="$(runp --merge "$work/m-allpass"/*.json 2>&1)"; rc=$?
if (( rc == 0 )) && grep -q 'VERDICT: COMPLETE' <<<"$out" && grep -qE 'FAIL 0 ' <<<"$out" && ls "$fx"/.prod/evidence/*.json >/dev/null 2>&1; then ok "D zero FAIL -> COMPLETE, exit 0, record written"; else bad "D all-PASS merge: rc=$rc ($(tail -3 <<<"$out" | tr '\n' ' '))"; fi
for g in $groups; do
  mut "onefail-$g" "for x in docs:
    for r in docs[x]['rows']:
        if r['verdict']=='FAIL': r['verdict']='PASS'; r['evidence']=r['evidence'] or 'x'
docs['$g']['rows'][0]['verdict']='FAIL'"
  clear_records
  out="$(runp --merge "$work/m-onefail-$g"/*.json 2>&1)"; rc=$?
  if (( rc == 1 )) && grep -q 'VERDICT: INCOMPLETE' <<<"$out" && grep -qE 'FAIL 1 ' <<<"$out"; then ok "D one FAIL in group '$g' -> INCOMPLETE, exit 1"; else bad "D one FAIL in '$g': rc=$rc ($(tail -2 <<<"$out" | tr '\n' ' '))"; fi
done

scenario "E. non-vacuity is owned by dynamic, once; one checkout never runs two probes"
owners_of_nv="$(python3 - "$work/res" "$groups" <<'PY'
import json,sys
d,groups=sys.argv[1],sys.argv[2].split()
print(" ".join(g for g in groups if "invariants-non-vacuity" in json.load(open(f"{d}/{g}.json"))["expected"]))
PY
)"
if [[ "$owners_of_nv" == dynamic ]]; then ok "E invariants-non-vacuity is expected of exactly one group: dynamic"; else bad "E invariants-non-vacuity expected of: '$owners_of_nv'"; fi
lock="$TMPDIR/prod-probe-$(cd "$fx" && pwd -P | shasum | cut -c1-12).lock"
mkdir "$lock"
out="$(PROBE_LOCK_TRIES=1 runp --group static --out "$work/locked.json" 2>&1)"; rc=$?
if (( rc == 2 )) && grep -qF "refusing to run beside it" <<<"$out" && [[ ! -e "$work/locked.json" ]] && [[ -d "$lock" ]]; then ok "E a held lock -> exit 2, nothing run, the holder's lock left in place"
else bad "E held lock: rc=$rc, results written: $([[ -e "$work/locked.json" ]] && echo yes || echo no), lock still there: $([[ -d "$lock" ]] && echo yes || echo no)"; fi
rmdir "$lock" 2>/dev/null

scenario "F. bad flags are refused"
out="$(runp --group bogus 2>&1)"; rc=$?
if (( rc == 2 )) && grep -q "unknown group 'bogus'" <<<"$out"; then ok "F --group bogus -> exit 2, names the known groups"; else bad "F --group bogus: rc=$rc"; fi
out="$(runp --group suite --group static 2>&1)"; rc=$?
if (( rc == 2 )) && grep -q "given twice" <<<"$out"; then ok "F --group twice -> exit 2 (one invocation runs ONE group)"; else bad "F --group twice: rc=$rc"; fi

scenario "G. contradictory ownership declarations refuse to shard"
pdir="$work/probe-copy"; mkdir -p "$pdir"
declared() { # declared <label> <needle> <python edit of `s`>
  local label="$1" needle="$2"
  python3 - "$probe" "$pdir/verify-standard.sh" <<PY || { bad "$label: the edit did not apply"; return; }
import sys
s=open(sys.argv[1]).read()
orig=s
$3
assert s!=orig, "edit matched nothing"
open(sys.argv[2],"w").write(s)
PY
  local out rc; out="$(PROBE="$pdir/verify-standard.sh" runp --group static --out "$work/decl.json" 2>&1)"; rc=$?
  if (( rc == 2 )) && grep -qF "refusing to shard" <<<"$out" && grep -qF -- "$needle" <<<"$out"; then ok "$label"
  else bad "$label: rc=$rc ($(grep -m2 -E 'shard declarations|refusing' <<<"$out" | tr '\n' ' '))"; fi
}
# Anchored at a line START: the SHARDING comment quotes the same marker text.
sg='\nif shard_run suite; then   # @shard-begin suite\n'
declared "G a row gated in two groups" "is in gated regions of BOTH" \
  "s=s.replace('$sg','$sg'+'row \"fuzz\" PASS \"x\"\n',1)"
declared "G implemented_row inside a non-dynamic region" "only runs in group dynamic" \
  "s=s.replace('$sg','$sg'+'implemented_row \"made-up-impl\" k\n',1)"
declared "G a region never closed" "never closed" \
  "i=s.rindex('fi   # @shard-end'); s=s[:i]+'fi'+s[i+len('fi   # @shard-end'):]"
declared "G a marker that gates a different group" "must sit on exactly" \
  "s=s.replace('\\nif shard_run suite; then   # @shard-begin suite','\\nif shard_run static; then   # @shard-begin suite',1)"
declared "G a @shard-rows id that is also literal" "literal AND declared" \
  "s=s.replace('# @shard-rows static cheap-gate','# @shard-rows static build cheap-gate',1)"
declared "G a row literal only in a comment (derivation parity)" "differ from the full run" \
  "s=s.replace('# @shard-groups ','# a comment naming row \"comment-only-row\"\n# @shard-groups ',1)"

scenario "H. an undeclared row fails closed"
python3 - "$probe" "$pdir/verify-standard.sh" <<'PY'
import sys
s=open(sys.argv[1]).read()
anchor='# --- 1. build + tests'
assert anchor in s
s=s.replace(anchor,'_undeclared_id="undeclared-x"; row "$_undeclared_id" PASS "emitted under a variable name"\n'+anchor,1)
open(sys.argv[2],"w").write(s)
PY
mkdir -p "$work/res-h"
for g in $groups; do PROBE="$pdir/verify-standard.sh" runp --group "$g" --out "$work/res-h/$g.json" >/dev/null 2>&1; done
n_in="$(python3 -c "import json,sys;print(sum(any(r['dimension']=='undeclared-x' for r in json.load(open(f))['rows']) for f in sys.argv[1:]))" "$work"/res-h/*.json)"
clear_records
out="$(PROBE="$pdir/verify-standard.sh" runp --merge "$work"/res-h/*.json 2>&1)"; rc=$?
if (( rc != 0 )) && grep -qF "unknown row 'undeclared-x'" <<<"$out" && [[ "$n_in" -ge 1 ]]; then ok "H an undeclared variable-named row reaches $n_in shard(s) and the merge refuses it"
else bad "H undeclared row: rc=$rc, in $n_in shard(s) ($(grep -m2 -E 'REFUSED|^  - ' <<<"$out" | tr '\n' ' '))"; fi

if [[ "$failures" -ne 0 ]]; then echo "shard-selftest: FAIL -- ${failures} assertion(s) failed" >&2; exit 1; fi
echo "shard-selftest: PASS -- ${CASES} case(s) over ${SCEN} scenarios against the probe's real sharding"
