#!/usr/bin/env bash
# monorepo-assembly-selftest.sh -- the modules assemble TOGETHER into one monorepo with the monorepo-root
# module, with the real manifests and no corrected copies: each manifest alone, the seven-unit assembly
# (root, design-system, go x2, rust, python, db-postgres) with its generated repo.yaml, per-unit file ownership,
# the settings check, the unit list of check-fast, .gitignore anchoring, the db-postgres gate in the tree, the
# catalog invariant and the lockfile's frozen check, single layout unchanged, and one RED mutation per guarded
# thing. Two cases pin a KNOWN GAP (design-system packages are not listed in repo.yaml; the lockfile is
# scope-specific) and turn RED the day it is fixed, so they get updated then.
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
SL=(--slot REPO=demo-repo --slot SCOPE=demo --slot SERVICE=catalog --slot PACKAGE=catalog --slot OWNER=demo-owner)
SL=(--slot REPO=demo-repo --slot SCOPE=demo --slot SERVICE=catalog --slot PACKAGE=catalog --slot OWNER=demo-owner)
SLG=(--slot REPO=demo-repo --slot SCOPE=demo --slot SERVICE=catalog --slot OWNER=demo-owner) # no PACKAGE: no python module
# The seven-unit monorepo: root + design-system + go, rust, python + a SECOND instance of service-go + db-postgres.
# SCOPE is the design-system module's own literal (ds-scope): the committed pnpm-lock.yaml names @ds-scope/*.
U7=(--module monorepo-root --module design-system --unit service-go:catalog --unit service-rust:billing
    --unit "service-python:invoices,PACKAGE=invoices" --unit service-go:catalog-worker --unit db-postgres:db
    --slot REPO=demo-repo --slot SCOPE=ds-scope --slot OWNER=demo-owner)
U6=(--module monorepo-root --unit service-go:catalog --unit service-rust:billing
    --unit "service-python:invoices,PACKAGE=invoices" --unit service-go:catalog-worker --unit db-postgres:db
    --slot REPO=demo-repo --slot OWNER=demo-owner) # the same without design-system
slots_for() { # the slots one module declares (an unknown or undeclared slot is exit 2)
  case "$1" in
    monorepo-root) echo "--slot REPO=demo-repo" ;;
    design-system) echo "--slot SCOPE=demo" ;;
    service-go | service-rust) echo "--slot SERVICE=catalog --slot OWNER=demo-owner" ;;
    service-python) echo "--slot SERVICE=catalog --slot PACKAGE=catalog --slot OWNER=demo-owner" ;;
    *) echo "" ;;
  esac
}
# A <modules-dir> <args...>: the real assembler against a modules directory
A() { local md="$1"; shift; "$py" -I -B "$asm" --modules-dir "$md" "$@"; }
check() { bash "$1/scripts/monorepo-settings-check.sh" "$1"; }
# gitenv: git with no user/system configuration (check-ignore reads the .gitignore files only)
gitq() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
# tree_hash <dir>: one sha over every path, mode and content (links by target)
tree_hash() { "$py" - "$1" <<'E'
import hashlib, os, sys
h, root = hashlib.sha256(), sys.argv[1]
for d, ds, fs in os.walk(root):
    ds.sort()
    for n in sorted(fs + [x for x in ds if os.path.islink(os.path.join(d, x))]):
        p = os.path.join(d, n)
        st = os.lstat(p)
        body = os.readlink(p).encode() if os.path.islink(p) else open(p, "rb").read()
        h.update(("%s %o\0" % (os.path.relpath(p, root), st.st_mode & 0o777)).encode() + body + b"\0")
print(h.hexdigest())
E
}
# gitignore_ok <assembled-tree>: the four ANCHORED service-go patterns ignore the paths under services/<id>/
# for both go instances and do NOT ignore the same names at the repository root (needs git)
gitignore_ok() {
  local t="$1" id p bad=0
  [[ -d "$t/.git" ]] || gitq -C "$t" init -q || return 2
  for id in catalog catalog-worker; do
    for p in data/x coverage.out benchmarks/profiles/a.prof .prod/verify-standard/z; do
      gitq -C "$t" check-ignore -q "services/$id/$p" || { echo "  services/$id/$p is not ignored"; bad=1; }
    done
  done
  for p in data/x coverage.out benchmarks/profiles/a.prof .prod/verify-standard/z; do
    gitq -C "$t" check-ignore -q "$p" && { echo "  $p IS ignored at the repository root"; bad=1; }
  done
  return $bad
}

