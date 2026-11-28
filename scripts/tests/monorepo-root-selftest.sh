#!/usr/bin/env bash
# monorepo-root-selftest.sh -- the monorepo-root module, assembled for real with the design-system and a
# service module, then its settings check, its root Makefile and its repo.yaml schema, one RED case per rule.
# Hermetic, sequential, no network. Needs python3 with PyYAML (PYTHON=<interpreter> to choose one; the
# script takes the first of python3, python3.14, python3.13, python3.12 that imports yaml, else exits 2).
# MOD_SRC=<dir> tests another copy of the module (mutation proofs). Final line: `<N> ok, <M> failed[, K skipped]`.
# Exit: 0 all ok - 1 a case failed - 2 cannot run.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mods="$here/prod-new/modules"
modsrc="${MOD_SRC:-$mods/monorepo-root}"
asm="$here/scripts/assemble.py"

py=""
for c in "${PYTHON:-}" python3 python3.14 python3.13 python3.12; do
  [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' 2>/dev/null && { py="$c"; break; }
done
[[ -n "$py" ]] || { echo "FAIL: no python3 with PyYAML found (CI installs PyYAML==6.0.2); set PYTHON=" >&2; exit 2; }
export PYTHON="$py"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/monorepo-root.XXXXXX")" || exit 2
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
export TMPDIR="$tmp" HOME="$tmp/home"; mkdir -p "$HOME"

ok=0; bad=0; skipped=0
pass() { ok=$((ok + 1)); echo "ok   $1"; }
fail() { bad=$((bad + 1)); echo "FAIL $1${2:+ -- $2}"; }
skip() { skipped=$((skipped + 1)); echo "SKIP $1 -- $2"; }

# expect <name> <rc> <egrep pattern> <command...>: the command exits <rc> and its output matches the pattern
expect() {
  local name="$1" want="$2" pat="$3" out rc; shift 3
  out="$("$@" 2>&1)"; rc=$?
  if [[ $rc -ne $want ]]; then fail "$name" "exit $rc, want $want: $(head -c 240 <<<"$out")"
  elif [[ -n "$pat" ]] && ! grep -Eq -- "$pat" <<<"$out"; then fail "$name" "output lacks /$pat/: $(head -c 240 <<<"$out")"
  else pass "$name"; fi
}
check() { bash "$1/scripts/monorepo-settings-check.sh" "$1"; }
jedit() { "$py" -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));exec(sys.argv[2]);json.dump(d,open(p,"w"),indent=2)' "$1" "$2"; }
fresh() { cp -R "$D" "$tmp/c-$1" && echo "$tmp/c-$1"; }
lineno() { grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1; }

# ---- scratch module directory: the real module under test + design-system + service-python
S="$tmp/mods"; mkdir -p "$S"
cp -R "$modsrc" "$S/monorepo-root"
for m in design-system service-python; do
  mkdir -p "$S/$m"; (cd "$mods/$m" && tar --exclude node_modules --exclude dist --exclude __pycache__ --exclude .venv -cf - .) | (cd "$S/$m" && tar xf -)
done
# The design-system module as it must be once it sits under this root (follow-up for its owner): it does not
# place the root files this module owns, and its packages take versions from the catalog.
# Its manifest also carries keys assemble.py does not know (description, lands_at, notes, a slot `example`), lacks `source` and has a README.md that nothing places, places packages/** as `unit` (which lands under services/<SERVICE>): fixed here.
jedit "$S/design-system/module.json" 'd["exclude"]=["package.json","pnpm-workspace.yaml","pnpm-lock.yaml","tsconfig.base.json",".npmrc",".gitignore","README.md"]
for k in ("description","lands_at","notes"): d.pop(k,None)
d["source"]="."
d["placement"]["packages/**"]="root"
d["slots"]["SCOPE"].pop("example",None)'
for p in tokens theme; do
  jedit "$S/design-system/packages/$p/package.json" '
for f in ("dependencies","devDependencies"):
    for k,v in list(d.get(f,{}).items()):
        if v!="workspace:*": d[f][k]="catalog:"'
done

A() { "$py" -I -B "$asm" --modules-dir "$S" "$@"; }
D="$tmp/repo"
expect "assemble monorepo-root + design-system + service-python" 0 "" \
  A --dest "$D" --layout monorepo --module monorepo-root --module design-system --module service-python \
    --slot REPO=demo-repo --slot SCOPE=demo --slot SERVICE=orders --slot PACKAGE=orders --slot OWNER=demo-owner
[[ -d "$D" ]] || { echo "$ok ok, $((bad + 1)) failed (nothing assembled, later cases not run)"; exit 1; }
for f in package.json pnpm-workspace.yaml tsconfig.base.json .nvmrc .gitignore .editorconfig Makefile repo.yaml \
         docs/repo-schema.md scripts/monorepo-settings-check.sh scripts/monorepo-run.sh scripts/monorepo_check.py \
         packages/tokens/package.json packages/theme/package.json services/orders/Makefile; do
  [[ -f "$D/$f" ]] || fail "assembled tree lacks $f"
done
if grep -rIlE '<(REPO|SERVICE|PACKAGE|OWNER|SCOPE)>|repo-name|ds-scope' "$D" >/dev/null; then fail "slot placeholders or literals left in the assembled tree"; else pass "no slot placeholder or literal left"; fi
grep -q '"name": "demo-repo"' "$D/package.json" && grep -q 'name: demo-repo' "$D/repo.yaml" && pass "REPO slot filled in package.json and repo.yaml" || fail "REPO slot not filled"
[[ ! -e "$D/README.md" ]] && pass "module README is not placed" || fail "module README was placed"

# the assembler refuses a second module writing a root file this one owns (different bytes)
mkdir -p "$S/rogue"; echo '{"name": "x"}' > "$S/rogue/package.json"
printf '{"id":"rogue","source":".","slots":{},"placement":{"package.json":"root"}}\n' > "$S/rogue/module.json"
expect "a second module placing the root package.json is refused" 1 "package.json" \
  A --dest "$tmp/rg" --layout monorepo --module monorepo-root --module rogue --slot REPO=demo-repo
