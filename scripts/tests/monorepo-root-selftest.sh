#!/usr/bin/env bash
# monorepo-root-selftest.sh -- the monorepo-root module, assembled for real with the design-system and a
# service module, then its settings check, its root Makefile and its repo.yaml schema, one RED case per rule.
# The default run is hermetic, sequential, no network, no pnpm; it is what CI runs. MONOREPO_LIVE=1 (set by a human
# or an opt-in job that has pnpm 10.34.3 and the registry) adds the live pnpm section; NO_PNPM=1 forces it off.
# Needs python3 with PyYAML (PYTHON=<interpreter> to choose one; the
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
export TMPDIR="$tmp" HOME="$tmp/home" REPO_HERE="$here"; mkdir -p "$HOME"

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
# The design-system module is the REAL one (its manifest excludes the root files this module owns and declares its two
# packages as units); no corrected copy.

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

# ---- repo.yaml is written by the assembler: one entry per unit (service orders, packages tokens and theme)
# The lockfile is generated by `make lock` (needs the registry), so a fresh scaffold has JS packages and no lockfile:
# exactly one finding, `lockfile-missing`. The hermetic cases below write a minimal pnpm-lock.yaml by hand (minlock):
# the check only tests that the file EXISTS, it never parses it (no rule reads a lockfile), so these cases prove the
# rule's presence test and NOT that pnpm accepts the file (make lock-check does, in the assembly selftest, with network).
minlock() { printf "lockfileVersion: '9.0'\n\nsettings:\n  autoInstallPeers: true\n  excludeLinksFromLockfile: false\n\nimporters:\n\n  .: {}\n" > "$1/pnpm-lock.yaml"; }
expect "a fresh scaffold (JS packages, no pnpm-lock.yaml) is RED: lockfile-missing, naming make lock" 1 "^pnpm-lock.yaml:1: lockfile-missing .*make lock" check "$D"
expect "a fresh scaffold has exactly ONE finding (lockfile-missing)" 1 "FAIL monorepo-settings-check: 1 finding\(s\)" check "$D"
minlock "$D"
expect "settings check passes on the assembled clean tree (root pnpm-lock.yaml present)" 0 "^OK monorepo-settings-check" check "$D"
expect "repo.yaml validates" 0 "" bash -c '"$0" -B "$1/scripts/monorepo_check.py" validate "$1/repo.yaml"' "$py" "$D"
alone="$tmp/alone"; A --dest "$alone" --layout monorepo --module monorepo-root --slot REPO=demo-repo >/dev/null 2>&1
expect "the module alone assembles to a tree the check accepts (no units yet)" 0 "^OK" check "$alone"
# lockfile-missing: no JS package, no finding; a workspace file with zero package.json, no finding; a lockfile in a UNIT
# only: both second-lockfile and lockfile-missing
expect "no JS package and no pnpm-lock.yaml: no lockfile-missing" 0 "^OK" check "$alone"
c="$tmp/lk-empty"; cp -R "$alone" "$c"; mkdir -p "$c/packages/empty" "$c/apps/empty"; : > "$c/packages/empty/README.md"
out="$(check "$c" 2>&1)"; rc=$?
# the two empty directories are not units in repo.yaml, so unit-unlisted fires (that is the repo.yaml rule, not this one);
# what must NOT fire is lockfile-missing, because no directory holds a package.json
if [[ $rc -eq 1 ]] && ! grep -q 'lockfile-missing' <<<"$out" && grep -Fq 'apps/empty is not a unit' <<<"$out"; then
  pass "pnpm-workspace.yaml present, directories under packages/ and apps/ but zero package.json: no lockfile-missing"
else fail "pnpm-workspace.yaml present, directories under packages/ and apps/ but zero package.json: no lockfile-missing" "exit $rc: $(head -c 300 <<<"$out")"; fi
c="$(fresh lk-unit)"; rm "$c/pnpm-lock.yaml"; : > "$c/services/orders/pnpm-lock.yaml"
out="$(check "$c" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -Eq '^services/orders/pnpm-lock.yaml:1: second-lockfile' <<<"$out" && grep -Eq '^pnpm-lock.yaml:1: lockfile-missing' <<<"$out"; then
  pass "a lockfile in a unit and none at the root: both second-lockfile and lockfile-missing"
else fail "a lockfile in a unit and none at the root: both second-lockfile and lockfile-missing" "exit $rc: $(head -c 300 <<<"$out")"; fi

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

c="$(fresh unit1)"; sed -i.b '/id: "theme"/d' "$c/repo.yaml"; rm "$c/repo.yaml.b"
expect "a directory under packages/ missing from repo.yaml is RED" 1 "unit-unlisted packages/theme" check "$c"
c="$(fresh unit2)"; sed -i.b '/id: "orders"/d' "$c/repo.yaml"; rm "$c/repo.yaml.b"
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
printf "lockfileVersion: '9.0'\n" > "$F/pnpm-lock.yaml"
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
minlock "$B"
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
expect "the one root pnpm-lock.yaml is allowed" 0 "^OK" check "$W"
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

# ---- review 2, B1: package.json top-level keys are an ALLOW-list (root and workspace packages apart)
# One case through the CLI (the reviewer's devEngines manifest); the key matrix below runs in-process (one python
# start for all of it: a process per case is what made this suite slow).
pcase "reviewer-B1: devEngines.runtime in a workspace package is refused (pkg-key), at its line" packages/a/package.json \
  'd["devEngines"]={"runtime":{"name":"node","version":"22.11.0","onFail":"download"}}' "^packages/a/package.json:[0-9]+: pkg-key package.json key 'devEngines' is not allowed"
# the shipped manifests are accepted: the module's root package.json and the two design-system packages (verbatim copies)
DS="$tmp/dsfix"; cp -R "$alone" "$DS"; cp "$modsrc/package.json" "$DS/package.json"; mkdir -p "$DS/packages/tokens" "$DS/packages/theme"
cat > "$DS/packages/tokens/package.json" <<'J'
{
  "name": "@ds-scope/tokens",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "description": "Brand-neutral design tokens: DTCG JSON sources, alias resolver, CSS and typed TS emitters.",
  "engines": { "node": ">=24 <27" },
  "exports": {
    ".": "./src/index.ts",
    "./css": "./dist/tokens.css",
    "./json": "./dist/tokens.json"
  },
  "files": ["src", "dist"],
  "scripts": {
    "build": "node scripts/build.ts",
    "test": "vitest run",
    "typecheck": "tsc -p tsconfig.json"
  },
  "devDependencies": {
    "@types/node": "catalog:",
    "typescript": "catalog:",
    "vitest": "catalog:"
  }
}
J
cat > "$DS/packages/theme/package.json" <<'J'
{
  "name": "@ds-scope/theme",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "description": "Typed theme contract over CSS custom properties, with light and dark themes filled from the tokens package.",
  "engines": { "node": ">=24 <27" },
  "exports": {
    ".": "./src/index.ts",
    "./css": "./dist/theme.css"
  },
  "files": ["src", "dist"],
  "scripts": {
    "build": "node scripts/build.ts",
    "test": "vitest run",
    "typecheck": "tsc -p tsconfig.json"
  },
  "dependencies": {
    "@ds-scope/tokens": "workspace:*"
  },
  "devDependencies": {
    "@types/node": "catalog:",
    "typescript": "catalog:",
    "vitest": "catalog:"
  }
}
J
sed -i.b 's|^units: \[\]|units:\n  - { id: pkg-tokens, kind: package, language: ts, path: packages/tokens }\n  - { id: pkg-theme, kind: package, language: ts, path: packages/theme }|' "$DS/repo.yaml"; rm "$DS/repo.yaml.b"
minlock "$DS"
expect "the shipped root package.json and the two design-system manifests (verbatim) are accepted" 0 "^OK" check "$DS"

# ---- review 2, B2: "has target T" is make's own verdict, not "make printed something"
RULE='check-fast verify:\n\t@echo "x $@" >> "$(LOG)"\n'
mk2() { local d="$tmp/b2-$1"; mkfake "$d"; mkdir -p "$d/services/x"; printf -- "$2" > "$d/services/x/Makefile"; repo_yaml "$d" svc-x:services/x; echo "$d"; }
b2red() { # <label> <tree> <egrep over the output>: root make verify exits non-zero, matches, and no recipe ran
  local out rc; : > "$LOG"; out="$(make -s -C "$2" verify 2>&1)"; rc=$?
  if [[ $rc -ne 0 && ! -s "$LOG" && "$out" != *"verify svc-x: ok"* ]] && grep -Eq -- "$3" <<<"$out"; then pass "$1"; else fail "$1" "rc=$rc log=$(cat "$LOG") $(head -c 300 <<<"$out")"; fi
}
b2ok() { local out rc; : > "$LOG"; out="$(make -s -C "$2" verify 2>&1)"; rc=$?; if [[ $rc -eq 0 && "$out" == *"verify svc-x: ok"* ]] && logis "x verify,"; then pass "$1"; else fail "$1" "rc=$rc log=$(cat "$LOG") $(head -c 300 <<<"$out")"; fi; }
T1="$(mk2 info 'check-fast:\n\t@echo "x $@" >> "$(LOG)"\n$(info building orders)\n.PHONY: check-fast verify\n')"
b2red "a \$(info) banner + .PHONY and no verify rule: root make verify is RED, no unit recipe ran" "$T1" "svc-x: Makefile has no verify target"
T2="$(mk2 phony 'check-fast:\n\t@echo "x $@" >> "$(LOG)"\n.PHONY: check-fast verify\n')"
# review 3, B1: a Makefile that silences make's own verdict (-s / .SILENT) and has no verify RULE is still RED
T1s="$(mk2 silent 'MAKEFLAGS += -s\n$(info building orders)\ncheck-fast:\n\t@echo "x $@" >> "$(LOG)"\n.PHONY: check-fast verify\n')"
b2red "round 3: MAKEFLAGS += -s + \$(info) + .PHONY and no verify rule: root make verify is RED" "$T1s" "svc-x: Makefile has no verify target"
T1t="$(mk2 silent2 '.SILENT:\n$(info building orders)\ncheck-fast:\n\t@echo "x $@" >> "$(LOG)"\n.PHONY: check-fast verify\n')"
b2red "round 3: the .SILENT: variant is RED too" "$T1t" "svc-x: Makefile has no verify target"
T3s="$(mk2 realsilent 'MAKEFLAGS += -s\n'"$RULE"'$(info make: '"'"'verify'"'"' is up to date.)\n.PHONY: check-fast verify\n')"
b2ok "a real verify rule with -s and the old false-RED banner (\$(info make: 'verify' is up to date.)) is present (control)" "$T3s"
# What inspection executes at the root: the unit's check-fast recipe has a `+` line first, then a $(MAKE) line, the top
# level a $(shell); verify is missing so the root refuses. Measured on GNU make 3.81 and 4.3 (README, limits): the parse-time
# $(shell) runs, the `+` line runs, the $(MAKE) line runs (its sub-make is in question mode and runs no plain line).
TM="$(mk2 marker 'MAKEFLAGS += -s\n$(shell touch PARSEMARK)\n.PHONY: check-fast verify sub\ncheck-fast:\n\t+touch PLUSMARK\n\t$(MAKE) sub\nsub:\n\ttouch SUBMARK\n')"
: > "$LOG"; out="$(make -s -C "$TM" verify 2>&1)"; rc=$?
U="$TM/services/x"
[[ $rc -ne 0 && "$out" == *"svc-x: Makefile has no verify target"* && -e "$U/PARSEMARK" && -e "$U/PLUSMARK" && ! -e "$U/SUBMARK" && ! -s "$LOG" ]] \
  && pass "inspection with a mandatory target missing: the parse-time \$(shell) and the + line ran, the plain recipe line of the sub-make did not" \
  || fail "inspection markers" "rc=$rc parse=$([[ -e $U/PARSEMARK ]] && echo yes) plus=$([[ -e $U/PLUSMARK ]] && echo yes) sub=$([[ -e $U/SUBMARK ]] && echo yes) $(head -c 200 <<<"$out")"