# ---- each manifest is accepted by the assembler on its own (one case per module)
for m in monorepo-root design-system service-go service-rust service-python; do
  # shellcheck disable=SC2046
  expect "manifest of $m is accepted alone (layout monorepo)" 0 "slots remaining: 0" \
    A "$mods" --dest "$tmp/alone-$m" --layout monorepo --module "$m" $(slots_for "$m")
done
expect "manifest of db-postgres is accepted alone (layout monorepo, --unit)" 0 "slots remaining: 0" \
  A "$mods" --dest "$tmp/alone-db" --layout monorepo --unit db-postgres:db

# ---- single layout still works for each service module alone, and no file moved: in layout single root
# and unit are both the repository root, so the real manifest equals the same manifest with every
# placement set to root; and (when the history has it) equals the tree built from the manifests of the
# commit before the per-unit placement (231d25f)
SBASE=231d25f
b="$tmp/b"; mkdir -p "$b/modules"; cp -R "$here/prod-new/template" "$b/template"
for m in service-go service-rust service-python; do cp -R "$mods/$m" "$b/modules/$m"; done
have_base=0
gitq -C "$here" rev-parse -q --verify "$SBASE^{commit}" >/dev/null 2>&1 && have_base=1
for m in service-go service-rust service-python; do
  # shellcheck disable=SC2046
  expect "single layout: $m alone assembles" 0 "layout single, slots remaining: 0" \
    A "$mods" --dest "$tmp/single-$m" --layout single --module "$m" $(slots_for "$m")
  "$py" -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["placement"]={k:"root" for k in d["placement"]};d.pop("root_merge",None);json.dump(d,open(p,"w"))' "$b/modules/$m/module.json"
  # shellcheck disable=SC2046
  A "$b/modules" --dest "$tmp/single-allroot-$m" --layout single --module "$m" $(slots_for "$m") >/dev/null 2>&1
  [[ -d "$tmp/single-allroot-$m" && "$(tree_hash "$tmp/single-$m")" == "$(tree_hash "$tmp/single-allroot-$m")" ]] \
    && pass "single layout: $m tree equals the all-root-placement tree (no file moved by unit placement)" \
    || fail "single layout: $m tree differs from the all-root-placement tree"
  if [[ $have_base -eq 1 ]]; then
    gitq -C "$here" show "$SBASE:prod-new/modules/$m/module.json" > "$b/modules/$m/module.json"
    # shellcheck disable=SC2046
    A "$b/modules" --dest "$tmp/single-base-$m" --layout single --module "$m" $(slots_for "$m") >/dev/null 2>&1
    [[ -d "$tmp/single-base-$m" && "$(tree_hash "$tmp/single-$m")" == "$(tree_hash "$tmp/single-base-$m")" ]] \
      && pass "single layout: $m tree equals the tree of the manifest at $SBASE" \
      || fail "single layout: $m tree differs from the tree of the manifest at $SBASE"
  fi
done
[[ $have_base -eq 1 ]] || skip "single layout equals the tree at $SBASE" "git history does not contain $SBASE (shallow clone or no git); the all-root equivalence above still ran"

# ---- the assembly: monorepo-root + design-system + a service, real manifests, no corrected copies
D="$tmp/repo"
expect "assemble monorepo-root + design-system + service-python" 0 "slots remaining: 0" \
  A "$mods" --dest "$D" --layout monorepo --module monorepo-root --module design-system --module service-python "${SL[@]}"