# .gitignore is the one root file with a merge rule: a contributor that declares the same glob composes
mkdir -p "$S/ign"; printf 'extra-ignored/\n' > "$S/ign/.gitignore"
printf '{"id":"ign","source":".","slots":{},"placement":{".gitignore":"root"},"root_merge":{".gitignore":"union-lines"}}\n' > "$S/ign/module.json"
A --dest "$tmp/ig" --layout monorepo --module monorepo-root --module ign --slot REPO=demo-repo >/dev/null 2>&1 \
  && grep -qx 'node_modules/' "$tmp/ig/.gitignore" && grep -qx 'extra-ignored/' "$tmp/ig/.gitignore" \
  && pass ".gitignore merges with a contributor that declares root_merge" || fail ".gitignore merge"

# ---- repo.yaml is filled the way a human (or later the assembler) fills it: one entry per unit
"$py" - "$D/repo.yaml" <<'E'
import sys
p = sys.argv[1]
t = open(p).read().replace("units: []\n", """units:
  - { id: svc-orders, kind: service, language: python, path: services/orders }
  - { id: pkg-tokens, kind: package, language: ts, path: packages/tokens }
  - { id: pkg-theme, kind: package, language: ts, path: packages/theme }
""")
open(p, "w").write(t)
E
expect "settings check passes on the assembled clean tree" 0 "^OK monorepo-settings-check" check "$D"
expect "repo.yaml validates" 0 "" bash -c '"$0" -B "$1/scripts/monorepo_check.py" validate "$1/repo.yaml"' "$py" "$D"
alone="$tmp/alone"; A --dest "$alone" --layout monorepo --module monorepo-root --slot REPO=demo-repo >/dev/null 2>&1
expect "the module alone assembles to a tree the check accepts (no units yet)" 0 "^OK" check "$alone"

# ---- settings-check rules, one case that breaks each
c="$(fresh dep)"; sed -i.b 's|"typescript": "catalog:"|"typescript": "^7.0.2"|' "$c/packages/tokens/package.json"; rm "$c/packages/tokens/package.json.b"
n="$(lineno "$c/packages/tokens/package.json" '"typescript"')"
expect "non-catalog dependency is RED, at its line" 1 "^packages/tokens/package.json:$n: non-catalog-dep .*\^7.0.2" check "$c"
c="$(fresh dep2)"; jedit "$c/packages/theme/package.json" 'd["dependencies"]["@demo/tokens"]="^0.1.0"'
expect "an internal dependency by range is RED" 1 "non-catalog-dep .*@demo/tokens" check "$c"
c="$(fresh dep3)"; jedit "$c/package.json" 'd["devDependencies"]={"left-pad":"1.3.0"}'
expect "the root package.json is held to the same rule" 1 "^package.json:[0-9]+: non-catalog-dep" check "$c"
c="$(fresh cat)"; jedit "$c/packages/tokens/package.json" 'd["devDependencies"]["typescript"]="catalog:nope"'
expect "a catalog: reference with no catalog entry is RED" 1 "catalog-missing" check "$c"

c="$(fresh lock1)"; : > "$c/package-lock.json"
expect "package-lock.json is RED" 1 "^package-lock.json:1: second-lockfile" check "$c"
c="$(fresh lock2)"; : > "$c/packages/theme/yarn.lock"
expect "yarn.lock in a package is RED" 1 "packages/theme/yarn.lock:1: second-lockfile" check "$c"
c="$(fresh lock3)"; : > "$c/services/orders/pnpm-lock.yaml"
expect "a nested pnpm-lock.yaml is RED" 1 "services/orders/pnpm-lock.yaml:1: second-lockfile" check "$c"

c="$(fresh pm)"; jedit "$c/package.json" 'del d["packageManager"]'
expect "missing packageManager is RED" 1 "^package.json:1: pm-engines packageManager" check "$c"
c="$(fresh pm2)"; jedit "$c/package.json" 'd["packageManager"]="pnpm@latest"'
expect "packageManager that is not an exact pnpm version is RED" 1 "pm-engines packageManager" check "$c"
c="$(fresh eng)"; jedit "$c/package.json" 'del d["engines"]'
expect "missing engines is RED" 1 "pm-engines engines" check "$c"
c="$(fresh eng2)"; jedit "$c/packages/theme/package.json" 'd["engines"]["node"]=">=22 <27"'
expect "a package engines.node differing from the root is RED" 1 "packages/theme/package.json:[0-9]+: pm-engines engines.node" check "$c"
c="$(fresh pm3)"; jedit "$c/packages/theme/package.json" 'd["packageManager"]="pnpm@9.0.0"'
expect "a package packageManager differing from the root is RED" 1 "packages/theme/package.json:[0-9]+: pm-engines packageManager" check "$c"
c="$(fresh nvm)"; printf '20\n' > "$c/.nvmrc"
expect ".nvmrc outside engines.node is RED" 1 "^.nvmrc:1: nvmrc" check "$c"

c="$(fresh sup1)"; printf 'minimumReleaseAge: 0\n' > "$c/packages/theme/pnpm-workspace.yaml"
expect "a nested pnpm-workspace.yaml is RED" 1 "packages/theme/pnpm-workspace.yaml:1: supply-override" check "$c"
c="$(fresh sup2)"; printf '# x\nminimum-release-age=0\n' > "$c/packages/tokens/.npmrc"
expect "a package .npmrc is RED (by existence)" 1 "packages/tokens/.npmrc:1: supply-override" check "$c"
c="$(fresh sup3)"; printf 'minimum-release-age=0\n' > "$c/.npmrc"
expect "the root .npmrc is not a second home for the settings" 1 "^.npmrc:1: supply-override" check "$c"
c="$(fresh sup4)"; jedit "$c/packages/theme/package.json" 'd["pnpm"]={"onlyBuiltDependencies":["esbuild"]}'
expect "a package.json pnpm field is RED" 1 "packages/theme/package.json:[0-9]+: supply-override" check "$c"
c="$(fresh set1)"; sed -i.b 's/^catalogMode: strict/catalogMode: manual/' "$c/pnpm-workspace.yaml"; rm "$c/pnpm-workspace.yaml.b"
expect "weakening catalogMode at the root is RED" 1 "root-settings catalogMode" check "$c"
c="$(fresh set2)"; sed -i.b 's/^minimumReleaseAge: .*/minimumReleaseAge: 60/' "$c/pnpm-workspace.yaml"; rm "$c/pnpm-workspace.yaml.b"
expect "a minimumReleaseAge below the floor is RED" 1 "root-settings minimumReleaseAge" check "$c"
c="$(fresh set3)"; sed -i.b '/^onlyBuiltDependencies/d' "$c/pnpm-workspace.yaml"; rm "$c/pnpm-workspace.yaml.b"
expect "dropping the install-script allowlist is RED" 1 "root-settings onlyBuiltDependencies" check "$c"