T3="$(mk2 real "$RULE"'$(info building orders)\n.PHONY: check-fast verify\n')"
b2ok "the same Makefile with a real verify rule (banner, .PHONY): present, runs (control)" "$T3"
# BUILD STATE (real make, so it runs on whichever GNU make the host has): the root's verdict about a unit's target does not depend on
# whether what the unit builds is fresh. The ROOT `make verify` is run three times in a row on a unit whose verify builds a file: green both
# times (the later runs find the output up to date, where `make -q` alone answers 0).
bs_root() { # <label> <unit Makefile text>: a root with one unit that builds services/x/build from src.c; verify three times
  local d out rc n; d="$(mk2 "bs-$1" "$2")"; echo src > "$d/services/x/src.c"
  for n in first second third; do
    out="$(make -s -C "$d" verify 2>&1)"; rc=$?
    if [[ $rc -eq 0 && "$out" == *"verify svc-x: ok"* ]]; then pass "build state, $1: the root make verify is green on the $n run (output $([[ $n == first ]] && echo missing || echo up to date))"
    else fail "build state, $1: root make verify, $n run" "rc=$rc $(head -c 300 <<<"$out")"; fi
  done
}
bs_root "verify runs \$(MAKE) build of a real file" '.PHONY: check-fast verify\ncheck-fast:\n\t@echo cf\nverify:\n\t$(MAKE) build\nbuild: src.c\n\tcp src.c build\n'
bs_root "verify: build with build a file target" '.PHONY: check-fast verify\ncheck-fast:\n\t@echo cf\nverify: build\nbuild: src.c\n\tcp src.c build\n'
# an included makefile that has a rule is remade by GNU make 3.81 under `-q -B` (4.3 does not): the -B look pins every makefile make has
# read, so the verdict is about the target's own rule graph. The two include shapes have NO rule that runs anything for verify: RED three
# times in a row; shapes A (`$(MAKE) build`) and B (`verify: build`) in a unit that ALSO has a remade include stay green three times.
bs_red() { # <label> <unit Makefile text>: a root whose unit has no verify rule that runs anything: RED three times in a row, no recipe ran
  local d out rc n; d="$(mk2 "bsr-$1" "$2")"; echo src > "$d/services/x/src.c"
  for n in first second third; do
    : > "$LOG"; out="$(make -s -C "$d" verify 2>&1)"; rc=$?
    if [[ $rc -ne 0 && ! -s "$LOG" && "$out" == *"svc-x: Makefile has no verify target"* ]]; then pass "build state, $1: the root make verify is RED on the $n run, no recipe ran"
    else fail "build state, $1: root make verify, $n run" "rc=$rc log=$(cat "$LOG") $(head -c 300 <<<"$out")"; fi
  done
}
CFR='check-fast:\n\t@echo "x $@" >> "$(LOG)"\n'
bs_red "include of a generated makefile, PHONY verify without a recipe" "$CFR"'-include gen.mk\n.PHONY: check-fast verify\ngen.mk:\n\techo "# gen" > gen.mk\n'
bs_red "include deps.mk built from src.c, PHONY verify without a recipe" "$CFR"'include deps.mk\n.PHONY: check-fast verify\ndeps.mk: src.c\n\ttouch deps.mk\n'
bs_red "verify depends on gen.mk, an included makefile with a rule" "$CFR"'-include gen.mk\nverify: gen.mk\ngen.mk:\n\techo "# gen" > gen.mk\n'
GENINC='-include gen.mk\ngen.mk:\n\techo "# gen" > gen.mk\n'
bs_root "shape A, MAKE build, plus a remade include" "$GENINC"'.PHONY: check-fast verify\ncheck-fast:\n\t@echo cf\nverify:\n\t$(MAKE) build\nbuild: src.c\n\tcp src.c build\n'
bs_root "shape B, verify depends on build, plus a remade include" "$GENINC"'.PHONY: check-fast verify\ncheck-fast:\n\t@echo cf\nverify: build\nbuild: src.c\n\tcp src.c build\n'
# review: the double-colon makefile-rule shapes (see the `five` cases): RED three times with nothing that runs for verify, green three times with a real verify
bsxn=0
bsx() { # <red|green> <label> <unit Makefile text>: like bs_root / bs_red, with gen.in and Makefile.in beside src.c
  local d out rc n
  bsxn=$((bsxn + 1)); d="$(mk2 "bsx-$bsxn" "$3")"; echo src > "$d/services/x/src.c"; echo in > "$d/services/x/gen.in"; echo in > "$d/services/x/Makefile.in"
  touch -t 200001010000 "$d/services/x/gen.in" "$d/services/x/Makefile.in"
  for n in first second third; do
    : > "$LOG"; out="$(make -s -C "$d" verify 2>&1)"; rc=$?
    if [[ "$1" == green && $rc -eq 0 && "$out" == *"verify svc-x: ok"* ]]; then pass "double-colon, $2: the root make verify is green on the $n run"
    elif [[ "$1" == red && $rc -ne 0 && ! -s "$LOG" && "$out" == *"svc-x: Makefile has no verify target"* ]]; then pass "double-colon, $2: the root make verify is RED on the $n run, no recipe ran"
    else fail "double-colon, $2: root make verify, $n run" "rc=$rc log=$(cat "$LOG") $(head -c 300 <<<"$out")"; fi
  done
}
GENDCI='-include gen.mk\ngen.mk:: gen.in\n\techo "# gen" > gen.mk\n'
bsx red "gen.mk:: gen.in, PHONY verify without a recipe" "$CFR""$GENDCI"'.PHONY: check-fast verify\n'
bsx red "gen.mk:: ;cmd, PHONY verify without a recipe" "$CFR"'-include gen.mk\ngen.mk:: ;echo "# gen" > gen.mk\n.PHONY: check-fast verify\n'
bsx red "Makefile:: Makefile.in, PHONY verify without a recipe" "$CFR"'.PHONY: check-fast verify\nMakefile:: Makefile.in\n\t@true\n'
bsx red "Makefile:: ;@true, PHONY verify without a recipe" "$CFR"'.PHONY: check-fast verify\nMakefile:: ;@true\n'
bsx green "dcp-B, double-colon Makefile rule + verify: build" "$CFR"'.PHONY: check-fast verify\nMakefile:: Makefile.in\n\t@true\nverify: build\nbuild: src.c\n\tcp src.c build\n'
bsx green "mkdc-B, double-colon include rule + verify: build" "$CFR""$GENDCI"'.PHONY: check-fast verify\nverify: build\nbuild: src.c\n\tcp src.c build\n'
bsx green "auto-B, Makefile: Makefile.in + verify: build" "$CFR"'.PHONY: check-fast verify\nMakefile: Makefile.in\n\ttouch Makefile\nverify: build\nbuild: src.c\n\tcp src.c build\n'
# the environment scrub on the REAL make: MAKEFILES names an extra makefile that gives verify a recipe (the root's own makefile overrides its
# own verify, the unit's .PHONY-only verify would become present); the scrub keeps the verdict RED and no recipe runs. Control: a make
# that is not scrubbed sees verify as present with the same variable.
EVM="$tmp/evil.mk"; printf 'verify:\n\t@echo evil >> "$(LOG)"\n' > "$EVM"
TEV="$(mk2 evilmk "$CFR"'.PHONY: check-fast verify\n')"
[[ "$(MAKEFILES="$EVM" make -C "$TEV/services/x" -q -- verify >/dev/null 2>&1; echo $?)" == 1 ]] \
  && pass "env scrub (control): with MAKEFILES=evil.mk a plain make sees verify as present (exit 1)" || fail "env scrub control (MAKEFILES)"
: > "$LOG"; out="$(MAKEFILES="$EVM" make -s -C "$TEV" verify 2>&1)"; rc=$?
[[ $rc -ne 0 && ! -s "$LOG" && "$out" == *"svc-x: Makefile has no verify target"* ]] \
  && pass "env scrub on real make: MAKEFILES=evil.mk in the root's environment does not make a .PHONY-only verify present (RED, nothing ran)" \
  || fail "env scrub MAKEFILES" "rc=$rc log=$(cat "$LOG") $(head -c 300 <<<"$out")"
# round 4 forgery: a `define` whose value imitates make's rule data base for a verify rule, plus .PHONY, and no rule.
# Make printed that text verbatim in round 4's data base; the verdict is now its exit status, which the text cannot move.
TF="$(mk2 forge 'define FAKE\n# Files\n\nverify:\n#  commands to execute (from `Makefile'"'"', line 1):\n\t@evil\nendef\n.PHONY: check-fast verify\ncheck-fast:\n\t@echo "x $@" >> "$(LOG)"\n')"
b2red "round 4: a define imitating a rule data base + .PHONY and no verify rule: root make verify is RED, no unit recipe ran" "$TF" "svc-x: Makefile has no verify target"
# root flags: the root make's own -n/-k/-B/-s/-i must not change the verdict lines (the inspection scrubs them)
for fl in -k -B -s -i; do
  : > "$LOG"; out="$(make $fl -C "$TF" verify 2>&1)"; rc=$?
  # -i ignores every recipe error by definition, so its exit status is 0; the verdict lines and "no unit recipe ran" are what must hold
  if [[ ( $rc -ne 0 || "$fl" == -i ) && ! -s "$LOG" && "$out" == *"svc-x: Makefile has no verify target"* ]]; then pass "root make $fl verify on the forged tree: same RED verdict line, no unit recipe ran"; else fail "root make $fl forged" "rc=$rc $(head -c 200 <<<"$out")"; fi
  : > "$LOG"; out="$(make $fl -C "$T3" verify 2>&1)"; rc=$?
  if [[ $rc -eq 0 && "$out" == *"verify svc-x: ok"* ]] && logis "x verify,"; then pass "root make $fl verify on the real tree: same verdict, runs (control)"; else fail "root make $fl real" "rc=$rc $(head -c 200 <<<"$out")"; fi
done
: > "$LOG"; out="$(make -n -C "$TF" verify 2>&1)"; rc=$?
[[ $rc -eq 0 && ! -s "$LOG" && "$out" != *"evil"* ]] && pass "root make -n verify: prints, runs no unit recipe line (nothing to compare: the settings check is a recipe line of the root)" || fail "root make -n" "rc=$rc $(head -c 200 <<<"$out")"
T4="$(mk2 file "$RULE")"
T5="$(mk2 catchall '%%:\n\t@echo "fwd $@" >> "$(LOG)"\n')"
b2red "a catch-all %: rule is RED (targets cannot be verified), no recipe ran" "$T5" "unit-target unit svc-x: Makefile answers for any target name .*: targets cannot be verified"
T6="$(mk2 default '.DEFAULT:\n\t@echo "fwd $@" >> "$(LOG)"\n')"
: > "$LOG"; out="$(bash "$T5/scripts/monorepo-run.sh" verify 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *"answers for any target name"* && ! -s "$LOG" ]] && pass "the runner alone refuses a catch-all unit, no recipe ran" || fail "runner catch-all" "rc=$rc $(head -c 200 <<<"$out")"
# the probe runs FIRST and a catch-all unit is asked nothing else (test hook MONOREPO_QUESTION_LOG: one line per question actually asked)
QL="$tmp/questions.log"; : > "$QL"; MONOREPO_QUESTION_LOG="$QL" bash "$T5/scripts/monorepo-run.sh" verify >/dev/null 2>&1
[[ -s "$QL" ]] && ! grep -qvE "__monorepo_(probe|control)_" "$QL" && pass "a catch-all unit is asked only about the random probe name and the control name (every logged question names one), never about verify" \
  || fail "probe first" "$(head -c 300 "$QL")"
# a question that times out leaves nothing running: every question is its own process group, killed on timeout and afterwards.
# MONOREPO_QUESTION_TIMEOUT=2 is the test hook (default 20 s). Markers: `sleep 3737.<pid>` / `sleep 3738.<pid>` / `MARK=storm<pid>`.
leftover() { pgrep -f -- "$1" > /dev/null 2>&1; }
LKM="3737.$$"; BGM="3738.$$"
TLK="$(mk2 leak "$CFR"'verify: build\nbuild:\n\t+$(MAKE) -f sub.mk t\n')"; printf 't:\n\t+sleep %s\n' "$LKM" > "$TLK/services/x/sub.mk"; : > "$TLK/services/x/build"
SECONDS=0; : > "$LOG"; out="$(MONOREPO_QUESTION_TIMEOUT=2 make -s -C "$TLK" verify 2>&1)"; rc=$?; el=$SECONDS
if [[ $rc -ne 0 && "$out" == *"unit svc-x: timed out asking make about the verify target"* ]] && ! leftover "sleep $LKM" && ((el < 15)); then
  pass "a question that times out (a sub-make of a + line sleeping) is judged missing and no process of that tree is left (${el}s)"