[[ -d "$D" ]] || { echo "$ok ok, $((bad + 1)) failed (nothing assembled, later cases not run)"; exit 1; }
G="$tmp/repo-go"
expect "assemble monorepo-root + design-system + service-go" 0 "slots remaining: 0" \
  A "$mods" --dest "$G" --layout monorepo --module monorepo-root --module design-system --module service-go "${SLG[@]}"
S7="$tmp/seven"
expect "seven-unit assembly (root, design-system, go x2 as catalog and catalog-worker, rust, python, db-postgres) exits 0" 0 "slots remaining: 0" \
  A "$mods" --dest "$S7" --layout monorepo "${U7[@]}"
S6="$tmp/six"
expect "the same without design-system exits 0" 0 "slots remaining: 0" \
  A "$mods" --dest "$S6" --layout monorepo "${U6[@]}"
[[ -d "$S7" && -d "$S6" ]] || { echo "$ok ok, $((bad + 1)) failed (seven-unit tree missing, later cases not run)"; exit 1; }

for t in "$D" "$G"; do
  n="${t##*/}"
  # pnpm-lock.yaml names @ds-scope/* (the lockfile is monorepo-root's, which does not know the scope slot)
  if grep -rIlE --exclude=pnpm-lock.yaml '<(REPO|SERVICE|PACKAGE|OWNER|SCOPE)>|repo-name|ds-scope' "$t" >/dev/null; then fail "$n: slot placeholders or literals left"; else pass "$n: no slot placeholder or literal left"; fi
  [[ -f "$t/packages/tokens/package.json" && -f "$t/packages/theme/package.json" && ! -e "$t/services/catalog/packages" ]] \
    && pass "$n: design-system packages are at packages/, none under services/" || fail "$n: design-system packages misplaced"
  [[ -f "$t/services/catalog/Makefile" && ! -e "$t/services/catalog/package.json" ]] \
    && pass "$n: the service is under services/catalog" || fail "$n: service not under services/catalog"
done
if grep -rIlE '<(REPO|SERVICE|PACKAGE|OWNER|SCOPE)>|repo-name' "$S7" "$S6" >/dev/null; then fail "seven/six-unit trees: slot placeholders or literals left"; else pass "seven/six-unit trees: no slot placeholder or literal left (ds-scope is the real scope there)"; fi
# KNOWN GAP, pinned: the lockfile is a monorepo-root file and monorepo-root does not know the design-system's
# SCOPE slot, so under any other scope the lockfile still names @ds-scope/* and --frozen-lockfile refuses.
grep -q '@ds-scope/' "$D/pnpm-lock.yaml" && pass "known gap pinned: with SCOPE=demo the lockfile still names @ds-scope/* (frozen install only works for SCOPE=ds-scope)" \
  || fail "the lockfile no longer carries the ds-scope literal: the known gap is fixed, update this case and the frozen-install case"
"$py" - "$D" "$G" "$S7" <<'E' && pass "one root package.json with packageManager, one pnpm-workspace.yaml, exactly one lockfile (the root pnpm-lock.yaml), all at the root" || fail "root files: see above"
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
    if found["pnpm-lock.yaml"] != ["pnpm-lock.yaml"]: bad.append("%s: lockfiles %s" % (root, found["pnpm-lock.yaml"]))
    if found["tsconfig.base.json"] != ["tsconfig.base.json"]: bad.append("%s: tsconfig.base.json %s" % (root, found["tsconfig.base.json"]))
for b in bad: print("  " + b)
sys.exit(1 if bad else 0)
E
# the root .gitignore is monorepo-root's alone: no service contributes to it any more
cmp -s "$S7/.gitignore" "$mods/monorepo-root/.gitignore" && pass "root .gitignore is monorepo-root's file, byte for byte (the services' .gitignore are unit files)" || fail "root .gitignore differs from monorepo-root's"
for u in catalog catalog-worker billing invoices; do
  [[ -f "$S7/services/$u/.gitignore" ]] && pass "services/$u/.gitignore is the service's own" || fail "services/$u/.gitignore missing"
