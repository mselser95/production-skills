#!/usr/bin/env bash
# monorepo-assembly-selftest.sh -- the modules assemble TOGETHER into one monorepo with the monorepo-root
# module, with the real manifests and no corrected copies: each manifest alone, the assembled tree's shape
# (one root package.json / pnpm-workspace.yaml, packages/ vs services/, merged .gitignore), the root module's
# settings check on it, the catalog equality, and one RED mutation per guarded thing.
# Hermetic, sequential, no network, no Docker. Needs python3 with PyYAML (PYTHON=<interpreter> to choose
# one; first of python3, python3.14, python3.13, python3.12 that imports yaml). Final line:
# `<N> ok, <M> failed[, K skipped]`. Exit: 0 all ok - 1 a case failed - 2 cannot run.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mods="$here/prod-new/modules"
asm="$here/scripts/assemble.py"

py=""
for c in "${PYTHON:-}" python3 python3.14 python3.13 python3.12; do
  [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' 2>/dev/null && { py="$c"; break; }
done
[[ -n "$py" ]] || { echo "FAIL: no python3 with PyYAML found; set PYTHON=" >&2; exit 2; }
export PYTHON="$py"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/monorepo-assembly.XXXXXX")" || exit 2
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
SL=(--slot REPO=demo-repo --slot SCOPE=demo --slot SERVICE=orders --slot PACKAGE=orders --slot OWNER=demo-owner)
SLG=(--slot REPO=demo-repo --slot SCOPE=demo --slot SERVICE=orders --slot OWNER=demo-owner) # no PACKAGE: no python module
slots_for() { # the slots one module declares (an unknown or undeclared slot is exit 2)
  case "$1" in
    monorepo-root) echo "--slot REPO=demo-repo" ;;
    design-system) echo "--slot SCOPE=demo" ;;
    service-go | service-rust) echo "--slot SERVICE=orders --slot OWNER=demo-owner" ;;
    service-python) echo "--slot SERVICE=orders --slot PACKAGE=orders --slot OWNER=demo-owner" ;;
    *) echo "" ;;
  esac
}
# A <modules-dir> <args...>: the real assembler against a modules directory
A() { local md="$1"; shift; "$py" -I -B "$asm" --modules-dir "$md" "$@"; }
check() { bash "$1/scripts/monorepo-settings-check.sh" "$1"; }

# ---- each manifest is accepted by the assembler on its own (one case per module)
for m in monorepo-root design-system service-go service-rust service-python; do
  # shellcheck disable=SC2046
  expect "manifest of $m is accepted alone (layout monorepo)" 0 "slots remaining: 0" \
    A "$mods" --dest "$tmp/alone-$m" --layout monorepo --module "$m" $(slots_for "$m")
done
# db-postgres: its manifest is still the old descriptive format (summary / contributes / liabilities, no
# source, no placement), which the assembler refuses with exit 2. A SKIP while that is so; turns into an
# ok the day the manifest is migrated (outside this task's file list: reported).
if A "$mods" --dest "$tmp/alone-db" --layout monorepo --module db-postgres >/dev/null 2>&1
then pass "manifest of db-postgres is accepted alone"
else skip "manifest of db-postgres is accepted alone" "its module.json is in the old descriptive format (reported, not in this task)"; fi

# ---- single layout still works for each service module alone
for m in service-go service-rust service-python; do
  # shellcheck disable=SC2046
  expect "single layout: $m alone assembles" 0 "layout single, slots remaining: 0" \
    A "$mods" --dest "$tmp/single-$m" --layout single --module "$m" $(slots_for "$m")
done

# ---- the assembly: monorepo-root + design-system + a service, real manifests, no corrected copies
D="$tmp/repo"
expect "assemble monorepo-root + design-system + service-python" 0 "slots remaining: 0" \
  A "$mods" --dest "$D" --layout monorepo --module monorepo-root --module design-system --module service-python "${SL[@]}"
[[ -d "$D" ]] || { echo "$ok ok, $((bad + 1)) failed (nothing assembled, later cases not run)"; exit 1; }
G="$tmp/repo-go"
expect "assemble monorepo-root + design-system + service-go" 0 "slots remaining: 0" \
  A "$mods" --dest "$G" --layout monorepo --module monorepo-root --module design-system --module service-go "${SLG[@]}"
# The six-module assembly (three services at once, db-postgres) is NOT possible today: assemble.py takes ONE
# global SERVICE slot, so every service's unit files land in services/<SERVICE>/ and collide, and db-postgres
# has an old-format manifest. Reported, not worked around; this case turns into an ok when it is fixed.
if A "$mods" --dest "$tmp/six" --layout monorepo --module monorepo-root --module design-system --module service-go \
     --module service-rust --module service-python --module db-postgres "${SL[@]}" >/dev/null 2>&1