else fail "timeout leaves processes" "rc=$rc el=$el left=$(pgrep -f -- "sleep $LKM" | tr '\n' ' ') $(head -c 300 <<<"$out")"; fi
leftover "sleep $LKM" && pkill -f -- "sleep $LKM"
TBG="$(mk2 bgjob "$CFR"'verify:\n\t+sleep '"$BGM"' &\n')"
out="$(check "$TBG" 2>&1 < /dev/null)"; rc=$?  # the check alone: the root's make would RUN this verify for real and leave its own sleeper
if ! leftover "sleep $BGM"; then pass "a + line that backgrounds a process and returns leaves nothing behind after the check"
else fail "background job survives" "rc=$rc left=$(pgrep -f -- "sleep $BGM" | tr '\n' ' ')"; fi
leftover "sleep $BGM" && pkill -f -- "sleep $BGM"
# TERM / HUP / INT: a question runs in its own session, so a signal to the checker, to its wrapper or to the root make's process
# group does not reach it by itself. The checker's handler kills every live question group, removes its private temp dir and
# exits 128+n; the bash wrapper runs the checker as a background child and forwards TERM. Each case: a unit whose question blocks on
# `+sleep 43.<unique>` (MONOREPO_QUESTION_TIMEOUT=300), the target started in a NEW session with its own TMPDIR, the signal sent,
# and within 2 s no process matches the marker and the TMPDIR is empty (the private dir and the wrapper's temp file are gone).
sign=0
sigcase() { # <label> <check|wrapper|make> <signal name> <expected exit status or -> [q1|b]: where the question blocks (q1: the first question; b: the -B look, after the list pass made the private dir)
  local label="$1" kind="$2" sig="$3" want="$4" stage="${5:-q1}" n=$((++sign)) u td d pid rc=- left_p left_t
  u="43.$$$n"; td="$tmp/sigt$n"; mkdir -p "$td"
  if [[ "$stage" == b ]]; then
    d="$(mk2 "sig$n" "$CFR"'.PHONY: verify\nverify: build\nbuild: src.c\n\t+sleep '"$u"'\n')"; echo src > "$d/services/x/src.c"; : > "$d/services/x/build"
  else
    d="$(mk2 "sig$n" "$CFR"'.PHONY: verify\nverify: build\nbuild:\n\t+sleep '"$u"'\n')"
  fi
  case "$kind" in
    check) set -- "$py" -B "$d/scripts/monorepo_check.py" check "$d" ;;
    wrapper) set -- bash "$d/scripts/monorepo-run.sh" verify ;;
    *) set -- make -s -C "$d" verify ;;
  esac
  MONOREPO_QUESTION_TIMEOUT=300 TMPDIR="$td" "$py" -c 'import os,signal,sys;os.setsid();signal.signal(signal.SIGINT,signal.SIG_DFL);os.execvp(sys.argv[1],sys.argv[1:])' "$@" >/dev/null 2>&1 </dev/null &
  pid=$!
  for _ in $(seq 1 60); do leftover "sleep $u" && break; sleep 0.1; done
  if ! leftover "sleep $u"; then fail "$label" "the blocking question never started"; kill -KILL "$pid" 2>/dev/null; return; fi
  if [[ "$kind" == make ]]; then kill "-$sig" -- "-$pid" 2>/dev/null; else kill "-$sig" "$pid" 2>/dev/null; fi
  for _ in $(seq 1 20); do leftover "sleep $u" || [[ -n "$(find "$td" -mindepth 1 -maxdepth 1 2>/dev/null)" ]] || break; sleep 0.1; done
  { wait "$pid"; rc=$?; } 2>/dev/null
  left_p="$(pgrep -f -- "sleep $u" | tr '\n' ' ')"; left_t="$(find "$td" -mindepth 1 -maxdepth 1 2>/dev/null | tr '\n' ' ')"
  if [[ -z "$left_p" && -z "$left_t" ]] && { [[ "$want" == - ]] || [[ "$rc" == "$want" ]]; }; then pass "$label (exit $rc, nothing left)"
  else fail "$label" "exit $rc (want $want) processes: $left_p temp: $left_t"; fi
  [[ -n "$left_p" ]] && pkill -f -- "sleep $u"; [[ "$kind" == make ]] && kill -KILL -- "-$pid" 2>/dev/null
  return 0
}
sigcase "TERM to the checker (blocked in the first question) kills the question's group" check TERM 143
sigcase "TERM to the checker (blocked in the -B look, private temp dir made) kills the group and removes the private temp dir" check TERM 143 b
sigcase "HUP to the checker (blocked in the -B look) kills the group and removes the private temp dir" check HUP 129 b
sigcase "INT to the checker (blocked in the -B look) kills the group and removes the private temp dir" check INT 130 b
sigcase "TERM to the wrapper script (monorepo-run.sh, blocked in the -B look) leaves no question and no temp file" wrapper TERM 143 b
sigcase "HUP to the wrapper script (blocked in the first question) leaves no question and no temp file" wrapper HUP 129
sigcase "INT to the wrapper script (blocked in the -B look) leaves no question and no temp file" wrapper INT 130 b
sigcase "TERM to the process group of the root make verify (blocked in the -B look) leaves nothing" make TERM - b
sigcase "HUP to the process group of the root make verify (blocked in the first question) leaves nothing" make HUP -
# the spawn window: a TERM that lands between `Popen` returning its child and the checker registering the child's group must still kill that
# group (the handler holds the signal until the group is registered). The test delivers the TERM from inside a Popen subclass, right after the
# child exists and before the registry has it; without the hold the handler runs with an empty registry and the question's sleep survives.
swu="43.$$77"; swd="$tmp/sigt-sw"; mkdir -p "$swd"
SWU="$(mk2 sigsw "$CFR"'.PHONY: verify\nverify: build\nbuild:\n\t+sleep '"$swu"'\n')"
MONOREPO_QUESTION_TIMEOUT=300 TMPDIR="$swd" "$py" -B - "$SWU/scripts/monorepo_check.py" "$SWU/services/x" > /dev/null 2>&1 <<'P'
import importlib.util, os, signal, subprocess, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
real = subprocess.Popen
class Spawn(real):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        os.kill(os.getpid(), signal.SIGTERM)
subprocess.Popen = Spawn
m.install_signal_handlers()
m.private_dir()
m.make_ask(sys.argv[2], "verify", "-q")
P
swrc=$?
sleep 1  # a surviving question needs a moment to reach its sleep: look only after that
if [[ $swrc -eq 143 ]] && ! leftover "sleep $swu" && [[ -z "$(find "$swd" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then pass "a TERM that lands while a question is being spawned still kills its group and removes the private temp dir (exit 143)"
else fail "spawn window" "exit $swrc left=$(pgrep -f -- "sleep $swu" | tr '\n' ' ') temp=$(find "$swd" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"; fi
leftover "sleep $swu" && pkill -f -- "sleep $swu"
# a second TERM during the cleanup (a process group TERM reaches the checker twice: from the group and forwarded by make) must not cut it short:
# the test sends the second TERM from inside the removal of the private temp dir; the dir must still be gone and the exit status 143.
rsd="$tmp/sigt-re"; mkdir -p "$rsd"
RSU="$(mk2 sigre "$CFR"'.PHONY: verify\n')"
TMPDIR="$rsd" "$py" -B - "$RSU/scripts/monorepo_check.py" > /dev/null 2>&1 <<'P'
import importlib.util, os, shutil, signal, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.install_signal_handlers()
m.private_dir()
real = shutil.rmtree
def twice(*a, **k):
    os.kill(os.getpid(), signal.SIGTERM)
    return real(*a, **k)
m.shutil.rmtree = twice
os.kill(os.getpid(), signal.SIGTERM)
P
rsrc=$?
if [[ $rsrc -eq 143 && -z "$(find "$rsd" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then pass "a second TERM while the checker is cleaning up does not abandon the cleanup (private temp dir removed, exit 143)"
else fail "second signal during cleanup" "exit $rsrc temp=$(find "$rsd" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"; fi
if [[ -n "${MONOREPO_STORM:-}" ]]; then # a forwarding catch-all forks without bound: run it only where the process count is capped (docker --pids-limit)
  TST="$(mk2 storm "$CFR"'%%:\n\t+$(MAKE) $@ MARK=storm'"$$"'\n')"
  SECONDS=0; : > "$LOG"; out="$(make -s -C "$TST" verify 2>&1)"; rc=$?; el=$SECONDS
  # the verdict is RED either way and that is what is asserted: where forks are allowed the probe times out (5 s) and the unit is
  # a catch-all; under a pids limit the storm hits the cap, make's forks fail and answer 2 / 2, so the unit is "no verify target"
  if [[ $rc -ne 0 && ( "$out" == *"timed out asking make about"* || "$out" == *"svc-x: Makefile has no verify target"* ) ]] && ! leftover "MARK=storm$$" && ((el < 20)); then
    pass "a forwarding catch-all (%: +\$(MAKE) \$@) is refused (RED: $([[ "$out" == *"answers for any target name"* ]] && echo catch-all || echo "no verify target, forks capped")) and nothing is left (${el}s)"
  else fail "forwarding catch-all" "rc=$rc el=$el left=$(pgrep -f -- "MARK=storm$$" | wc -l) $(head -c 300 <<<"$out")"; fi
  leftover "MARK=storm$$" && pkill -f -- "MARK=storm$$"
else skip "forwarding catch-all storm" "MONOREPO_STORM is not set (run it where the process count is capped, e.g. docker --pids-limit 512)"; fi
# A FAKE make on PATH answers the question by exit status only, so a Linux host with another GNU make is covered by
# the same verdicts: it is called `make -C <dir> -q|-n -- <target>`. FAKE_MAKE_MODE: rc0 | rc1 | rc2 | rc3 | sleep | sig | q2n0 | q2n3 | q2sleep | q2env | catchq2n0 (q2n0 | q2n3 | q2sleep: -q 2, then
# -n 0|3|silence; q2env: -q 2, then -n 0 only when the make flags are scrubbed from its environment, else 3; catchq2n0: the PROBE name answers -q 2, -n 0) |
# q0b1 | q0b0 | q0b2n0 | q0b2n2 | q0benv: -q answers 0 and the `-q -B` look answers 1 | 0 | 2 (then -n 0) | 2 (then -n 2) | 1 only when the make flags are scrubbed, else 3;
# rc1 is the "first question answers 1" mode and rc2 "both answer 2"; every call is appended to $FAKE_MAKE_LOG as `<flag> <target>` (`-qB <target>` for the -B look) when it is set.
# These modes pin the TWO-QUESTION mechanics and are the same on every GNU make; the real-make rows pin only what holds on 3.81 and 4.3.
# all1 (answers 1 to EVERY name, the probe included). Every call prints a FORGED rule data base and a verdict-looking banner:
# the root must read neither. It answers 2 to the probe name, unless in all1 mode.
FB="$tmp/fakebin"; mkdir -p "$FB"
cat > "$FB/make" <<'E'
#!/usr/bin/env bash
# the list pass is `make -C <dir> -q -f <makefile> -f <dir>/list.mk -- <name>`: note it as `-qL <name>`, write the makefile's name where the
# module's list.mk would (list.out beside it), answer 2
if [[ "${*: -1}" == __monorepo_control_* ]]; then  # the control question: 0 (settled) unless FAKE_MAKE_MODE=unsettled
  [[ -n "${FAKE_MAKE_LOG:-}" ]] && echo "-qC ${*: -1}" >> "$FAKE_MAKE_LOG"
  [[ "${FAKE_MAKE_MODE:-}" == unsettled ]] && exit 1; [[ "${FAKE_MAKE_MODE:-}" == ctlsleep ]] && exec sleep 5; exit 0
fi
if [[ "${*: -3:1}" == */list.mk ]]; then
  [[ -n "${FAKE_MAKE_LOG:-}" ]] && echo "-qL ${*: -1}${FAKE_MAKE_ENVLOG:+ env=[${MAKEFLAGS-}${MFLAGS-}${MAKELEVEL-}${MAKEOVERRIDES-}${GNUMAKEFLAGS-}${MAKEFILES-}]}" >> "$FAKE_MAKE_LOG"
  lm="${*: -3:1}"; [[ "${FAKE_MAKE_MODE:-}" == nolist ]] || printf '%s\n' "${*: -5:1}" > "${lm%list.mk}list.out"; exit 2
fi
# the -B look is `make -C <dir> -q -B -o <makefile>... -- <target>`: note it in the log as `-qB <target>`, then answer as if it were `-q -- <target>`
# every other question carries `-o <makefile>` before the `--`: strip them, then the form is `-C <dir> -q|-n [-B] -- <target>`
args=(); skip=""; for a in "$@"; do if [[ -n "$skip" ]]; then skip=""; elif [[ "$a" == -o ]]; then skip=1; else args+=("$a"); fi; done; set -- "${args[@]}"
B=""; if [[ "${4:-}" == -B ]]; then B=1; set -- "$1" "$2" "$3" "${@: -2}"; fi
[[ -n "${FAKE_MAKE_LOG:-}" ]] && echo "$3${B:+B} $5" >> "$FAKE_MAKE_LOG"
echo "make: Entering directory '$2'"; echo "# Make data base, printed on Thu Jan  1 00:00:00 2026"; echo "# Files"; echo "verify:"
echo "#  commands to execute (from \`Makefile', line 1):"; printf '\t@evil\n'; echo "make: 'verify' is up to date."
[[ "${FAKE_MAKE_MODE:-}" == all1 ]] && exit 1
[[ "${FAKE_MAKE_MODE:-}" == catchq2n0 && "$5" == __monorepo_probe_* && "$3" == -n ]] && exit 0
[[ "$5" == __monorepo_probe_* ]] && exit 2
case "${FAKE_MAKE_MODE:-}" in
  q2env) [[ "$3" == -n ]] && { [[ -z "${MAKEFLAGS-}${MFLAGS-}${MAKELEVEL-}${MAKEOVERRIDES-}${GNUMAKEFLAGS-}${MAKEFILES-}" ]] && exit 0; exit 3; }; exit 2 ;;
  catchq2n0) exit 2 ;;
  q0b1|nolist) [[ -n "$B" ]] && exit 1; [[ "$3" == -q ]] && exit 0; exit 2 ;;
  q0b0) [[ "$3" == -q ]] && exit 0; exit 2 ;;
  q0b2n0) [[ -n "$B" ]] && exit 2; [[ "$3" == -n ]] && exit 0; exit 0 ;;
  q0b2n2) [[ -n "$B" ]] && exit 2; [[ "$3" == -n ]] && exit 2; exit 0 ;;
  q0benv) [[ -n "$B" ]] && { [[ -z "${MAKEFLAGS-}${MFLAGS-}${MAKELEVEL-}${MAKEOVERRIDES-}${GNUMAKEFLAGS-}${MAKEFILES-}" ]] && exit 1; exit 3; }; [[ "$3" == -q ]] && exit 0; exit 2 ;;
  q2n0) [[ "$3" == -n ]] && exit 0; exit 2 ;; q2n3) [[ "$3" == -n ]] && exit 3; exit 2 ;; q2sleep) [[ "$3" == -n ]] && exec sleep 5; exit 2 ;;
  rc0) exit 0 ;; rc1) exit 1 ;; rc2) exit 2 ;; rc3) exit 3 ;; sleep) exec sleep 5 ;; sig) kill -9 $$ ;;
esac
exit 99
E
chmod +x "$FB/make"
# symlinked unit inside the repo, and its control (two real directories)
M7="$tmp/b3g"; mkfake "$M7"; svc_make "$M7/services/a" a "check-fast verify"; ln -s a "$M7/services/b"; repo_yaml "$M7" svc-a:services/a svc-b:services/b
: > "$LOG"; out="$(bash "$M7/scripts/monorepo-run.sh" verify 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *"services/b is a symlink"* && ! -s "$LOG" ]] && pass "the runner alone refuses the in-repo unit symlink (services/b -> a), nothing ran" || fail "in-repo symlink runner" "rc=$rc log=$(cat "$LOG") $(head -c 300 <<<"$out")"
# git: a tracked node_modules/
G="$tmp/gt"; cp -R "$B" "$G"; mkdir -p "$G/node_modules/x"; printf '{}' > "$G/node_modules/x/package.json"; git -C "$G" init -q 2>/dev/null
# the in-process matrix (module under test = the assembled copy of it)
"$py" -B - "$D/scripts/monorepo_check.py" "$W" "$T2" "$T4" "$T6" "$FB" "$M7" "$G" "$tmp" <<'P' > "$tmp/matrix.out" 2>&1
import importlib.util, json, os, re, shutil, subprocess, sys, time
mod, W, T2, T4, T6, FB, M7, G, TMP = sys.argv[1:10]
spec = importlib.util.spec_from_file_location("mc", mod); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def say(ok, name, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else " -- " + detail[:300].replace("\n", " | ")))
def run(root):
    m._rc_cache.clear()
    return ["%s:%d: %s %s" % f for f in m.check(root)]
def has(lines, pat): return any(re.search(pat, l) for l in lines)
def edit(rel, fn, root=W):
    p = os.path.join(root, rel); old = open(p).read(); d = json.loads(old); fn(d)
    open(p, "w").write(json.dumps(d, indent=2)); return p, old
