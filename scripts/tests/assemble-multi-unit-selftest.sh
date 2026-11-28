#!/usr/bin/env bash
# assemble-multi-unit-selftest.sh -- scripts/assemble.py builds a monorepo with MORE THAN ONE unit
# (--unit MODULE:ID[,K=V...]). Scratch modules in a temp --modules-dir; the real service-go only for the
# non-regression diff against the previous assembler and the wrapper. Hermetic, sequential, no network.
# ASSEMBLE=<path> runs another copy of the assembler (mutation proofs). Exit: 0 ok - 1 a case failed - 2 no case ran.
# Final line: "<N> ok, <M> failed[, K skipped]".
# derived-from: the assemble.py header (UNIT INSTANCES, REPO INVENTORY) -- candidate, pinning: false, ttl: 2027-06-30
set -uo pipefail
umask 022

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
asm="${ASSEMBLE:-$here/scripts/assemble.py}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/assemble-multi.XXXXXX")" || exit 2
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
mods="$tmp/mods"; out="$tmp/out"; mkdir -p "$mods" "$out"

ok=0; bad=0; skipped=0
pass() { ok=$((ok + 1)); echo "ok   $1"; }
fail() { bad=$((bad + 1)); echo "FAIL $1${2:+ -- $2}"; }
A() { python3 -I -B "$asm" --modules-dir "$mods" "$@"; }

# mk <id> <json-without-id/source> <file>...: a scratch module (source "."), files as path=content (\n expanded)
mk() {
  local id="$1" json="$2" f; shift 2
  mkdir -p "$mods/$id"
  printf '{"id":"%s","source":".",%s}\n' "$id" "$json" >"$mods/$id/module.json"
  for f in "$@"; do mkdir -p "$mods/$id/$(dirname "${f%%=*}")"; printf '%b' "${f#*=}" >"$mods/$id/${f%%=*}"; done
}
SL='"slots":{"SERVICE":"unit name","OWNER":"owner"}'
U='"unit":{"kind":"service","language":"go"}'
mk svc "$SL,$U,\"placement\":{\"README.md\":\"unit\",\"cmd/**\":\"unit\",\"LICENSE\":\"root\"}" \
  'README.md=svc <SERVICE> owner <OWNER>\n' 'cmd/<SERVICE>/main.go=package <SERVICE>\n// <OWNER>\n' 'LICENSE=MIT\n'
mk svcnk "$SL,\"placement\":{\"README.md\":\"unit\"}" 'README.md=<SERVICE> <OWNER>\n'
mk svcx '"slots":{"SERVICE":"unit name","OWNER":"owner","EXTRA":"extra"},"placement":{"README.md":"unit"}' 'README.md=<SERVICE> <OWNER> <EXTRA>\n'
mk svcnarrow '"slots":{"SERVICE":{"charset":"lower-digits-dash","max_len":8},"OWNER":"owner"},"placement":{"README.md":"unit"}' 'README.md=<SERVICE> <OWNER>\n'
mk svcci "$SL,$U,\"placement\":{\"README.md\":\"unit\",\"ci.yml\":\"root\"}" 'README.md=<SERVICE>\n' 'ci.yml=name: ci <SERVICE>\n'
mk svcm "$SL,$U,\"placement\":{\"README.md\":\"unit\",\".gitignore\":\"root\"},\"root_merge\":{\".gitignore\":\"union-lines\"}" \
  'README.md=<SERVICE>\n' '.gitignore=common\n<SERVICE>-bin\n'