c="$(fresh unit1)"; sed -i.b '/pkg-theme/d' "$c/repo.yaml"; rm "$c/repo.yaml.b"
expect "a directory under packages/ missing from repo.yaml is RED" 1 "unit-unlisted packages/theme" check "$c"
c="$(fresh unit2)"; sed -i.b '/svc-orders/d' "$c/repo.yaml"; rm "$c/repo.yaml.b"
expect "a directory under services/ missing from repo.yaml is RED" 1 "unit-unlisted services/orders" check "$c"
c="$(fresh unit3)"; printf '  - { id: svc-ghost, kind: service, language: go, path: services/ghost }\n' >> "$c/repo.yaml"
n="$(lineno "$c/repo.yaml" 'svc-ghost')"
expect "a repo.yaml path that does not exist is RED, at its line" 1 "^repo.yaml:$n: unit-path .*services/ghost" check "$c"
c="$(fresh tgt1)"; sed -i.b 's/^verify:/verifx:/' "$c/services/orders/Makefile"; rm "$c/services/orders/Makefile.b"
expect "a service without the verify target is RED" 1 "services/orders/Makefile:1: unit-target .*no verify" check "$c"
c="$(fresh tgt2)"; sed -i.b 's/^check-fast:/check-fasx:/' "$c/services/orders/Makefile"; rm "$c/services/orders/Makefile.b"
expect "a service without the check-fast target is RED" 1 "unit-target .*no check-fast" check "$c"
c="$(fresh tgt3)"; jedit "$c/packages/tokens/package.json" 'del d["scripts"]["test"]'
expect "a package without a test script is RED" 1 "packages/tokens/package.json:1: unit-target .*no .test" check "$c"

# ---- repo.yaml schema: malformed files are refused
V() { printf '%s' "$2" > "$tmp/v-$1.yaml"; bash -c '"$0" -B "$1" validate "$2"' "$py" "$D/scripts/monorepo_check.py" "$tmp/v-$1.yaml"; }
hdr=$'version: v2\nrepo: { name: demo-repo, layout: monorepo }\n'
expect "schema: unparseable YAML is refused" 1 "not valid YAML" V s1 $'units: [\n'
expect "schema: wrong version is refused" 1 "version must be" V s2 $'version: v1\nrepo: { name: demo-repo, layout: monorepo }\nunits: []\n'
expect "schema: unknown kind is refused" 1 "kind 'worker' not one of" V s3 "${hdr}units:"$'\n  - { id: a, kind: worker, language: go, path: services/a }\n'
expect "schema: language not allowed for the kind is refused" 1 "language 'go' not allowed for kind app" V s4 "${hdr}units:"$'\n  - { id: a, kind: app, language: go, path: apps/a }\n'
expect "schema: a path outside the kind's root is refused" 1 "path 'packages/a' must be services/<name>" V s5 "${hdr}units:"$'\n  - { id: a, kind: service, language: go, path: packages/a }\n'
expect "schema: a path with .. is refused" 1 "must be services/<name>" V s6 "${hdr}units:"$'\n  - { id: a, kind: service, language: go, path: services/../x }\n'
expect "schema: duplicate id is refused" 1 "duplicate unit id 'a'" V s7 "${hdr}units:"$'\n  - { id: a, kind: service, language: go, path: services/a }\n  - { id: a, kind: service, language: go, path: services/b }\n'
expect "schema: duplicate path is refused" 1 "duplicate unit path" V s8 "${hdr}units:"$'\n  - { id: a, kind: service, language: go, path: services/a }\n  - { id: b, kind: service, language: go, path: services/a }\n'
expect "schema: an extra unit key is refused" 1 "exactly id, kind, language, path" V s9 "${hdr}units:"$'\n  - { id: a, kind: service, language: go, path: services/a, spec: x }\n'
expect "schema: a duplicate YAML key is refused" 1 "duplicate key" V s10 "${hdr}units: []"$'\nunits: []\n'
expect "schema: a missing units key is refused" 1 "units must be a list" V s11 "$hdr"
expect "schema: the database unit at db is accepted" 0 "" V s12 "${hdr}units:"$'\n  - { id: db, kind: database, language: sql, path: db }\n'
c="$(fresh bad)"; printf 'units: [\n' > "$c/repo.yaml"
expect "a malformed repo.yaml makes the settings check RED" 1 "^repo.yaml:1: repo-yaml" check "$c"

# ---- the root Makefile delegates: fake units that record their calls
F="$(cd "$tmp" && pwd -P)/fake"; mkdir -p "$F/scripts" "$F/services/a" "$F/services/b" "$F/services/c" "$F/packages/p" "$F/db"
cp "$D/Makefile" "$D/package.json" "$D/pnpm-workspace.yaml" "$D/.nvmrc" "$F/"; cp "$D/scripts/monorepo-run.sh" "$D/scripts/monorepo-settings-check.sh" "$D/scripts/monorepo_check.py" "$F/scripts/"
for u in a b c; do
  printf 'check-fast:\n\t@echo "%s check-fast" >> "$(LOG)"\nverify:\n\t@echo "%s verify" >> "$(LOG)"; %s\n' "$u" "$u" "$([[ $u == b ]] && echo 'exit 3' || echo true)" > "$F/services/$u/Makefile"