def restore(p, old): open(p, "w").write(old)
assert run(W) == [], run(W)
# workspace and root: every key outside the allow-list is a pkg-key finding naming the key and the file
WS = "packages/a/package.json"; RT = "package.json"
bad = [(WS, "devEngines", {"runtime": {"name": "node", "version": "22.11.0", "onFail": "download"}}), (WS, "workspaces", ["x"]),
       (WS, "dependenciesMeta", {"typescript": {"injected": True}}), (WS, "config", {"registry": "https://registry.example.com/"}),
       (WS, "publishConfig", {"registry": "https://registry.example.com/", "main": "evil.js"}), (WS, "imports", {"#dep": "left-pad"}),
       (WS, "os", ["linux"]), (WS, "directories", {"lib": "x"}), (WS, "inventedKey", 1), (WS, "anotherInventedKey", []),
       (RT, "devEngines", {"runtime": {"name": "node", "version": "22.11.0", "onFail": "download"}}), (RT, "workspaces", ["x"]),
       (RT, "publishConfig", {"access": "public"}), (RT, "version", "1.0.0"), (RT, "inventedKey", 1)]
for rel, key, val in bad:
    p, old = edit(rel, lambda d: d.__setitem__(key, val)); out = run(W); restore(p, old)
    say(has(out, r"^%s:\d+: pkg-key package.json key '%s' is not allowed" % (re.escape(rel), key)), "pkg-key: %s in %s is refused" % (key, rel), "\n".join(out))
for label, meta, pat in (("a key besides optional", {"typescript": {"optional": True, "x": 1}}, "peerDependenciesMeta.typescript"),
                         ("a non-boolean optional", {"typescript": {"optional": "yes"}}, "peerDependenciesMeta.typescript")):
    p, old = edit(WS, lambda d: d.__setitem__("peerDependenciesMeta", meta)); out = run(W); restore(p, old)
    say(has(out, "^%s:\\d+: pkg-key %s" % (re.escape(WS), pat)), "peerDependenciesMeta with %s is refused" % label, "\n".join(out))
p, old = edit(WS, lambda d: d.__setitem__("engines", {"node": ">=24 <27", "bun": ">=1"})); out = run(W); restore(p, old)
say(has(out, "pm-engines engines.bun"), "an engines key besides node and pnpm is refused", "\n".join(out))
def allkeys(d):
    d.update({"type": "module", "description": "x", "license": "MIT", "main": "a.js", "module": "a.mjs", "types": "a.d.ts", "exports": {".": "./a.js"},
              "files": ["a.js"], "sideEffects": False, "engines": {"node": ">=24 <27"}, "bin": {"a": "a.js"}, "repository": "x", "keywords": ["a"], "author": "x",
              "peerDependencies": {"typescript": "catalog:"}, "peerDependenciesMeta": {"typescript": {"optional": True}}, "optionalDependencies": {"typescript": "catalog:"}})
p, old = edit(WS, allkeys); out = run(W); restore(p, old)
say(out == [], "every key of the workspace allow-list is accepted together", "\n".join(out))
# B2: make's own verdict
out = run(T2)
say(has(out, "unit-target unit svc-x: Makefile has no verify target") and not has(out, "no check-fast"), ".PHONY only (no banner): verify is missing, check-fast (a real rule) is present", "\n".join(out))
open(os.path.join(T4, "services/x/verify"), "w").close(); out = run(T4)
say(has(out, r"svc-x: Makefile has no verify target.*\.PHONY: verify"), "a real rule + a file named verify, no .PHONY: reported missing, with the .PHONY hint", "\n".join(out))
os.remove(os.path.join(T4, "services/x/verify")); out = run(T4)
say(out == [], "the same unit without the file: present (control)", "\n".join(out))
out = run(T2)
say(has(out, r"svc-x: Makefile has no verify target: make has nothing to run for verify even with everything considered out of date \(exit status 0 for `make -q` and for `make -q -B`\)\. Usual causes: the name only in `\.PHONY`; an empty recipe \(`verify: ;`\); prerequisites that have no recipe of their own\.")
    and not has(out, "no recipe, or a name only in"), "the idle finding says what is true: nothing to run even with everything out of date (make -q 0 and make -q -B 0), the usual causes, what to change", "\n".join(out))
open(os.path.join(T4, "services/x/verify"), "w").close(); out = run(T4)
say(has(out, r"svc-x: Makefile has no verify target.*file named verify beside a rule that is not \.PHONY.*declare `\.PHONY: verify`") and not has(out, "even with everything considered out of date"),
    "a rule with a recipe + a file named verify, no .PHONY: the .PHONY hint text, not the idle text", "\n".join(out))
os.remove(os.path.join(T4, "services/x/verify"))
out = run(T6)
say(has(out, "unit-target unit svc-x: Makefile answers for any target name .*targets cannot be verified"), "a .DEFAULT: rule is RED too", "\n".join(out))
# "unit has target T" is make's own verdict by EXIT STATUS (`make -q T`, output discarded), never what make prints.
# One scenario table: Makefile shape -> make's exit status for `verify` -> the state the root judges. Exit status 1 =
# make would run something (present), 0 = nothing to do (idle = missing), 2 = no rule / error (norule = missing).
# check-fast always has a real rule. `want_rc` is make's measured answer, the same on GNU make 3.81 and 4.3; None where the two
# differ (see the next comment): then the JUDGED state and the end-to-end result of a real `make verify` in the unit are asserted.
CF = "check-fast:\n\t@echo cf\n"
RV = "verify:\n\t@echo v\n"
UD = os.path.join(TMP, "units"); os.makedirs(UD)
def state(name, text, files=(), target="verify", extra=None):
    d = os.path.join(UD, name); os.makedirs(d)
    if text is not None: open(os.path.join(d, "Makefile"), "w").write(text)
    for f in files: open(os.path.join(d, f), "w").close()
    for f, body in (extra or {}).items():
        os.makedirs(os.path.dirname(os.path.join(d, f)), exist_ok=True); open(os.path.join(d, f), "w").write(body)
    m._rc_cache.clear(); return m.make_target_state(d, target), m.make_rc(d, target), m.make_answer(d, target)[1]
FORGE = ("define FAKE\n# Files\n\nverify:\n#  commands to execute (from `Makefile', line 1):\n\t@evil\nendef\n"
         ".PHONY: verify\n" + CF)
SCEN = [
    # (name, Makefile text, files beside it, extra files, want_rc, want_state)
    ("round 4: a define shaped like a rule data base + .PHONY, no rule", FORGE, (), None, 0, "idle"),
    ("round 3: MAKEFLAGS += -s + $(info) + .PHONY only", "MAKEFLAGS += -s\n$(info banner)\n.PHONY: check-fast verify\n" + CF, (), None, 0, "idle"),
    ("round 3: .SILENT: + $(info) + .PHONY only", ".SILENT:\n$(info banner)\n.PHONY: check-fast verify\n" + CF, (), None, 0, "idle"),
    ("round 2: a $(info) banner + .PHONY only", "$(info building orders)\n.PHONY: check-fast verify\n" + CF, (), None, 0, "idle"),
    (".PHONY only", ".PHONY: check-fast verify\n" + CF, (), None, 0, "idle"),
    ("a real rule with -s (control)", "MAKEFLAGS += -s\n.PHONY: verify\n" + RV, (), None, 1, "present"),
    ("a real rule with .SILENT (control)", ".SILENT:\n.PHONY: verify\n" + RV, (), None, 1, "present"),
    ("a real rule with a banner (control)", "$(info building orders)\n" + RV, (), None, 1, "present"),
    ("a real rule with $(info make: 'verify' is up to date.) (control)", "$(info make: 'verify' is up to date.)\n" + RV, (), None, 1, "present"),
    ("verify: ; (an explicit empty recipe)", "verify: ;\n", (), None, 0, "idle"),
    ("verify: check-fast lint where both have recipes (THE REAL SERVICE SHAPE)", "verify: check-fast lint\n" + CF + "lint:\n\t@echo l\n", (), None, 1, "present"),
    ("verify: other where other is phony with no recipe", ".PHONY: other\nverify: other\n", (), None, 0, "idle"),
    ("verify: other where other has no rule at all", "verify: other\n", (), None, 2, "norule"),
    ("check-fast verify: on one line", "check-fast verify:\n\t@echo x\n", (), None, 1, "present"),
    ("a double-colon rule", "verify::\n\t@echo v\n", (), None, 1, "present"),
    ("a rule in an included file", "include rules.mk\n", (), {"rules.mk": RV}, 1, "present"),
    ("a static pattern rule", "verify check-fast: %:\n\t@echo s\n", (), None, 1, "present"),
    ("a non-catch-all pattern rule ver%: ; @echo (round 4's false RED)", "ver%: ; @echo p\n", (), None, 1, "present"),
    ("a file named verify, no .PHONY", RV, ("verify",), None, 0, "idle"),
    ("a file named verify, with .PHONY (control)", ".PHONY: verify\n" + RV, ("verify",), None, 1, "present"),
    ("a catch-all %: with a recipe", "%:\n\t@echo fwd\n", (), None, 1, "catch-all"),
    ("a catch-all %: ; (empty recipe)", "%: ;\n", (), None, 0, "catch-all"),
    (".DEFAULT: with a recipe", ".DEFAULT:\n\t@echo fwd\n", (), None, 1, "catch-all"),
    ("an explicit rule beside a catch-all: the unit is still refused (an explicit rule cannot be told apart)", RV + "%:\n\t@echo fwd\n", (), None, 1, "catch-all"),
    ("a unit that defines exactly the probe name is not a catch-all (the probe name is random)", "__monorepo_probe_0000000000000000:\n\t@echo p\n" + RV, (), None, 1, "present"),
    ("no Makefile", None, (), None, 2, "norule"),
    ("a Makefile with a syntax error (the list pass cannot list it: error, fail closed)", "this is not a makefile\n", (), None, None, "error"),
    # ---- the second question (`make -n`, asked only when -q answered 2). GNU make 3.81 and 4.3 both execute, under -q, the first
    # recipe line when it is `+` or has $(MAKE); the exit status then differs (3.81: 2, 4.3: 1) and the judged state is the same.
    ("a $(MAKE) first line: verify: $(MAKE) check-fast, $(MAKE) lint (the review's blocker)", CF + "lint:\n\t@echo l\nverify:\n\t$(MAKE) check-fast\n\t$(MAKE) lint\n", (), None, None, "present"),
    ("@$(MAKE) --no-print-directory check-fast", CF + "verify:\n\t@$(MAKE) --no-print-directory check-fast\n", (), None, None, "present"),
    ("$(MAKE) -C sub all", "verify:\n\t$(MAKE) -C sub all\n", (), {"sub/Makefile": "all:\n\t@echo a\n"}, None, "present"),
    ("$(MAKE) first and .PHONY: verify", ".PHONY: verify\nverify:\n\t$(MAKE) check-fast\n" + CF, (), None, None, "present"),
    ("a plain line first, then $(MAKE): -q answers 1, the second question is not asked", "verify:\n\t@echo a\n\t$(MAKE) check-fast\n" + CF, (), None, 1, "present", None),
    ("verify: $(MAKE) nosuch (the sub-target has no rule: the real run fails too)", "verify:\n\t$(MAKE) nosuch\n", (), None, 2, "norule", 2),
    ("verify: $(MAKE) -f nosuch.mk", "verify:\n\t$(MAKE) -f nosuch.mk\n", (), None, 2, "norule", 2),
    ("no rule for verify at all", CF, (), None, 2, "norule", 2),
    ("a missing-file prerequisite (verify: nofile)", "verify: nofile\n\t@echo v\n", (), None, 2, "norule", 2),
    ("a Makefile with a syntax error: nothing is listed, no question is asked: error", "this is not a makefile\n", (), None, None, "error", None),
    ("no Makefile: both questions answer 2", None, (), None, 2, "norule", 2),
    ("verify: FORCE with an empty FORCE rule and no recipe", "verify: FORCE\nFORCE:\n", (), None, 0, "idle", None),
    ("verify: dep with a double-colon dep:: that has no recipe", "verify: dep\ndep::\n", (), None, 0, "idle", None),
    ("verify: | dep (order-only prerequisite) with a recipe (control)", "verify: | dep\n\t@echo v\ndep:\n", (), None, 1, "present", None),
    ("a catch-all %: whose recipe starts with $(MAKE): the probe name goes through both questions too", "%:\n\t$(MAKE) check-fast\n" + CF, (), None, None, "catch-all"),
]
for i, (name, text, files, extra, want_rc, want, *wn) in enumerate(SCEN):
    got, rc, rn = state("u%d" % i, text, files, extra=extra)
    # a 7th element is the second question's answer (asked only when the first answers 2); absent = not checked.
    # want_rc None = the exit status differs between GNU make 3.81 and 4.3: the judged state and, for a unit judged
    # present, the end-to-end result (a real `make verify` in the unit is green) are what the product guarantees.
    e2e = want == "present" and want_rc is None and subprocess.run(["make", "-C", os.path.join(UD, "u%d" % i), "verify"], capture_output=True).returncode == 0
    say(got == want and (want_rc is None or rc == want_rc) and (not wn or rn == wn[0]) and (want_rc is not None or want != "present" or e2e),
        "make -q verify: %s -> %s%s -> %s%s" % (name, "-q any of 1, 2" if want_rc is None else "-q %d" % want_rc, "" if not wn else ", -n %s" % wn[0], want,
                                              ", real run green" if want_rc is None and want == "present" else ""), "got -q %s, -n %s -> %s, real run green: %s" % (rc, rn, got, e2e))
# the version-dependent shapes: a recipe whose first line is `+` and fails. GNU make 3.81 answers 2 to both questions (judged
# missing), 4.3 answers 1 to the first (judged present); on both the root `make verify` is NOT green (judged missing: RED at the
# check; judged present: the real run fails loudly). Asserted: never green. The judged state is printed as a note.
for k, (name, text) in enumerate((("verify: +false (a failing + line)", "verify:\n\t+false\n"), ("verify: +exit 1 (a + line that fails)", "verify:\n\t+exit 1\n"),
                                  ("verify: $(MAKE) -f sub.mk x where the sub-make's recipe fails", "verify:\n\t$(MAKE) -f sub.mk x\n"))):
    got, rc, rn = state("vd%d" % k, text, (), extra={"sub.mk": "x:\n\t@false\n"})
    real = subprocess.run(["make", "-C", os.path.join(UD, "vd%d" % k), "verify"], capture_output=True).returncode
    say(got in ("present", "norule") and not (got == "present" and real == 0) and real != 0,
        "root verify is never green: %s (judged %s here: -q %s, -n %s; real run exits %s)" % (name, got, rc, rn, real), "got %s, real %s" % (got, real))