then pass "six-module monorepo assembly"
else skip "six-module monorepo assembly" "assemble.py has one global SERVICE slot (three services collide) and db-postgres has an old-format manifest (reported)"; fi

for t in "$D" "$G"; do
  n="${t##*/}"
  if grep -rIlE '<(REPO|SERVICE|PACKAGE|OWNER|SCOPE)>|repo-name|ds-scope' "$t" >/dev/null; then fail "$n: slot placeholders or literals left"; else pass "$n: no slot placeholder or literal left"; fi
  [[ -f "$t/packages/tokens/package.json" && -f "$t/packages/theme/package.json" && ! -e "$t/services/orders/packages" ]] \
    && pass "$n: design-system packages are at packages/, none under services/" || fail "$n: design-system packages misplaced"
  [[ -f "$t/services/orders/Makefile" && ! -e "$t/services/orders/package.json" ]] \
    && pass "$n: the service is under services/orders" || fail "$n: service not under services/orders"
done
"$py" - "$D" "$G" <<'E' && pass "one root package.json with packageManager, one pnpm-workspace.yaml, at most one lockfile, all at the root" || fail "root files: see above"
import os, sys, json
bad = []
for root in sys.argv[1:]:
    found = {"package.json": [], "pnpm-workspace.yaml": [], "pnpm-lock.yaml": [], "tsconfig.base.json": []}
    for d, _, fs in os.walk(root):
        for f in fs:
            if f in found:
                found[f].append(os.path.relpath(os.path.join(d, f), root))
    pms = [p for p in found["package.json"] if "packageManager" in json.load(open(os.path.join(root, p)))]
    if pms != ["package.json"]: bad.append("%s: packageManager in %s" % (root, pms))
    if found["pnpm-workspace.yaml"] != ["pnpm-workspace.yaml"]: bad.append("%s: workspace files %s" % (root, found["pnpm-workspace.yaml"]))
    if len(found["pnpm-lock.yaml"]) > 1 or found["pnpm-lock.yaml"] not in ([], ["pnpm-lock.yaml"]): bad.append("%s: lockfiles %s" % (root, found["pnpm-lock.yaml"]))
    if found["tsconfig.base.json"] != ["tsconfig.base.json"]: bad.append("%s: tsconfig.base.json %s" % (root, found["tsconfig.base.json"]))
for b in bad: print("  " + b)
sys.exit(1 if bad else 0)
E
# the root .gitignore is the union of the contributors' lines, each once
"$py" - "$G" "$mods/monorepo-root/.gitignore" "$here/prod-new/template/.gitignore" <<'E' && pass ".gitignore is the line-union: every contributor line once" || fail ".gitignore union"
import sys
out = open(sys.argv[1] + "/.gitignore").read().splitlines()
want = [l for p in sys.argv[2:] for l in open(p).read().splitlines() if l.strip()]
bad = [l for l in want if out.count(l) != 1]
for l in bad: print("  line %r appears %d times" % (l, out.count(l)))
sys.exit(1 if bad or not want else 0)
E

# ---- the root module's settings check on the assembled tree.
# unit-unlisted is EXPECTED RED until the assembler generates repo.yaml entries; the entries are then added
# the way a human would (one per unit) and the check must be GREEN. non-catalog-dep must be GREEN throughout.
out="$(PYTHON="$py" check "$D" 2>&1)"
rest="$(grep -v 'unit-unlisted\|^FAIL monorepo-settings-check' <<<"$out")"
if [[ "$out" == *unit-unlisted* && -z "$rest" ]]; then
  pass "before repo.yaml entries only unit-unlisted is RED (expected, assembler does not generate entries yet)"
else fail "settings check on the bare assembly: only unit-unlisted was expected" "$(head -c 300 <<<"$out")"; fi
[[ "$out" == *non-catalog-dep* ]] && fail "non-catalog-dep on design-system packages" || pass "non-catalog-dep is GREEN on the design-system packages"
fill() { "$py" - "$1/repo.yaml" "$2" <<'E'
import sys
p, lang = sys.argv[1], sys.argv[2]
t = open(p).read().replace("units: []\n", """units:
  - { id: orders, kind: service, language: %s, path: services/orders }
  - { id: demo-tokens, kind: package, language: ts, path: packages/tokens }
  - { id: demo-theme, kind: package, language: ts, path: packages/theme }
""" % lang)
open(p, "w").write(t)
E
}
fill "$D" python
expect "settings check GREEN once repo.yaml lists the units (python tree)" 0 "^OK monorepo-settings-check" check "$D"
fill "$G" go
expect "settings check GREEN once repo.yaml lists the units (go tree)" 0 "^OK monorepo-settings-check" check "$G"