done
printf 'check-fast:\n\t@echo "db check-fast" >> "$(LOG)"\n' > "$F/db/Makefile"
printf '{"name":"p","version":"1.0.0","private":true,"scripts":{"test":"x","check-fast":"x"}}\n' > "$F/packages/p/package.json"
printf '#!/usr/bin/env bash\necho "pnpm $*" >> "$LOG"\n' > "$F/fakepnpm"; chmod +x "$F/fakepnpm"
cat > "$F/repo.yaml" <<'E'
version: v2
repo: { name: demo-repo, layout: monorepo }
units:
  - { id: svc-a, kind: service, language: go, path: services/a }
  - { id: svc-b, kind: service, language: rust, path: services/b }
  - { id: pkg-p, kind: package, language: ts, path: packages/p }
  - { id: svc-c, kind: service, language: python, path: services/c }
  - { id: db, kind: database, language: sql, path: db }
E
export LOG="$tmp/calls.log"; export PNPM="$F/fakepnpm"
: > "$LOG"; expect "make check-fast: one line per unit, every unit that has it runs" 0 "check-fast svc-a: ok" make -s -C "$F" check-fast
want=$'svc-a: ok\ncheck-fast svc-b: ok\ncheck-fast pkg-p: ok\ncheck-fast svc-c: ok\ncheck-fast db: ok'
out="$(make -s -C "$F" check-fast 2>&1)"; [[ "$out" == *"$want"* && "$out" == *"over 5 unit(s)" ]] && pass "make check-fast prints one line per unit, in repo.yaml order" || fail "check-fast lines" "$out"
[[ "$(tr '\n' ' ' < "$LOG")" == "a check-fast b check-fast pnpm --dir $F/packages/p run check-fast c check-fast db check-fast a check-fast b check-fast pnpm --dir $F/packages/p run check-fast c check-fast db check-fast " ]] \
  && pass "units are called by their own mechanism (make -C / pnpm --dir) in order" || fail "call log" "$(tr '\n' ' ' < "$LOG")"
: > "$LOG"; expect "make verify: the first failing unit fails the run" 2 "verify svc-b: FAIL \(2\)" make -s -C "$F" verify
[[ "$(tr '\n' ' ' < "$LOG")" == "a verify b verify " ]] && pass "first failure stops: later units are not called" || fail "stop on first failure" "$(tr '\n' ' ' < "$LOG")"
: > "$LOG"; out="$(make -s -C "$F" test 2>&1)"
[[ "$out" == *"test svc-a: skip (no test)"* && "$out" == *"test pkg-p: ok"* && "$(cat "$LOG")" == "pnpm --dir $F/packages/p run test" ]] && pass "a unit without the target is a skip line, not a silent hole" || fail "test target" "$out"
expect "the settings-check target runs the check (the fake tree is valid)" 0 "^OK monorepo-settings-check" make -s -C "$F" settings-check

# ---- the allow-lists (review B1/B2): a base tree with two packages, one of them named dist
B="$tmp/base"; cp -R "$alone" "$B"
for p in a dist; do
  mkdir -p "$B/packages/$p"
  printf '{"name":"%s","version":"1.0.0","private":true,"scripts":{"test":"true"},"dependencies":{"typescript":"catalog:"}}\n' "$p" > "$B/packages/$p/package.json"