# the same function through the check, with a FAKE make on PATH answering by exit status only (and printing forged text)
path0 = os.environ["PATH"]; os.environ["PATH"] = FB + os.pathsep + path0
tmo = m.MAKE_TIMEOUT; m.MAKE_TIMEOUT = 0.3
for mode, want, name in (("rc1", None, "fake make exit 1 (would run something) for both targets: present, clean (control)"),
                         ("rc0", "exit status 0", "fake make exit 0 (nothing to do): both mandatory targets missing"),
                         ("rc2", "make -q: 2, make -n: 2", "fake make exit 2 to -q AND -n (no rule / error): both mandatory targets missing, whatever it printed"),
                         ("rc3", "exit status 3", "fake make exit 3 (any other status): both missing"),
                         ("q2n0", None, "fake make: -q 2, then -n 0 (a recipe `make -q` runs and fails): present, clean"),
                         ("q2n3", "make -q: 2, make -n: 3", "fake make: -q 2, then -n 3 (an answer that is neither): both missing, both statuses named"),
                         ("q2sleep", "timed out", "fake make: -q 2, then -n does not answer in time: both missing"),
                         ("sleep", "timed out", "fake make that does not answer in time: both missing"),
                         ("sig", "timed out, was killed", "fake make killed by a signal: both missing")):
    os.environ["FAKE_MAKE_MODE"] = mode; out = run(T2)
    if want is None: okk = out == []
    elif want == "timed out": okk = (has(out, "unit svc-x: timed out asking make about the check-fast target") and has(out, "unit svc-x: timed out asking make about the verify target")
                                     and not has(out, "no check-fast target") and not has(out, "catch|answers for any target name"))
    else: okk = has(out, "no check-fast target.*" + want) and has(out, "no verify target.*" + want)
    say(okk, name, "\n".join(out))
os.environ["FAKE_MAKE_MODE"] = "all1"; out = run(T2)
say(has(out, "unit-target unit svc-x: Makefile answers for any target name") and not has(out, "no verify target"), "fake make answering 1 to EVERY name (the probe too): RED as a catch-all", "\n".join(out))
os.environ["FAKE_MAKE_MODE"] = "catchq2n0"; out = run(T2)
say(has(out, "unit-target unit svc-x: Makefile answers for any target name") and not has(out, "no verify target"), "fake make answering the PROBE name -q 2, -n 0 (a catch-all whose recipe starts with $(MAKE)): RED as a catch-all, on any GNU make", "\n".join(out))
# the second question is asked ONLY when the first answers 2: the fake logs every call
FLOG = os.path.join(TMP, "fake-make.log"); os.environ["FAKE_MAKE_LOG"] = FLOG
for mode, asks_n in (("rc1", False), ("q2n0", True), ("rc2", True)):
    open(FLOG, "w").close(); os.environ["FAKE_MAKE_MODE"] = mode; out = run(T2); calls = open(FLOG).read().split("\n")[:-1]
    real_n = [c for c in calls if c.startswith("-n ") and not c.endswith(m.PROBE_NAME)]
    say(("-q verify" in calls) and bool(real_n) == asks_n and any(c == "-n " + m.PROBE_NAME for c in calls),
        "fake make %s: `make -n` for a real target is %s, the probe name is asked both questions" % (mode, "asked (-q answered 2)" if asks_n else "NOT asked (-q answered 1)"), str(calls))
# the second question runs in the scrubbed environment too: injected make flags must not reach the fake's -n call
os.environ["FAKE_MAKE_MODE"] = "q2env"; os.environ["MAKEFLAGS"] = "n"; os.environ["MFLAGS"] = "-n"; os.environ["GNUMAKEFLAGS"] = "-k"; out = run(T2)
for v in ("MAKEFLAGS", "MFLAGS", "GNUMAKEFLAGS"): os.environ.pop(v)
say(out == [], "the second question (-n) is asked with MAKEFLAGS / MFLAGS / GNUMAKEFLAGS scrubbed (fake q2env: -n 0 only when they are absent): present, clean", "\n".join(out))
# the -B look (a verdict independent of build state): asked ONLY when -q answered 0, only for a real target, and in the scrubbed environment
for mode, want, name in (("q0b1", None, "fake make: -q 0, then -q -B 1 (up to date, real rule graph): present, clean"),
                         ("q0b0", "exit status 0", "fake make: -q 0, then -q -B 0 (nothing to run even with everything out of date): both mandatory targets missing"),
                         ("q0b2n0", None, "fake make: -q 0, -q -B 2, then -n 0: present, clean"),
                         ("q0b2n2", "make -q: 0, make -q -B: 2, make -n: 2", "fake make: -q 0, -q -B 2, then -n 2: both missing, all three statuses named")):
    os.environ["FAKE_MAKE_MODE"] = mode; out = run(T2)
    if want is None: okk = out == []
    else: okk = has(out, "no check-fast target.*" + want) and has(out, "no verify target.*" + want)
    say(okk, name, "\n".join(out))
for mode, want_b, want_n in (("rc1", False, False), ("q0b1", True, False), ("q0b0", True, False), ("q0b2n0", True, True), ("rc2", False, True)):
    open(FLOG, "w").close(); os.environ["FAKE_MAKE_MODE"] = mode; out = run(T2); calls = open(FLOG).read().split("\n")[:-1]
    look_b = [c for c in calls if c.startswith("-qB ")]
    first = all(("-q " + c[4:]) in calls[:calls.index(c)] for c in look_b)
    real_n = [c for c in calls if c.startswith("-n ") and not c.endswith(m.PROBE_NAME)]
    say(bool(look_b) == want_b and first and not any(c.endswith(m.PROBE_NAME) for c in look_b) and bool(real_n) == want_n,
        "fake make %s: `-q -B` is %s (only as the second look, never for the probe name); `make -n` for a real target is %s" % (
            mode, "asked" if want_b else "NOT asked", "asked" if want_n else "NOT asked"), str(calls))
os.environ["FAKE_MAKE_MODE"] = "q0benv"; os.environ["MAKEFLAGS"] = "n"; os.environ["MFLAGS"] = "-n"; os.environ["GNUMAKEFLAGS"] = "-k"; out = run(T2)
for v in ("MAKEFLAGS", "MFLAGS", "GNUMAKEFLAGS"): os.environ.pop(v)
say(out == [], "the -B look is asked with MAKEFLAGS / MFLAGS / GNUMAKEFLAGS scrubbed (fake q0benv: -q -B 1 only when they are absent): present, clean", "\n".join(out))
# the list pass: asked once per unit, FIRST, whatever the first question answers, scrubbed like every question; the -B look
# carries -o for what the pass wrote; a pass that writes nothing fails closed (error, `-qB` never asked)
for mode, want_l, want_b in (("rc1", True, False), ("rc2", True, False), ("q0b1", True, True), ("q0b0", True, True)):
    open(FLOG, "w").close(); os.environ["FAKE_MAKE_MODE"] = mode; os.environ["FAKE_MAKE_ENVLOG"] = "1"
    os.environ["MAKEFLAGS"] = "n"; os.environ["MFLAGS"] = "-n"; os.environ["GNUMAKEFLAGS"] = "-k"; os.environ["MAKEFILES"] = "/nonexistent.mk"
    out = run(T2)
    for v in ("MAKEFLAGS", "MFLAGS", "GNUMAKEFLAGS", "MAKEFILES", "FAKE_MAKE_ENVLOG"): os.environ.pop(v)
    calls = open(FLOG).read().split("\n")[:-1]; lp = [c for c in calls if c.startswith("-qL ")]
    scrubbed = all(c.endswith(" env=[]") for c in lp)
    say(bool(lp) == want_l and (not want_l or (len(lp) == 1 and all(c.startswith("-qL " + m.PROBE_NAME) for c in lp))) and scrubbed
        and bool([c for c in calls if c.startswith("-qB ")]) == want_b,
        "fake make %s: the list pass is %s (once per unit, for the probe name, env scrubbed)" % (mode, "asked" if want_l else "NOT asked"), str(calls))
open(FLOG, "w").close(); os.environ["FAKE_MAKE_MODE"] = "nolist"; out = run(T2); calls = open(FLOG).read().split("\n")[:-1]
os.environ.pop("FAKE_MAKE_MODE")
say(has(out, "no check-fast target: make could not answer for check-fast \\(the makefiles make read could not be listed") and not [c for c in calls if c.startswith("-qB ")],
    "a list pass that wrote nothing fails closed: 'could not be listed', no -B look is asked", "\n".join(out) + str(calls))
os.environ.pop("FAKE_MAKE_LOG")
m.MAKE_TIMEOUT = tmo
# the runner's `units` over the fake: rc1 -> has=1, rc0/rc2 -> has=0, all1 -> refused (rc 2, nothing listed)
for mode, wantrc, want in (("rc1", 0, "\t1\t1"), ("q2n0", 0, "\t1\t1"), ("rc0", 0, "\t0\t1"), ("rc2", 0, "\t0\t1"), ("all1", 2, "")):
    os.environ["FAKE_MAKE_MODE"] = mode
    r = subprocess.run([sys.executable, "-B", mod, "units", T2, "verify"], capture_output=True, text=True)
    say(r.returncode == wantrc and want in r.stdout and (mode != "all1" or ("answers for any target name" in r.stderr and r.stdout == "")),
        "the runner's `units` over a fake make in mode %s: rc %d, row ends %r" % (mode, wantrc, want), r.stdout + r.stderr)
for mode, want in (("q0b1", "\t1\t1"), ("q0b0", "\t0\t1")):
    os.environ["FAKE_MAKE_MODE"] = mode
    r = subprocess.run([sys.executable, "-B", mod, "units", T2, "verify"], capture_output=True, text=True)
    say(r.returncode == 0 and want in r.stdout, "the runner's `units` over a fake make in mode %s: row ends %r" % (mode, want), r.stdout + r.stderr)
os.environ["PATH"] = path0; os.environ.pop("FAKE_MAKE_MODE")
# root make flags must not change the verdict: the scrub. A MAKEFLAGS the root make would hand to the check is injected;
# the answer for the forged tree, the file-named-verify tree and the real tree must be what it is without flags.
for fl in ("n", "B", "i", "k", "s", "t", "-j2 --warn-undefined-variables"):
    os.environ["MAKEFLAGS"] = fl; os.environ["MFLAGS"] = "-" + fl
    rows = (("forged", FORGE, (), "idle"), ("file", RV, ("verify",), "idle"), ("real", RV, (), "present"))
    res = []
    for nm, tx, fs, want in rows:
        got, rc, _ = state("flag-%s-%s" % (fl.split()[0].lstrip("-"), nm), tx, fs)
        res.append(got == want)
    say(all(res), "inherited MAKEFLAGS=%r: forged .PHONY tree and file-named-verify tree still missing, real rule still present" % fl, str(res))
os.environ.pop("MAKEFLAGS"); os.environ.pop("MFLAGS")
# what inspection executes (the same on GNU make 3.81 and 4.3, measured on both; README limits). Each case pins ONE fact with a marker file.
def marker(name, text, claim_ran, claim_notran, target="verify", extra=None):
    d = os.path.join(UD, "mk-" + name); os.makedirs(d)
    open(os.path.join(d, "Makefile"), "w").write(text)
    for f, body in (extra or {}).items(): open(os.path.join(d, f), "w").write(body)
    m._rc_cache.clear(); m.make_rc(d, target)
    ran = {f for f in os.listdir(d) if f.isupper()}
    say(set(claim_ran) <= ran and not (set(claim_notran) & ran), "make -q: " + {
        "parse": "a parse-time $(shell) runs",
        "remake": "an included file that has a rule is remade (make's own makefile remaking)",
        "plusT": "a `+` line of the target itself runs",
        "plusP1": "a `+` line of a prerequisite runs",
        "plusP2": "a `+` line of a SECOND prerequisite runs too",
        "submake": "a $(MAKE) line runs",
        "plain": "a plain recipe line does not run",
        "afterplain": "a `+` line AFTER the first plain line of a recipe does not run (a recipe runs at most up to its first plain line)",
        "plainthenplus": "a recipe whose first line is plain runs none of its lines, `+` lines later in it included",
        "plainTplusP": "the `+` line of a prerequisite runs, the target's own plain recipe does not",
        "remakefull": "an included file's remake runs its recipe IN FULL (the plain lines too)",
        "qdelete": "a file target a `+` line created is deleted again when the recipe goes on with a plain line",
        "qkeep": "a file target a `+` line created is kept when the recipe ends there (control for the deletion)",
    }[name], "ran: %s" % sorted(ran))