done

# ---- per-unit files belong to the unit: nothing of a service at the repository root
bad_root=""
for p in AGENTS.md CODEOWNERS registries .github .prod docs/RUNBOOK.md scripts/verify-standard.sh scripts/coverage-floors.txt; do [[ -e "$S7/$p" ]] && bad_root+=" $p"; done
[[ -z "$bad_root" ]] && pass "no service file at the repository root (AGENTS.md, CODEOWNERS, registries/, .github/, .prod/, verify-standard.sh ...)" || fail "service files at the root:$bad_root"
miss=""
for u in catalog catalog-worker; do for p in AGENTS.md CODEOWNERS .github/workflows/pr.yaml registries/waivers.yaml .prod/context/change-plan.yaml scripts/verify-standard.sh docs/RUNBOOK.md; do [[ -f "$S7/services/$u/$p" ]] || miss+=" $u:$p"; done; done
for p in registries/waivers.yaml .gitignore; do [[ -f "$S7/services/billing/$p" ]] || miss+=" billing:$p"; done
[[ -z "$miss" ]] && pass "each service's own files are under services/<id>/" || fail "service files missing under services/<id>:$miss"
# nothing of one service inside another's directory
"$py" - "$S7" <<'E' && pass "no unit's directory mentions another unit's id (paths and contents)" || fail "cross-unit mention: see above"
import os, re, sys
root = sys.argv[1]
ids = ["catalog", "catalog-worker", "billing", "invoices"]
bad = []
for me in ids:
    for other in ids:
        if other == me: continue
        # an id is a whole word: neighbours in [a-z0-9_-] make it part of another name (catalog vs catalog-worker)
        rx = re.compile(rb"(?<![a-z0-9_-])" + re.escape(other.encode()) + rb"(?![a-z0-9_-])")
        for d, _, fs in os.walk(os.path.join(root, "services", me)):
            for f in fs:
                p = os.path.join(d, f)
                if rx.search(os.path.relpath(p, root).encode()) or rx.search(open(p, "rb").read()):
                    bad.append("%s mentions %s: %s" % (me, other, os.path.relpath(p, root)))
for b in bad[:20]: print("  " + b)
sys.exit(1 if bad else 0)
E

# ---- repo.yaml written by the assembler: the five instances that place unit files (design-system places none)
"$py" - "$S7/repo.yaml" <<'E' && pass "repo.yaml lists exactly the assembled units (id, kind, language, path)" || fail "repo.yaml units differ"
import sys, yaml
got = sorted((u["id"], u["kind"], u["language"], u["path"]) for u in yaml.safe_load(open(sys.argv[1]))["units"])
want = sorted([("db", "database", "sql", "db"), ("billing", "service", "rust", "services/billing"),
               ("invoices", "service", "python", "services/invoices"), ("catalog", "service", "go", "services/catalog"),
               ("catalog-worker", "service", "go", "services/catalog-worker")])
for g in got:
    if g not in want: print("  unexpected", g)
for w in want:
    if w not in got: print("  missing", w)
sys.exit(0 if got == want else 1)
E

