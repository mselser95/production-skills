#!/usr/bin/env bash
# web-format-selftest.sh -- the web-react `format` package (prod-new/modules/web-react/packages/format).
# The default run is hermetic: static checks only, no network, no install, no node. It proves the manifest stays inside
# the workspace rules, the tsconfig inherits the strict base, the source holds no float-based formatting call, every
# exported function has a test and a provenance header, and nothing generated is committed.
# WEB_FORMAT_LIVE=1 (a human, or the opt-in container job that has node >=24, pnpm 10.34.3 and the registry) adds the
# live section: copy the package to a scratch workspace, `pnpm install --ignore-scripts`, typecheck + vitest, the TZ
# matrix, then MUTATIONS of the source, each proven RED after its unmutated control ran GREEN the same way.
# PKG_SRC=<dir> tests another copy of the package (mutation proofs of this script). Final line:
# `<N> ok, <M> failed[, K skipped]`. Exit: 0 all ok - 1 a case failed - 2 cannot run.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
root_mod="$here/prod-new/modules/monorepo-root"
pkg="${PKG_SRC:-$here/prod-new/modules/web-react/packages/format}"
# The catalog line this package needs and monorepo-root does not carry yet (see the module hand-back).
pending_catalog="fast-check"
pending_version="4.10.3"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not found" >&2; exit 2; }
[[ -f "$pkg/package.json" ]] || { echo "FAIL: no package at $pkg" >&2; exit 2; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/web-format.XXXXXX")" || exit 2
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
export TMPDIR="$tmp" HOME="$tmp/home"; mkdir -p "$HOME"

ok=0; bad=0; skipped=0
pass() { ok=$((ok + 1)); echo "ok   $1"; }
fail() { bad=$((bad + 1)); echo "FAIL $1${2:+ -- $2}"; }
skip() { skipped=$((skipped + 1)); echo "SKIP $1 -- $2"; }

# ---- manifest: allow-list and catalog rules, read from the monorepo-root module's own definitions
py_out="$(python3 -I -B - "$pkg/package.json" "$root_mod" "$pending_catalog" <<'PY'
import ast, json, re, sys
pj, root, pending = sys.argv[1:4]
out = []
def say(ok, msg): out.append(("ok   " if ok else "FAIL ") + msg)
d = json.load(open(pj))
src = open(root + "/scripts/monorepo_check.py").read()
vals = {}
for node in ast.parse(src).body:
    if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
        vals[node.targets[0].id] = node.value
dep_fields = ast.literal_eval(vals["DEP_FIELDS"])
ws = vals["WORKSPACE_PKG_KEYS"].args[0]                      # frozenset((... ) + DEP_FIELDS)
allowed = set(ast.literal_eval(ws.left)) | set(dep_fields)
extra = sorted(set(d) - allowed)
say(not extra, "package.json keys are inside the workspace allow-list" + ("" if not extra else ": refused " + ",".join(extra)))
say(re.fullmatch(r"@ds-scope/format", d.get("name", "")) is not None, "package name is @ds-scope/format (the scope slot literal)")
say(d.get("private") is True and d.get("type") == "module", "private, ESM")
rootpkg = json.load(open(root + "/package.json"))
say(d.get("engines") == rootpkg["engines"] or d.get("engines") == {"node": rootpkg["engines"]["node"]}, "engines match the root's node range")
life = {"preinstall", "install", "postinstall", "prepare", "prepublish", "prepublishOnly", "preprepare", "postprepare"}
say(not (set(d.get("scripts", {})) & life), "no lifecycle script")
say(set(d.get("scripts", {})) == {"test", "typecheck"}, "scripts are exactly test and typecheck (the names the other TS packages use)")
say("dependencies" not in d and "peerDependencies" not in d and "optionalDependencies" not in d, "runtime-dependency-free: no dependencies / peerDependencies / optionalDependencies")
dev = d.get("devDependencies", {})
say(all(v == "catalog:" for v in dev.values()) and len(dev) > 0, "every devDependency is `catalog:` (no exact or range version in the manifest)")
cat = open(root + "/pnpm-workspace.yaml").read()
m = re.search(r"^catalog:\n((?:  .*\n)+)", cat, re.M)
names = {re.sub(r"[\"']", "", l.split(":")[0].strip()) for l in m.group(1).splitlines()} if m else set()
for n in sorted(dev):
    if n in names: say(True, "catalog entry exists for " + n)
    elif n == pending: out.append("SKIP catalog entry for %s -- monorepo-root's pnpm-workspace.yaml has no `%s` line yet (a follow-up edit owned by that module)" % (n, n))
    else: say(False, "no catalog entry for " + n)
sys.stdout.write("\n".join(out) + "\n")
PY
)" || { fail "manifest checker did not run" "$py_out"; py_out=""; }
while IFS= read -r l; do
  case "$l" in
    "ok   "*) pass "${l#ok   }";;
    "FAIL "*) fail "${l#FAIL }";;
    "SKIP "*) l="${l#SKIP }"; skip "${l%% -- *}" "${l#* -- }";;
  esac