marker("parse", "X := $(shell touch PARSE)\nverify:\n\t@echo v\n", ["PARSE"], [])
marker("remake", "-include gen.mk\ngen.mk:\n\ttouch GEN\nverify:\n\t@echo v\n", ["GEN"], [])
marker("plusT", ".PHONY: verify\nverify:\n\t+touch PLUST\n", ["PLUST"], [])
marker("plusP1", ".PHONY: verify p1\nverify: p1\np1:\n\t+touch PLUSP1\n", ["PLUSP1"], [])
marker("plusP2", ".PHONY: verify p1 p2\nverify: p1 p2\np1:\n\t+touch PLUSP1\np2:\n\t+touch PLUSP2\n", ["PLUSP1", "PLUSP2"], [])
marker("submake", ".PHONY: verify\nverify:\n\t$(MAKE) -f sub.mk\n", ["SUBRAN"], [], extra={"sub.mk": "$(shell touch SUBRAN)\nx: ;\n"})
marker("plain", ".PHONY: verify\nverify:\n\ttouch PLAIN\n", [], ["PLAIN"])
marker("afterplain", ".PHONY: verify\nverify:\n\ttouch PLAIN\n\t+touch AFTER\n", [], ["PLAIN", "AFTER"])
marker("plainthenplus", ".PHONY: verify\nverify:\n\t@echo first\n\t+touch LATER\n\t$(MAKE) -f sub.mk\n", [], ["LATER", "SUBRAN"], extra={"sub.mk": "$(shell touch SUBRAN)\nx: ;\n"})
marker("plainTplusP", ".PHONY: verify p1\nverify: p1\n\ttouch PLAINT\np1:\n\t+touch PLUSP1\n", ["PLUSP1"], ["PLAINT"])
marker("remakefull", "-include gen.mk\ngen.mk:\n\ttouch GEN1\n\t@echo x\n\ttouch GEN2\nverify:\n\t@echo v\n", ["GEN1", "GEN2"], [])
# a file target created by a `+` line: under -q make deletes it when the recipe goes on with a plain line (3.81 and 4.3), keeps it otherwise
marker("qdelete", "VERIFY:\n\t+touch VERIFY\n\t@echo b\n", [], ["VERIFY"], target="VERIFY")
marker("qkeep", "VERIFY:\n\t+touch VERIFY\n", ["VERIFY"], [], target="VERIFY")
# the SECOND question, `make -n`, asked alone: it walks the WHOLE recipe, so every `+` / $(MAKE) line of the target and of
# all its out-of-date prerequisites runs (sub-makes in dry-run mode: their `+` lines run, their plain lines do not)
def marker_n(name, text, claim_ran, claim_notran, extra=None):
    d = os.path.join(UD, "mn-" + name); os.makedirs(d)
    open(os.path.join(d, "Makefile"), "w").write(text)
    for f, body in (extra or {}).items(): open(os.path.join(d, f), "w").write(body)
    m._rc_cache.clear(); m.make_rc_dry(d, "verify")
    ran = {f for f in os.listdir(d) if f.isupper()}
    say(set(claim_ran) <= ran and not (set(claim_notran) & ran), "make -n: " + {
        "walk": "`+` lines run after plain lines too (both of them), plain lines do not",
        "prereqs": "`+` lines of two prerequisites run after their plain lines",
        "sub": "a $(MAKE) line runs, its sub-make in dry-run mode runs its `+` line and not its plain line",
        "plain": "a plain recipe line does not run",
    }[name], "ran: %s" % sorted(ran))
marker_n("walk", "verify:\n\t@echo a\n\t+touch M1\n\ttouch PLAIN\n\t+touch M2\n", ["M1", "M2"], ["PLAIN"])
marker_n("prereqs", ".PHONY: verify p1 p2\nverify: p1 p2\n\t@echo v\np1:\n\t@echo x\n\t+touch P1A\n\t@echo y\n\t+touch P1B\np2:\n\t+touch P2\n", ["P1A", "P1B", "P2"], [])
marker_n("sub", "verify:\n\t@echo a\n\t$(MAKE) -f sub.mk t\n", ["SUBPLUS"], ["SUBPLAIN"], extra={"sub.mk": "t:\n\t+touch SUBPLUS\n\t@echo x\n\ttouch SUBPLAIN\n"})
marker_n("plain", "verify:\n\ttouch PLAIN\n", [], ["PLAIN"])
# BUILD STATE on the real make: the verdict does not depend on whether the outputs are fresh. Judged before a real run, the real run is green,
# judged again after it (outputs up to date: `make -q` alone answers 0 now).
for k, (txt, fl) in {"verify runs $(MAKE) build of a real file": (".PHONY: verify\nverify:\n\t$(MAKE) build\nbuild: src.c\n\tcp src.c build\n", {"src.c": "x"}),
                     "verify: build with build a file target": (".PHONY: verify\nverify: build\nbuild: src.c\n\tcp src.c build\n", {"src.c": "x"})}.items():
    nm = "bs-" + k.split()[1].strip(":$()")
    before = state(nm, txt, extra=fl)[0]; d = os.path.join(UD, nm)
    real = subprocess.run(["make", "-C", d, "verify"], capture_output=True).returncode
    m._rc_cache.clear(); after = m.make_target_state(d, "verify"); qa = m.make_rc(d, "verify"); qb = m.make_rc_always(d, "verify")
    # the -B path is certain only for the prerequisite shape (-q 0 after, -q -B 1); the sub-make shape answers 1 or 0 on -q, by version
    say(before == "present" and real == 0 and after == "present" and (k.startswith("verify runs") or (qa == 0 and qb == 1)),
        "build state, %s: present before a real `make verify`, the real run is green, present after (outputs up to date)" % k, "before %s real %s after %s (-q %s, -q -B %s)" % (before, real, after, qa, qb))
for k, (txt, fl) in {"a non-phony verify FILE target with a recipe": ("verify:\n\t@echo v\n", ("verify",)), "a non-phony verify file with no recipe": ("verify:\n", ("verify",))}.items():
    nm = "bf-" + str(len(k)); before = state(nm, txt, fl)[0]; d = os.path.join(UD, nm)
    real = subprocess.run(["make", "-C", d, "verify"], capture_output=True).returncode; m._rc_cache.clear()
    say(before == "idle" and real == 0 and m.make_target_state(d, "verify") == "idle", "build state, %s: idle before and after a real `make verify` (up to date, nothing runs)" % k, "before %s real %s" % (before, real))
# `make -q -B`: the same classes of lines as `-q`, but more of them, since nothing counts as up to date; the markers are the same on 3.81 and 4.3.
def marker_b(label, text, claim_ran, claim_notran, ctl, extra=None):
    ran = {}
    for look, fn in (("q", m.make_rc), ("B", m.make_rc_always)):
        d = os.path.join(UD, "mb-%d-%s" % (len(os.listdir(UD)), look)); os.makedirs(d)
        open(os.path.join(d, "Makefile"), "w").write(text)
        for f, body in (extra or {}).items():
            open(os.path.join(d, f), "w").write(body); os.utime(os.path.join(d, f), (1, 1)) if f in ("f", "src") else None
        m._rc_cache.clear(); fn(d, "verify"); ran[look] = {f for f in os.listdir(d) if f.isupper()}
    say(set(claim_ran) <= ran["B"] and not (set(claim_notran) & ran["B"]) and not (set(ctl) & ran["q"]),
        "make -q -B: " + label, "-q ran %s, -q -B ran %s" % (sorted(ran["q"]), sorted(ran["B"])))
marker_b("an up-to-date prerequisite's `+` line runs (it does not under -q alone)", ".PHONY: verify\nverify: p1\n\t@echo v\np1: f\n\t+touch PLUSP1\n", ["PLUSP1"], [], ["PLUSP1"], extra={"f": "", "p1": ""})
marker_b("a sub-make is given -B: the `+` line of its up-to-date target runs (it does not under -q alone)", "verify:\n\t$(MAKE) -f sub.mk t\n", ["SUBPLUS"], [], ["SUBPLUS"], extra={"sub.mk": "t: f\n\t+touch SUBPLUS\n", "f": "", "t": ""})
marker_b("an up-to-date included file that has a rule is NOT remade (pinned: neither under -q nor under -q -B)", "-include gen.mk\ngen.mk: src\n\ttouch GEN1\n\t@echo x\n\ttouch GEN2\nverify:\n\t@echo v\n", [], ["GEN1", "GEN2"], ["GEN1"], extra={"src": "", "gen.mk": ""})
marker_b("a plain recipe line still does not run", ".PHONY: verify\nverify:\n\ttouch PLAIN\n", [], ["PLAIN"], [])
marker_b("a `+` line after a plain line of the target's recipe still does not run", ".PHONY: verify\nverify:\n\ttouch PLAIN\n\t+touch AFTER\n", [], ["PLAIN", "AFTER"], [])
marker_b("a parse-time $(shell) runs", "X := $(shell touch PARSE)\nverify:\n\t@echo v\n", ["PARSE"], [], [])
# the second question is asked ONLY when the first answers 2: over the three shipped service Makefiles (-q answers 1 for
# their check-fast and verify) a counting make on PATH sees no `-n` for any real target; the only -n is the probe's
CB = os.path.join(TMP, "countbin"); os.makedirs(CB); CLOG = os.path.join(TMP, "make-calls.log")
real_make = shutil.which("make")
open(os.path.join(CB, "make"), "w").write('#!/usr/bin/env bash\necho "$3 ${@: -1}" >> "%s"\nexec "%s" "$@"\n' % (CLOG, real_make))
os.chmod(os.path.join(CB, "make"), 0o755)
repo = os.environ["REPO_HERE"]; path1 = os.environ["PATH"]; os.environ["PATH"] = CB + os.pathsep + path1
units3 = ("prod-new/template", "prod-new/modules/service-rust", "prod-new/modules/service-python/template")
states = []
for u in units3:
    m._rc_cache.clear()
    for t in ("check-fast", "verify"): states.append(m.make_target_state(os.path.join(repo, u), t))
calls = open(CLOG).read().split("\n")[:-1] if os.path.exists(CLOG) else []
dry = [c for c in calls if c.startswith("-n ")]
os.environ["PATH"] = path1
say(states == ["present"] * 6 and len(calls) > 0 and all(c.split(" ", 1)[1] == m.PROBE_NAME for c in dry) and 0 < len(dry) <= len(units3)
    and sum(c.startswith("-q ") and not c.endswith((m.PROBE_NAME, m.CONTROL_NAME)) for c in calls) == 6,
    "the three shipped service Makefiles (check-fast, verify): present on -q alone, `make -n` asked only for the probe name (at most once per unit)", "states %s calls %s" % (states, calls))
# ... and no `-B` look is ever asked for them (it is asked only when -q answers 0): a make on PATH that logs ALL its arguments
CB2 = os.path.join(TMP, "countbin2"); os.makedirs(CB2); CLOG2 = os.path.join(TMP, "make-args.log")
open(os.path.join(CB2, "make"), "w").write('#!/usr/bin/env bash\necho "$*" >> "%s"\nexec "%s" "$@"\n' % (CLOG2, real_make)); os.chmod(os.path.join(CB2, "make"), 0o755)
os.environ["PATH"] = CB2 + os.pathsep + path1
states2 = []
for u in units3:
    m._rc_cache.clear()
    for t in ("check-fast", "verify"): states2.append(m.make_target_state(os.path.join(repo, u), t))
os.environ["PATH"] = path1
args2 = open(CLOG2).read().split("\n")[:-1] if os.path.exists(CLOG2) else []
say(states2 == ["present"] * 6 and len(args2) >= 6 and not any("-B" in a.split() for a in args2),
    "the three shipped service Makefiles: no `make -q -B` question is asked for any of their targets (nor the probe name)", "states %s args %s" % (states2, args2))
# the limit the README names: the inspection sees a unit as plain `make <target>` would, without the caller's command-line
# variables. `make verify MODE=fast` at the root reaches the unit's make as a command-line override; the inspection (flags
# scrubbed) sees only an environment MODE, which `MODE := strict` overrides. PINNED, not fixed.
cv = os.path.join(UD, "cmdvar"); os.makedirs(cv)
open(os.path.join(cv, "Makefile"), "w").write("MODE := strict\nifeq ($(MODE),fast)\nverify: ;\nelse\nverify:\n\t@echo v\nendif\n")
os.environ["MODE"] = "fast"; m._rc_cache.clear(); st_cv = m.make_target_state(cv, "verify")
real_cv = subprocess.run(["make", "-C", cv, "-q", "--", "verify", "MODE=fast"], capture_output=True).returncode; os.environ.pop("MODE")
say(st_cv == "present" and real_cv == 0, "pinned limit: `MODE := strict` + `ifeq ($(MODE),fast)` -> `verify: ;`: the inspection (env MODE=fast) says present, the real run with MODE=fast on the command line has nothing to do (-q 0)", "inspection %s, command-line -q %s" % (st_cv, real_cv))
# a manifest that does not parse: ONE pkg-parse finding, no stray-package-json and no "no test script" besides
for label, raw in (("a trailing comma", '{"name":"a","version":"1.0.0","scripts":{"test":"true",}}'), ("a BOM", "\ufeff" + '{"name":"a","version":"1.0.0","scripts":{"test":"true"}}')):
    pj = os.path.join(W, "packages/a/package.json"); old = open(pj, encoding="utf-8").read()
    open(pj, "w", encoding="utf-8").write(raw); out = run(W); open(pj, "w", encoding="utf-8").write(old)
    mine = [l for l in out if l.startswith("packages/a/package.json:")]
    say(len(mine) == 1 and "pkg-parse" in mine[0] and len(out) == 1, "package.json with %s: exactly ONE finding (pkg-parse), no stray / no-test-script follow-ups" % label, "\n".join(out))
# review: -B look is pinned (GNU make 3.81 remakes an included makefile under -B). Judged at five points: fresh, after a real run, again,
# after touching a source, after another real run; the verdict must be the same at every point.
GEN = "-include gen.mk\ngen.mk:\n\techo '# gen' > gen.mk\n"
def five(label, text, want, extra=None):
    nm = "five-%d" % len(os.listdir(UD)); d = os.path.join(UD, nm); os.makedirs(d); open(os.path.join(d, "Makefile"), "w").write(text)
    for f, body in (extra or {}).items(): open(os.path.join(d, f), "w").write(body)
    for f in ("Makefile.in", "gen.in"):  # a prerequisite of a makefile rule is OLDER than the makefile: same mtime tick or not, the answer must not depend on it
        if os.path.exists(os.path.join(d, f)): os.utime(os.path.join(d, f), (946684800, 946684800))
    def judge(): m._rc_cache.clear(); return m.make_target_state(d, "verify")
    def real(): subprocess.run(["make", "-C", d, "verify"], capture_output=True)
    pts = [judge()]; real(); pts.append(judge()); pts.append(judge())
    if os.path.exists(os.path.join(d, "src.c")): os.utime(os.path.join(d, "src.c"), None)
    pts.append(judge()); real(); pts.append(judge())
    say(pts == [want] * 5, "-B look pinned, %s: judged %s at all five points" % (label, want), "points %s" % pts)