# ---- the root module's settings check on the assembled trees. No manual edit anywhere: the assembler wrote
# the entries. KNOWN GAP, pinned: the design-system module is ONE instance with two packages and no unit
# files, so repo.yaml cannot list packages/tokens and packages/theme and the check reports exactly those two
# unit-unlisted findings and nothing else. Without the design-system the check is GREEN.
expect "settings check GREEN on the six-unit assembly (no design-system), no manual edit" 0 "^OK monorepo-settings-check" check "$S6"
for t in "$S7" "$D"; do
  out="$(PYTHON="$py" check "$t" 2>&1)"
  rest="$(grep -v 'unit-unlisted packages/\(theme\|tokens\) is not a unit\|^FAIL monorepo-settings-check' <<<"$out")"
  n="$(grep -c 'unit-unlisted packages/' <<<"$out")"
  if [[ "$n" -eq 2 && -z "$rest" ]]; then
    pass "known gap pinned (${t##*/}): the design-system packages are the ONLY unit-unlisted findings, nothing else is RED"
  else fail "settings check on ${t##*/}: only the two package unit-unlisted findings were expected (the gap may be fixed: update this case)" "$(head -c 300 <<<"$out")"; fi
  [[ "$out" == *non-catalog-dep* ]] && fail "non-catalog-dep on design-system packages" || pass "non-catalog-dep is GREEN on the design-system packages (${t##*/})"
done
fill() { "$py" - "$1/repo.yaml" <<'E'
import sys
p = sys.argv[1]
t = open(p).read()
t += """  - { id: demo-tokens, kind: package, language: ts, path: packages/tokens }
  - { id: demo-theme, kind: package, language: ts, path: packages/theme }
"""
open(p, "w").write(t)
E
}
c="$tmp/s7-filled"; cp -R "$S7" "$c"; fill "$c"
expect "settings check GREEN on the seven-unit assembly once the two packages are listed by hand" 0 "^OK monorepo-settings-check" check "$c"

# ---- make -n check-fast at the root, and the unit list it runs (no toolchain is started)
expect "root make -n check-fast runs the unit runner" 0 "monorepo-run.sh check-fast" make -n -C "$S7" check-fast
units="$("$py" -B "$S7/scripts/monorepo_check.py" units "$S7" check-fast 2>&1)"
"$py" - "$units" <<'E' && pass "check-fast will run in exactly billing, catalog, catalog-worker, invoices; db has none" || fail "check-fast unit list wrong: $units"
import sys
rows = [l.split("\t") for l in sys.argv[1].splitlines() if l]
has = sorted(r[0] for r in rows if r[3] == "1")
sys.exit(0 if has == ["billing", "catalog", "catalog-worker", "invoices"] and {r[0] for r in rows} == {"db", "billing", "invoices", "catalog", "catalog-worker"} else 1)
E

# ---- .gitignore: the service's anchored patterns follow the service into services/<id>/
if command -v git >/dev/null 2>&1; then
  out="$(gitignore_ok "$S7" 2>&1)" && pass ".gitignore: the four anchored patterns ignore services/<id>/... for both go instances, and nothing at the repository root" || fail ".gitignore anchoring" "$out"
else skip ".gitignore check-ignore cases" "git is not installed"; fi

# ---- db-postgres in the assembled tree: its files, and its hermetic gate resolves its own paths there
miss=""
for p in db/image.lock db/compose.yml db/README.md scripts/db-pin-check.sh scripts/db_pin_compose.py scripts/tests/db-pin-check-selftest.sh; do [[ -f "$S7/$p" ]] || miss+=" $p"; done
[[ -z "$miss" && ! -e "$S7/db/db" ]] && pass "db-postgres lands at db/ (README as the unit file) and scripts/" || fail "db-postgres files misplaced:$miss"
expect "db-postgres: db-pin-check.sh runs in the assembled tree (no Docker) and finds db/image.lock" 0 "^OK db-pin-check" \
  env PATH="$(dirname "$(command -v "$py")"):$PATH" bash "$S7/scripts/db-pin-check.sh" "$S7/db/image.lock" --compose "$S7/db/compose.yml" "$S7/db/compose.timescale.yml"
expect "db-postgres: db-pin-check.sh finds its default lock ($here/../db/image.lock)" 0 "^OK db-pin-check" \
  env PATH="$(dirname "$(command -v "$py")"):$PATH" bash "$S7/scripts/db-pin-check.sh"