done
sed -i.b 's|^units: \[\]|units:\n  - { id: pkg-a, kind: package, language: ts, path: packages/a }\n  - { id: pkg-dist, kind: package, language: ts, path: packages/dist }|' "$B/repo.yaml"; rm "$B/repo.yaml.b"
expect "allow-list base tree (two packages, one named dist) is clean" 0 "^OK" check "$B"
W="$tmp/work"; cp -R "$B" "$W"
red() { local out rc; out="$(check "$2" 2>&1)"; rc=$?; if [[ $rc -eq 1 ]] && grep -Eq -- "$3" <<<"$out"; then pass "$1"; else fail "$1" "exit $rc: $(head -c 300 <<<"$out")"; fi; }
# wcase <label> <key> <text appended to the workspace file>: RED naming the key at its real line
wcase() {
  local ws="$W/pnpm-workspace.yaml" n; cp "$ws" "$tmp/ws.bak"; n=$(( $(wc -l < "$ws") + 1 )); printf '%s\n' "$3" >> "$ws"
  red "workspace key $2 is refused ($1), at line $n" "$W" "^pnpm-workspace.yaml:$n: root-settings key '$2' is not allowed"; cp "$tmp/ws.bak" "$ws"
}
wcase reviewer-B1 overrides $'overrides:\n  typescript: 5.0.0'
wcase reviewer-B2 minimumReleaseAgeExclude "minimumReleaseAgeExclude: ['*']"
wcase "" trustPolicyExclude "trustPolicyExclude: ['*']"
wcase "" packageExtensions $'packageExtensions:\n  x: {dependencies: {y: 1.0.0}}'
wcase "" patchedDependencies $'patchedDependencies:\n  typescript@7.0.2: patches/t.patch'
wcase "" allowedDeprecatedVersions $'allowedDeprecatedVersions:\n  left-pad: "*"'
wcase "" pnpmfile "pnpmfile: ./hooks.cjs"
wcase "" registry "registry: https://registry.example.com/"
wcase "" shamefullyHoist "shamefullyHoist: true"
wcase "" nodeLinker "nodeLinker: hoisted"
wcase invented madeUpSetting "madeUpSetting: 1"
wcase invented anotherUnknownKey "anotherUnknownKey: [a, b]"
wcase "" ignoredBuiltDependencies "ignoredBuiltDependencies: [esbuild]"
# a setting present with a weak or wrong-typed value is RED at the key's own line
wset() { # <label> <sed expression> <key> <egrep tail>
  local ws="$W/pnpm-workspace.yaml" n; cp "$ws" "$tmp/ws.bak"; sed -i.b "$2" "$ws"; mv "$ws.b" "$tmp/ws.sedbak"; n="$(lineno "$ws" "$3:")"
  red "$1, at line $n" "$W" "^pnpm-workspace.yaml:$n: root-settings $3 $4"; cp "$tmp/ws.bak" "$ws"
}
wset "minimumReleaseAge below the floor is RED" 's/^minimumReleaseAge: .*/minimumReleaseAge: 1439/' minimumReleaseAge "must be an integer"
wset "minimumReleaseAge as a string is RED" 's/^minimumReleaseAge: .*/minimumReleaseAge: "10080"/' minimumReleaseAge "must be an integer"
wset "engineStrict: 1 (an int, not true) is RED" 's/^engineStrict: true/engineStrict: 1/' engineStrict "must be True"
wset "trustPolicy off is RED" 's/^trustPolicy: .*/trustPolicy: off/' trustPolicy "must be 'no-downgrade'"
wset "onlyBuiltDependencies: ['*'] is RED" "s/^onlyBuiltDependencies: .*/onlyBuiltDependencies: ['*']/" onlyBuiltDependencies "must be a block list"
wset "an onlyBuiltDependencies glob with a reason is still RED" $'s/^onlyBuiltDependencies: .*/onlyBuiltDependencies:\\\n  - "es*" # reason: x/' onlyBuiltDependencies "must be a block list|entry .* plain package name"
c="$tmp/obd"; cp -R "$B" "$c"; sed -i.b $'s/^onlyBuiltDependencies: .*/onlyBuiltDependencies:\\\n  - esbuild # reason: downloads its binary in postinstall/' "$c/pnpm-workspace.yaml"; mv "$c/pnpm-workspace.yaml.b" "$tmp/obd.sedbak"
expect "an onlyBuiltDependencies entry with a plain name and a reason is accepted" 0 "^OK" check "$c"
sed -i.b 's/ # reason: .*//' "$c/pnpm-workspace.yaml"; mv "$c/pnpm-workspace.yaml.b" "$tmp/obd.sedbak2"; n="$(grep -n '^  - esbuild' "$c/pnpm-workspace.yaml" | cut -d: -f1)"
expect "the same entry without its reason is RED, at the entry's line" 1 "^pnpm-workspace.yaml:$n: root-settings onlyBuiltDependencies entry 'esbuild' needs" check "$c"
c="$tmp/dupk"; cp -R "$B" "$c"; printf 'catalogMode: manual\n' >> "$c/pnpm-workspace.yaml"
expect "a duplicate key in the workspace file is RED" 1 "root-settings .*duplicate key 'catalogMode'" check "$c"
c="$tmp/cat1"; cp -R "$B" "$c"; sed -i.b 's/^  typescript: 7.0.2/  typescript: ^7.0.2/' "$c/pnpm-workspace.yaml"; mv "$c/pnpm-workspace.yaml.b" "$tmp/cat1.sedbak"; n="$(lineno "$c/pnpm-workspace.yaml" 'typescript: ^7')"
expect "a catalog entry that is a range is RED, at its line" 1 "^pnpm-workspace.yaml:$n: catalog-spec .*typescript" check "$c"
c="$tmp/cat2"; cp -R "$B" "$c"; sed -i.b 's/^  typescript: 7.0.2/  typescript: npm:left-pad@1.3.0/' "$c/pnpm-workspace.yaml"; mv "$c/pnpm-workspace.yaml.b" "$tmp/cat2.sedbak"
expect "a catalog entry that is an npm: alias is RED" 1 "catalog-spec .*typescript" check "$c"
c="$tmp/cat3"; cp -R "$B" "$c"; printf 'catalogs:\n  legacy:\n    left-pad: ">=1"\n' >> "$c/pnpm-workspace.yaml"
expect "a named catalog entry that is a range is RED" 1 "catalog-spec catalogs.legacy left-pad" check "$c"
c="$tmp/glob"; cp -R "$B" "$c"; sed -i.b 's|^  - apps/\*|  - services/*|' "$c/pnpm-workspace.yaml"; mv "$c/pnpm-workspace.yaml.b" "$tmp/glob.sedbak"
expect "a workspace glob outside apps/* and packages/* is RED" 1 "workspace-glob .*services/\*" check "$c"

# ---- files refused by existence anywhere: at the root, in a unit, in a unit named packages/dist
# fcase <relpath> <rule> [content]
fcase() {
  local rel="$1" out rc; mkdir -p "$W/$(dirname "$rel")"; printf '%s' "${3:-}" > "$W/$rel"
  out="$(check "$W" 2>&1)"; rc=$?; mv "$W/$rel" "$tmp/fcase.gone"
  if [[ $rc -eq 1 ]] && grep -Eq -- "^$rel:1: $2 " <<<"$out"; then pass "refused by name: $rel"; else fail "refused by name: $rel" "exit $rc: $(head -c 300 <<<"$out")"; fi
}
for place in "" packages/a/ packages/dist/; do
  for name in .npmrc .pnpmfile.cjs .pnpmfile.mjs pnpmfile.cjs pnpmfile.mjs package.yaml package.json5; do fcase "$place$name" supply-override; done
  for name in package-lock.json npm-shrinkwrap.json yarn.lock bun.lock bun.lockb deno.lock; do fcase "$place$name" second-lockfile; done
  if [[ -n "$place" ]]; then fcase "${place}pnpm-lock.yaml" second-lockfile; fcase "${place}pnpm-workspace.yaml" supply-override; fi
done
# the reviewer's constructs, verbatim in spirit
fcase .npmrc supply-override $'minimum-release-age-exclude[]=*\n'
fcase .pnpmfile.cjs supply-override 'module.exports = { hooks: { readPackage(pkg) { if (pkg.dependencies) pkg.dependencies.typescript = "5.0.0"; return pkg } } }'
fcase packages/a/package.yaml supply-override $'dependencies:\n  typescript: 5.0.0\n'
fcase .npmrc supply-override $'registry=https://registry.example.com/\npnpmfile=./hooks.cjs\n'
fcase .NPMRC supply-override
: > "$W/pnpm-lock.yaml"
expect "the one root pnpm-lock.yaml is allowed" 0 "^OK" check "$W"; mv "$W/pnpm-lock.yaml" "$tmp/fcase.gone"
mkdir -p "$W/node_modules/x"; : > "$W/node_modules/x/.npmrc"
expect "node_modules/ is the one place not walked" 0 "^OK" check "$W"; mv "$W/node_modules" "$tmp/nm.gone"