SRC = {"src.c": "x"}
five("`-include gen.mk` with a rule + .PHONY verify (no rule runs anything)", GEN + ".PHONY: verify\n", "idle")
five("`include deps.mk` (deps.mk: src.c) + .PHONY verify", "include deps.mk\n.PHONY: verify\ndeps.mk: src.c\n\ttouch deps.mk\n", "idle", SRC)
five("`verify: gen.mk` where gen.mk is included and has a rule", GEN + "verify: gen.mk\n", "idle")
five("shape A (verify runs $(MAKE) build) + a remade include", GEN + ".PHONY: verify\nverify:\n\t$(MAKE) build\nbuild: src.c\n\tcp src.c build\n", "present", SRC)
five("shape B (verify: build) + a remade include", GEN + ".PHONY: verify\nverify: build\nbuild: src.c\n\tcp src.c build\n", "present", SRC)
five("shape B without include (control)", ".PHONY: verify\nverify: build\nbuild: src.c\n\tcp src.c build\n", "present", SRC)
five(".PHONY only, no include (control)", ".PHONY: verify\n", "idle")
five("stamp design (verify: .stamp, .stamp: src.c)", ".PHONY: verify\nverify: .stamp\n.stamp: src.c\n\ttouch .stamp\n", "present", SRC)
# review: the -B look must not add rules to the unit's rule base. An eval'd pin rule for a makefile collides with a DOUBLE-COLON rule for the same
# makefile ("both : and :: entries": exit 2, then `-n` 0 judged a rule-less unit present). The look names the makefiles with -o instead. Same
# five points, both makes: the double-colon shapes with nothing that runs for verify are idle; with a REAL verify they stay present.
SRC2 = {"src.c": "x", "gen.in": "x", "Makefile.in": "x"}
GENDC = "-include gen.mk\ngen.mk:: gen.in\n\techo '# gen' > gen.mk\n"
five("double-colon include rule (gen.mk:: gen.in) + .PHONY verify", GENDC + ".PHONY: verify\n", "idle", SRC2)
five("double-colon include rule with an inline recipe (gen.mk:: ;cmd) + .PHONY verify", "-include gen.mk\ngen.mk:: ;echo '# gen' > gen.mk\n.PHONY: verify\n", "idle")
five("double-colon rule for the unit's own makefile (Makefile:: Makefile.in) + .PHONY verify", ".PHONY: verify\nMakefile:: Makefile.in\n\t@true\n", "idle", SRC2)
five("double-colon rule for the unit's own makefile (Makefile:: ;@true) + .PHONY verify", ".PHONY: verify\nMakefile:: ;@true\n", "idle")
five("deferred ROOT = $(dir $(lastword $(MAKEFILE_LIST))) + .SECONDEXPANSION, nothing runs", ".SECONDEXPANSION:\nROOT = $(dir $(lastword $(MAKEFILE_LIST)))\n.PHONY: verify\nverify: $$(ROOT)Makefile\n", "idle")
five("verify: FORCE (FORCE has no rule)", "verify: FORCE\nFORCE:\n", "idle")
five("verify: dep with a double-colon dep:: and no recipe", "verify: dep\ndep::\n", "idle")
B_ = ".PHONY: verify\nverify: build\nbuild: src.c\n\tcp src.c build\n"
five("dcp-B: double-colon Makefile rule + a real verify (verify: build)", ".PHONY: verify\nMakefile:: Makefile.in\n\t@true\nverify: build\nbuild: src.c\n\tcp src.c build\n", "present", SRC2)
five("mkdc-B: double-colon include rule + a real verify", GENDC + B_, "present", SRC2)
five("dcp-B2: double-colon Makefile rule without prerequisites (Makefile:: ;@true) + a real verify", ".PHONY: verify\nMakefile:: ;@true\nverify: build\nbuild: src.c\n\tcp src.c build\n", "present", SRC)
five("auto-B: single-colon Makefile: Makefile.in + a real verify", ".PHONY: verify\nMakefile: Makefile.in\n\ttouch Makefile\nverify: build\nbuild: src.c\n\tcp src.c build\n", "present", SRC2)
five("pattern rule + a real verify (verify: x.out, %.out: %.in)", ".PHONY: verify\n%.out: %.in\n\tcp $< $@\nverify: x.out\n", "present", {"x.in": "x"})
five("deferred MAKEFILE_LIST + .SECONDEXPANSION + a real verify", ".SECONDEXPANSION:\nROOT = $(dir $(lastword $(MAKEFILE_LIST)))\n.PHONY: verify\nverify: $$(ROOT)build\nbuild: src.c\n\tcp src.c build\n", "present", SRC)
five("build recipe starts with $(MAKE) (-q 0 when up to date, -q -B 2, -n 0): present", ".PHONY: verify\nverify: build\nbuild: src.c\n\t$(MAKE) -f Makefile copy\ncopy:\n\tcp src.c build\n", "present", SRC)
# PINNED LIMIT: a makefile rule whose recipe leaves its prerequisite NEWER than the makefile (here `Makefile:: Makefile.in` with `@true`, Makefile.in newer)
# never converges. Under `-o Makefile` the control question loops on GNU make 3.81 and on 4.3 alike (measured on both): it times out, the state is `error`
# with the reason `timeout` (the finding says "timed out"), one timeout per unit (nothing more is asked after it). Asserted: error/timeout, quick, on any make.
d = os.path.join(UD, "never-converges"); os.makedirs(d)
open(os.path.join(d, "Makefile"), "w").write(".PHONY: verify\nMakefile:: Makefile.in\n\t@true\nverify: build\nbuild: src.c\n\tcp src.c build\n")
for f in ("src.c", "Makefile.in", "build"): open(os.path.join(d, f), "w").write("x")
os.utime(os.path.join(d, "Makefile"), (946684800, 946684800)); os.utime(os.path.join(d, "src.c"), (946684800, 946684800))
os.utime(os.path.join(d, "Makefile.in"), (946684900, 946684900)); os.utime(os.path.join(d, "build"), (946685000, 946685000))
def fresh_state(): m._rc_cache.clear(); m._timed_out.clear()
m.MAKE_TIMEOUT = 2.0; m.PROBE_TIMEOUT = 2.0; fresh_state(); t0 = time.time(); st_nc = m.make_target_state(d, "verify"); st_nc2 = m.make_target_state(d, "check-fast"); el_nc = time.time() - t0
why_nc = m.unit_why(d); m.MAKE_TIMEOUT = 20.0; m.PROBE_TIMEOUT = 5.0
say(st_nc == "error" and st_nc2 == "error" and why_nc == "timeout" and el_nc < 8, "pinned limit: a makefile rule whose prerequisite stays newer than the makefile is error / timed out (not present, not catch-all), one timeout for two targets, quickly", "state %s %s why %s after %.1fs" % (st_nc, st_nc2, why_nc, el_nc))
# the review's shapes: an included makefile that make REMAKES (a FORCE'd `-include version.mk`) or that is MISSING and whose rule does not create it. Before the
# list-first order GNU make 3.81 answered `-q` 1 to every target for them: `.PHONY: verify` or `verify: ;` was judged present with nothing to run.
mk_ver = subprocess.run(["make", "--version"], capture_output=True, text=True).stdout.split("\n")[0]; is381 = "3.81" in mk_ver
m.MAKE_TIMEOUT = 3.0; m.PROBE_TIMEOUT = 3.0
def shape(tag, inc, verify, extra=None):
    d = os.path.join(UD, "inc-" + tag); os.makedirs(d); open(os.path.join(d, "Makefile"), "w").write(inc + verify)
    for f, body in (extra or {}).items(): open(os.path.join(d, f), "w").write(body)
    fresh_state(); return m.make_target_state(d, "verify")
VF = {"no rule": "", ".PHONY only": ".PHONY: verify\n", "verify: ;": "verify: ;\n"}; REAL = "verify:\n\t@echo v\n"
FORCEW = "-include version.mk\nversion.mk: FORCE\n\t@echo V=1 > version.mk\nFORCE:\n"
FORCEN = "-include version.mk\nversion.mk: FORCE\n\t@true\nFORCE:\n"
NOCREATE = "-include gen.mk\ngen.mk:\n\t@true\n"
CREATES = "include gen.mk\ngen.mk:\n\t@echo '# g' > gen.mk\n"
for nm, inc, ok_idle in (("FORCE'd -include version.mk (recipe writes it)", FORCEW, True), ("FORCE'd -include version.mk (recipe writes nothing)", FORCEN, False),
                         ("-include gen.mk whose rule does not create it", NOCREATE, False)):
    for vn, vt in VF.items():
        st = shape("%s-%s" % (len(os.listdir(UD)), vn[:3]), inc, vt)
        # safety direction, both makes: never present. 3.81: the unsettled makefile is error (control), except the FORCE'd one that WRITES its file (judged on the target)
        want_ok = st != "present" and ((not is381) or ok_idle or st == "error")
        say(want_ok, "%s + %s: not judged present (here: %s)%s" % (nm, vn, st, "; on 3.81 an unsettled makefile is error" if is381 and not ok_idle else ""), "state %s on %s" % (st, mk_ver))
    if not (is381 is False and ok_idle):  # 4.3 re-executes a FORCE'd include forever on the real run too: its real-verify judgment is flaky there, not asserted
        st = shape("%s-real" % len(os.listdir(UD)), inc, REAL)
        want = "present" if (ok_idle or not is381) else "error"
        say(st == want, "%s + a real verify: %s on %s" % (nm, want, "3.81" if is381 else "4.3"), "state %s on %s" % (st, mk_ver))
for vn, vt, want in (("no rule", "", "norule"), (".PHONY only", ".PHONY: verify\n", "idle"), ("verify: ;", "verify: ;\n", "idle"), ("a real verify", REAL, "present")):
    st = shape("cr-%s" % len(os.listdir(UD)), CREATES, vt)
    say(st == want, "`include gen.mk` whose rule creates it + %s: %s (both makes)" % (vn, want), "state %s" % st)
for ik in ("include", "-include"):
    st = shape("carry-%s" % len(os.listdir(UD)), ik + " gen.mk\ngen.mk:\n\t@printf 'verify:\\n\\t@echo v\\n' > gen.mk\n", "")
    say(st == "present", "a generated makefile that carries the target (%s gen.mk): present (the list pass generates it first)" % ik, "state %s" % st)
# a unit on which the random-name probe HANGS (a forwarding catch-all, here `%:` with a `+@sleep 5` recipe): state error / timed out, never a catch-all, and the
# unit's 2nd target asks nothing more (one timeout per unit)
m.MAKE_TIMEOUT = 1.0; m.PROBE_TIMEOUT = 1.0
st_h = shape("hang-%s" % len(os.listdir(UD)), "%:\n\t+@sleep 5\n", ""); st_h2 = m.make_target_state(os.path.join(UD, "inc-" + [n for n in os.listdir(UD) if n.startswith("inc-hang-")][0][4:]), "check-fast")
say(st_h == "error" and st_h2 == "error", "a unit on which the probe hangs is `error` (timed out), not a catch-all, for both targets", "states %s %s" % (st_h, st_h2))
m.MAKE_TIMEOUT = 20.0; m.PROBE_TIMEOUT = 5.0
# BEGIN list-pass block
# The list pass (first question) judged on its own: (i) it times out with NO list, (ii) make cannot read the Makefile, (iii) the list
# names something that is not a path, (b) it times out WITH a complete list (used), (c) it is waited for up to its limit, and the
# limit a timeout finding prints is the one that applied. GNU make 3.81 and 4.3 alike except the one case guarded by the version.
LPR = os.path.join(TMP, "lp"); os.makedirs(LPR)
def lproot(name, text, extra=None):
    d = os.path.join(LPR, name); os.makedirs(os.path.join(d, "services/x"))
    open(os.path.join(d, "repo.yaml"), "w").write("version: v2\nrepo:\n  name: demo\n  layout: monorepo\nunits:\n  - { id: svc-x, kind: service, language: go, path: services/x }\n")
    open(os.path.join(d, "services/x/Makefile"), "w").write(text)
    for f, body in (extra or {}).items(): open(os.path.join(d, "services/x", f), "w").write(body)
    return d
def lpun(root): m._rc_cache.clear(); m._timed_out.clear(); return ["%s:%d: %s %s" % f for f in m.check(root) if f[2] == "unit-target"]
LPT = "check-fast:\n\t@echo cf\nverify:\n\t@echo v\n"
m.MAKE_TIMEOUT = 20.0; m.PROBE_TIMEOUT = 2.0
t0 = time.time(); out = lpun(lproot("sleep", "$(shell sleep 30)\n" + LPT)); el = time.time() - t0
say(len(out) == 2 and all(re.search(r"timed out listing the unit's makefiles \(no list after 2 s", l) and "space or newline" not in l and "could not be listed" not in l for l in out) and el < 8,
    "a list pass that times out with no list (a parse-time $(shell sleep 30)): error, finding says it timed out listing, with the limit, not `space or newline` (%.1fs)" % el, "\n".join(out))
out = lpun(lproot("guard", "ifndef ENV\n$(error set ENV)\nendif\n" + LPT))
say(len(out) == 2 and all("make could not read the unit's Makefile" in l and re.search(r"exited with status [1-9]", l) and "space or newline" not in l and "timed out" not in l for l in out),
    "a Makefile that make cannot read (an $(error) guard): error, finding says make could not read the Makefile, with its exit status, not `space or newline`", "\n".join(out))
out = lpun(lproot("space", "include a\\ b.mk\n" + LPT, {"a b.mk": "X=1\n"}))
say(len(out) == 2 and all("a name with a space or newline" in l and "make could not read" not in l and "timed out" not in l for l in out),
    "a list that names a path that does not exist (a makefile whose name has a space splits): error, the `space or newline` finding (control of the two messages above)", "\n".join(out))
out = lpun(lproot("plain", LPT))
say(out == [], "a plain unit under the same drivers: present, no finding (control)", "\n".join(out))
# the fake `make`: its own modes, no relation to the one above. F2 = lhang (writes the list, then hangs) | nhang (hangs before any list) | chang (the control hangs) | qhang (a question hangs)
FB2 = os.path.join(TMP, "fakebin2"); os.makedirs(FB2)
open(os.path.join(FB2, "make"), "w").write(r'''#!/usr/bin/env bash
last="${*: -1}"
if [[ "$last" == __monorepo_control_* ]]; then [[ "${F2:-}" == chang ]] && exec sleep 30; exit 0; fi
if [[ "${*: -3:1}" == */list.mk ]]; then
  lm="${*: -3:1}"; echo "list" >> "$F2LOG"
  [[ "${F2:-}" == nhang ]] && exec sleep 30
  printf '%s\n' "${*: -5:1}" > "${lm%list.mk}list.tmp$$" && mv "${lm%list.mk}list.tmp$$" "${lm%list.mk}list.out"
  [[ "${F2:-}" == lhang ]] && exec sleep 30
  exit 2
fi
[[ "${F2:-}" == qhang && "$last" != __monorepo_probe_* ]] && exec sleep 30
[[ "$last" == __monorepo_probe_* ]] && exit 2
exit 1
''')
os.chmod(os.path.join(FB2, "make"), 0o755)
F2LOG = os.path.join(TMP, "fake2.log"); os.environ["F2LOG"] = F2LOG
FR2 = lproot("fake2", LPT); pathf = os.environ["PATH"]; os.environ["PATH"] = FB2 + os.pathsep + pathf
def f2(mode):
    open(F2LOG, "w").close(); os.environ["F2"] = mode; t = time.time(); o = lpun(FR2); return o, time.time() - t, open(F2LOG).read().split()
