#!/usr/bin/env bash
# monorepo-assembly-selftest.sh -- the modules assemble TOGETHER into one monorepo with the monorepo-root
# module, with the real manifests and no corrected copies: each manifest alone, the seven-unit assembly
# (root, design-system, go x2, rust, python, db-postgres) with its generated repo.yaml, per-unit file ownership,
# the settings check, the unit list of check-fast, .gitignore anchoring, the db-postgres gate in the tree, the
# catalog invariant, the GENERATED lockfile (`make lock` under two scopes, then the frozen check), single layout
# unchanged (and "one service + database" in single layout, for go, rust and python), and one RED mutation per guarded thing, each with
# a green control. No known gap is pinned: the design-system packages are declared units, so repo.yaml lists
# them and the root settings check on the seven-unit tree has no finding but lockfile-missing (GREEN once a lockfile exists).
# Sequential, no Docker; the network is used by ONE section only (make lock needs the npm registry; that section prints a
# SKIP, never an ok, when pnpm is absent or the registry unreachable). Needs python3 with PyYAML (PYTHON=<interpreter> to choose
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
SLG=(--slot REPO=demo-repo --slot SCOPE=demo --slot SERVICE=catalog --slot OWNER=demo-owner) # no PACKAGE: no python module
# The seven-unit monorepo: root + design-system + go, rust, python + a SECOND instance of service-go + db-postgres.
U7=(--module monorepo-root --module design-system --unit service-go:catalog --unit service-rust:billing
    --unit "service-python:invoices,PACKAGE=invoices" --unit service-go:catalog-worker --module db-postgres
    --slot REPO=demo-repo --slot SCOPE=demo --slot OWNER=demo-owner)