mk dbm '"slots":{"OWNER":"owner"},"unit":{"kind":"database","language":"sql"},"placement":{"schema.sql":"unit"}' 'schema.sql=-- <OWNER>\n'
mk pkgm "$SL,\"unit\":{\"kind\":\"package\",\"language\":\"ts\"},\"placement\":{\"README.md\":\"unit\"}" 'README.md=<SERVICE> <OWNER>\n'
mk lnk "$SL,\"placement\":{\"README.md\":\"unit\",\"ln.txt\":\"unit\"}" 'README.md=<SERVICE>\n'
ln -s ../b/README.md "$mods/lnk/ln.txt"
mk lnkok "$SL,\"placement\":{\"README.md\":\"unit\",\"ln.txt\":\"unit\"}" 'README.md=<SERVICE>\n'
ln -s ../../README.md "$mods/lnkok/ln.txt"
RY='# header\nversion: v2\nrepo:\n  name: <REPO>\n  layout: monorepo\nunits: []\n'
RS='"slots":{"REPO":"repo name"},"placement":{"repo.yaml":"root"}'
mk rr "$RS" "repo.yaml=$RY"
mk rrnone "$RS" 'repo.yaml=version: v2\nrepo: <REPO>\n'
mk rrcomment "$RS" 'repo.yaml=# units: []\nunits: {}\nrepo: <REPO>\n'
mk rrtwo "$RS" 'repo.yaml=units: []\nunits: []\nrepo: <REPO>\n'
mk rrindent "$RS" 'repo.yaml=repo: <REPO>\n units: []\n'

# run <name> <rc> <stderr-grep|-> <args...>: exit class, message, and (rc != 0) nothing written, no .assemble-* left
D=""
run() {
  local name="$1" want="$2" pat="$3" rc; shift 3
  D="$out/$name"
  A --dest "$D" "$@" >"$out/$name.out" 2>"$out/$name.err"; rc=$?
  if [[ $rc -ne $want ]]; then fail "$name" "exit $rc, want $want: $(head -c 200 "$out/$name.err")"; return 1; fi
  if [[ "$pat" != "-" ]] && ! grep -Eq -- "$pat" "$out/$name.err"; then fail "$name" "stderr lacks /$pat/: $(head -c 200 "$out/$name.err")"; return 1; fi
  if [[ $want -ne 0 ]]; then
    if [[ -e "$D" ]] || compgen -G "$out/.assemble-*" >/dev/null; then fail "$name" "something was left behind"; return 1; fi
  fi
  return 0
}
has() { [[ "$(cat "$1" 2>/dev/null)" == "$2" ]]; }   # <file> <exact content without the trailing newline>

# 1. two instances of one module: right substitution, no cross-contamination
if run c1 0 - --layout monorepo --unit svc:a --unit svc:b,OWNER=other --slot OWNER=acme \
  && has "$D/services/a/README.md" "svc a owner acme" && has "$D/services/b/README.md" "svc b owner other" \
  && has "$D/services/a/cmd/a/main.go" $'package a\n// acme' && has "$D/services/b/cmd/b/main.go" $'package b\n// other' \
  && ! grep -rq other "$D/services/a" && ! grep -rq acme "$D/services/b" && [[ "$(grep -rl . "$D" | grep -c LICENSE)" == 1 ]]; then
  pass "1: two instances, own dirs, own OWNER, nothing crosses, shared LICENSE written once; per-instance slot beats global"
else fail "1: two instances" "$(find "$D" -type f 2>/dev/null | tr '\n' ' ')"; fi

# 2. missing slot for one instance names the instance; the unit slot cannot be overridden; an undeclared K is refused
run c2a 2 'svcx\[b\].*EXTRA' --layout monorepo --unit svcx:a,EXTRA=1 --unit svcx:b --slot OWNER=o && pass "2: slot missing for one instance: exit 2, instance named" || true
run c2b 2 'unit slot' --layout monorepo --unit svc:a,SERVICE=z --slot OWNER=o && pass "2: overriding the unit slot: exit 2" || true
run c2c 2 'does not declare slot NOPE' --layout monorepo --unit svc:a,NOPE=z --slot OWNER=o && pass "2: slot the module does not declare: exit 2" || true
run c2d 2 'charset' --layout monorepo --unit svcnarrow:Abc --slot OWNER=o && pass "2: module narrowing (charset) applies to the unit id" || true