m.MAKE_TIMEOUT = 4.0; m.PROBE_TIMEOUT = 1.0
out, el, ls = f2("lhang")
say(out == [] and 1 <= el < 4 and ls == ["list"],
    "a list pass that wrote its list and then hangs: it is waited for up to its limit (1 s here, %.1fs), then ended, and the complete list is used (judged from the later questions, no finding)" % el,
    "%s %s %s" % (out, el, ls))
out, el, ls = f2("chang")
say(len(out) == 2 and all("did not answer in 1 s" in l for l in out), "a control that hangs: the finding prints the limit that applied, 1 s (PROBE_TIMEOUT), not the 4 s question limit", "\n".join(out))
out, el, ls = f2("qhang")
say(len(out) == 2 and all("did not answer in 4 s" in l for l in out), "a question that hangs: the finding prints 4 s (MAKE_TIMEOUT)", "\n".join(out))
out, el, ls = f2("nhang")
say(len(out) == 2 and all("timed out listing the unit's makefiles (no list after 1 s" in l for l in out), "a fake list pass that hangs before writing: the timed-out-listing finding, 1 s", "\n".join(out))
os.environ["PATH"] = pathf; os.environ.pop("F2")
m.MAKE_TIMEOUT = 20.0; m.PROBE_TIMEOUT = 5.0
# 4.x only: a FORCE'd include whose recipe WRITES it makes make 4.x restart during the list pass; the pass runs to its 5 s limit and the complete list it wrote is used:
# with a real verify the unit is present every time, at about 5 s per inspection (3 inspections here, each within 7 s, to keep the suite short)
if "GNU Make 4" in mk_ver:
    FW = lproot("force", "-include version.mk\nversion.mk: FORCE\n\t@echo V=1 > version.mk\nFORCE:\n.PHONY: verify check-fast FORCE\nverify:\n\t@echo ok\ncheck-fast:\n\t@echo ok\n")
    n_ok, worst = 0, 0.0
    for i in range(3):
        t = time.time(); o = lpun(FW); d = time.time() - t; worst = max(worst, d); n_ok += o == []
    say(n_ok == 3 and worst <= 7, "make 4.x: a FORCE'd `-include version.mk` whose recipe writes it, with a real verify: present %d of 3 inspections (slowest %.1fs, limit 7 s)" % (n_ok, worst), "%d ok of 3, slowest %.1fs" % (n_ok, worst))
# a GENERATED makefile (an include with a rule that writes it through a redirect, slower than a blink): the list pass waits for make, so on a fresh clone
# the unit carrying the target is present, the generated file is complete and the user's own make still works; the generation ran under the list pass only
GLOG = os.path.join(TMP, "gen.log"); open(GLOG, "w").close()
GBASE = "check-fast:\n\t@echo cf\ninclude gen.mk\ngen.mk: gen.in\n"
gen1 = lproot("gen1", GBASE + "\t@echo start $(MAKECMDGOALS) >> " + GLOG + "\n\tsh -c 'sleep 2; echo \"verify: ; @echo real\"' > $@\n\t@echo end $(MAKECMDGOALS) >> " + GLOG + "\n", {"gen.in": "x\n"})
t0 = time.time(); out = lpun(gen1); el = time.time() - t0; gu = os.path.join(gen1, "services/x"); gtxt = open(os.path.join(gu, "gen.mk")).read() if os.path.exists(os.path.join(gu, "gen.mk")) else None
rq = subprocess.run(["make", "-C", gu, "-q", "verify"], capture_output=True).returncode; rn = subprocess.run(["make", "-C", gu, "-n", "verify"], capture_output=True).returncode
say(out == [] and gtxt == "verify: ; @echo real\n" and rq == 1 and rn == 0 and el < 6,
    "a generated makefile (include gen.mk, gen.mk rebuilt through a 2 s redirect) that carries the target, fresh state: judged present (%.1fs), gen.mk complete, and the user's own make -q / make -n verify still work" % el, "%s | %r | -q %s -n %s" % (out, gtxt, rq, rn))
glog = open(GLOG).read().split("\n")
say(glog == ["start " + m.PROBE_NAME, "end " + m.PROBE_NAME, ""], "that generation ran once, under the list pass only (start and end under the random list name, nothing under the control or a later question)", "%s" % glog)
gen2 = lproot("gen2", GBASE + "\tprintf 'verify:' > $@\n\tsleep 1; echo ' ; @echo real' >> $@\n", {"gen.in": "x\n"})
out = lpun(gen2); gu2 = os.path.join(gen2, "services/x"); gtxt = open(os.path.join(gu2, "gen.mk")).read() if os.path.exists(os.path.join(gu2, "gen.mk")) else None
rq = subprocess.run(["make", "-C", gu2, "-q", "verify"], capture_output=True).returncode
say(out == [] and gtxt == "verify: ; @echo real\n" and rq == 1, "the two-step generation (printf > gen.mk, then >> gen.mk) is complete, not a partial file, and the unit is present", "%s | %r | -q %s" % (out, gtxt, rq))
# END list-pass block
# the -B question carries the unit's makefile and the makefiles it read (-o); a unit without a makefile is never asked -B
CB3 = os.path.join(TMP, "countbin3"); os.makedirs(CB3); CLOG3 = os.path.join(TMP, "make-args3.log")
open(os.path.join(CB3, "make"), "w").write('#!/usr/bin/env bash\necho "$*" >> "%s"\nexec "%s" "$@"\n' % (CLOG3, real_make)); os.chmod(os.path.join(CB3, "make"), 0o755)
d3 = os.path.join(UD, "five-pinargs"); os.makedirs(d3); open(os.path.join(d3, "Makefile"), "w").write(".PHONY: verify\n")
os.environ["PATH"] = CB3 + os.pathsep + path1; m._rc_cache.clear(); m.make_target_state(d3, "verify"); os.environ["PATH"] = path1
calls3 = [a for a in open(CLOG3).read().split("\n") if a]
bl = [a for a in calls3 if " -B " in a]
ll = [a for a in calls3 if "list.mk" in a and " -o " not in a]
cl = [a for a in calls3 if "list.mk" in a and " -o " in a]
say(len(bl) == 1 and re.search(r"-q -B -o Makefile -- verify$", bl[0]) is not None and " -f " not in bl[0], "the -B look names every makefile make read with -o and adds no -f (nothing enters the unit's rule base)", "calls %s" % bl)
say(len(ll) == 1 and re.search(r"-q -f Makefile -f \S*list\.mk -- __monorepo_probe_[0-9a-f]+$", ll[0]) is not None and " -o " not in ll[0] and " -B" not in ll[0],
    "the list pass is `-q -f <makefile> -f list.mk -- <random name>`: no -o, no -B", "calls %s" % ll)
say(len(cl) == 1 and re.search(r"-q -f Makefile -f \S*list\.mk -o Makefile -- __monorepo_control_[0-9a-f]+$", cl[0]) is not None and " -B" not in cl[0],
    "the control question is `-q -f <makefile> -f list.mk -o <each listed makefile> -- <control name>`", "calls %s" % cl)
iq = [i for i, a in enumerate(calls3) if a.endswith("-q -o Makefile -- verify")]
say(len(iq) == 1 and len(ll) == 1 and len(cl) == 1 and len(bl) == 1 and calls3.index(ll[0]) < calls3.index(cl[0]) < iq[0] < calls3.index(bl[0]),
    "order: the list pass, then the control, then the first question (with -o), then the -B look", "calls %s" % calls3)
# MAKEFLAGS=r (no built-in rules) in the caller's environment: `verify: tool` with tool.sh (the built-in `.sh` rule) stays present
d4 = os.path.join(UD, "flags-r"); os.makedirs(d4); open(os.path.join(d4, "Makefile"), "w").write("verify: tool\n"); open(os.path.join(d4, "tool.sh"), "w").write("echo x\n")
ctl = subprocess.run(["make", "-C", d4, "-q", "--", "verify"], capture_output=True, env=dict(os.environ, MAKEFLAGS="r")).returncode
os.environ["MAKEFLAGS"] = "r"; m._rc_cache.clear(); st_r = m.make_target_state(d4, "verify"); os.environ.pop("MAKEFLAGS")
m._rc_cache.clear(); st_r0 = m.make_target_state(d4, "verify")
say(ctl != 1 and st_r == "present" and st_r0 == "present", "env scrub on real make: MAKEFLAGS=r in the environment does not remove the built-in `.sh` rule from the inspection (control: an unscrubbed make with it answers %s)" % ctl, "scrubbed %s, plain %s, unscrubbed -q %s" % (st_r, st_r0, ctl))
# warnings
out = run(M7)
say(has(out, r"^repo.yaml:\d+: unit-path unit svc-b: path services/b: services/b is a symlink"), "an in-repo unit symlink (services/b -> a) is refused by the check", "\n".join(out))
os.remove(os.path.join(M7, "services/b")); os.mkdir(os.path.join(M7, "services/b")); shutil.copy(os.path.join(M7, "services/a/Makefile"), os.path.join(M7, "services/b/Makefile")); out = run(M7)
say(out == [], "the same two units as real directories are clean (control)", "\n".join(out))
out = run(G)
say(out == [], "an untracked node_modules/ in a git repo is not a finding (control)", "\n".join(out))
subprocess.run(["git", "-C", G, "add", "-f", "node_modules"], capture_output=True); out = run(G)
say(has(out, r"^node_modules/x/package.json:1: tracked-node-modules node_modules/ is tracked"), "a TRACKED node_modules/ is RED (tracked-node-modules)", "\n".join(out))
nm = os.path.join(W, "packages/a/node_modules/x"); os.makedirs(nm); open(os.path.join(nm, "package.json"), "w").write("{}"); out = run(W); shutil.rmtree(os.path.join(W, "packages/a/node_modules"))
say(out == [], "a package.json under node_modules/ is not stray (control)", "\n".join(out))
for rel in ("services/s", "packages/a/sub"):
    os.makedirs(os.path.join(W, rel)); open(os.path.join(W, rel, "package.json"), "w").write('{"name":"s"}'); out = run(W); shutil.rmtree(os.path.join(W, rel))
    say(has(out, "^%s/package.json:1: stray-package-json" % re.escape(rel)), "a package.json at %s is RED (stray-package-json)" % rel, "\n".join(out))
os.rmdir(os.path.join(W, "services")) if os.path.isdir(os.path.join(W, "services")) else None
P
while IFS= read -r l; do case "$l" in "ok   "*) pass "${l#ok   }";; "FAIL "*) fail "${l#FAIL }";; *) fail "matrix output" "$l";; esac; done < "$tmp/matrix.out"
[[ -s "$tmp/matrix.out" ]] || fail "matrix produced no output"

# ---- pnpm: the assembled root really installs (offline, zero third-party dependencies); live section, MONOREPO_LIVE=1
have_pm="$(pnpm -v 2>/dev/null | tail -1)"
want_pm="$("$py" -c 'import json,sys;print(json.load(open(sys.argv[1]))["packageManager"].split("@")[1])' "$alone/package.json")"
if [[ -n "${NO_PNPM:-}" ]]; then skip "pnpm live section" "NO_PNPM is set (mutation runs only)"
elif [[ -z "${MONOREPO_LIVE:-}" ]]; then skip "pnpm live section (install, overrides, devEngines)" "MONOREPO_LIVE is not set; the default run is hermetic and is what CI runs"
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
  # Review 2 B1: devEngines.runtime is honoured by pnpm (the lockfile gains node@runtime:<version>, fetched from the
  # network, outside the catalog and engines.node) and the settings check is RED on that very tree.
  E2="$tmp/live2"; cp -R "$alone" "$E2"; mkdir -p "$E2/packages/a"
  printf '{"name":"a","version":"1.0.0","private":true,"scripts":{"test":"true"},"devEngines":{"runtime":{"name":"node","version":"22.11.0","onFail":"download"}}}\n' > "$E2/packages/a/package.json"
  sed -i.b 's/^units: \[\]/units:\n  - { id: pkg-a, kind: package, language: ts, path: packages\/a }/' "$E2/repo.yaml"; mv "$E2/repo.yaml.b" "$tmp/live2.sedbak"
  expect "the live devEngines tree is RED (pkg-key)" 1 "packages/a/package.json:[0-9]+: pkg-key package.json key 'devEngines' is not allowed" check "$E2"
  lo="$(cd "$E2" && CI=true timeout 75 pnpm install --ignore-scripts 2>&1 | tail -n 5)"
  if [[ -f "$E2/pnpm-lock.yaml" ]] && grep -q 'node@runtime:22.11.0' "$E2/pnpm-lock.yaml"; then
    pass "B1 live: pnpm honoured devEngines.runtime (lockfile gained node@runtime:22.11.0, outside the catalog and engines.node)"
  elif [[ -f "$E2/pnpm-lock.yaml" ]]; then fail "B1 live: devEngines.runtime not in the lockfile" "$(head -c 300 "$E2/pnpm-lock.yaml")"
  else skip "B1 live install of a devEngines construct" "no lockfile written (network unreachable?): $(tr '\n' ' ' <<<"$lo" | head -c 160)"; fi
fi

summary="$ok ok, $bad failed"; [[ $skipped -gt 0 ]] && summary+=", $skipped skipped"; echo "$summary"
[[ $((ok + bad)) -gt 0 ]] || exit 2
[[ $bad -eq 0 ]]