# ---- F4: every dependency is catalog:, and the catalog holds exact versions
"$py" - "$D" <<'E' && pass "design-system packages hold only catalog: / workspace:*; the catalog holds exact versions and covers every one" || fail "catalog invariant"
import sys, json, glob, re, yaml
root = sys.argv[1]
cat = yaml.safe_load(open(root + "/pnpm-workspace.yaml"))["catalog"]
names, bad = set(), []
for p in sorted(glob.glob(root + "/packages/*/package.json")):
    d = json.load(open(p))
    for f in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
        for k, v in d.get(f, {}).items():
            if v == "catalog:": names.add(k)
            elif v != "workspace:*": bad.append("%s %s=%s" % (p, k, v))
for k in sorted(names):
    if not re.fullmatch(r"\d+\.\d+\.\d+", str(cat.get(k))): bad.append("catalog %s=%r is not an exact version" % (k, cat.get(k)))
for k in cat:
    if k not in names: bad.append("catalog entry %s is used by no package" % k)
# the lockfile records the same catalog versions
lock = yaml.safe_load(open(root + "/pnpm-lock.yaml"))["catalogs"]["default"]
for k, v in cat.items():
    if lock.get(k, {}).get("specifier") != str(v): bad.append("lockfile catalog %s=%s != %s" % (k, lock.get(k), v))
for b in bad: print("  " + b)
sys.exit(1 if bad or not names else 0)
E

# ---- pnpm: the committed root lockfile is in sync with the assembled workspace. `--lockfile-only` makes the
# frozen check need no package store, so it is hermetic and takes 0.3 s; the full `--frozen-lockfile --offline`
# install needs a populated store (done by hand, see the hand-back).
frozen() { bash -c 'cd "$1" && pnpm install --frozen-lockfile --lockfile-only --ignore-scripts --offline' _ "$1"; }
if ! command -v pnpm >/dev/null 2>&1; then
  skip "pnpm install --frozen-lockfile (lockfile in sync)" "pnpm is not installed"
else
  expect "pnpm install --frozen-lockfile --lockfile-only --ignore-scripts --offline on a fresh seven-unit assembly" 0 "" frozen "$S7"
  S7b="$tmp/seven-b"
  A "$mods" --dest "$S7b" --layout monorepo --module monorepo-root --module design-system --unit service-go:payments --unit service-go:payments-worker --unit "service-python:risk,PACKAGE=risk" \
    --slot REPO=other-repo --slot SCOPE=ds-scope --slot OWNER=demo-owner >/dev/null 2>&1
  expect "the lockfile does not depend on the service ids (a second assembly with other ids)" 0 "" frozen "$S7b"
fi

# ---- mutations on scratch copies of the modules: each must turn the assembly (or the check) RED
M="$tmp/x/modules"; mkdir -p "$M" "$tmp/x"
cp -R "$here/prod-new/template" "$tmp/x/template"
for m in monorepo-root design-system service-go service-rust service-python db-postgres; do cp -R "$mods/$m" "$M/$m"; done
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

jedit "$M/service-python/module.json" 'del d["unit"]'
expect "mutation: the unit key removed from service-python is refused (unit files, repo.yaml present)" 2 "declares no .unit." \
  A "$M" --dest "$tmp/m6" --layout monorepo "${U7[@]}"
reset_mod service-python

expect "the unmutated service-go refuses the id Orders (charset lower-digits-dash)" 2 "" \
  A "$mods" --dest "$tmp/m7ok" --layout monorepo --module monorepo-root --unit service-go:Orders --slot REPO=demo-repo --slot OWNER=demo-owner
jedit "$M/service-go/module.json" 'd["slots"]["SERVICE"]="service name"'
if A "$M" --dest "$tmp/m7" --layout monorepo --module monorepo-root --unit service-go:Orders --slot REPO=demo-repo --slot OWNER=demo-owner >/dev/null 2>&1; then
  expect "mutation: with no charset the id Orders is accepted and the settings check in the assembled tree is RED" 1 "Orders" check "$tmp/m7"
else fail "mutation: service-go without charset should accept the id Orders"; fi
reset_mod service-go