# 3. duplicate / case-only / equal dirs: exit 2, nothing written
run c3a 2 'same id' --layout monorepo --unit svc:a --unit svc:a --slot OWNER=o && pass "3: duplicate id refused" || true
run c3b 2 'same id' --layout monorepo --unit svc:foo --unit svc:FOO --slot OWNER=o && pass "3: ids differing only by case refused" || true
run c3c 2 'same id' --layout monorepo --unit svc:a --unit svcnk:A --slot OWNER=o && pass "3: same id in two modules refused" || true
run c3d 2 'share the unit directory' --layout monorepo --unit dbm:x --unit dbm:y --slot OWNER=o && pass "3: two instances with equal unit dirs (database kind) refused" || true
run c3e 2 'share the unit directory' --layout single --unit svc:a --unit svc:b --slot OWNER=o && pass "3: layout single: two units share the root, refused" || true
run c3f 2 'share the unit directory' --layout monorepo --module svc --unit svc:b --slot SERVICE=b --slot OWNER=o && pass "3: --module and --unit at one dir refused" || true
if python3 -I -B - "$asm" <<'PY'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("asm", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
c = m.dirs_clash
assert c("services/a", "services/a") and c("", "services/a") and c("services/a", "") and c("Services/A", "services/a")
assert c("services/a", "services/a/b") and c("services/a/b", "services/a") and c("é", "é")
assert not c("services/a", "services/ab") and not c("services/a", "services/b") and not c("db", "services/db")
PY
then pass "3: unit directories equal or nested (case, NFC, ancestor, descendant) clash; siblings and prefixes do not"
else fail "3: dirs_clash"; fi

# 4. --module and --unit mixed; --module alone is byte-identical to the previous assembler
if run c4a 0 - --layout monorepo --module svc --unit svc:b --slot SERVICE=a --slot OWNER=o && has "$D/services/a/README.md" "svc a owner o" && has "$D/services/b/README.md" "svc b owner o"; then
  pass "4: --module (global slots) and --unit mixed"
else fail "4: mixed"; fi
base="$tmp/assemble-base.py"
if git -C "$here" show origin/master:scripts/assemble.py >"$base" 2>/dev/null && [[ -s "$base" ]]; then
  modes() { (cd "$1" && find . -exec ls -ld {} + | awk '{print substr($1,1,10), $NF}' | LC_ALL=C sort); }
  same=1; why=""
  for lay in single monorepo; do
    python3 -I -B "$base" --modules-dir "$here/prod-new/modules" --dest "$tmp/nb-$lay" --layout "$lay" --module service-go --slot SERVICE=payments --slot OWNER=acme >/dev/null 2>&1 || { same=0; why="base failed $lay"; }
    python3 -I -B "$asm" --modules-dir "$here/prod-new/modules" --dest "$tmp/nn-$lay" --layout "$lay" --module service-go --slot SERVICE=payments --slot OWNER=acme >/dev/null 2>&1 || { same=0; why="new failed $lay"; }
    diff -r "$tmp/nb-$lay" "$tmp/nn-$lay" >/dev/null 2>&1 || { same=0; why="diff -r $lay"; }
    [[ "$(modes "$tmp/nb-$lay")" == "$(modes "$tmp/nn-$lay")" ]] || { same=0; why="modes $lay"; }
  done
  python3 -I -B "$asm" --modules-dir "$here/prod-new/modules" --dest "$tmp/nu" --layout monorepo --unit service-go:payments --slot OWNER=acme >/dev/null 2>&1
  diff -r "$tmp/nb-monorepo" "$tmp/nu" >/dev/null 2>&1 || { same=0; why="--unit vs --module"; }
  [[ $same -eq 1 && -f "$tmp/nn-monorepo/services/payments/go.mod" ]] && pass "4: real service-go, single and monorepo: tree and modes identical to origin/master's assembler; --unit equals --module" || fail "4: non-regression" "$why"
else skipped=$((skipped + 1)); echo "skip 4: origin/master:scripts/assemble.py is not available here"; fi

# 5. root files from several instances
run c5a 0 - --layout monorepo --unit svcm:a --unit svcm:b --slot OWNER=o && has "$D/.gitignore" $'common\na-bin\nb-bin' && pass "5: root_merge union-lines by every contributor: merged once, no repeated line" || fail "5: merge" "$(cat "$D/.gitignore" 2>/dev/null | tr '\n' '|')"
run c5b 1 'ci\.yml.*svcci\[a\].*svcci\[b\]|ci\.yml.*svcci\[b\].*svcci\[a\]' --layout monorepo --unit svcci:a --unit svcci:b --slot OWNER=o && grep -q 'per-unit file at the root' "$out/c5b.err" && pass "5: slot-dependent root file from two instances: exit 1, path and both unit ids named, per-unit message" || fail "5: conflict message" "$(head -c 200 "$out/c5b.err")"
run c5c 0 - --layout monorepo --unit svcci:a --slot OWNER=o && has "$D/ci.yml" "name: ci a" && pass "5: the same module once is no conflict" || true

# 6. every security rule per instance
zw="$(printf 'a\xe2\x80\x8bb')"
n=0; allok=1
for id in .git .GIT a. "$zw" 'git~1' a:b '.git:x' 'a b'; do
  n=$((n + 1))
  run "c6id$n" 2 - --layout monorepo --unit svc:ok --unit "svc:$id" --slot OWNER=o || allok=0
done
[[ $allok -eq 1 ]] && pass "6: a unit id that is or reaches .git (any case, trailing dot, zero-width, git~1, colon) or has a space: exit 2, nothing written" || fail "6: reserved unit ids"
allok=1; n=0
for v in .. /abs a/b ../x; do
  n=$((n + 1))
  run "c6sl$n" 2 - --layout monorepo --unit svc:a,OWNER="$v" --slot OWNER=o || allok=0
done
[[ $allok -eq 1 ]] && pass "6: a per-instance slot value escaping the unit dir (.., absolute, with /): exit 2, nothing written" || fail "6: slot escape"
run c6l 1 'couples' --layout monorepo --unit lnk:a --unit lnk:b --slot OWNER=o && pass "6: a link from one unit into another unit's directory: refused (exit 1), nothing written" || true
run c6k 0 - --layout monorepo --unit lnkok:a --unit lnkok:b --slot OWNER=o && [[ -L "$D/services/a/ln.txt" ]] && pass "6: a link that leaves for the repo root stays allowed" || fail "6: link control"

# 7. repo.yaml inventory
want="$(printf '# header\nversion: v2\nrepo:\n  name: demo\n  layout: monorepo\nunits:\n  - { id: "main", kind: "database", language: "sql", path: "db" }\n  - { id: "ui", kind: "package", language: "ts", path: "packages/ui" }\n  - { id: "a", kind: "service", language: "go", path: "services/a" }\n  - { id: "b", kind: "service", language: "go", path: "services/b" }')"
if run c7a 0 - --layout monorepo --unit svc:b --unit dbm:main --unit svc:a --unit pkgm:ui --module rr --slot REPO=demo --slot OWNER=o && has "$D/repo.yaml" "$want"; then
  pass "7: repo.yaml entries exact (id, kind, language, path), sorted by path"
else fail "7: repo.yaml" "$(cat "${D:-/nonexistent}/repo.yaml" 2>/dev/null | tail -n 5 | tr '\n' '|')"; fi
specials=(true null yes 123 1e3 a.b a_b 0x1f off)
args=(); for s in "${specials[@]}"; do args+=(--unit "svc:$s"); done
if run c7b 0 - --layout monorepo "${args[@]}" --module rr --slot REPO=demo --slot OWNER=o; then
  sp=1; for s in "${specials[@]}"; do grep -qxF "  - { id: \"$s\", kind: \"service\", language: \"go\", path: \"services/$s\" }" "$D/repo.yaml" || sp=0; done
  [[ $sp -eq 1 ]] && pass "7: ids true/null/yes/123/1e3/0x1f/off/a.b/a_b are emitted double-quoted" || fail "7: quoting" "$(tail -n 3 "$D/repo.yaml")"
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -I -B - "$D/repo.yaml" "${specials[@]}" <<'PY' && pass "7: PyYAML loads every id as a string, paths as services/<id>" || fail "7: PyYAML"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
u = d["units"]
assert sorted(x["id"] for x in u) == sorted(sys.argv[2:]) and all(type(x["id"]) is str for x in u)
assert all(set(x) == {"id", "kind", "language", "path"} for x in u) and d["version"] == "v2"
PY
  else skipped=$((skipped + 1)); echo "skip 7: PyYAML is not importable (line-shape assertions above stand in)"; fi
fi
run c7c 2 'svcnk.*declares no .unit' --layout monorepo --unit svcnk:a --module rr --slot REPO=demo --slot OWNER=o && pass "7: unit files but no kind/language declared (repo.yaml present): exit 2, module named" || true
run c7d 0 - --layout monorepo --unit svcnk:a --slot OWNER=o && pass "7: no repo.yaml contributed: no kind needed, nothing generated" || true
run c7e 2 'exactly one line' --layout monorepo --unit svc:a --module rrnone --slot REPO=d --slot OWNER=o && pass "7: repo.yaml without a units: [] line: exit 2" || true
run c7f 2 'exactly one line' --layout monorepo --unit svc:a --module rrcomment --slot REPO=d --slot OWNER=o && pass "7: only a comment holding units: [] (no exact line): exit 2" || true
run c7g 2 'exactly one line' --layout monorepo --unit svc:a --module rrtwo --slot REPO=d --slot OWNER=o && pass "7: two units: [] lines: exit 2" || true
run c7h 2 'exactly one line' --layout monorepo --unit svc:a --module rrindent --slot REPO=d --slot OWNER=o && pass "7: an indented units: [] is not column 0: exit 2" || true
run c7i 0 - --layout monorepo --module rr --slot REPO=demo && has "$D/repo.yaml" "$(printf '# header\nversion: v2\nrepo:\n  name: demo\n  layout: monorepo\nunits: []')" && pass "7: no unit instance: units: [] untouched" || fail "7: empty inventory"
run c7j 0 - --layout single --unit svc:a --module rr --slot REPO=demo --slot OWNER=o && grep -qx 'units: \[\]' "$D/repo.yaml" && pass "7: layout single never generates the inventory" || fail "7: single"

# 8. atomicity and signals with two instances
mk svcbad "$SL,\"placement\":{\"README.md\":\"unit\"}" 'README.md=<SERVICE>\n' 'extra.txt=x\n'
run c8a 1 'unplaced: extra.txt' --layout monorepo --unit svc:a --unit svcbad:b --slot OWNER=o && pass "8: a failure in the SECOND instance leaves no dest and no temp dir" || true
cat >"$tmp/drv.py" <<'PY'
import importlib.util, os, signal, sys
sp = importlib.util.spec_from_file_location("asm", sys.argv[1]); asm = importlib.util.module_from_spec(sp); sp.loader.exec_module(asm)
real = asm.write_tree
def wt(*a, **k):
    real(*a, **k)            # both instances fully written into the temp tree, then the TERM
    os.kill(os.getpid(), signal.SIGTERM)
asm.write_tree = wt
sys.argv = ["assemble.py"] + sys.argv[2:]
asm.main()
PY
python3 -I -B "$tmp/drv.py" "$asm" --modules-dir "$mods" --dest "$out/c8b" --layout monorepo --unit svc:a --unit svc:b --slot OWNER=o >/dev/null 2>"$out/c8b.err"; rc=$?
if [[ $rc -eq 143 && ! -e "$out/c8b" ]] && ! compgen -G "$out/.assemble-*" >/dev/null && grep -q interrupted "$out/c8b.err"; then
  pass "8: SIGTERM after both instances were written: exit 143, no dest, no temp dir"
else fail "8: SIGTERM" "rc=$rc temp dirs: $(compgen -G "$out/.assemble-*" | wc -l)"; fi

# 9. the wrapper keeps working
if bash "$here/scripts/instantiate-template.sh" "$tmp/wrap" payments acme >/dev/null 2>"$tmp/wrap.err" && [[ -f "$tmp/wrap/go.mod" && -f "$tmp/wrap/cmd/payments/main.go" ]]; then
  pass "9: scripts/instantiate-template.sh (one invocation) still assembles service-go"
else fail "9: wrapper" "$(head -c 200 "$tmp/wrap.err")"; fi

echo "$ok ok, $bad failed${skipped:+, $skipped skipped}" | sed 's/, 0 skipped//'
[[ $((ok + bad)) -gt 0 ]] || exit 2
[[ $bad -eq 0 ]]