U6=(--module monorepo-root --unit service-go:catalog --unit service-rust:billing
    --unit "service-python:invoices,PACKAGE=invoices" --unit service-go:catalog-worker --module db-postgres
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

# github_root_ok <assembled-tree> <1|0 python unit present>: with python the root's .github is EXACTLY the one
# reusable workflow (no other file, no other workflow); without python the root has no .github. Prints the finding.
github_root_ok() {
  local t="$1" haspy="$2" found
  found="$(cd "$t" && find .github 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
  if [[ "$haspy" == 1 ]]; then
    [[ "$found" == ".github .github/workflows .github/workflows/python-unit.yml " ]] || { echo "  root .github is: ${found:-absent}"; return 1; }
  else
    [[ -z "$found" ]] || { echo "  root .github is: $found"; return 1; }
  fi
}

# ---- each manifest is accepted by the assembler on its own (one case per module)
for m in monorepo-root design-system service-go service-rust service-python db-postgres; do
  # shellcheck disable=SC2046
  expect "manifest of $m is accepted alone (layout monorepo)" 0 "slots remaining: 0" \
    A "$mods" --dest "$tmp/alone-$m" --layout monorepo --module "$m" $(slots_for "$m")
done

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

# ---- db-postgres in layout single: its README lives at db/README.md in both layouts (never a root README.md that
# would collide with a service's), and its gate runs in the assembled tree. "One service + database" follows below.
expect "single layout: db-postgres alone assembles and generates no inventory" 0 "layout single" \
  A "$mods" --dest "$tmp/single-db" --layout single --module db-postgres
[[ ! -e "$tmp/single-db/repo.yaml" && -f "$tmp/single-db/db/README.md" && ! -e "$tmp/single-db/README.md" ]] \
  && pass "single layout: db-postgres lands db/README.md and has no root README.md and no repo.yaml" || fail "single layout: db-postgres alone has a root README.md or a repo.yaml, or lacks db/README.md"
expect "single layout: db-postgres alone: db-pin-check.sh passes in the assembled tree" 0 "^OK db-pin-check" \
  env PATH="$(dirname "$(command -v "$py")"):$PATH" bash "$tmp/single-db/scripts/db-pin-check.sh" "$tmp/single-db/db/image.lock" --compose "$tmp/single-db/db/compose.yml" "$tmp/single-db/db/compose.timescale.yml"

# ---- "one service + database" in layout single (the assembler lets a module's declared units coexist with a service
# whose unit directory is the root): for each service module, the tree with db-postgres is the service-alone tree plus
# EXACTLY the files db-postgres places (db/** and scripts/**, both `root`), nothing generated, and its pin gate passes.
# tree_list <dir>: `path mode sha256` per file or link, sorted
tree_list() { "$py" - "$1" <<'E'
import hashlib, os, sys
root, out = sys.argv[1], []
for d, ds, fs in os.walk(root):
    for n in fs + [x for x in ds if os.path.islink(os.path.join(d, x))]:
        p = os.path.join(d, n); st = os.lstat(p)
        body = os.readlink(p).encode() if os.path.islink(p) else open(p, "rb").read()
        out.append("%s %o %s" % (os.path.relpath(p, root), st.st_mode & 0o777, hashlib.sha256(body).hexdigest()))
print("\n".join(sorted(out)))
E
}
# svcdb_ok <alone-tree> <with-db-tree>: alone is a subset (same mode and digest) of with-db, the extra paths are exactly
# the db-postgres module's own files under db/ and scripts/, db/README.md among them, none generated
svcdb_ok() {
  local a="$1" w="$2" extra want
  [[ -z "$(comm -23 <(tree_list "$a") <(tree_list "$w"))" ]] || { echo "  a service file differs or is missing"; return 1; }
  extra="$(comm -13 <(tree_list "$a" | cut -d' ' -f1) <(tree_list "$w" | cut -d' ' -f1))"
  want="$(cd "$mods/db-postgres" && find db scripts -type f | sort)"
  [[ "$extra" == "$want" ]] || { echo "  extra files differ from the module's db/ and scripts/ files"; return 1; }
  [[ -f "$w/db/README.md" && ! -e "$w/repo.yaml" ]] || { echo "  no db/README.md, or a repo.yaml exists"; return 1; }
  grep -qx 'db/README.md' <<<"$extra" || return 1
}
for m in service-go service-rust service-python; do
  # shellcheck disable=SC2046
  expect "single layout: $m alone assembles (baseline for the database case)" 0 "layout single" \
    A "$mods" --dest "$tmp/sd-alone-$m" --layout single --module "$m" $(slots_for "$m")
  # shellcheck disable=SC2046
  expect "single layout: $m + db-postgres assembles (exit 0)" 0 "layout single" \
    A "$mods" --dest "$tmp/sd-$m" --layout single --module "$m" --module db-postgres $(slots_for "$m")
  out="$(svcdb_ok "$tmp/sd-alone-$m" "$tmp/sd-$m" 2>&1)" \
    && pass "single layout: $m + db-postgres = $m alone (same files, modes, digests) + db/** and scripts/** of db-postgres, db/README.md, no inventory" \
    || fail "single layout: $m + db-postgres tree" "$out"
  expect "single layout: $m + db-postgres: db-pin-check.sh passes in the assembled tree" 0 "^OK db-pin-check" \
    env PATH="$(dirname "$(command -v "$py")"):$PATH" bash "$tmp/sd-$m/scripts/db-pin-check.sh" "$tmp/sd-$m/db/image.lock" --compose "$tmp/sd-$m/db/compose.yml" "$tmp/sd-$m/db/compose.timescale.yml"
done

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
  if grep -rIlE '<(REPO|SERVICE|PACKAGE|OWNER|SCOPE)>|repo-name|ds-scope' "$t" >/dev/null; then fail "$n: slot placeholders or literals left"; else pass "$n: no slot placeholder or literal left"; fi
  [[ -f "$t/packages/tokens/package.json" && -f "$t/packages/theme/package.json" && ! -e "$t/services/catalog/packages" ]] \
    && pass "$n: design-system packages are at packages/, none under services/" || fail "$n: design-system packages misplaced"
  [[ -f "$t/services/catalog/Makefile" && ! -e "$t/services/catalog/package.json" ]] \
    && pass "$n: the service is under services/catalog" || fail "$n: service not under services/catalog"
done
if grep -rIlE '<(REPO|SERVICE|PACKAGE|OWNER|SCOPE)>|repo-name|ds-scope' "$S7" "$S6" >/dev/null; then fail "seven/six-unit trees: slot placeholders or literals left"; else pass "seven/six-unit trees: no slot placeholder or literal left"; fi
"$py" - "$D" "$G" "$S7" <<'E' && pass "one root package.json with packageManager, one pnpm-workspace.yaml, no lockfile shipped (it is generated by make lock), all at the root" || fail "root files: see above"
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
    if found["pnpm-lock.yaml"] != []: bad.append("%s: lockfiles %s" % (root, found["pnpm-lock.yaml"]))
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
for p in AGENTS.md CODEOWNERS registries .prod docs/RUNBOOK.md scripts/verify-standard.sh scripts/coverage-floors.txt; do [[ -e "$S7/$p" ]] && bad_root+=" $p"; done
[[ -z "$bad_root" ]] && pass "no service file at the repository root (AGENTS.md, CODEOWNERS, registries/, .prod/, verify-standard.sh ...)" || fail "service files at the root:$bad_root"
# the one exception: service-python's reusable workflow. With a python unit the root's .github holds exactly
# .github/workflows/python-unit.yml; without one the root has no .github at all
for t in "$S7" "$S6" "$D"; do
  gh_msg="$(github_root_ok "$t" 1)" && pass "${t##*/}: the root .github holds exactly workflows/python-unit.yml (a python unit is present)" || fail "${t##*/}: root .github" "$gh_msg"
done
gh_msg="$(github_root_ok "$G" 0)" && pass "repo-go: no .github at the repository root (no python unit)" || fail "repo-go: root .github" "$gh_msg"
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

# ---- repo.yaml written by the assembler: the services (instances), the database and the two packages (declared units)
inv_ok() { "$py" - "$1" <<'E'
import sys, yaml
got = sorted((u["id"], u["kind"], u["language"], u["path"]) for u in yaml.safe_load(open(sys.argv[1]))["units"])
want = sorted([("db", "database", "sql", "db"), ("tokens", "package", "ts", "packages/tokens"),
               ("theme", "package", "ts", "packages/theme"), ("billing", "service", "rust", "services/billing"),
               ("invoices", "service", "python", "services/invoices"), ("catalog", "service", "go", "services/catalog"),
               ("catalog-worker", "service", "go", "services/catalog-worker")])
for g in got:
    if g not in want: print("  unexpected", g)
for w in want:
    if w not in got: print("  missing", w)
sys.exit(0 if got == want else 1)
E
}
inv_ok "$S7/repo.yaml" && pass "repo.yaml lists exactly seven units: db, tokens, theme, billing, invoices, catalog, catalog-worker (id, kind, language, path)" || fail "repo.yaml units differ"

# ---- the root module's settings check on the assembled trees: no manual edit anywhere, the assembler wrote
# every entry (the design-system packages are declared units)
# The trees with JS packages (the design-system) have no lockfile until `make lock` has run: exactly ONE finding,
# lockfile-missing, and GREEN once a lockfile exists. The lockfile here is written by hand (minimal; the check only tests
# that the file exists and never parses it), so this proves the rule's presence test, NOT pnpm's acceptance of it (the
# network section below proves that with the generated lockfile). S6 has no JS package: GREEN with no lockfile.
minlock() { printf "lockfileVersion: '9.0'\n\nsettings:\n  autoInstallPeers: true\n  excludeLinksFromLockfile: false\n\nimporters:\n\n  .: {}\n" > "$1/pnpm-lock.yaml"; }
expect "settings check GREEN on the assembled tree ${S6##*/} (no JS package, so no lockfile needed), no manual edit" 0 "^OK monorepo-settings-check" check "$S6"
for t in "$S7" "$D" "$G"; do
  out="$(check "$t" 2>&1)"; rc=$?; found="$(grep -E '^[^ :]+:[0-9]+: ' <<<"$out")"
  if [[ $rc -eq 1 && "$found" == "pnpm-lock.yaml:1: lockfile-missing "* && $(wc -l <<<"$found") -eq 1 ]]; then
    pass "settings check on the fresh assembled tree ${t##*/}: exactly ONE finding, lockfile-missing"
  else fail "settings check on the fresh assembled tree ${t##*/}: exactly ONE finding, lockfile-missing" "exit $rc: $(head -c 300 <<<"$out")"; fi
  cp -R "$t" "$tmp/lk-${t##*/}"; minlock "$tmp/lk-${t##*/}"
  expect "settings check GREEN on the assembled tree ${t##*/} once a (hand-written) lockfile exists, no other edit" 0 "^OK monorepo-settings-check" check "$tmp/lk-${t##*/}"
done

# ---- make -n check-fast at the root, and the unit list it runs (no toolchain is started)
out="$(make --no-print-directory -n -C "$S7" check-fast 2>&1)"   # GNU make 4 prints Entering/Leaving directory with -C
[[ "$(grep -n . <<<"$out" | sed -n 1p | cut -d: -f2-)" == "bash scripts/monorepo-settings-check.sh" && "$(grep -n . <<<"$out" | sed -n 2p | cut -d: -f2-)" == "bash scripts/monorepo-run.sh check-fast" ]] \
  && pass "root make -n check-fast shows the settings check first, then the unit runner" || fail "root make -n check-fast order" "$out"
units="$("$py" -B "$S7/scripts/monorepo_check.py" units "$S7" check-fast 2>&1)"
"$py" - "$units" <<'E' && pass "check-fast covers exactly the four services (billing, catalog, catalog-worker, invoices); db, tokens, theme have none; seven units listed" || fail "check-fast unit list wrong: $units"
import sys
rows = [l.split("\t") for l in sys.argv[1].splitlines() if l]
has = sorted(r[0] for r in rows if r[3] == "1")
sys.exit(0 if has == ["billing", "catalog", "catalog-worker", "invoices"] and {r[0] for r in rows} == {"db", "theme", "tokens", "billing", "invoices", "catalog", "catalog-worker"} else 1)
E

# ---- .gitignore: the service's anchored patterns follow the service into services/<id>/
if command -v git >/dev/null 2>&1; then
  out="$(gitignore_ok "$S7" 2>&1)" && pass ".gitignore: the four anchored patterns ignore services/<id>/... for both go instances, and nothing at the repository root" || fail ".gitignore anchoring" "$out"
else skip ".gitignore check-ignore cases" "git is not installed"; fi

# ---- db-postgres in the assembled tree: its files, and its hermetic gate resolves its own paths there
miss=""
for p in db/image.lock db/compose.yml db/README.md db/bootstrap/README.md scripts/db-pin-check.sh scripts/db_pin_compose.py scripts/tests/db-pin-check-selftest.sh; do [[ -f "$S7/$p" ]] || miss+=" $p"; done
[[ -z "$miss" && ! -e "$S7/db/db" && ! -e "$S7/README.md" ]] && pass "db-postgres lands at db/ (its README is db/README.md, none at the repository root) and scripts/" || fail "db-postgres files misplaced:$miss"
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
for b in bad: print("  " + b)
sys.exit(1 if bad or not names else 0)
E

# ---- the lockfile is GENERATED (never shipped): `make lock` writes it, `make lock-check` (frozen, lockfile-only,
# offline) passes right after, under two different scopes; the registry is needed for `make lock` only
tools_ok=1
if ! command -v pnpm >/dev/null 2>&1; then tools_ok=0; reason="pnpm is not installed"
elif ! command -v curl >/dev/null 2>&1 || ! curl -sS -m 5 -o /dev/null https://registry.npmjs.org/ 2>/dev/null; then tools_ok=0; reason="the npm registry is unreachable"; fi
# pnpm_env: a private HOME, store and caches, so nothing of the user's pnpm state is read or written
pnpm_env() { env HOME="$tmp/home" npm_config_store_dir="$tmp/home/store" XDG_CACHE_HOME="$tmp/home/cache" XDG_DATA_HOME="$tmp/home/data" \
  XDG_STATE_HOME="$tmp/home/state" npm_config_update_notifier=false "$@"; }
mklock() { pnpm_env make -C "$1" lock; }
lockchk() { pnpm_env make -C "$1" lock-check; }
expect "root Makefile: make -n lock runs pnpm install --lockfile-only --ignore-scripts" 0 "pnpm install --lockfile-only --ignore-scripts" make -n -C "$S7" lock
expect "root Makefile: make -n lock-check runs the frozen, lockfile-only, offline install" 0 "pnpm install --frozen-lockfile --lockfile-only --ignore-scripts --offline" make -n -C "$S7" lock-check
if [[ $tools_ok -eq 0 ]]; then
  skip "make lock under two scopes, then make lock-check (not reported ok)" "$reason"
else
  SA="$tmp/scope-a"; SB="$tmp/scope-b"
  mkws() { A "$mods" --dest "$1" --layout monorepo --module monorepo-root --module design-system --unit service-go:catalog \
    --slot REPO=demo-repo --slot SCOPE="$2" --slot OWNER=demo-owner >/dev/null 2>&1; }
  mkws "$SA" acme; mkws "$SB" other
  expect "make lock-check on a fresh assembly (no lockfile yet) is RED" 2 "" lockchk "$SA"
  expect "make lock generates the lockfile under scope acme" 0 "" mklock "$SA"
  expect "make lock generates the lockfile under scope other" 0 "" mklock "$SB"
  grep -q '@acme/tokens' "$SA/pnpm-lock.yaml" && grep -q '@other/tokens' "$SB/pnpm-lock.yaml" && ! grep -q '@acme/' "$SB/pnpm-lock.yaml" \
    && pass "each generated lockfile names its own scope (@acme/*, @other/*), none the other's" || fail "generated lockfile scope names"
  expect "make lock-check (frozen, offline) passes right after make lock, scope acme" 0 "" lockchk "$SA"
  expect "make lock-check (frozen, offline) passes right after make lock, scope other" 0 "" lockchk "$SB"
  expect "the settings check stays GREEN once the lockfile is generated" 0 "^OK monorepo-settings-check" check "$SA"
  c="$tmp/m14"; cp -R "$SA" "$c"
  sed -i.b 's|^  vitest: .*|  vitest: 5.1.0|' "$c/pnpm-workspace.yaml"; rm "$c/pnpm-workspace.yaml.b"
  expect "mutation: a catalog version changed without regenerating the lockfile makes make lock-check RED (control: scope acme above is GREEN)" 2 "" lockchk "$c"
  c="$tmp/m15"; cp -R "$SA" "$c"; cp "$SB/pnpm-lock.yaml" "$c/pnpm-lock.yaml"
  expect "mutation: another scope's lockfile in the tree makes make lock-check RED (control: scope acme above is GREEN)" 2 "" lockchk "$c"
fi

# ---- mutations on scratch copies of the modules: each one is RED, and each has a GREEN control (the same
# scenario on the unmutated copy, placed the same way) that runs first and must pass
M="$tmp/x/modules"; mkdir -p "$M" "$tmp/x"
cp -R "$here/prod-new/template" "$tmp/x/template"
for m in monorepo-root design-system service-go service-rust service-python db-postgres; do cp -R "$mods/$m" "$M/$m"; done
# jedit <manifest> <python statements>: edits the parsed manifest (d) and may touch files (dd = module dir);
# fails when the edit changed neither the manifest nor... the statements raise or leave d unchanged AND no file
jedit() { "$py" -c '
import copy, json, os, sys
p = sys.argv[1]; dd = os.path.dirname(p); d = json.load(open(p)); o = copy.deepcopy(d)
before = sorted(os.listdir(dd))
exec(sys.argv[2])
if d == o and sorted(os.listdir(dd)) == before: sys.exit(3)
json.dump(d, open(p, "w"), indent=2)' "$1" "$2"; }
reset_mod() { rm -rf "${M:?}/$1"; cp -R "$mods/$1" "$M/$1"; }
mi=0
# mut_asm <name> <rc> <pattern> <module> <edit> <assembler args...>: control, edit, expect, reset
mut_asm() {
  local name="$1" want="$2" pat="$3" mod="$4" edit="$5"; shift 5; mi=$((mi + 1))
  if A "$M" --dest "$tmp/ctl$mi" "$@" >/dev/null 2>&1; then pass "control for the next mutation: the unmutated copy assembles (exit 0)"
  else fail "control for: $name" "the unmutated scratch copy does not assemble"; fi
  if jedit "$M/$mod/module.json" "$edit"; then expect "$name" "$want" "$pat" A "$M" --dest "$tmp/mut$mi" "$@"
  else fail "$name" "the edit changed nothing"; fi
  reset_mod "$mod"
}
MROOT=(--layout monorepo --module monorepo-root --slot REPO=demo-repo)

mut_asm "mutation: design-system placement back to unit is refused (it would land under services/)" 2 "SERVICE slot" design-system \
  'd["placement"]["packages/**"]="unit"' --layout monorepo --module monorepo-root --module design-system --module service-python "${SL[@]}"

mut_asm "mutation: design-system root package.json not excluded collides with the root module's" 1 "package.json" design-system \
  'open(dd + "/package.json", "w").write("{\"name\": \"design-system-workspace\", \"private\": true}\n"); d["placement"]["package.json"]="root"' \
  --layout monorepo --module monorepo-root --module design-system --module service-python "${SL[@]}"

mut_asm "mutation: a declared design-system unit path changed (packages/tok is not packages/tokens) is exit 2" 2 "packages/tok" design-system \
  'd["units"][0]["path"]="packages/tok"' --layout monorepo "${U7[@]}"

# the design-system units removed: it assembles, but the root settings check is RED (the control is the GREEN S7 above)
jedit "$M/design-system/module.json" 'del d["units"]' && A "$M" --dest "$tmp/mu" --layout monorepo "${U7[@]}" >/dev/null 2>&1
[[ -d "$tmp/mu" ]] && expect "mutation: units removed from the design-system manifest: the settings check on the assembled tree is RED (unit-unlisted)" 1 "unit-unlisted packages/(theme|tokens)" check "$tmp/mu" \
  || fail "mutation: design-system without units should still assemble"
reset_mod design-system

c="$tmp/m3"; cp -R "$D" "$c"
sed -i.b 's|"typescript": "catalog:"|"typescript": "7.0.2"|' "$c/packages/tokens/package.json"; rm "$c/packages/tokens/package.json.b"
expect "mutation: a dependency back to an exact version makes the settings check RED (control: the unmutated tree is GREEN above)" 1 "non-catalog-dep .*7\.0\.2" check "$c"

c="$tmp/m4"; cp -R "$D" "$c"
sed -i.b 's|"private": true,|"private": true, "devEngines": {"runtime": {"name": "node"}},|' "$c/packages/tokens/package.json"; rm "$c/packages/tokens/package.json.b"
grep -q devEngines "$c/packages/tokens/package.json" && expect "mutation: a workspace package.json gaining devEngines makes the settings check RED (control: the unmutated tree is GREEN above)" 1 "devEngines" check "$c" \
  || fail "mutation devEngines: the edit changed nothing"

mut_asm "mutation: the unit key removed from service-python is refused (unit files, repo.yaml present)" 2 "declares no .unit." service-python \
  'del d["unit"]' --layout monorepo "${U7[@]}"

expect "the unmutated service-go refuses the id Orders (charset lower-digits-dash)" 2 "" \
  A "$mods" --dest "$tmp/m7ok" --layout monorepo --module monorepo-root --unit service-go:Orders --slot REPO=demo-repo --slot OWNER=demo-owner
jedit "$M/service-go/module.json" 'del d["slots"]["SERVICE"]["charset"]' \
  && expect "mutation: with the charset removed the id Orders is STILL refused (second guard: the inventory id grammar, exit 2)" 2 "does not match" \
    A "$M" --dest "$tmp/m7" --layout monorepo --module monorepo-root --unit service-go:Orders --slot REPO=demo-repo --slot OWNER=demo-owner \
  || fail "mutation: the charset edit changed nothing"
reset_mod service-go

mut_asm "mutation: a slot-dependent service-go file (AGENTS.md) back at root collides between two instances" 1 "AGENTS.md" service-go \
  'd["placement"]["AGENTS.md"]="root"' "${MROOT[@]}" --slot OWNER=demo-owner --unit service-go:catalog --unit service-go:catalog-worker

A "$M" --dest "$tmp/ctlreg" "${MROOT[@]}" --slot OWNER=demo-owner --unit service-go:catalog --unit service-rust:billing >/dev/null 2>&1 \
  && pass "control for the next mutation: the unmutated copies of service-go and service-rust assemble (exit 0)" || fail "control for the registries mutation"
jedit "$M/service-rust/module.json" 'd["placement"]["registries/**"]="root"' && jedit "$M/service-go/module.json" 'd["placement"]["registries/**"]="root"' \
  && expect "mutation: the registries of service-go and service-rust back at root collide" 1 "registries/" \
    A "$M" --dest "$tmp/mreg" "${MROOT[@]}" --slot OWNER=demo-owner --unit service-go:catalog --unit service-rust:billing || fail "registries mutation: the edit changed nothing"
reset_mod service-go; reset_mod service-rust

jedit "$M/service-go/module.json" 'd["placement"][".gitignore"]="root"; d["root_merge"]={".gitignore":"union-lines"}'
if A "$M" --dest "$tmp/m10" --layout monorepo "${U6[@]}" >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  gitignore_ok "$S6" >/dev/null 2>&1 && pass "control for the next mutation: the unmutated six-unit tree passes the anchored .gitignore check" || fail "control for the .gitignore mutation"
  out="$(gitignore_ok "$tmp/m10" 2>&1)" && fail "mutation: .gitignore back to root+merge should break the anchored patterns" \
    || { [[ "$out" == *"is not ignored"* ]] && pass "mutation: .gitignore back to root+merge leaves services/<id>/ unignored (check-ignore RED)" || fail "mutation .gitignore: unexpected output" "$out"; }
elif command -v git >/dev/null 2>&1; then fail "mutation: .gitignore root+merge assembly should still assemble"
else skip "mutation: .gitignore back to root+merge" "git is not installed"; fi
reset_mod service-go

mut_asm "mutation: db-postgres manifest with an unknown key is exit 2" 2 "unknown key" db-postgres \
  'd["summary"]="x"' "${MROOT[@]}" --module db-postgres

mut_asm "mutation: a db-postgres declared unit of kind service (path db is not services/db) is exit 2" 2 "db" db-postgres \
  'd["units"][0]["kind"]="service"' "${MROOT[@]}" --module db-postgres

# the README back at the module root: in layout single it lands at the repository root (where a service's README.md
# would collide with it) instead of db/README.md; the unmutated copy lands db/README.md only (control, same args)
A "$M" --dest "$tmp/ctlrd" --layout single --module db-postgres >/dev/null 2>&1 && [[ -f "$tmp/ctlrd/db/README.md" && ! -e "$tmp/ctlrd/README.md" ]] \
  && pass "control for the next mutation: the unmutated db-postgres lands db/README.md and no root README.md" || fail "control for the README mutation"
jedit "$M/db-postgres/module.json" 'os.rename(dd + "/db/README.md", dd + "/README.md"); d["placement"]["README.md"]="root"' \
  && A "$M" --dest "$tmp/mrd" --layout single --module db-postgres >/dev/null 2>&1
[[ -f "$tmp/mrd/README.md" && ! -e "$tmp/mrd/db/README.md" ]] && pass "mutation: db-postgres README back at the module root lands a root README.md (the service collision), RED against the case above" \
  || fail "mutation: the README at the module root should land at the repository root"
reset_mod db-postgres

# db `units` removed: it assembles, but repo.yaml lacks db (the same comparison as the case above is RED)
jedit "$M/db-postgres/module.json" 'del d["units"]' && A "$M" --dest "$tmp/mdb" --layout monorepo "${U7[@]}" >/dev/null 2>&1
if [[ -f "$tmp/mdb/repo.yaml" ]]; then inv_ok "$tmp/mdb/repo.yaml" >/dev/null 2>&1 && fail "mutation: db units removed should drop db from repo.yaml" \
  || pass "mutation: units removed from the db-postgres manifest: repo.yaml no longer lists db (inventory comparison RED)"
else fail "mutation: db-postgres without units should still assemble"; fi
reset_mod db-postgres

mut_asm "mutation: a root file of the root module inside another unit's directory (services/catalog/) is refused" 1 "root file inside the unit directory" monorepo-root \
  'os.makedirs(dd + "/services/catalog"); open(dd + "/services/catalog/x.txt", "w").write("x\n"); d["placement"]["services/**"]="root"' \
  --layout monorepo "${U7[@]}"

# the lock target removed from the root Makefile: make lock has no rule (the control is the make -n lock case above)
sed -i.b -e '/^lock:/,/^$/d' -e 's/ lock lock-check$/ lock-check/' "$M/monorepo-root/Makefile"; rm "$M/monorepo-root/Makefile.b"
if A "$M" --dest "$tmp/mlock" --layout monorepo "${U7[@]}" >/dev/null 2>&1; then
  expect "mutation: the lock target removed from the root Makefile makes make lock fail" 2 "No rule to make target" make -n -C "$tmp/mlock" lock
else fail "mutation: root Makefile without lock should assemble"; fi
reset_mod monorepo-root

if [[ $tools_ok -eq 1 ]]; then
  # the lockfile placement restored: a lockfile generated under scope acme ships in monorepo-root, and an
  # assembly under scope other fails the frozen check (the control: the scope acme assembly passes it, above)
  cp "$SA/pnpm-lock.yaml" "$M/monorepo-root/pnpm-lock.yaml"
  jedit "$M/monorepo-root/module.json" 'd["placement"]["pnpm-lock.yaml"]="root"'
  A "$M" --dest "$tmp/mshipped" --layout monorepo --module monorepo-root --module design-system --slot REPO=demo-repo --slot SCOPE=other >/dev/null 2>&1
  [[ -f "$tmp/mshipped/pnpm-lock.yaml" ]] && expect "mutation: the lockfile placement restored: a shipped acme lockfile fails the frozen check under scope other" 2 "" lockchk "$tmp/mshipped" \
    || fail "mutation: the shipped-lockfile assembly did not produce a lockfile"
  reset_mod monorepo-root
fi

mut_asm "mutation: an unknown key in the design-system manifest is exit 2" 2 "unknown key" design-system \
  'd["description"]="x"' --layout monorepo --module design-system --slot SCOPE=demo

# the root-workflow rule must DEMAND the file when python is present, and refuse anything else under .github:
# control = the unmutated copy passes; mutants = the workflow key back to "unit", then a stray workflow / stray root file
pyargs=(--layout monorepo --module monorepo-root --unit "service-python:invoices,PACKAGE=invoices" --slot REPO=demo-repo --slot OWNER=demo-owner)
if A "$M" --dest "$tmp/mwfc" "${pyargs[@]}" >/dev/null 2>&1 && github_root_ok "$tmp/mwfc" 1 >/dev/null; then
  pass "control for the next mutations: the unmutated copy puts exactly python-unit.yml under the root .github"
  : >"$tmp/mwfc/.github/workflows/other.yml"
  github_root_ok "$tmp/mwfc" 1 >/dev/null && fail "mutation: a second root workflow is accepted" || pass "mutation: a second workflow under the root .github is RED"
  rm "$tmp/mwfc/.github/workflows/other.yml"; : >"$tmp/mwfc/.github/CODEOWNERS"
  github_root_ok "$tmp/mwfc" 1 >/dev/null && fail "mutation: a stray root .github file is accepted" || pass "mutation: a stray file under the root .github is RED"
else fail "control for the root-workflow mutations" "the unmutated copy does not pass"; fi
if jedit "$M/service-python/module.json" 'd["placement"][".github/workflows/python-unit.yml"]="unit"' \
  && A "$M" --dest "$tmp/mwfm" "${pyargs[@]}" >/dev/null 2>&1; then
  github_root_ok "$tmp/mwfm" 1 >/dev/null && fail "mutation: python-unit.yml placed in the unit is accepted" || pass "mutation: python-unit.yml placed in the unit leaves the root without it, RED"
else fail "mutation: python-unit.yml placed in the unit" "the edit changed nothing or the copy does not assemble"; fi
reset_mod service-python
G0="$tmp/mwfg"; A "$M" --dest "$G0" --layout monorepo --module monorepo-root --unit service-go:catalog --slot REPO=demo-repo --slot OWNER=demo-owner >/dev/null 2>&1 \
  && { mkdir -p "$G0/.github/workflows"; : >"$G0/.github/workflows/python-unit.yml"; github_root_ok "$G0" 0 >/dev/null && fail "mutation: a root .github without a python unit is accepted" || pass "mutation: a root .github with no python unit is RED"; } \
  || fail "mutation: the go-only assembly for the no-python check did not assemble"

# ---- mutation on a scratch copy of the ASSEMBLER (placed where it finds template/: $tmp/x/scripts): the single-layout
# exemption removed (an instance's root unit directory is compared with a declared directory again) makes each
# "service + db-postgres" assembly exit 2. The control is the UNMUTATED copy, same place, same scenario: it must assemble.
mkdir -p "$tmp/x/scripts"; cp "$asm" "$tmp/x/scripts/assemble.py"
XA() { "$py" -I -B "$tmp/x/scripts/assemble.py" --modules-dir "$M" "$@"; }
for m in service-go service-rust service-python; do
  # shellcheck disable=SC2046
  XA --dest "$tmp/xctl-$m" --layout single --module "$m" --module db-postgres $(slots_for "$m") >/dev/null 2>&1 \
    && pass "control for the next mutation: the unmutated assembler copy assembles $m + db-postgres in single (exit 0)" \
    || fail "control for the exemption mutation: $m + db-postgres" "the unmutated copy does not assemble"
done
if "$py" -I -B - "$tmp/x/scripts/assemble.py" <<'E'
import sys
p = sys.argv[1]; s = open(p).read()
old = '            if a.layout == "single" and x["decl"] != y["decl"]:\n                continue\n'
if old not in s: sys.exit(3)
open(p, "w").write(s.replace(old, ""))
E
then
  for m in service-go service-rust service-python; do
    # shellcheck disable=SC2046
    expect "mutation: single-layout exemption removed: $m + db-postgres is refused (exit 2, shared unit directory)" 2 "would share the unit directory" \
      XA --dest "$tmp/xmut-$m" --layout single --module "$m" --module db-postgres $(slots_for "$m")
  done
else
  fail "mutation: single-layout exemption removed" "the edit changed nothing"
fi

summary="$ok ok, $bad failed"; [[ $skipped -gt 0 ]] && summary+=", $skipped skipped"; echo "$summary"
[[ $bad -eq 0 ]]