jedit "$M/service-go/module.json" 'd["placement"]["AGENTS.md"]="root"'
expect "mutation: a slot-dependent service-go file (AGENTS.md) back at root collides between two instances" 1 "AGENTS.md" \
  A "$M" --dest "$tmp/m8" --layout monorepo --module monorepo-root --unit service-go:catalog --unit service-go:catalog-worker --slot REPO=demo-repo --slot OWNER=demo-owner
reset_mod service-go

jedit "$M/service-go/module.json" 'd["placement"]["registries/**"]="root"'
jedit "$M/service-rust/module.json" 'd["placement"]["registries/**"]="root"'
expect "mutation: the registries of service-go and service-rust back at root collide" 1 "registries/" \
  A "$M" --dest "$tmp/m9" --layout monorepo --module monorepo-root --unit service-go:catalog --unit service-rust:billing --slot REPO=demo-repo --slot OWNER=demo-owner
reset_mod service-go; reset_mod service-rust

jedit "$M/service-go/module.json" 'd["placement"][".gitignore"]="root"; d["root_merge"]={".gitignore":"union-lines"}'
if A "$M" --dest "$tmp/m10" --layout monorepo "${U6[@]}" >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  out="$(gitignore_ok "$tmp/m10" 2>&1)" && fail "mutation: .gitignore back to root+merge should break the anchored patterns" \
    || { [[ "$out" == *"is not ignored"* ]] && pass "mutation: .gitignore back to root+merge leaves services/<id>/ unignored (check-ignore RED)" || fail "mutation .gitignore: unexpected output" "$out"; }
elif command -v git >/dev/null 2>&1; then fail "mutation: .gitignore root+merge assembly should still assemble"
else skip "mutation: .gitignore back to root+merge" "git is not installed"; fi
reset_mod service-go

printf '{\n  "id": "db-postgres",\n  "summary": "x",\n  "contributes": [],\n  "requires": [],\n  "liabilities": []\n}\n' > "$M/db-postgres/module.json"
expect "mutation: db-postgres manifest back to the old descriptive format is exit 2" 2 "" \
  A "$M" --dest "$tmp/m11" --layout monorepo --module monorepo-root --unit db-postgres:db --slot REPO=demo-repo
reset_mod db-postgres

jedit "$M/db-postgres/module.json" 'd["unit"]["kind"]="service"'
expect "mutation: db-postgres unit kind service is refused (no SERVICE slot, would land under services/)" 2 "SERVICE slot" \
  A "$M" --dest "$tmp/m12" --layout monorepo --module monorepo-root --unit db-postgres:db --slot REPO=demo-repo
reset_mod db-postgres

jedit "$M/monorepo-root/module.json" 'del d["placement"]["pnpm-lock.yaml"]'
expect "mutation: the lockfile placement removed leaves an unplaced file (assembly refused)" 1 "pnpm-lock.yaml" \
  A "$M" --dest "$tmp/m13" --layout monorepo "${U7[@]}"
reset_mod monorepo-root

if command -v pnpm >/dev/null 2>&1; then
  c="$tmp/m14"; cp -R "$S7" "$c"
  sed -i.b 's|^  vitest: .*|  vitest: 5.1.0|' "$c/pnpm-workspace.yaml"; rm "$c/pnpm-workspace.yaml.b"
  expect "mutation: a catalog version changed without regenerating the lockfile makes the frozen install RED" 1 "" frozen "$c"
else skip "mutation: catalog version changed without the lockfile" "pnpm is not installed"; fi

jedit "$M/design-system/module.json" 'd["description"]="x"'
expect "mutation: an unknown key in the design-system manifest is exit 2" 2 "unknown key" \
  A "$M" --dest "$tmp/m5" --layout monorepo --module design-system --slot SCOPE=demo

summary="$ok ok, $bad failed"; [[ $skipped -gt 0 ]] && summary+=", $skipped skipped"; echo "$summary"
[[ $bad -eq 0 ]]