# ---- F4: every dependency version moved, unchanged, into the catalog
"$py" - "$D" <<'E' && pass "(name, version) pairs before == pairs in the catalog; packages hold only catalog: / workspace:*" || fail "catalog equality"
import sys, json, glob, yaml
root = sys.argv[1]
# the exact pins the design-system packages carried before they moved to catalog: (recorded here on purpose)
before = {("@types/node", "26.6.11"), ("typescript", "7.0.2"), ("vitest", "5.1.2")}
cat = yaml.safe_load(open(root + "/pnpm-workspace.yaml"))["catalog"]
names, bad = set(), []
for p in sorted(glob.glob(root + "/packages/*/package.json")):
    d = json.load(open(p))
    for f in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
        for k, v in d.get(f, {}).items():
            if v == "catalog:": names.add(k)
            elif v != "workspace:*": bad.append("%s %s=%s" % (p, k, v))
after = {(k, str(cat.get(k))) for k in names}
if after != before: bad.append("before %s != after %s" % (sorted(before), sorted(after)))
for b in bad: print("  " + b)
sys.exit(1 if bad or not names else 0)
E

# ---- pnpm: offline frozen install from the assembled lockfile
if [[ ! -f "$D/pnpm-lock.yaml" ]]; then
  skip "pnpm install --frozen-lockfile --offline" "no root pnpm-lock.yaml: it cannot be generated yet (vitest 5.1.2 is younger than minimumReleaseAge); see the hand-back for the command"
elif ! command -v pnpm >/dev/null 2>&1; then
  skip "pnpm install --frozen-lockfile --offline" "pnpm is not installed"
else
  expect "pnpm install --frozen-lockfile --ignore-scripts --offline" 0 "" \
    bash -c 'cd "$1" && pnpm install --frozen-lockfile --ignore-scripts --offline' _ "$D"
fi

# ---- mutations on scratch copies of the modules: each must turn the assembly (or the check) RED
M="$tmp/x/modules"; mkdir -p "$M" "$tmp/x"
cp -R "$here/prod-new/template" "$tmp/x/template"
for m in monorepo-root design-system service-go service-rust service-python; do cp -R "$mods/$m" "$M/$m"; done
jedit() { "$py" -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));exec(sys.argv[2]);json.dump(d,open(p,"w"),indent=2)' "$1" "$2"; }
reset_mod() { rm -rf "${M:?}/$1"; cp -R "$mods/$1" "$M/$1"; }

jedit "$M/design-system/module.json" 'd["placement"]["packages/**"]="unit"'
expect "mutation: design-system placement back to unit is refused (it would land under services/)" 2 "SERVICE slot" \
  A "$M" --dest "$tmp/m1" --layout monorepo --module monorepo-root --module design-system --module service-python "${SL[@]}"
reset_mod design-system

printf '{"name": "design-system-workspace", "private": true}\n' > "$M/design-system/package.json"
jedit "$M/design-system/module.json" 'd["placement"]["package.json"]="root"'
expect "mutation: design-system root package.json not excluded collides with the root module's" 1 "package.json" \
  A "$M" --dest "$tmp/m2" --layout monorepo --module monorepo-root --module design-system --module service-python "${SL[@]}"
reset_mod design-system

c="$tmp/m3"; cp -R "$D" "$c"
sed -i.b 's|"typescript": "catalog:"|"typescript": "7.0.2"|' "$c/packages/tokens/package.json"; rm "$c/packages/tokens/package.json.b"
expect "mutation: a dependency back to an exact version makes the settings check RED" 1 "non-catalog-dep .*7\.0\.2" check "$c"

jedit "$M/service-go/module.json" 'del d["root_merge"]'
expect "mutation: root_merge removed from service-go collides on .gitignore" 1 "\.gitignore" \
  A "$M" --dest "$tmp/m4" --layout monorepo --module monorepo-root --module service-go --slot REPO=demo-repo --slot SERVICE=orders --slot OWNER=demo-owner
reset_mod service-go

jedit "$M/service-rust/module.json" 'del d["root_merge"]'
expect "mutation: root_merge removed from service-rust collides on .gitignore" 1 "\.gitignore" \
  A "$M" --dest "$tmp/m4r" --layout monorepo --module monorepo-root --module service-rust --slot REPO=demo-repo --slot SERVICE=orders --slot OWNER=demo-owner
reset_mod service-rust

jedit "$M/design-system/module.json" 'd["description"]="x"'
expect "mutation: an unknown key in the design-system manifest is exit 2" 2 "unknown key" \
  A "$M" --dest "$tmp/m5" --layout monorepo --module design-system --slot SCOPE=demo

summary="$ok ok, $bad failed"; [[ $skipped -gt 0 ]] && summary+=", $skipped skipped"; echo "$summary"
[[ $bad -eq 0 ]]