# ---- package.json: refused fields, and the only dependency spec forms
# pcase <label> <file> <python edit of the parsed package.json> <egrep>
pcase() {
  local f="$W/$2"; cp "$f" "$tmp/pk.bak"; jedit "$f" "$3"; red "$1" "$W" "$4"; cp "$tmp/pk.bak" "$f"
}
for file in package.json packages/a/package.json; do
  pcase "$file: resolutions is refused" "$file" 'd["resolutions"]={"typescript":"5.0.0"}' "^$file:[0-9]+: supply-override the .resolutions"
  pcase "$file: overrides is refused" "$file" 'd["overrides"]={"typescript":"5.0.0"}' "^$file:[0-9]+: supply-override the .overrides"
  pcase "$file: pnpm.overrides (the pnpm field) is refused" "$file" 'd["pnpm"]={"overrides":{"typescript":"5.0.0"}}' "^$file:[0-9]+: supply-override the .pnpm"
  pcase "$file: an empty pnpm field is refused" "$file" 'd["pnpm"]={}' "^$file:[0-9]+: supply-override the .pnpm"
  pcase "$file: bundledDependencies is refused" "$file" 'd["bundledDependencies"]=["typescript"]' "^$file:[0-9]+: supply-override the .bundledDependencies"
  pcase "$file: bundleDependencies is refused" "$file" 'd["bundleDependencies"]=["typescript"]' "^$file:[0-9]+: supply-override the .bundleDependencies"
done
while IFS='|' read -r label spec rule; do
  for fld in dependencies peerDependencies; do
    pcase "$fld spec form $label ($spec) is refused" packages/a/package.json "d['$fld']={'left-pad':'$spec'}" "^packages/a/package.json:[0-9]+: $rule $fld left-pad"
  done
done <<'F'
range|^1.0.0|non-catalog-dep
exact version|1.0.0|non-catalog-dep
npm alias|npm:left-pad@1.3.0|non-catalog-dep
file:|file:../x|non-catalog-dep
link:|link:../x|non-catalog-dep
git URL|git+https://example.com/a/b.git|non-catalog-dep
tarball URL|https://example.com/x.tgz|non-catalog-dep
workspace:^|workspace:^|non-catalog-dep
workspace:~|workspace:~|non-catalog-dep
dist-tag|latest|non-catalog-dep
catalog:missing|catalog:missing|catalog-missing
F
pcase "devDependencies range is refused" packages/a/package.json 'd["devDependencies"]={"left-pad":"^1.0.0"}' "non-catalog-dep devDependencies left-pad"
pcase "optionalDependencies range is refused" packages/a/package.json 'd["optionalDependencies"]={"left-pad":"^1.0.0"}' "non-catalog-dep optionalDependencies left-pad"
pcase "root package.json peerDependencies range is refused" package.json 'd["peerDependencies"]={"left-pad":"^1.0.0"}' "^package.json:[0-9]+: non-catalog-dep peerDependencies"
c="$tmp/peer"; cp -R "$B" "$c"; jedit "$c/packages/a/package.json" 'd["peerDependencies"]={"typescript":"catalog:"}; d["dependencies"]["@x/sib"]="workspace:*"'
expect "peerDependencies as catalog: (valid in pnpm 10) and workspace:* are accepted" 0 "^OK" check "$c"
# packageManager and engines
c="$tmp/pmh"; cp -R "$B" "$c"; h='pnpm@10.34.3+sha512.0123abcd'; jedit "$c/package.json" "d['packageManager']='$h'"
expect "the packageManager hash form is accepted at the root" 0 "^OK" check "$c"
jedit "$c/packages/a/package.json" "d['packageManager']='$h'"
expect "the same hash form in a package is accepted" 0 "^OK" check "$c"
jedit "$c/packages/a/package.json" "d['packageManager']='pnpm@10.34.3'"
expect "the plain form in a package against a hash root is RED" 1 "packages/a/package.json:[0-9]+: pm-engines packageManager differs" check "$c"
c="$tmp/eng1"; cp -R "$B" "$c"; jedit "$c/package.json" 'd["engines"]["node"]=">=20 <99"'
expect "root engines.node widened (same shape) is RED" 1 "^package.json:[0-9]+: pm-engines engines must be exactly" check "$c"
c="$tmp/eng2"; cp -R "$B" "$c"; jedit "$c/package.json" 'd["engines"]["pnpm"]=">=9.0.0 <99"'
expect "root engines.pnpm widened (same shape) is RED" 1 "pm-engines engines must be exactly" check "$c"
c="$tmp/eng3"; cp -R "$B" "$c"; jedit "$c/packages/a/package.json" 'd["engines"]={"node":">=24 <27"}'
expect "a package engines that states only one key, equal to the root's, is accepted" 0 "^OK" check "$c"
jedit "$c/packages/a/package.json" 'd["engines"]={"node":">=24 <27","npm":">=1"}'
expect "a package engines key the root does not have is RED" 1 "packages/a/package.json:[0-9]+: pm-engines engines.npm" check "$c"
c="$tmp/eng4"; cp -R "$B" "$c"; jedit "$c/packages/a/package.json" 'd["engines"]={"node":">=24 <27","pnpm":">=10.34.3 <13"}'
expect "a package engines equal to the root's is accepted" 0 "^OK" check "$c"
"$py" -B - "$modsrc/scripts/monorepo_check.py" "$modsrc/package.json" <<'P' && pass "ENGINES_EXPECTED equals the engines of the shipped package.json" || fail "ENGINES_EXPECTED differs from the shipped package.json"
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if m.ENGINES_EXPECTED == json.load(open(sys.argv[2]))["engines"] else 1)
P
# real line numbers in root-settings findings
c="$tmp/ln"; cp -R "$B" "$c"; sed -i.b 's/^strictDepBuilds: true/strictDepBuilds: false/' "$c/pnpm-workspace.yaml"; mv "$c/pnpm-workspace.yaml.b" "$tmp/ln.sedbak"; n="$(lineno "$c/pnpm-workspace.yaml" 'strictDepBuilds:')"
[[ "$n" -gt 1 ]] && expect "a root-settings finding carries the real line, not 1 (line $n)" 1 "^pnpm-workspace.yaml:$n: root-settings strictDepBuilds" check "$c" || fail "line fixture"
# unit-unlisted covers db/, and the layout guard
mkdir -p "$W/db"; red "a db/ directory that repo.yaml does not list is RED" "$W" "^repo.yaml:1: unit-unlisted db "; mv "$W/db" "$tmp/db.gone"
mkdir -p "$tmp/empty"; expect "no pnpm-workspace.yaml + repo.yaml pair (not a monorepo root) is refused first" 1 "no pnpm-workspace.yaml \+ repo.yaml pair" bash "$D/scripts/monorepo-settings-check.sh" "$tmp/empty"

