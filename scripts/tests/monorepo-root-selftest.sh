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
expect "a package .npmrc setting a supply-chain key is RED, at its line" 1 "packages/tokens/.npmrc:2: supply-override" check "$c"
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
cp "$D/Makefile" "$F/Makefile"; cp "$D/scripts/monorepo-run.sh" "$D/scripts/monorepo-settings-check.sh" "$D/scripts/monorepo_check.py" "$F/scripts/"
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
expect "the settings-check target runs the check" 2 "FAIL monorepo-settings-check" make -s -C "$F" settings-check

# ---- pnpm: the assembled root really installs (offline, zero third-party dependencies)
have_pm="$(pnpm -v 2>/dev/null | tail -1)"
want_pm="$("$py" -c 'import json,sys;print(json.load(open(sys.argv[1]))["packageManager"].split("@")[1])' "$alone/package.json")"
if ! command -v pnpm >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then skip "pnpm install --frozen-lockfile --offline" "pnpm or node not installed"
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
fi

summary="$ok ok, $bad failed"; [[ $skipped -gt 0 ]] && summary+=", $skipped skipped"; echo "$summary"
[[ $((ok + bad)) -gt 0 ]] || exit 2
[[ $bad -eq 0 ]]