done <<<"$py_out"
[[ -n "$py_out" ]] || fail "manifest checker produced no output"

# ---- tsconfig: inherits the strict base; the base carries the strict flags; the package may not weaken them
base="$root_mod/tsconfig.base.json"
python3 -I -B - "$pkg/tsconfig.json" "$base" <<'PY' && pass "tsconfig extends the base, sets no compilerOptions, and the base is strict (strict, noUncheckedIndexedAccess, exactOptionalPropertyTypes, verbatimModuleSyntax, ...)" || fail "tsconfig strictness"
import json, sys
t = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))["compilerOptions"]
assert t.get("extends") == "../../tsconfig.base.json", t.get("extends")
assert "compilerOptions" not in t, "package tsconfig must not override compilerOptions"
assert set(t.get("include", [])) == {"src", "test"}, t.get("include")
for k in ("strict", "noUncheckedIndexedAccess", "exactOptionalPropertyTypes", "noImplicitOverride", "noFallthroughCasesInSwitch", "verbatimModuleSyntax", "isolatedModules", "noImplicitReturns"):
    assert b.get(k) is True, k
PY

# ---- no float-based formatting in src/: the same grep the package's own guard test runs
forbidden_rx='\.toFixed\(|\.toPrecision\(|\.toExponential\(|\.toLocaleString\(|\bparseFloat\(|\bparseInt\(|\bNumber\(|\bMath\.round\('
forbidden_hits() { # <dir>: offending non-comment, non-allow-listed lines
  grep -nE -- "$forbidden_rx" "$1"/*.ts 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*(//|\*|/\*)' | grep -v 'format-guard-allow:'
}
if hits="$(forbidden_hits "$pkg/src")"; then fail "src/ holds a forbidden float-based call" "$(head -c 240 <<<"$hits")"; else pass "src/ holds no toFixed / toPrecision / toExponential / toLocaleString / parseFloat / parseInt / Number( / Math.round("; fi
n_src="$(find "$pkg/src" -name '*.ts' | wc -l | tr -d ' ')"
[[ "$n_src" -ge 8 ]] && pass "src/ has $n_src source files (the grep scans something)" || fail "src/ has only $n_src source files"
# the grep bites: a copy with one forbidden line is caught, the clean copy is not
cp -R "$pkg/src" "$tmp/src-ctl"; cp -R "$pkg/src" "$tmp/src-mut"
printf 'export const leak = (x: string): string => (0.1).toFixed(2) + x;\n' >> "$tmp/src-mut/types.ts"
forbidden_hits "$tmp/src-ctl" >/dev/null && fail "grep control: the unmutated copy was flagged" || pass "grep control: the unmutated copy is clean"
forbidden_hits "$tmp/src-mut" >/dev/null && pass "grep mutant: a toFixed line appended to src is caught" || fail "grep mutant: a toFixed line went unnoticed"
printf 'export const ok2 = (x: string): string => x.concat("a").toFixed(2); // format-guard-allow: test\n' > "$tmp/src-mut/types.ts"
forbidden_hits "$tmp/src-mut" >/dev/null && fail "grep: an allow-marked line was flagged" || pass "grep: the allow marker is honoured"

# ---- every exported function has a test file and a re-export; every test file has a provenance header
fns="$(grep -hoE '^export function [A-Za-z0-9_]+' "$pkg"/src/*.ts | awk '{print $3}' | sort -u)"
for f in formatDecimal formatMoney formatPercent formatNum formatDate formatCalendarDate orPlaceholder; do
  if ! grep -qx "$f" <<<"$fns"; then fail "$f is not an exported function of src/"
  elif grep -qE "\b$f\b" "$pkg/src/index.ts" && grep -lE "\b$f\(" "$pkg"/test/*.test.ts >/dev/null 2>&1; then pass "$f is re-exported by index.ts and called in a test file"
  else fail "$f lacks a re-export or a test"; fi
done
for t in "$pkg"/test/*.test.ts; do
  first="$(head -n 1 "$t")"
  grep -qE '^// provenance: (candidate; ttl: [0-9]{4}-[0-9]{2}-[0-9]{2}|derived; clause: .+); subject: ' <<<"$first" && pass "$(basename "$t") has a provenance header" || fail "$(basename "$t") lacks a provenance header on line 1"
done
grep -l 'fast-check' "$pkg"/test/properties.test.ts >/dev/null 2>&1 && grep -qE 'SEED = [0-9]+' "$pkg/test/properties.test.ts" && grep -q 'seed: SEED' "$pkg/test/properties.test.ts" && pass "properties.test.ts uses fast-check with a fixed seed" || fail "properties.test.ts: fast-check with a fixed seed not found"

# ---- nothing generated is shipped or tracked
junk="$(find "$pkg" \( -name node_modules -o -name dist -o -name coverage -o -name 'pnpm-lock.yaml' -o -name 'package-lock.json' -o -name 'yarn.lock' -o -name '*.tsbuildinfo' -o -name 'vitest.config.*' \) -print 2>/dev/null | head -n 3)"
[[ -z "$junk" ]] && pass "no node_modules / dist / coverage / lockfile / tsbuildinfo / vitest config in the package" || fail "generated or config files in the package" "$junk"
if git -C "$here" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked="$(git -C "$here" ls-files -- "$pkg" 2>/dev/null | grep -E '(^|/)(node_modules|dist|coverage)/|pnpm-lock\.yaml|package-lock\.json|yarn\.lock' | head -n 3)"
  [[ -z "$tracked" ]] && pass "git tracks no generated file or lockfile under the package" || fail "tracked generated files" "$tracked"
else skip "git tracked-file check" "not a git work tree"; fi

# ---- live: scratch workspace, install, typecheck, vitest, TZ matrix, mutations
if [[ -z "${WEB_FORMAT_LIVE:-}" ]]; then
  skip "live section (install, typecheck, vitest, TZ matrix, mutations)" "WEB_FORMAT_LIVE is not set; the default run is hermetic"
elif ! command -v node >/dev/null 2>&1 || ! command -v pnpm >/dev/null 2>&1; then
  skip "live section" "node or pnpm not found"
else
  ws="$tmp/ws"; mkdir -p "$ws/packages" "$tmp/pnpmhome"
  export PNPM_HOME="$tmp/pnpmhome" npm_config_cache="$tmp/cache" npm_config_store_dir="$tmp/store" CI=true
  cp "$root_mod/package.json" "$root_mod/tsconfig.base.json" "$ws/"
  if grep -qE "^  ${pending_catalog}:" "$root_mod/pnpm-workspace.yaml"; then cp "$root_mod/pnpm-workspace.yaml" "$ws/"
  else sed "s/^catalog:\$/catalog:\n  ${pending_catalog}: ${pending_version}/" "$root_mod/pnpm-workspace.yaml" > "$ws/pnpm-workspace.yaml"; fi
  cp -R "$pkg" "$ws/packages/format"; pk="$ws/packages/format"
  ins="$(cd "$ws" && timeout 200 pnpm install --ignore-scripts 2>&1 | tail -n 3)"
  if [[ ! -d "$pk/node_modules" ]]; then fail "live: pnpm install" "$(tr '\n' ' ' <<<"$ins" | head -c 240)"
  else
    pass "live: pnpm install --ignore-scripts into a scratch workspace"
    pm() { (cd "$pk" && timeout 90 pnpm exec "$@" 2>&1); }
    out="$(pm tsc -p tsconfig.json)" && pass "live: typecheck (tsc -p tsconfig.json) is clean" || fail "live: typecheck" "$(head -c 300 <<<"$out")"
    out="$(pm vitest run)"; rc=$?
    summary_line="$(grep -E 'Tests +[0-9]+' <<<"$out" | head -n 1 | sed 's/^ *//')"
    [[ $rc -eq 0 ]] && pass "live: vitest run is green ($summary_line)" || fail "live: vitest run" "$(grep -E 'FAIL|Error' <<<"$out" | head -n 3 | head -c 300)"
    for z in America/Argentina/Buenos_Aires Asia/Kolkata UTC; do
      out="$(cd "$pk" && TZ="$z" timeout 90 pnpm exec vitest run test/date.test.ts 2>&1)" && pass "live: date tests green under TZ=$z" || fail "live: date tests under TZ=$z" "$(head -c 200 <<<"$out")"
    done

    # mutate <name> <file under src> <test files> <failing-test regex> <old> <new>
    mutate() {
      local name="$1" file="$pk/src/$2" tests="$3" must="$4" old="$5" new="$6" c m
      cp "$file" "$tmp/orig.bak"
      c="$(pm vitest run $tests)"; crc=$?
      if [[ $crc -ne 0 ]]; then fail "mutant $name: control (unmutated) is not green" "$(grep -E 'FAIL' <<<"$c" | head -n 2 | head -c 200)"; return; fi
      if ! python3 -I -B -c 'import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(old) != 1: sys.exit(3)
open(p, "w", encoding="utf-8").write(s.replace(old, new))' "$file" "$old" "$new"; then
        fail "mutant $name: the patch did not apply exactly once"; cp "$tmp/orig.bak" "$file"; return
      fi
      if cmp -s "$file" "$tmp/orig.bak"; then fail "mutant $name: the patch did not change the file"; return; fi
      m="$(pm vitest run $tests)"; mrc=$?
      cp "$tmp/orig.bak" "$file"
      if [[ $mrc -eq 0 ]]; then fail "mutant $name: still GREEN (tests do not bite)"
      elif ! grep -Eq -- "(FAIL|×).*($must)" <<<"$m"; then fail "mutant $name: RED, but not in the expected test /$must/" "$(grep -E 'FAIL|×' <<<"$m" | head -n 2 | head -c 240)"
      else pass "mutant $name: control GREEN, mutant RED in /$must/ ($(grep -cE '^ *(FAIL|×)' <<<"$m") failing lines)"; fi
    }
    mutate "rounding through Number().toFixed" round.ts "test/properties.test.ts" "2\\. digits round-trip" \
      "  if (frac.length <= maxFrac) return { int, frac };" \
      "  { const s = Number(int + '.' + frac).toFixed(maxFrac); const dot = s.indexOf('.'); return dot < 0 ? { int: s, frac: '' } : { int: s.slice(0, dot), frac: s.slice(dot + 1) }; }"
    mutate "exponent accepted by the grammar" grammar.ts "test/decimal.test.ts" "1e5" \
      "const DECIMAL = /^(-?)(0|[1-9][0-9]*)(?:\\.([0-9]+))?\$/;" \
      "const DECIMAL = /^(-?)(0|[1-9][0-9]*)(?:\\.([0-9]+))?(?:[eE][+-]?[0-9]+)?\$/;"
    mutate "half-even and half-up swapped" round.ts "test/decimal.test.ts test/properties.test.ts" "half-even|half-up|4\\. the result equals" \
      "  return mode === 'half-up' ? true : lastKept % 2 === 1;" \
      "  return mode === 'half-up' ? lastKept % 2 === 1 : true;"
    mutate "grouping size hard-coded to 3" locale.ts "test/decimal.test.ts" "en-IN" \
      "const secondary = pieces.length >= 3 ? (pieces[pieces.length - 2] ?? primary) : primary;" \
      "const secondary = 3;"
    mutate "timeZone defaults to the ambient zone" date.ts "test/date.test.ts" "outputs do not depend on it" \
      "const o: Intl.DateTimeFormatOptions = { timeZone: options.timeZone };" \
      "const o: Intl.DateTimeFormatOptions = {};"
    mutate "currency fraction digits hard-coded to 2" money.ts "test/money.test.ts" "USD 2, JPY 0, KWD 3" \
      "const digits = resolved.maximumFractionDigits;" \
      "const digits = 2;"
    mutate "negative zero keeps its minus" number.ts "test/decimal.test.ts" "negative zero" \
      "  if (body.zero) return 'none';" \
      "  if (false) return 'none';"
    mutate "carry through all nines dropped" round.ts "test/decimal.test.ts" "carry" \
      "  if (i === 0) return '1' + '0'.repeat(d.length);" \
      "  if (i === 0) return '0'.repeat(d.length);"
    # typecheck bites: a type error in src is RED, the clean tree was GREEN above
    printf "export const bad: number = 'a';\n" > "$pk/src/zz-type-error.ts"
    out="$(pm tsc -p tsconfig.json)" && fail "mutant type error: typecheck stayed GREEN" || pass "mutant type error in src: typecheck control GREEN, mutant RED"
    rm -f "$pk/src/zz-type-error.ts"
  fi
fi

summary="$ok ok, $bad failed"; [[ $skipped -gt 0 ]] && summary+=", $skipped skipped"; echo "$summary"
[[ $((ok + bad)) -gt 0 ]] || exit 2
[[ $bad -eq 0 ]]