# ---- review B3: the root Makefile RUNS the settings check, and the runner fails (never skips) a missing mandatory target
mkfake() { # <dir>: a minimal valid monorepo root (the shipped scripts, Makefile and pins) with no units
  mkdir -p "$1/scripts"; cp "$D/Makefile" "$D/package.json" "$D/pnpm-workspace.yaml" "$D/.nvmrc" "$1/"
  cp "$D/scripts/monorepo-run.sh" "$D/scripts/monorepo-settings-check.sh" "$D/scripts/monorepo_check.py" "$1/scripts/"
}
svc_make() { # <dir> <id> <targets line, e.g. "check-fast verify">: a service Makefile whose targets log "<id> <target>"
  mkdir -p "$1"; printf '%s:\n\t@echo "%s $@" >> "$(LOG)"\n' "$3" "$2" > "$1/Makefile"
}
repo_yaml() { # <dir> <id:path>...
  local d="$1" u; shift
  { printf 'version: v2\nrepo: { name: demo-repo, layout: monorepo }\nunits:\n'
    for u in "$@"; do printf '  - { id: %s, kind: service, language: go, path: %s }\n' "${u%%:*}" "${u#*:}"; done; } > "$d/repo.yaml"
}
logis() { [[ "$(tr '\n' ',' < "$LOG")" == "$1" ]]; }
M1="$tmp/b3a"; mkfake "$M1"; svc_make "$M1/services/x" x "check-fast verify"; svc_make "$M1/services/y" y "check-fast"
repo_yaml "$M1" svc-x:services/x svc-y:services/y
: > "$LOG"; out="$(make -s -C "$M1" verify 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -Eq 'unit-target unit svc-y: .*verify' <<<"$out" && grep -q 'FAIL monorepo-settings-check' <<<"$out" && [[ ! -s "$LOG" ]]; then
  pass "B3: root make verify with a service lacking verify exits non-zero before any unit runs, naming unit and target"
else fail "B3 make verify without a mandatory target" "rc=$rc log=$(tr '\n' ',' < "$LOG") $(head -c 300 <<<"$out")"; fi
: > "$LOG"; out="$(bash "$M1/scripts/monorepo-run.sh" verify 2>&1)"; rc=$?
if [[ $rc -eq 1 && "$out" == *"verify svc-y: FAIL (mandatory target verify missing in services/y)"* && ! -s "$LOG" ]]; then
  pass "B3: the runner alone FAILs (not skip) on a missing mandatory target, and nothing ran"
else fail "B3 runner mandatory target" "rc=$rc log=$(tr '\n' ',' < "$LOG") $(head -c 300 <<<"$out")"; fi
# a settings-check finding the runner does not know about still stops the run before any unit
M2="$tmp/b3b"; mkfake "$M2"; svc_make "$M2/services/x" x "check-fast verify"; repo_yaml "$M2" svc-x:services/x; : > "$M2/.npmrc"
: > "$LOG"; out="$(make -s -C "$M2" verify 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"supply-override"* && ! -s "$LOG" ]] && pass "B3: a red settings check (a .npmrc) stops make verify before any unit runs" || fail "B3 red check stops verify" "rc=$rc log=$(cat "$LOG")"
: > "$LOG"; out="$(make -s -C "$M2" check-fast 2>&1)"; rc=$?
[[ $rc -ne 0 && ! -s "$LOG" ]] && pass "B3: the same for make check-fast" || fail "B3 red check stops check-fast" "rc=$rc"
# with the targets present every unit runs; the one-line form `check-fast verify:` counts as present
M3="$tmp/b3c"; mkfake "$M3"; svc_make "$M3/services/x" x "check-fast verify"; svc_make "$M3/services/y" y "check-fast verify"
repo_yaml "$M3" svc-x:services/x svc-y:services/y
: > "$LOG"; out="$(make -s -C "$M3" verify 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"will run in 2 of 2 unit(s)"* && "$out" == *"over 2 unit(s)" ]] && logis "x verify,y verify," && pass "B3: with the target present make verify runs all units, announcing the count first" || fail "B3 all units" "rc=$rc log=$(tr '\n' ',' < "$LOG")"
M4="$tmp/b3d"; mkfake "$M4"; svc_make "$M4/services/x" x "check-fast verify"; repo_yaml "$M4" svc-x:services/x
printf 'check-fast verify:\n\t@echo "x $@" >> "$(LOG)"\n' > "$M4/services/x/Makefile"
: > "$LOG"; out="$(make -s -C "$M4" verify 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && logis "x verify," && pass "B3: a one-line 'check-fast verify:' Makefile counts as having both targets" || fail "B3 one-line targets" "rc=$rc $(head -c 300 <<<"$out")"
# a database unit has no mandatory target: absent -> skip
mkdir -p "$M4/db"; printf 'version: v2\nrepo: { name: demo-repo, layout: monorepo }\nunits:\n  - { id: svc-x, kind: service, language: go, path: services/x }\n  - { id: db, kind: database, language: sql, path: db }\n' > "$M4/repo.yaml"
: > "$LOG"; out="$(make -s -C "$M4" verify 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"verify db: skip (no verify)"* ]] && pass "an optional target missing (database, verify) is a skip line" || fail "database skip" "rc=$rc $(head -c 300 <<<"$out")"
# a unit recipe that reads stdin neither swallows the rest of the list nor sees the caller's stdin
M5="$tmp/b3e"; mkfake "$M5"; MARK="$tmp/stdin.mark"; export MARK
for u in a b c; do svc_make "$M5/services/$u" "$u" "check-fast verify"; done
printf 'check-fast verify:\n\t@cat >> "$(MARK)"; echo "a $@" >> "$(LOG)"\n' > "$M5/services/a/Makefile"
repo_yaml "$M5" svc-a:services/a svc-b:services/b svc-c:services/c
: > "$LOG"; : > "$MARK"; out="$(printf 'junk\n' | make -s -C "$M5" check-fast 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"over 3 unit(s)" ]] && logis "a check-fast,b check-fast,c check-fast," && [[ ! -s "$MARK" ]] && pass "a unit recipe that reads stdin: all 3 units run and the unit reads nothing from the caller's stdin" \
  || fail "stdin" "rc=$rc log=$(tr '\n' ',' < "$LOG") mark=$(cat "$MARK") $(head -c 200 <<<"$out")"
# a unit path through a symlink out of the repository is refused; nothing runs there
M6="$tmp/b3f"; mkfake "$M6"; mkdir -p "$tmp/outside"; MARKER="$tmp/outside.marker"; export MARKER
printf 'check-fast verify:\n\t@touch "$(MARKER)"\n' > "$tmp/outside/Makefile"; ln -s "$tmp/outside" "$tmp/b3f-link"; mkdir -p "$M6/services"; ln -s "$tmp/outside" "$M6/services/evil"
repo_yaml "$M6" svc-evil:services/evil
out="$(bash "$M6/scripts/monorepo-run.sh" check-fast 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *"services/evil is a symlink"* && ! -e "$MARKER" ]] && pass "a symlinked unit path out of the repo is refused by the runner, nothing executed there" || fail "symlink runner" "rc=$rc marker=$([[ -e $MARKER ]] && echo present) $(head -c 300 <<<"$out")"
out="$(make -s -C "$M6" verify 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"unit-path"*"symlink"* && ! -e "$MARKER" ]] && pass "the settings check names the symlinked unit path (unit-path), nothing executed" || fail "symlink check" "rc=$rc $(head -c 300 <<<"$out")"

# ---- pnpm: the assembled root really installs (offline, zero third-party dependencies)
have_pm="$(pnpm -v 2>/dev/null | tail -1)"
want_pm="$("$py" -c 'import json,sys;print(json.load(open(sys.argv[1]))["packageManager"].split("@")[1])' "$alone/package.json")"
if [[ -n "${NO_PNPM:-}" ]]; then skip "pnpm install section" "NO_PNPM is set (mutation runs only)"
elif ! command -v pnpm >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then skip "pnpm install --frozen-lockfile --offline" "pnpm or node not installed"
elif [[ "$have_pm" != "$want_pm" ]]; then skip "pnpm install --frozen-lockfile --offline" "installed pnpm $have_pm is not the pinned $want_pm (would fetch it)"
elif ! node -e 'const m=+process.versions.node.split(".")[0];process.exit(m>=24&&m<27?0:1)'; then skip "pnpm install --frozen-lockfile --offline" "node $(node -v) outside engines.node"
else
  I="$tmp/pm"; cp -R "$alone" "$I"; mkdir -p "$I/packages/a"
  printf '{"name":"a","version":"1.0.0","private":true,"scripts":{"test":"true"}}\n' > "$I/packages/a/package.json"
  sed -i.b 's/^units: \[\]/units:\n  - { id: pkg-a, kind: package, language: ts, path: packages\/a }/' "$I/repo.yaml"; rm "$I/repo.yaml.b"
  expect "pnpm install --offline resolves the assembled root" 0 "Done in" bash -c 'cd "$0" && CI=true pnpm install --offline' "$I"
  expect "pnpm install --frozen-lockfile --offline passes on the fresh lockfile" 0 "Done in" bash -c 'cd "$0" && CI=true pnpm install --frozen-lockfile --offline' "$I"
  expect "the settings check passes on the installed tree" 0 "^OK" check "$I"
  jedit "$I/packages/a/package.json" 'd["engines"]={"node":">=99"}'
  expect "engineStrict: pnpm refuses a package whose engines.node the running node fails" 1 "engines.node" bash -c 'cd "$0" && CI=true pnpm install --offline' "$I"
  # The B1 construct is live: with `overrides:` in the workspace file pnpm resolves a version the catalog does not
  # name, and the settings check is RED on that very tree. Needs the registry; no lockfile written is a SKIP.
  L="$tmp/live"; cp -R "$alone" "$L"; mkdir -p "$L/packages/a"
  printf '{"name":"a","version":"1.0.0","private":true,"scripts":{"test":"true"},"dependencies":{"is-odd":"catalog:"}}\n' > "$L/packages/a/package.json"
  sed -i.b 's/^units: \[\]/units:\n  - { id: pkg-a, kind: package, language: ts, path: packages\/a }/' "$L/repo.yaml"; mv "$L/repo.yaml.b" "$tmp/live.sedbak"
  "$py" - "$L/pnpm-workspace.yaml" <<'P'
import re, sys
p = sys.argv[1]; t = open(p).read()
t = re.sub(r"catalog:\n(  .*\n)+", "catalog:\n  is-odd: 3.0.1\n", t) + "overrides:\n  is-odd: 3.0.0\n"
open(p, "w").write(t)
P
  expect "the live tree (is-odd 3.0.1 in the catalog, overrides to 3.0.0) is RED" 1 "root-settings key 'overrides' is not allowed" check "$L"
  lo="$(cd "$L" && CI=true timeout 60 pnpm install --ignore-scripts 2>&1 | tail -n 5)"
  if [[ -f "$L/pnpm-lock.yaml" ]] && grep -q 'is-odd@3.0.0:' "$L/pnpm-lock.yaml" && ! grep -q 'is-odd@3.0.1:' "$L/pnpm-lock.yaml"; then
    pass "B1 live: pnpm installed is-odd 3.0.0 although the catalog says 3.0.1 (overrides is a real second home for versions)"
  elif [[ -f "$L/pnpm-lock.yaml" ]]; then fail "B1 live: the override did not take effect" "$(grep -n 'is-odd@' "$L/pnpm-lock.yaml" | head -3)"
  else skip "B1 live install of an overrides construct" "no lockfile written (registry unreachable?): $(tr '\n' ' ' <<<"$lo" | head -c 160)"; fi
fi

summary="$ok ok, $bad failed"; [[ $skipped -gt 0 ]] && summary+=", $skipped skipped"; echo "$summary"
[[ $((ok + bad)) -gt 0 ]] || exit 2
[[ $bad -eq 0 ]]
