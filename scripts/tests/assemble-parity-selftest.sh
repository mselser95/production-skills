#!/usr/bin/env bash
# assemble-parity-selftest.sh -- scripts/instantiate-template.sh is a thin wrapper over scripts/assemble.py:
# one golden case proves it still equals the frozen original tool on the real template; everything else
# tests the assembler. Hermetic, sequential, no network.
# ASSEMBLE=<path> runs another copy of the assembler; BASE_FIXTURE=<path> another golden fixture (mutation proofs).
# Exit: 0 all ok - 1 a case failed - 2 zero cases ran.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
asm="${ASSEMBLE:-$here/scripts/assemble.py}"
inst="$here/scripts/instantiate-template.sh"
mods="$here/prod-new/modules"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/assemble-parity.XXXXXX")" || exit 2
absd="$(mktemp -d /tmp/aa.XXXXXX)" || exit 2   # a SHORT absolute path: the 64-character cap would refuse a long one first
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp" "$absd"' EXIT   # a case may leave a 000 / 500 directory
mkdir -p "$tmp/dt"; export DIRECT_TMP="$tmp/dt"   # direct.py creates its directories here, so the trap removes them
tmpnames() { local x; for x in "${TMPDIR:-/tmp}"/tmp*; do [[ -e "$x" ]] && echo "${x##*/}"; done | sort; }
tmp_before="$(tmpnames)"

ok=0; bad=0
pass() { ok=$((ok + 1)); echo "ok   $1"; }
fail() { bad=$((bad + 1)); echo "FAIL $1${2:+ -- $2}"; }
GREENS=" "
green() { if "$1" "${2:-$asm}"; then GREENS+="$1 "; return 0; fi; return 1; }   # <scenario> [real tool]: run it on the REAL tool, cache a green
A() { python3 -I -B "${USE:-$asm}" --modules-dir "${MODS:-$mods}" "$@"; }
# files, directories AND the root ("."): mode string + path
modes() { (cd "$1" && find . -exec ls -ld {} + | awk '{print substr($1,1,10), $NF}' | LC_ALL=C sort); }

base="${BASE_FIXTURE:-$here/scripts/tests/fixtures/instantiate-template.base.sh.txt}"
golden() { # <label> <svc> <owner>: the wrapper equals the frozen ORIGINAL tool on the REAL template (umask 022)
  local d="$tmp/$1"; mkdir -p "$d"
  (umask 022; bash "$inst" "$d/a" "$2" "$3") >/dev/null 2>"$d.err" || { fail "$1 wrapper" "$(head -c 200 "$d.err")"; return; }
  (umask 022; cd "$here" && bash "$base" "$d/b" "$2" "$3") >/dev/null 2>&1 || { fail "$1 frozen original failed"; return; }
  if diff -r "$d/a" "$d/b" >"$d.diff" 2>&1; then pass "$1 golden: diff -r empty against the frozen original"; else fail "$1 golden diff -r" "$(head -c 200 "$d.diff")"; fi
  local ma mb; ma="$(modes "$d/a")"; mb="$(modes "$d/b")"
  if [[ "$ma" == "$mb" ]] && grep -q '^d.* \./cmd$' <<<"$ma" && grep -q ' \.$' <<<"$ma"; then pass "$1 golden: file, directory and root modes equal"
  else fail "$1 golden modes differ" "$(diff <(modes "$d/a") <(modes "$d/b") | head -c 200)"; fi
}

golden p1 payments acme
golden p2 order-book some-org
golden p3 ledger9 acme.io

# placement glob dropped from a COPY of the manifest -> a file is unplaced -> refused
mkdir -p "$tmp/m/prod-new/modules/service-go"
cp -R "$here/prod-new/template" "$tmp/m/prod-new/template"
grep -v '"scripts/\*\*"' "$mods/service-go/module.json" >"$tmp/m/prod-new/modules/service-go/module.json"
if MODS="$tmp/m/prod-new/modules" A --dest "$tmp/g" --layout single --module service-go --slot SERVICE=x --slot OWNER=y >/dev/null 2>"$tmp/g.err"; then
  fail "dropped glob not detected" "assemble succeeded"
elif grep -q 'unplaced: scripts/' "$tmp/g.err" && [[ ! -e "$tmp/g" ]]; then pass "dropped glob RED (unplaced, nothing written)"
else fail "dropped glob" "$(head -c 200 "$tmp/g.err")"; fi

# leftover <SLOT> in a path: scratch template copy with an undeclared slot in a path
mkdir -p "$tmp/s/prod-new/modules"
cp -R "$here/prod-new/template" "$tmp/s/prod-new/template"
cp -R "$mods/service-go" "$tmp/s/prod-new/modules/service-go"
mkdir -p "$tmp/s/prod-new/template/cmd/<BOGUS>" && : >"$tmp/s/prod-new/template/cmd/<BOGUS>/main.go"
if MODS="$tmp/s/prod-new/modules" A --dest "$tmp/l" --layout single --module service-go --slot SERVICE=x --slot OWNER=y >/dev/null 2>"$tmp/l.err"; then
  fail "leftover slot in path accepted"
elif grep -q 'path: .*<BOGUS>' "$tmp/l.err"; then pass "leftover <SLOT> in path refused, path named"
else fail "leftover slot message" "$(head -c 200 "$tmp/l.err")"; fi

# non-empty dest refused, and untouched
mkdir -p "$tmp/ne" && echo keep >"$tmp/ne/f"
if A --dest "$tmp/ne" --layout single --module service-go --slot SERVICE=x --slot OWNER=y >/dev/null 2>&1; then fail "non-empty dest accepted"
elif [[ "$(ls "$tmp/ne")" == "f" ]]; then pass "non-empty dest refused, untouched"; else fail "non-empty dest modified"; fi

# unknown slot / module / layout -> exit 2
A --dest "$tmp/u1" --layout single --module service-go --slot SERVICE=x --slot OWNER=y --slot NOPE=z >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && pass "unknown slot exit 2" || fail "unknown slot" "rc=$rc"
A --dest "$tmp/u2" --layout single --module nope --slot SERVICE=x --slot OWNER=y >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && pass "unknown module exit 2" || fail "unknown module" "rc=$rc"
A --dest "$tmp/u3" --layout nope --module service-go --slot SERVICE=x --slot OWNER=y >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && pass "unknown layout exit 2" || fail "unknown layout" "rc=$rc"

# monorepo: unit under services/<SERVICE>/, root-only files at the root
mo="$tmp/mono"
if A --dest "$mo" --layout monorepo --module service-go --slot SERVICE=ledger --slot OWNER=acme >/dev/null 2>"$tmp/mo.err" \
  && [[ -f "$mo/services/ledger/go.mod" && -f "$mo/services/ledger/cmd/ledger/main.go" && -f "$mo/CODEOWNERS" \
        && -d "$mo/.github" && -f "$mo/AGENTS.md" && -d "$mo/scripts" \
        && ! -e "$mo/go.mod" && ! -e "$mo/CODEOWNERS.x" && ! -e "$mo/services/ledger/CODEOWNERS" \
        && ! -e "$mo/services/ledger/.github" && ! -e "$mo/cmd" ]]; then pass "monorepo placement"
else fail "monorepo placement" "$(head -c 200 "$tmp/mo.err")"; fi

# determinism: same inputs twice -> identical trees and modes
A --dest "$tmp/d1" --layout monorepo --module service-go --slot SERVICE=ledger --slot OWNER=acme >/dev/null 2>&1
if diff -r "$mo" "$tmp/d1" >/dev/null && [[ "$(modes "$mo")" == "$(modes "$tmp/d1")" ]]; then pass "deterministic"; else fail "not deterministic"; fi

# ---- scratch-module cases (own --modules-dir; manifests are written here) ----
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
sm="$tmp/sm"; mkdir -p "$sm"
# mkmod <id> <manifest-json>   (files are added by the caller under $sm/<id>)
mkmod() { mkdir -p "$sm/$1"; printf '%s\n' "$2" >"$sm/$1/module.json"; }
run() { # <dest-name> <layout> <modules...> -- slots...   -> sets rc, err file $tmp/<dest>.err
  local dn="$1" lay="$2"; shift 2; local mm=() ss=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do mm+=(--module "$1"); shift; done
  shift; for x in "$@"; do ss+=(--slot "$x"); done
  MODS="$sm" A --dest "$tmp/$dn" --layout "$lay" "${mm[@]}" "${ss[@]}" ${AFLAGS:-} >"$tmp/$dn.out" 2>"$tmp/$dn.err"; rc=$?
}
M1='{"id":"gi","source":".","slots":{},"placement":{"**":"unit"}}'

# git work tree: git-ignored build output is not assembled; module.json never shipped
mkmod gi "$M1"; echo hi >"$sm/gi/a.txt"; mkdir -p "$sm/gi/target/deep"; echo j >"$sm/gi/target/deep/x.o"
printf 'target/\n' >"$sm/gi/.gitignore"
git -C "$sm/gi" init -q 2>/dev/null; git -C "$sm/gi" add a.txt >/dev/null 2>&1
run gi single gi --
if [[ $rc -eq 0 && -f "$tmp/gi/a.txt" && -f "$tmp/gi/.gitignore" && ! -e "$tmp/gi/target" && ! -e "$tmp/gi/module.json" ]]; then
  pass "git: ignored target/ not assembled, no refusal, module.json not shipped"
else fail "git ignore" "rc=$rc $(head -c 200 "$tmp/gi.err")"; fi

# tracked file deleted from the working tree: skipped, no crash
git -C "$sm/gi" add .gitignore >/dev/null 2>&1; rm "$sm/gi/a.txt"
run gd single gi --
if [[ $rc -eq 0 && ! -e "$tmp/gd/a.txt" && -f "$tmp/gd/.gitignore" ]]; then pass "git: tracked-but-deleted file skipped"
else fail "git deleted" "rc=$rc $(head -c 200 "$tmp/gd.err")"; fi

# outside git: walk fallback; junk without exclude is refused (unplaced), with exclude it is not assembled
MW='{"id":"nw","source":".","slots":{},"placement":{"*.txt":"unit"}}'
mkmod nw "$MW"; echo hi >"$sm/nw/a.txt"; mkdir -p "$sm/nw/target"; echo j >"$sm/nw/target/x.o"
run nw1 single nw --
if [[ $rc -eq 1 ]] && grep -q 'unplaced: target/x.o' "$tmp/nw1.err" && ! grep -q 'module.json' "$tmp/nw1.err"; then pass "walk: junk without exclude refused; module.json not reported"
else fail "walk junk" "rc=$rc $(head -c 200 "$tmp/nw1.err")"; fi
mkmod nw '{"id":"nw","source":".","slots":{},"exclude":["target/**"],"placement":{"*.txt":"unit"}}'
run nw2 single nw --
if [[ $rc -eq 0 && -f "$tmp/nw2/a.txt" && ! -e "$tmp/nw2/target" && ! -e "$tmp/nw2/module.json" ]]; then pass "walk: exclude keeps target/ out"
else fail "walk exclude" "rc=$rc $(head -c 200 "$tmp/nw2.err")"; fi

# service-go: git path and walk path agree (ignored-file exclusion does not change the result)
mkdir -p "$tmp/w/prod-new/modules"; cp -R "$here/prod-new/template" "$tmp/w/prod-new/template"; cp -R "$mods/service-go" "$tmp/w/prod-new/modules/"
MODS="$tmp/w/prod-new/modules" A --dest "$tmp/wk" --layout single --module service-go --slot SERVICE=payments --slot OWNER=acme >/dev/null 2>&1
if diff -r "$tmp/p1/a" "$tmp/wk" >/dev/null && [[ "$(modes "$tmp/p1/a")" == "$(modes "$tmp/wk")" ]]; then pass "service-go: git list == walk list (tree and modes)"
else fail "git vs walk differ for service-go"; fi

# root collisions
mkmod ra '{"id":"ra","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ra/f"
mkmod rb '{"id":"rb","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/rb/f"
echo same >"$sm/ra/f/CODEOWNERS"; echo same >"$sm/rb/f/CODEOWNERS"; echo a >"$sm/ra/f/only-a"
run c1 single ra rb --
if [[ $rc -eq 0 && "$(cat "$tmp/c1/CODEOWNERS")" == same && -f "$tmp/c1/only-a" ]]; then pass "identical root files written once"
else fail "identical root files" "rc=$rc $(head -c 200 "$tmp/c1.err")"; fi
echo different >"$sm/rb/f/CODEOWNERS"
run c2 single ra rb --
if [[ $rc -eq 1 ]] && grep -q 'modules ra and rb' "$tmp/c2.err" && grep -q 'CODEOWNERS' "$tmp/c2.err" && grep -q 'monorepo-root' "$tmp/c2.err" && [[ ! -e "$tmp/c2" ]]; then pass "differing root files: error names both modules and path"
else fail "differing root files" "rc=$rc $(head -c 300 "$tmp/c2.err")"; fi

# root_merge union-lines
mkmod ma '{"id":"ma","source":"f","slots":{},"root_merge":{".gitignore":"union-lines"},"placement":{"**":"root"}}'; mkdir -p "$sm/ma/f"
mkmod mb '{"id":"mb","source":"f","slots":{},"root_merge":{".gitignore":"union-lines"},"placement":{"**":"root"}}'; mkdir -p "$sm/mb/f"
printf 'b\na\nc\n' >"$sm/ma/f/.gitignore"; printf 'c\nd\na\ne\n' >"$sm/mb/f/.gitignore"
run u1 single ma mb --
if [[ $rc -eq 0 && "$(tr '\n' ',' <"$tmp/u1/.gitignore")" == "b,a,c,d,e," ]]; then pass "union-lines: stable, de-duplicated, first-seen order"
else fail "union-lines" "rc=$rc got $(tr '\n' ',' <"$tmp/u1/.gitignore" 2>/dev/null)"; fi
run u2 single mb ma --
[[ "$(tr '\n' ',' <"$tmp/u2/.gitignore" 2>/dev/null)" == "c,d,a,e,b," ]] && pass "union-lines: order follows module order" || fail "union-lines order"
mkmod mc '{"id":"mc","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/mc/f"; echo z >"$sm/mc/f/.gitignore"
run u3 single ma mc --
[[ $rc -eq 1 ]] && pass "union-lines needs every contributor to opt in" || fail "partial root_merge" "rc=$rc"
mkmod mx '{"id":"mx","source":"f","slots":{},"root_merge":{"*.yaml":"deep-merge"},"placement":{"**":"root"}}'; mkdir -p "$sm/mx/f"; echo q >"$sm/mx/f/q"
run u4 single mx --
if [[ $rc -eq 2 ]] && grep -q 'deep-merge' "$tmp/u4.err"; then pass "unknown merge strategy exit 2"; else fail "unknown strategy" "rc=$rc"; fi

# strict_slots, slot_allow
mkmod st '{"id":"st","source":"f","slots":{},"strict_slots":true,"placement":{"**":"root"}}'; mkdir -p "$sm/st/f"
printf 'ok <TAB> and <FOO> here\n' >"$sm/st/f/a.md"
run s1 single st --
if [[ $rc -eq 1 ]] && grep -q 'file: a.md.*<FOO>' "$tmp/s1.err"; then pass "strict_slots: stray <FOO> refused"; else fail "strict refuse" "rc=$rc $(head -c 200 "$tmp/s1.err")"; fi
mkmod st '{"id":"st","source":"f","slots":{},"strict_slots":true,"slot_allow":["TAB","FOO"],"placement":{"**":"root"}}'
run s2 single st --
[[ $rc -eq 0 ]] && pass "strict_slots: slot_allow accepts" || fail "slot_allow" "rc=$rc $(head -c 200 "$tmp/s2.err")"
mkmod st '{"id":"st","source":"f","slots":{},"placement":{"**":"root"}}'
run s3 single st --
[[ $rc -eq 0 ]] && pass "non-strict module tolerates stray tokens" || fail "non-strict" "rc=$rc"

# literal slots: contents and paths; unused literal is an error
mkmod li '{"id":"li","source":"f","slots":{"SCOPE":{"description":"scope","literal":"ds-scope"}},"placement":{"**":"root"}}'; mkdir -p "$sm/li/f/ds-scope"
echo 'import "ds-scope/x"' >"$sm/li/f/ds-scope/index.js"
run l1 single li -- SCOPE=acme-ui
if [[ $rc -eq 0 && "$(cat "$tmp/l1/acme-ui/index.js" 2>/dev/null)" == 'import "acme-ui/x"' ]]; then pass "literal slot substituted in path and contents"
else fail "literal slot" "rc=$rc $(head -c 200 "$tmp/l1.err")"; fi
mkmod lj '{"id":"lj","source":"f","slots":{"SCOPE":{"description":"scope","literal":"nowhere-token"}},"placement":{"**":"root"}}'; mkdir -p "$sm/lj/f"; echo plain >"$sm/lj/f/a"
run l2 single lj -- SCOPE=x
if [[ $rc -eq 1 ]] && grep -q 'never occurs' "$tmp/l2.err" && [[ ! -e "$tmp/l2" ]]; then pass "literal that never occurs is an error"
else fail "unused literal" "rc=$rc $(head -c 200 "$tmp/l2.err")"; fi

# determinism with scratch modules
run u5 single ma mb --
diff -r "$tmp/u1" "$tmp/u5" >/dev/null && pass "union assembly deterministic" || fail "union assembly not deterministic"

# ======================= hardening cases (validator findings) =======================
rd() { tr '\n' ',' <"$1" 2>/dev/null; }
nolines() { ! grep -q Traceback "$1"; }
# runc <label> <layout> <modules...> -- slots...  : dest $tmp/<label>/dest next to a canary; logs outside
runc() {
  local lb="$1" lay="$2"; shift 2; local mm=() ss=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do mm+=(--module "$1"); shift; done
  shift; for x in "$@"; do ss+=(--slot "$x"); done
  mkdir -p "$tmp/$lb"; echo canary >"$tmp/$lb/canary"
  (umask "${UMK:-$(umask)}"; MODS="$sm" A --dest "$tmp/$lb/dest" --layout "$lay" "${mm[@]}" "${ss[@]}" ${AFLAGS:-}) >"$tmp/log_$lb.out" 2>"$tmp/log_$lb.err"; rc=$?
}
untouched() { [[ "$(ls -A "$tmp/$1" | tr '\n' ' ')" == "canary " && "$(cat "$tmp/$1/canary")" == canary ]]; }
# mutant <from> <to> <out> [<in>]: exact-once text replacement in a copy (a rename makes this FAIL loudly)
mutant() {
  python3 -I -c 'import sys
s = open(sys.argv[1]).read()
assert s.count(sys.argv[2]) == 1, sys.argv[2]
open(sys.argv[4], "w").write(s.replace(sys.argv[2], sys.argv[3]))' "${4:-$asm}" "$1" "$2" "$3" || { fail "mutant marker missing or not unique: $1"; return 1; }
}
mutant '    if not v.isascii() or VALUE_RX.fullmatch(v) is None:' '    if False:' "$tmp/m-nogram.py"
mutant '    if "\0" in rel or rel.startswith("/")' '    return False
    if "\0" in rel or rel.startswith("/")' "$tmp/m-noesc.py"
python3 -I - "$tmp/m-nogram.py" "$tmp/m-both.py" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = '    if "\\0" in rel or rel.startswith("/")'
assert s.count(a) == 1
open(sys.argv[2], "w").write(s.replace(a, "    return False\n" + a))
PY

# ---- path escape: grammar (layer a) and escapes() (layer b) each stop it, canary untouched
mkmod esc '{"id":"esc","source":"f","slots":{"SERVICE":"s"},"placement":{"A-*":"root","cmd/**":"unit","*.md":"root"}}'
mkdir -p "$sm/esc/f/cmd/<SERVICE>"; echo 'package <SERVICE>' >"$sm/esc/f/cmd/<SERVICE>/main.go"
echo '# <SERVICE>' >"$sm/esc/f/<SERVICE>.md"; echo first >"$sm/esc/f/A-first"
mkdir -p "$absd"; echo keep >"$absd/EXIST.md"
esc_case() { # <label> <layout> <expect-rc> <expect-text> <slot value>   (USE=<assembler> optional)
  runc "$1" "$2" esc -- "SERVICE=$5"
  if [[ $rc -eq $3 ]] && grep -Eq -- "$4" "$tmp/log_$1.err" && nolines "$tmp/log_$1.err" && untouched "$1"; then pass "escape $1 refused (rc $3), canary untouched, no new sibling"
  else fail "escape $1" "rc=$rc $(head -c 160 "$tmp/log_$1.err") ls=$(ls -A "$tmp/$1" | tr '\n' ' ')"; fi
}
esc_case e1 single 2 grammar '../../ESC1'
esc_case e2 single 2 grammar 'a/../../../ESC3'
esc_case e3 monorepo 2 grammar '../../ESC4'
esc_case e4 single 2 grammar "$absd/EXIST"
[[ "$(cat "$absd/EXIST.md")" == keep ]] && pass "absolute-path SERVICE did not overwrite an existing file" || fail "existing file overwritten"
USE="$tmp/m-nogram.py" esc_case n1 single 1 escape '../../ESC1'
USE="$tmp/m-nogram.py" esc_case n3 monorepo 1 escape '../../ESC4'
USE="$tmp/m-nogram.py" esc_case n4 single 1 escape "$absd/NEW"
[[ ! -e "$absd/NEW.md" ]] && pass "escape layer alone: no file at the absolute path" || fail "absolute path written"
USE="$tmp/m-noesc.py" esc_case g1 single 2 grammar '../../ESC1'
USE="$tmp/m-both.py" runc b1 single esc -- 'SERVICE=../../ESC1'
if [[ -e "$tmp/b1/ESC1/main.go" ]]; then pass "both layers removed -> the escape really happens (cases are not vacuous)"; else fail "both removed but nothing escaped" "rc=$rc"; fi
mkmod up '{"id":"up","source":"f","slots":{"SERVICE":"s"},"placement":{"**":"unit"}}'; mkdir -p "$sm/up/f"; echo r >"$sm/up/f/README"
USE="$tmp/m-nogram.py" runc b2 monorepo up -- 'SERVICE=<BOGUS>'
if [[ $rc -eq 1 ]] && grep -q 'path: services/<BOGUS>/README' "$tmp/log_b2.err" && untouched b2; then pass "leftover token is checked on the FINAL path (unit prefix included)"
else fail "leftover on final path" "rc=$rc $(head -c 200 "$tmp/log_b2.err")"; fi

# ---- symlinks: copied as links; absolute/escaping refused; planned link as a prefix refused
mkmod la '{"id":"la","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/la/f/sub"; echo s >"$sm/la/f/sub/keep"; ln -s sub "$sm/la/f/d"
mkmod lb '{"id":"lb","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/lb/f/d"; echo x >"$sm/lb/f/d/f"
runc sl1 single la lb --
if [[ $rc -eq 1 ]] && grep -q 'path conflict' "$tmp/log_sl1.err" && grep -q 'la' "$tmp/log_sl1.err" && grep -q 'lb' "$tmp/log_sl1.err" && grep -q 'link' "$tmp/log_sl1.err" && nolines "$tmp/log_sl1.err" && untouched sl1 && [[ ! -e "$sm/la/f/sub/f" ]]; then
  pass "link redirect: module B cannot write beneath module A's link (both named, nothing written)"
else fail "link redirect" "rc=$rc $(head -c 200 "$tmp/log_sl1.err")"; fi
mkmod lc '{"id":"lc","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/lc/f"; ln -s /outside "$sm/lc/f/d2"
runc sl2 single lc --
[[ $rc -eq 1 ]] && grep -q 'link: d2 -> /outside' "$tmp/log_sl2.err" && untouched sl2 && pass "absolute link target refused" || fail "absolute link" "rc=$rc $(head -c 200 "$tmp/log_sl2.err")"
rm "$sm/lc/f/d2"; ln -s ../../x "$sm/lc/f/d3"
runc sl3 single lc --
[[ $rc -eq 1 ]] && grep -q 'link: d3' "$tmp/log_sl3.err" && pass "link escaping the module tree refused" || fail "escaping link" "rc=$rc"
rm "$sm/lc/f/d3"; echo real >"$sm/lc/f/real"; ln -s real "$sm/lc/f/lnk"
run sl4 single lc --
if [[ $rc -eq 0 && -L "$tmp/sl4/lnk" && "$(readlink "$tmp/sl4/lnk")" == real && "$(cat "$tmp/sl4/lnk")" == real ]]; then pass "relative in-tree link copied as a link"; else fail "link copy" "rc=$rc"; fi
mkdir -p "$tmp/emp"; ln -s "$tmp/emp" "$tmp/dlink"
run dlink single lc --
if [[ $rc -eq 1 ]] && grep -q 'symlink' "$tmp/dlink.err" && [[ -L "$tmp/dlink" && -z "$(ls -A "$tmp/emp")" ]]; then pass "dest that is a symlink refused, target untouched"; else fail "dest symlink" "rc=$rc $(head -c 160 "$tmp/dlink.err")"; fi

# ---- atomicity: file/dir conflict and a mid-write failure leave dest untouched
mkmod fa '{"id":"fa","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/fa/f"; echo f >"$sm/fa/f/x"
mkmod fb '{"id":"fb","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/fb/f/x"; echo y >"$sm/fb/f/x/y"
runc fd single fa fb --
if [[ $rc -eq 1 ]] && grep -q 'path conflict' "$tmp/log_fd.err" && grep -q 'fa' "$tmp/log_fd.err" && grep -q 'fb' "$tmp/log_fd.err" && nolines "$tmp/log_fd.err" && untouched fd; then
  pass "file vs directory conflict: both modules named, exit 1, no traceback, nothing written"
else fail "file/dir conflict" "rc=$rc $(head -c 200 "$tmp/log_fd.err")"; fi
# a 200-character source name + a 64-character value = 264 > NAME_MAX: fails while WRITING, after planning passed
mkmod lng '{"id":"lng","source":"f","slots":{"SERVICE":"s"},"placement":{"**":"root"}}'; mkdir -p "$sm/lng/f"
: >"$sm/lng/f/$(printf 'n%.0s' $(seq 1 200))<SERVICE>"
runc at single lng -- "SERVICE=$(printf 'z%.0s' $(seq 1 64))"
if [[ $rc -eq 1 ]] && grep -q 'nothing written' "$tmp/log_at.err" && nolines "$tmp/log_at.err" && untouched at; then
  pass "mid-write failure (name too long): dest absent, temp dir removed, one-line error"
else fail "atomic write" "rc=$rc $(head -c 160 "$tmp/log_at.err") ls=$(ls -A "$tmp/at" | tr '\n' ' ')"; fi

# ---- slots: order independence (one pass), literal boundaries
mkmod ord '{"id":"ord","source":"f","slots":{"SERVICE":"s","LIT":{"description":"l","literal":"foo"}},"placement":{"**":"root"}}'
mkdir -p "$sm/ord/f"; echo '<SERVICE> and foo' >"$sm/ord/f/t.txt"
run o1 single ord -- SERVICE=foo LIT=bar
run o2 single ord -- LIT=bar SERVICE=foo
if diff -r "$tmp/o1" "$tmp/o2" >/dev/null && [[ "$(cat "$tmp/o1/t.txt")" == 'foo and bar' ]]; then pass "slot order does not change the tree; a substituted value is never re-scanned"
else fail "slot order" "$(cat "$tmp/o1/t.txt" 2>/dev/null) | $(cat "$tmp/o2/t.txt" 2>/dev/null)"; fi
mkmod bd '{"id":"bd","source":"f","slots":{"SCOPE":{"description":"s","literal":"acme"}},"placement":{"**":"root"}}'
mkdir -p "$sm/bd/f/acme"; echo 'x' >"$sm/bd/f/acme/x.txt"; echo 'y' >"$sm/bd/f/acmes.txt"
echo '@acme/pkg acmes xacme acme_x acme.' >"$sm/bd/f/c.txt"
run bd1 single bd -- SCOPE=ui9
if [[ $rc -eq 0 && "$(cat "$tmp/bd1/c.txt")" == '@ui9/pkg acmes xacme acme_x ui9.' && -f "$tmp/bd1/ui9/x.txt" && -f "$tmp/bd1/acmes.txt" ]]; then
  pass "literal boundary: @acme/pkg and acme/ hit; acmes, xacme, acme_x do not"
else fail "literal boundary" "rc=$rc $(cat "$tmp/bd1/c.txt" 2>/dev/null)"; fi
mkmod sh '{"id":"sh","source":"f","slots":{"SCOPE":{"description":"s","literal":"ab"}},"placement":{"**":"root"}}'; mkdir -p "$sm/sh/f"; echo ab >"$sm/sh/f/a"
run sh1 single sh -- SCOPE=x
[[ $rc -eq 2 ]] && grep -q 'at least 3' "$tmp/sh1.err" && pass "literal shorter than 3 chars: exit 2" || fail "short literal" "rc=$rc"
mkmod lc2 '{"id":"lc2","source":"f","slots":{"SCOPE":{"description":"d","literal":"ds-scope"}},"placement":{"**":"root"}}'
mkdir -p "$sm/lc2/f"; echo 'ds-scope <SCOPE>' >"$sm/lc2/f/a"
run lc2 single lc2 -- SCOPE=ui
[[ $rc -eq 1 ]] && grep -q 'file: a' "$tmp/lc2.err" && [[ ! -e "$tmp/lc2" ]] && pass "leftover <SCOPE> token in contents refused" || fail "leftover content" "rc=$rc $(head -c 160 "$tmp/lc2.err")"
mkmod tw '{"id":"tw","source":"f","slots":{"SCOPE":{"description":"d","literal":"acme"}},"placement":{"**":"root"}}'
mkdir -p "$sm/tw/f"; echo one >"$sm/tw/f/acme.txt"; echo two >"$sm/tw/f/ui9.txt"
run tw single tw -- SCOPE=ui9
[[ $rc -eq 1 ]] && grep -q 'module tw places ui9.txt twice' "$tmp/tw.err" && pass "collision inside one module names that module" || fail "single-module collision" "rc=$rc $(head -c 200 "$tmp/tw.err")"

# ---- first match, declared-slot refusal, modes, link-vs-file
mkmod fm '{"id":"fm","source":"f","slots":{"SERVICE":"s"},"placement":{"*.txt":"root","**":"unit"}}'
mkdir -p "$sm/fm/f"; echo a >"$sm/fm/f/a.txt"; echo b >"$sm/fm/f/b.dat"
run fm single fm -- SERVICE=x; run fm2 monorepo fm -- SERVICE=svc
if [[ -f "$tmp/fm2/a.txt" && -f "$tmp/fm2/services/svc/b.dat" && ! -e "$tmp/fm2/services/svc/a.txt" ]]; then pass "first matching glob wins (monorepo: root vs unit)"; else fail "first match" "rc=$rc"; fi
mkmod ms '{"id":"ms","source":"f","slots":{"SERVICE":"s","OWNER":"o"},"placement":{"**":"root"}}'; mkdir -p "$sm/ms/f"; echo x >"$sm/ms/f/a"
run ms single ms -- SERVICE=x
[[ $rc -eq 2 ]] && grep -q "'OWNER'.*not given" "$tmp/ms.err" && [[ ! -e "$tmp/ms" ]] && pass "declared slot not given: exit 2, nothing written" || fail "missing slot" "rc=$rc"
mkmod ia '{"id":"ia","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ia/f"; echo same >"$sm/ia/f/s.sh"
mkmod ib '{"id":"ib","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ib/f"; echo same >"$sm/ib/f/s.sh"; chmod 755 "$sm/ib/f/s.sh"
run im single ia ib --
[[ $rc -eq 1 ]] && grep -q 'different mode' "$tmp/im.err" && pass "same bytes, different mode: refused as 'different mode'" || fail "mode compare" "rc=$rc $(head -c 200 "$tmp/im.err")"
mkmod ka '{"id":"ka","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ka/f"; ln -s t "$sm/ka/f/n"
mkmod kb '{"id":"kb","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/kb/f"; echo t >"$sm/kb/f/n"
run lf single ka kb --
[[ $rc -eq 1 ]] && grep -q 'link vs file' "$tmp/lf.err" && pass "link vs file collision says so" || fail "link vs file" "rc=$rc $(head -c 200 "$tmp/lf.err")"
mkmod nz '{"id":"nz","source":"f","slots":{},"placement":{"**":"unit"}}'; mkdir -p "$sm/nz/f"; echo z >"$sm/nz/f/z"
runc nz monorepo nz --
[[ $rc -eq 2 ]] && grep -q 'module nz' "$tmp/log_nz.err" && grep -q SERVICE "$tmp/log_nz.err" && untouched nz && pass "monorepo unit placement without a SERVICE slot: exit 2 naming the module" || fail "monorepo no SERVICE" "rc=$rc $(head -c 200 "$tmp/log_nz.err")"

# ---- union-lines rules
mkum() { mkmod "$1" "{\"id\":\"$1\",\"source\":\"f\",\"slots\":{},\"root_merge\":{\".gitignore\":\"union-lines\"},\"placement\":{\"**\":\"root\"}}"; mkdir -p "$sm/$1/f"; }
mkum un1; printf 'a\na\nb\n' >"$sm/un1/f/.gitignore"
mkum un2; printf 'b\nc\nc\n' >"$sm/un2/f/.gitignore"
run un12 single un1 un2 --
[[ $rc -eq 0 && "$(rd "$tmp/un12/.gitignore")" == "a,a,b,c,c," ]] && pass "union-lines: no de-dup within a file, only an already-present later line dropped" || fail "union dup" "rc=$rc got $(rd "$tmp/un12/.gitignore")"
mkum un3; printf 'x\r\ny\r\n' >"$sm/un3/f/.gitignore"
run un13 single un1 un3 --
[[ $rc -eq 1 ]] && grep -q 'CRLF' "$tmp/un13.err" && [[ ! -e "$tmp/un13" ]] && pass "union-lines: CRLF vs LF between contributors is an error" || fail "union eol" "rc=$rc $(head -c 200 "$tmp/un13.err")"
mkum un4; printf 'q\n' >"$sm/un4/f/.gitignore"; chmod 755 "$sm/un4/f/.gitignore"
run un14 single un1 un4 --
[[ $rc -eq 1 ]] && grep -q 'different mode' "$tmp/un14.err" && pass "union-lines: contributors must agree on mode" || fail "union mode" "rc=$rc $(head -c 200 "$tmp/un14.err")"
mkum un5; printf 'q' >"$sm/un5/f/.gitignore"
run un15 single un1 un5 --
[[ $rc -eq 1 ]] && grep -q 'trailing newline' "$tmp/un15.err" && pass "union-lines: a missing final newline is an error, not normalised" || fail "union eof" "rc=$rc $(head -c 200 "$tmp/un15.err")"

# ---- git: neutralised user config, GIT_* stripped, --strict-tracked
mkmod gg '{"id":"gg","source":"f","slots":{},"placement":{"**":"root"}}'
git -C "$sm/gg" init -q 2>/dev/null; mkdir -p "$sm/gg/f"; echo t >"$sm/gg/f/a.txt"; echo y >"$sm/gg/f/x.yaml"; echo l >"$sm/gg/f/y.log"
printf '*.log\n' >"$sm/gg/.gitignore"; git -C "$sm/gg" add f/a.txt >/dev/null 2>&1
printf '*.yaml\n' >"$tmp/gign"; printf '[core]\n\texcludesFile = %s\n' "$tmp/gign" >"$tmp/gcfg"
GIT_CONFIG_GLOBAL="$tmp/gcfg" run gg1 single gg --
if [[ $rc -eq 0 && -f "$tmp/gg1/x.yaml" && -f "$tmp/gg1/a.txt" && ! -e "$tmp/gg1/y.log" ]]; then pass "global gitignore neutralised (untracked .yaml ships); a parent .gitignore still applies"
else fail "global ignore" "rc=$rc $(head -c 160 "$tmp/gg1.err")"; fi
GIT_CONFIG_GLOBAL="$tmp/gcfg" AFLAGS=--strict-tracked run gg2 single gg --
[[ $rc -eq 1 ]] && grep -q 'x.yaml' "$tmp/gg2.err" && [[ ! -e "$tmp/gg2" ]] && pass "--strict-tracked refuses an untracked-not-ignored file" || fail "strict-tracked" "rc=$rc $(head -c 200 "$tmp/gg2.err")"
AFLAGS=--strict-tracked run gg3 single nw --
[[ $rc -eq 1 ]] && grep -q 'not inside a git work tree' "$tmp/gg3.err" && pass "--strict-tracked outside git refuses" || fail "strict outside git" "rc=$rc"
GIT_DIR="$tmp/no-such-git-dir" GIT_WORK_TREE="$tmp" run gs single gi --
if [[ $rc -eq 0 && ! -e "$tmp/gs/target" && -f "$tmp/gs/.gitignore" ]]; then pass "GIT_* variables are stripped (a hostile GIT_DIR does not change the listing)"
else fail "GIT_* stripping" "rc=$rc $(head -c 160 "$tmp/gs.err")"; fi

# ---- manifest errors: exit 2, the key named, never a traceback
mkdir -p "$sm/bm/f"; echo x >"$sm/bm/f/a"
mbad() { # <label> <manifest-json> <needle>
  printf '%s\n' "$2" >"$sm/bm/module.json"
  run "bm_$1" single bm --
  if [[ $rc -eq 2 ]] && grep -q -- "$3" "$tmp/bm_$1.err" && nolines "$tmp/bm_$1.err" && [[ ! -e "$tmp/bm_$1" ]]; then pass "manifest $1: exit 2 naming $3"
  else fail "manifest $1" "rc=$rc $(head -c 200 "$tmp/bm_$1.err")"; fi
}
# mbatch <label> <manifest-json> <needle>: the same refusal checked IN PROCESS (load_manifest: exit 2, one line naming
# the needle, no traceback), all records in ONE python process at the end of the round-4 section
: >"$tmp/mb.bin"; nmb=0
mbatch() { printf '%s\0%s\0%s\0' "$1" "$2" "$3" >>"$tmp/mb.bin"; nmb=$((nmb + 1)); }
P='"placement":{"**":"root"}'
mbad unknown-key "{\"id\":\"bm\",\"source\":\"f\",$P,\"bogus\":1}" bogus
mbatch strict-type "{\"id\":\"bm\",\"source\":\"f\",$P,\"strict_slots\":\"yes\"}" strict_slots
mbatch no-source "{\"id\":\"bm\",$P}" "'source'"
mbatch no-placement '{"id":"bm","source":"f"}' "'placement'"
mbatch no-id "{\"source\":\"f\",$P}" "'id'"
mbad id-mismatch "{\"id\":\"other\",\"source\":\"f\",$P}" "'id'"
mbatch src-abs "{\"id\":\"bm\",\"source\":\"/etc\",$P}" "'source'"
mbad src-escape "{\"id\":\"bm\",\"source\":\"../../../../..\",$P}" "outside"
mbatch slots-list "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":[]}" "'slots'"
mbatch place-type '{"id":"bm","source":"f","placement":{"**":5}}' "'placement'"
mbatch not-object '[]' "JSON object"
mbatch bad-json '{' "unreadable"
mbatch slot-key "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"nope\":1}}}" "unknown key"
mbatch bad-pattern "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"pattern\":\"(\"}}}" "pattern"
mbatch exclude-type "{\"id\":\"bm\",\"source\":\"f\",$P,\"exclude\":\"x\"}" "'exclude'"
mbatch slot-name "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"lower\":\"d\"}}" "slot name"

# ---- requires / conflicts are enforced; pattern narrows, never widens
mkmod rq '{"id":"rq","requires":["gi"],"source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/rq/f"; echo r >"$sm/rq/f/rq.txt"
run rq1 single rq --
[[ $rc -eq 1 ]] && grep -q 'requires module gi' "$tmp/rq1.err" && pass "requires enforced (missing module -> exit 1)" || fail "requires" "rc=$rc $(head -c 160 "$tmp/rq1.err")"
run rq2 single rq gi --
[[ $rc -eq 0 ]] && pass "requires satisfied when the module is selected" || fail "requires satisfied" "rc=$rc $(head -c 160 "$tmp/rq2.err")"
mkmod cf '{"id":"cf","conflicts":["rq"],"source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/cf/f"; echo c >"$sm/cf/f/cf.txt"
run cf1 single cf rq gi --
[[ $rc -eq 1 ]] && grep -q 'conflicts with module' "$tmp/cf1.err" && pass "conflicts enforced (exit 1)" || fail "conflicts" "rc=$rc $(head -c 160 "$tmp/cf1.err")"
# slot narrowing: `pattern` is gone (ReDoS); fixed `charset` / `max_len` narrow the grammar, never widen it
mkmod pt '{"id":"pt","source":"f","slots":{"NAME":{"description":"n","charset":"lower"}},"placement":{"**":"root"}}'; mkdir -p "$sm/pt/f"; echo '<NAME>' >"$sm/pt/f/t"
run pt1 single pt -- NAME=abc; r1=$rc; run pt2 single pt -- NAME=Abc; r2=$rc
[[ $r1 -eq 0 && $r2 -eq 2 ]] && grep -q 'charset' "$tmp/pt2.err" && pass "slot charset narrows the grammar" || fail "charset narrowing" "$r1/$r2"
mkmod pw '{"id":"pw","source":"f","slots":{"NAME":{"description":"n","max_len":64,"charset":"identifier"}},"placement":{"**":"root"}}'; mkdir -p "$sm/pw/f"; echo '<NAME>' >"$sm/pw/f/t"
run pw1 single pw -- NAME=a/b
[[ $rc -eq 2 ]] && grep -q 'grammar' "$tmp/pw1.err" && pass "a charset/max_len option cannot widen the grammar" || fail "widening" "rc=$rc"
run so1 single esc -- 'SERVICE=<OWNER>'; r1=$rc
[[ $r1 -eq 2 ]] && pass "SERVICE=<OWNER> refused (no order dependence left)" || fail "placeholder value" "rc=$r1"

# ---- value grammar through the assembler
mx="$tmp/mx"; mt="$mx/prod-new/template"; mkdir -p "$mx/prod-new/modules" "$mt/cmd/<SERVICE>" "$mt/scripts"
cp -R "$mods/service-go" "$mx/prod-new/modules/"
printf 'package main // <SERVICE> <OWNER>\n' >"$mt/cmd/<SERVICE>/main.go"; printf '* @<OWNER>\n' >"$mt/CODEOWNERS"
printf '#!/bin/sh\necho <SERVICE>\n' >"$mt/scripts/run.sh"; chmod 755 "$mt/scripts/run.sh"; printf '# <SERVICE>\n' >"$mt/README.md"
# directory fixtures: a 750 directory (source mode rule), an empty nested directory (dropped by both tools)
mkdir -p "$mt/docs/priv" "$mt/docs/hollow/deep"; printf 'x <SERVICE>\n' >"$mt/docs/priv/x.md"
find "$mt" -type d -exec chmod 755 {} +; chmod 750 "$mt/docs/priv"
# vp_both <label> <svc> <owner>: the assembler on the fixture template under umask ${UM:-022}. Sets VA (exit code).
# Overrides: VMX (fixture root), USE (assembler copy).
vp_both() {
  local d="$tmp/vp_$1" f="${VMX:-$mx}"; rm -rf "$d"; mkdir -p "$d"
  (umask "${UM:-022}"; MODS="$f/prod-new/modules" A --dest "$d/a" --layout single --module service-go --slot "SERVICE=$2" --slot "OWNER=$3") >/dev/null 2>"$d/a.err"; VA=$?
}
vparity() { # <label> <expect ok|refuse> <svc> <owner>
  vp_both "$1" "$3" "$4"
  local da=refuse; [[ $VA -eq 0 ]] && da=ok
  if [[ "$da" != "$2" ]]; then fail "value $1" "expected $2, assembler=$da"
  else pass "value $1: $2"; fi
}
long65="$(printf 'z%.0s' $(seq 1 65))"
# end to end for a few values; the WHOLE list is compared below in ONE python process (the assembler's own check_value)
vparity ok-a.b ok a.b 9lives
vparity ok-64 ok "$(printf 'z%.0s' $(seq 1 64))" acme
vparity bad-empty refuse '' acme
vparity bad-slash refuse 'a/b' acme
vparity bad-dotdot-owner refuse svc '../../E'
vparity bad-trailing-dot refuse 'x.' acme
vparity bad-trailing-dot-owner refuse svc 'acme.'
okv=(s a.b order-book A1_x 9lives A a_ x-y a.b.c z-_ "$(printf 'z%.0s' $(seq 1 64))")
badv=('' 'a/b' 'a\b' 'a&b' '\1' 'a b' '-x' '.x' '..' '.' '../../E' '/abs' 'a<OWNER>' $'a\nb' $'a\n' 'a;b' "a'b" 'é' 'a$b' $'a\xe9' 'x.' 'a..' 'a-.' "$long65")
vals="$tmp/vals.bin"; printf '%s\0' "${okv[@]}" "${badv[@]}" >"$vals"
vexp="$(printf '1%.0s' "${okv[@]}")$(printf '0%.0s' "${badv[@]}")"

# ======================= round 2: umask matrix, fixed slot options, signals, folds =======================
# ---- directory modes. Rule: dir = (source dir & ~umask) | u+w, root 0777 & ~umask
for um in 002 077 022; do UM=$um vp_both "um$um" um acme; mu="$(modes "$tmp/vp_um$um/a")"
  case $um in 002) dp="drwxr-x---"; rt="drwxrwxr-x";; 077) dp="drwx------"; rt="drwx------";; *) dp="drwxr-x---"; rt="drwxr-xr-x";; esac
  if [[ $VA -eq 0 ]] && grep -q "^$dp \./docs/priv$" <<<"$mu" && grep -q "^$rt \.$" <<<"$mu"; then pass "umask $um: docs/priv is $dp (source 750 & ~umask), root is $rt"
  else fail "dir modes umask $um" "VA=$VA $(grep -E ' \.(/docs/priv)?$' <<<"$mu" | head -c 160)"; fi
done
[[ ! -e "$tmp/vp_um022/a/docs/hollow" ]] && pass "an empty source directory is dropped (docs/hollow/deep)" || fail "empty directory rule"
mz="$tmp/mz"; cp -R "$mx" "$mz"; chmod 1750 "$mz/prod-new/template/docs/priv"
VMX="$mz" vp_both st1 s acme
sa="$(modes "$tmp/vp_st1/a")"
[[ $VA -eq 0 ]] && grep -Eq '^d.{8}[^tT] \./docs/priv$' <<<"$sa" && pass "sticky source directory: the bit is cleared" || fail "sticky directory" "VA=$VA"

# ---- special bits refused; exclude globs
my="$tmp/my"; cp -R "$mx" "$my"; chmod 4755 "$my/prod-new/template/scripts/run.sh"
VMX="$my" vp_both sp1 s acme
if [[ $VA -eq 1 ]] && grep -q 'run.sh' "$tmp/vp_sp1/a.err" && [[ ! -e "$tmp/vp_sp1/a" ]]; then pass "setuid source file: exit 1 naming it, nothing written"
else fail "setuid file" "VA=$VA"; fi
chmod 1755 "$my/prod-new/template/scripts/run.sh"; VMX="$my" vp_both sp2 s acme
[[ $VA -eq 1 ]] && pass "sticky source file: exit 1" || fail "sticky file" "VA=$VA"
mbatch excl-dotdot "{\"id\":\"bm\",\"source\":\"f\",$P,\"exclude\":[\"../x\"]}" "'exclude'"
mbatch excl-dotdot "{\"id\":\"bm\",\"source\":\"f\",$P,\"exclude\":[\"../x\"]}" "'exclude'"
mbatch excl-abs "{\"id\":\"bm\",\"source\":\"f\",$P,\"exclude\":[\"/x\"]}" "'exclude'"

# ---- B1: pattern is gone; the old ReDoS input exits 2 fast; 65 chars refused by both tools
mkmod rx '{"id":"rx","source":"f","slots":{"NAME":{"description":"n","pattern":"(a+)+$"}},"placement":{"**":"root"}}'; mkdir -p "$sm/rx/f"; echo '<NAME>' >"$sm/rx/f/t"
t0=$(date +%s); run rx1 single rx -- NAME=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-; t1=$(date +%s)
[[ $rc -eq 2 ]] && grep -q 'pattern' "$tmp/rx1.err" && (( t1 - t0 <= 1 )) && pass "manifest with a regex pattern: exit 2 naming the key, no regex ever runs (ReDoS input fast)" || fail "pattern key" "rc=$rc t=$((t1 - t0))s $(head -c 160 "$tmp/rx1.err")"
run lv1 single esc -- "SERVICE=$long65"
[[ $rc -eq 2 ]] && grep -q 'cap is 64' "$tmp/lv1.err" && pass "65-character value: exit 2 naming the cap" || fail "length cap" "rc=$rc $(head -c 160 "$tmp/lv1.err")"
run lv2 single esc -- "SERVICE=$(printf 'z%.0s' $(seq 1 64))"; [[ $rc -eq 0 ]] && pass "64-character value accepted" || fail "64 chars" "rc=$rc"
cs_case() { # <label> <manifest-slot-json> <value> <expect-rc>
  mkmod cs "{\"id\":\"cs\",\"source\":\"f\",\"slots\":{\"NAME\":$2},\"placement\":{\"**\":\"root\"}}"; mkdir -p "$sm/cs/f"; echo '<NAME>' >"$sm/cs/f/t"
  run "cs_$1" single cs -- "NAME=$3"
  if [[ $rc -eq $4 ]] && nolines "$tmp/cs_$1.err"; then pass "slot option $1: $3 -> rc $4"; else fail "slot option $1" "rc=$rc $(head -c 160 "$tmp/cs_$1.err")"; fi
}
cs_case lower-ok '{"charset":"lower"}' abc 0
cs_case lower-digit '{"charset":"lower"}' a1 2
cs_case lower-upper '{"charset":"lower"}' aBc 2
cs_case kebab-ok '{"charset":"lower-digits-dash"}' a-b9-c 0
cs_case kebab-under '{"charset":"lower-digits-dash"}' a_b 2
cs_case kebab-trail-dash '{"charset":"lower-digits-dash"}' ab- 2
cs_case kebab-double '{"charset":"lower-digits-dash"}' a--b 2
cs_case ident-ok '{"charset":"identifier"}' my_pkg9 0
cs_case ident-dash '{"charset":"identifier"}' my-pkg 2
cs_case ident-dot '{"charset":"identifier"}' my.pkg 2
cs_case ident-lead-digit '{"charset":"identifier"}' 9pkg 2
cs_case ident-lead-underscore '{"charset":"identifier"}' _pkg 2
cs_case maxlen-ok '{"max_len":5}' abcde 0
cs_case maxlen-over '{"max_len":5}' abcdef 2
mbatch max-len-zero "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"max_len\":0}}}" max_len
mbatch max-len-65 "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"max_len\":65}}}" max_len
mbatch max-len-bool "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"max_len\":true}}}" max_len
mbatch max-len-string "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"max_len\":\"x\"}}}" max_len
mbatch max-len-float "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"max_len\":1.5}}}" max_len
mbatch charset-unknown "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"charset\":\"upper\"}}}" charset
mbatch literal-slash "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"literal\":\"aa/bb\"}}}" "literal"
mbatch literal-long "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"literal\":\"$long65\"}}}" "literal"

# ---- the wrapper passes its arguments through faithfully (all validation is the assembler's)
run em1 single esc -- SERVICE=; [[ $rc -eq 2 ]] && pass "assemble: empty --slot value exit 2" || fail "empty slot" "rc=$rc"
wr() { local d="$tmp/wr_$1"; shift; rm -rf "$d"; "$WT" "$d" "$@" >"$d.out" 2>"$d.err"; wrc=$?; WD="$d"; }
sc_wrap() { local WT="$1" ok=1
  wr a order-book acme.io; [[ $wrc -eq 0 && -f "$WD/cmd/order-book/main.go" && -f "$WD/go.mod" && ! -e "$WD/services" ]] && grep -q acme.io "$WD/CODEOWNERS" || ok=0
  wr b; [[ $wrc -eq 0 && -f "$WD/cmd/svc/main.go" ]] && grep -q mselser95 "$WD/CODEOWNERS" || ok=0
  wr c "" acme; [[ $wrc -eq 2 && ! -e "$WD" ]] || ok=0
  wr d svc ""; [[ $wrc -eq 2 && ! -e "$WD" ]] || ok=0
  wr e a b c; [[ $wrc -eq 2 && ! -e "$WD" ]] || ok=0
  [[ $ok -eq 1 ]]; }
green sc_wrap "$inst" && pass "wrapper: hyphenated service + dotted owner, omitted args -> defaults, empty arg -> exit 2, a third argument -> exit 2, nothing written" || fail "wrapper arguments"

# ---- W3: duplicate JSON keys, at any depth
mbatch dup-slots "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{},\"slots\":{\"A\":\"d\"}}" "duplicate key 'slots'"
mbatch dup-nested "{\"id\":\"bm\",\"source\":\"f\",\"placement\":{\"**\":\"root\",\"**\":\"unit\"}}" "duplicate key '**'"

# ---- W5: source must stay in the module's own tree, or be exactly ../../template
mbad src-sibling "{\"id\":\"bm\",\"source\":\"../ra/f\",$P}" "outside the module"
mbad src-dotdot "{\"id\":\"bm\",\"source\":\"..\",$P}" "outside the module"
mbad src-two-up "{\"id\":\"bm\",\"source\":\"../..\",$P}" "outside the module"
mbad src-tpl-sub "{\"id\":\"bm\",\"source\":\"../../template/x\",$P}" "outside the module"
mbad src-tpl-missing "{\"id\":\"bm\",\"source\":\"../../template\",$P}" "not a directory"
mkdir -p "$sm/bm/inside/deep"; echo q >"$sm/bm/inside/deep/q"; ln -s ../ra "$sm/bm/lnk"
mbad src-symlink "{\"id\":\"bm\",\"source\":\"lnk\",$P}" "outside the module"
printf '%s\n' "{\"id\":\"bm\",\"source\":\"inside/../inside\",$P}" >"$sm/bm/module.json"; run bm_ok single bm --
[[ $rc -eq 0 && -f "$tmp/bm_ok/deep/q" ]] && pass "source: a subdirectory of the module (via inside/../inside) is accepted" || fail "source subdir" "rc=$rc $(head -c 160 "$tmp/bm_ok.err")"

# ---- W1: a link is judged by where it LANDS (its output location), its target text is never rewritten.
# Rule (monorepo): a link whose output lies in a unit directory must target inside that same unit;
# a link at the root must not target inside (or contain) a unit; a target leaving the repository is refused first.
mkmod lk '{"id":"lk","source":"f","slots":{"SERVICE":"s"},"placement":{"**":"unit"}}'; mkdir -p "$sm/lk/f"; ln -s ../../x "$sm/lk/f/L"
run lk1 monorepo lk -- SERVICE=svc
[[ $rc -eq 1 ]] && grep -q 'link: services/svc/L -> ../../x (module lk): the target x is outside the unit directory services/svc; a link of a unit must stay inside its own unit' "$tmp/lk1.err" && [[ ! -e "$tmp/lk1" ]] && pass "link ../../x under services/svc stays in the repo but leaves its unit: refused with the unit message" || fail "unit link (leaves unit)" "rc=$rc $(head -c 200 "$tmp/lk1.err")"
rm "$sm/lk/f/L"; mkdir -p "$sm/lk/f/sub"; ln -s ../x "$sm/lk/f/sub/L"
run lk1b monorepo lk -- SERVICE=svc
if [[ $rc -eq 0 && "$(readlink "$tmp/lk1b/services/svc/sub/L")" == ../x ]]; then pass "link sub/L -> ../x lands at services/svc/sub/L, targets services/svc/x: inside its unit, accepted, target text kept"
else fail "output-based link (inside unit)" "rc=$rc $(head -c 160 "$tmp/lk1b.err")"; fi
rm "$sm/lk/f/sub/L"; rmdir "$sm/lk/f/sub"; ln -s ../../x "$sm/lk/f/L"
rm "$sm/lk/f/L"; ln -s ../../../x "$sm/lk/f/L"
run lk2 monorepo lk -- SERVICE=svc
[[ $rc -eq 1 ]] && grep -q 'link: services/svc/L -> ../../../x' "$tmp/lk2.err" && [[ ! -e "$tmp/lk2" ]] && pass "link leaving dest from its OUTPUT location refused" || fail "output-based link (escape)" "rc=$rc $(head -c 160 "$tmp/lk2.err")"
mkdir -p "$sm/lk/f/d"; rm "$sm/lk/f/L"; ln -s ../../x "$sm/lk/f/d/L"
run lk3 single lk -- SERVICE=svc
[[ $rc -eq 1 ]] && grep -q 'link: d/L' "$tmp/lk3.err" && pass "link d/L -> ../../x leaves dest in layout single: refused" || fail "link depth" "rc=$rc"
rm "$sm/lk/f/d/L"; rmdir "$sm/lk/f/d"; echo y >"$sm/lk/f/y"
mkmod lkr '{"id":"lkr","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/lkr/f"; ln -s services/svc/y "$sm/lkr/f/R"
run lk4 monorepo lk lkr -- SERVICE=svc
[[ $rc -eq 1 ]] && grep -q 'link: R -> services/svc/y (module lkr): a root link whose target services/svc/y lies inside or contains the unit directory services/svc' "$tmp/lk4.err" && pass "root link into a unit directory refused (a root link may not couple the root to a unit)" || fail "root link into unit" "rc=$rc $(head -c 200 "$tmp/lk4.err")"
rm "$sm/lkr/f/R"; echo z >"$sm/lkr/f/z"; ln -s z "$sm/lkr/f/R"
run lk5 monorepo lk lkr -- SERVICE=svc
[[ $rc -eq 0 && "$(readlink "$tmp/lk5/R")" == z ]] && pass "root link to a root file accepted" || fail "root link inside root" "rc=$rc $(head -c 200 "$tmp/lk5.err")"

# ---- W2: case / normalisation collisions are refused on every platform
mkmod cfd '{"id":"cfd","source":"f","slots":{"SERVICE":"s"},"placement":{"**":"root"}}'; mkdir -p "$sm/cfd/f"; echo one >"$sm/cfd/f/a.md"; echo two >"$sm/cfd/f/<SERVICE>.md"
runc cf2 single cfd -- SERVICE=A
if [[ $rc -eq 1 ]] && grep -Eq "path collision: '(A.md|a.md)'.*'(a.md|A.md)'" "$tmp/log_cf2.err" && untouched cf2; then pass "a.md vs <SERVICE>.md=A.md: collision named, nothing written (any filesystem)"
else fail "case collision" "rc=$rc $(head -c 200 "$tmp/log_cf2.err")"; fi
mkmod cfp '{"id":"cfp","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/cfp/f/sub"; echo k >"$sm/cfp/f/sub/keep"; ln -s sub "$sm/cfp/f/D"
mkmod cfq '{"id":"cfq","source":"f","slots":{"SERVICE":"s"},"placement":{"**":"root"}}'; mkdir -p "$sm/cfq/f/<SERVICE>"; echo n >"$sm/cfq/f/<SERVICE>/f"
runc cf3 single cfp cfq -- SERVICE=d
[[ $rc -eq 1 ]] && grep -q 'path conflict' "$tmp/log_cf3.err" && untouched cf3 && pass "link D vs file d/f (case alias beneath a link): refused by the folded prefix check" || fail "case-aliased prefix" "rc=$rc $(head -c 200 "$tmp/log_cf3.err")"

# ---- M3: overlapping literal placeholders, longest first
mkmod ov '{"id":"ov","source":"f","slots":{"SHORT":{"description":"s","literal":"foo-"},"LONG":{"description":"l","literal":"foo-bar"}},"placement":{"**":"root"}}'
mkdir -p "$sm/ov/f"; echo 'foo-bar and foo-' >"$sm/ov/f/t.txt"
run ov1 single ov -- SHORT=x LONG=y
[[ $rc -eq 0 && "$(cat "$tmp/ov1/t.txt")" == 'y and x' ]] && pass "overlapping literals: the longer placeholder wins (foo-bar -> y, foo- -> x)" || fail "longest first" "rc=$rc $(cat "$tmp/ov1/t.txt" 2>/dev/null)"

# ---- direct calls into the module (no flag in the shipped tool): write step, fold, signals
cat >"$tmp/direct.py" <<'PY'
import importlib.util, os, signal, sys, tempfile
tempfile.tempdir = os.environ["DIRECT_TMP"]
spec = importlib.util.spec_from_file_location("assemble", sys.argv[1])
asm = importlib.util.module_from_spec(spec); spec.loader.exec_module(asm)
sc = sys.argv[2]
def ent(kind, data, mode=0o644): return {"kind": kind, "data": data, "mode": mode, "mods": ["x"], "merge": False}
def cli(dest, mdir): return ["assemble.py", "--dest", dest, "--layout", "single", "--module", "ra", "--modules-dir", mdir]
if sc == "esc":      # a planned link, then a path beneath it: only the WRITE-time check stands in the way
    t, o = tempfile.mkdtemp(), tempfile.mkdtemp()
    try:
        asm.write_tree({"L": ent("link", o), "L/NEW": ent("file", b"x")}, t, 0o22, {})
        print("WROTE" if os.path.exists(os.path.join(o, "NEW")) else "NOWRITE")
    except SystemExit as e:
        print("REFUSED" if not os.path.exists(os.path.join(o, "NEW")) else "WROTE", e.code)
elif sc == "excl":   # a path that already exists is never overwritten
    t = tempfile.mkdtemp(); open(os.path.join(t, "f"), "w").write("old")
    try:
        asm.write_tree({"f": ent("file", b"new")}, t, 0o22, {})
        print("OVERWRITTEN" if open(os.path.join(t, "f")).read() != "old" else "KEPT")
    except OSError:
        print("REFUSED" if open(os.path.join(t, "f")).read() == "old" else "OVERWRITTEN")
elif sc == "fold":
    ok = asm.fold("A.md") == asm.fold("a.md") and asm.fold("é") == asm.fold("é") and asm.fold("a") != asm.fold("b")
    print("FOLDS" if ok else "NOFOLD")
elif sc == "vals":   # the value grammar over a NUL-separated list: 1 accepted, 0 refused with exit 2
    out = ""
    for b in open(sys.argv[3], "rb").read().split(b"\0")[:-1]:
        try:
            asm.check_value("X", os.fsdecode(b)); out += "1"
        except SystemExit as e:
            out += "0" if e.code == 2 else "?"
    print(out)
elif sc == "names":  # the reserved-component rule: refused names and the names that must stay allowed
    good = [".github", ".gitignore", ".gitattributes", ".gitkeep", ".gitmodules", "git", "gitx", ".git-hooks",
            "a.b", "x.y", "git~2", "git~10", "dotgit", "CODEOWNERS"]
    bad = [".git", ".GIT", ".Git", ".git.", ".git ", ".git..", "x.", "x ", "git~1", "GIT~1", ".g‌it", "​.git"]
    wrong = [n for n in good if asm.reserved(n)] + [n for n in bad if not asm.reserved(n)]
    print("OK" if not wrong else "WRONG " + repr(wrong))
elif sc == "mbad":   # manifest refusals in process: [label, manifest, needle] records, NUL-separated
    import contextlib, io
    recs = open(sys.argv[3], "rb").read().split(b"\0")[:-1]
    mdir = tempfile.mkdtemp(); os.mkdir(os.path.join(mdir, "bm")); bad = []
    for i in range(0, len(recs), 3):
        label, man, needle = (x.decode() for x in recs[i:i + 3])
        open(os.path.join(mdir, "bm", "module.json"), "w").write(man + "\n")
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                asm.load_manifest("bm", mdir)
            bad.append(label + ":accepted")
        except SystemExit as e:
            msg = err.getvalue()
            if e.code != 2 or needle not in msg or "Traceback" in msg or msg.count("\n") != 1:
                bad.append("%s:rc=%s:%r" % (label, e.code, msg[:80]))
    print("OK %d" % (len(recs) // 3) if not bad else "BAD " + " ".join(bad))
elif sc.startswith("sig:"):   # a signal lands in the middle of the write phase
    signum = getattr(signal, sc[4:])
    dest, mdir = sys.argv[3], sys.argv[4]
    def slow_write(plan, tmp, umask, dir_modes=None):
        for i in range(3): open(os.path.join(tmp, "half%d" % i), "w").write("x")
        os.kill(os.getpid(), signum)
        raise RuntimeError("the signal was not delivered")
    asm.write_tree = slow_write
    sys.argv = cli(dest, mdir)
    asm.main()
elif sc == "clean":   # a write failure, then a TERM at the very start of the cleanup
    dest, mdir = sys.argv[3], sys.argv[4]
    def failing_write(plan, tmp, umask, dir_modes=None):
        for i in range(300): open(os.path.join(tmp, "f%d" % i), "w").write("x")
        os.mkdir(os.path.join(tmp, "sub")); open(os.path.join(tmp, "sub", "g"), "w").write("x")
        raise OSError("disk full (simulated)")
    real_rmtree = asm.shutil.rmtree
    def hit(path, *a, **k):
        os.kill(os.getpid(), signal.SIGTERM)
        real_rmtree(path, *a, **k)
    asm.write_tree = failing_write; asm.shutil.rmtree = hit
    sys.argv = cli(dest, mdir)
    asm.main()
elif sc == "commit":  # a TERM right after the rename: the tree is complete, so the run is a success
    dest, mdir = sys.argv[3], sys.argv[4]
    real_rename = asm.os.rename
    def late(a, b):
        real_rename(a, b); os.kill(os.getpid(), signal.SIGTERM)
    asm.os.rename = late
    sys.argv = cli(dest, mdir)
    asm.main()
elif sc == "changed":  # dest appears (non-empty) and a TERM is pending when the commit check runs
    dest, mdir = sys.argv[3], sys.argv[4]
    def tiny_write(plan, tmp, umask, dir_modes=None): open(os.path.join(tmp, "a"), "w").write("x")
    real_makedirs = asm.os.makedirs
    def plant(path, *a, **k):
        real_makedirs(path, *a, **k)
        real_makedirs(dest, exist_ok=True); open(os.path.join(dest, "intruder"), "w").write("x")
        os.kill(os.getpid(), signal.SIGTERM)
    asm.write_tree = tiny_write; asm.os.makedirs = plant
    sys.argv = cli(dest, mdir)
    asm.main()
elif sc == "bp":      # the reader of stdout is gone
    dest, mdir = sys.argv[3], sys.argv[4]
    class Broken:
        dead = False
        def write(self, s): Broken.dead = True; raise BrokenPipeError(32, "Broken pipe")
        def flush(self):
            if not Broken.dead: return
            Broken.dead = False; raise BrokenPipeError(32, "Broken pipe")
        def fileno(self): return 1
    sys.stdout = Broken()
    sys.argv = cli(dest, mdir)
    asm.main()
PY
direct() { python3 -I -B "$tmp/direct.py" "${USE:-$asm}" "$@" 2>/dev/null | tail -n 3 | tr '\n' ' '; }
[[ "$(direct esc)" == "REFUSED 1 " ]] && pass "write step refuses an entry beneath a planned link (hand-built plan), nothing written outside" || fail "write-time escape" "$(direct esc)"
[[ "$(direct excl)" == "REFUSED " ]] && pass "write step never overwrites an existing path (O_EXCL, hand-built plan)" || fail "write-time exclusivity" "$(direct excl)"
[[ "$(direct fold)" == "FOLDS " ]] && pass "fold(): case and NFC/NFD collapse to one key" || fail "fold" "$(direct fold)"
sigcase() { # <SIGNAME> <expected rc>
  local d="$tmp/sig_$1"; mkdir -p "$d"; echo canary >"$d/canary"
  (ulimit -c 0; python3 -I -B "$tmp/direct.py" "${USE:-$asm}" "sig:$1" "$d/dest" "$sm" >"$d/out" 2>"$d/err"); local r=$?
  if [[ $r -eq $2 && "$(cat "$d/err")" == "assemble: interrupted -- nothing written" && ! -s "$d/out" && "$(find "$d" -mindepth 1 -maxdepth 1 ! -name out ! -name err)" == "$d/canary" ]]; then
    pass "signal $1 during the write phase: exit $2, one stderr line, no temp dir, no dest, no traceback"
  else fail "signal $1" "rc=$r err=$(head -c 200 "$d/err") ls=$(ls -A "$d" | tr '\n' ' ')"; fi
}
sigcase SIGTERM 143; sigcase SIGINT 130; sigcase SIGHUP 129; sigcase SIGQUIT 131

# ---- mutants: each guard removed in a copy must turn its scenario RED
# red <label> <from> <to> <scenario>: PAIRED BY CONSTRUCTION. The scenario must already be green on the REAL tool
# (cached in GREENS, filled by `green`; run now when missing); a scenario with no green is a FAIL "unpaired" and
# its mutant is never judged. The scenario returns 0 when the guard holds and takes the tool path as $1.
pairing() { # <label> <scenario> <real-tool>
  [[ "$GREENS" == *" $2 "* ]] || green "$2" "$3"
  [[ "$GREENS" == *" $2 "* ]] || { fail "mutant $1: unpaired (scenario $2 is not green on the real tool)"; return 1; }
}
red() {
  local lb="$1" f="$tmp/mr-$1.py"
  pairing "$lb" "$4" "$asm" || return
  mutant "$2" "$3" "$f" || return
  if "$4" "$f"; then fail "mutant $lb stayed GREEN"; else pass "mutant $lb: RED"; fi
}
# redw: the same for the WRAPPER: the mutated wrapper runs beside a copy of the assembler, over the real prod-new
redw() { # <label> <from> <to> <scenario>
  local lb="$1" w="$tmp/wm/$1/scripts"
  pairing "$lb" "$4" "$inst" || return
  mkdir -p "$w" && ln -s "$here/prod-new" "$tmp/wm/$1/prod-new" && cp "$asm" "$w/assemble.py" || { fail "wrapper mutant $lb: setup"; return; }
  mutant "$2" "$3" "$w/instantiate-template.sh" "$inst" || return
  if "$4" "$w/instantiate-template.sh"; then fail "wrapper mutant $lb stayed GREEN"; else pass "wrapper mutant $lb: RED"; fi
}
sc_rc() { # <asm> <expect-rc> <err-needle|-> <label> <layout> <modules...> -- slots
  local u="$1" want="$2" nd="$3" lb="$4"; shift 4; chmod -R u+rwx "$tmp/mu_$lb" 2>/dev/null; rm -rf "$tmp/mu_$lb"; USE="$u" runc "mu_$lb" "$@"
  [[ $rc -eq $want ]] && { [[ "$nd" == - ]] || grep -q -- "$nd" "$tmp/log_mu_$lb.err"; }
}
sc_match()  { sc_rc "$1" 2 grammar m1 single esc -- 'SERVICE=a/b'; }
sc_owner()  { sc_rc "$1" 2 grammar m2 single ms -- SERVICE=x 'OWNER=a/b'; }
sc_linkpre(){ sc_rc "$1" 1 'path conflict' m3 single la lb --; }
sc_linkchk(){ sc_rc "$1" 1 'link: d2' m4 single lc2x --; }
sc_req()    { sc_rc "$1" 1 'requires module gi' m5 single rq --; }
sc_conf()   { sc_rc "$1" 1 'conflicts with module' m6 single cf rq gi --; }
sc_unk()    { printf '%s\n' "{\"id\":\"bm\",\"source\":\"f\",$P,\"bogus\":1}" >"$sm/bm/module.json"; sc_rc "$1" 2 bogus m7 single bm --; }
sc_idm()    { printf '%s\n' "{\"id\":\"other\",\"source\":\"f\",$P}" >"$sm/bm/module.json"; sc_rc "$1" 2 "'id'" m8 single bm --; }
sc_strict() { GIT_CONFIG_GLOBAL="$tmp/gcfg" AFLAGS=--strict-tracked sc_rc "$1" 1 x.yaml m9 single gg --; }
sc_cap()    { sc_rc "$1" 2 'cap is 64' m10 single esc -- "SERVICE=$long65"; }
sc_cset()   { mkmod cs '{"id":"cs","source":"f","slots":{"NAME":{"charset":"lower"}},"placement":{"**":"root"}}'; sc_rc "$1" 2 charset m11 single cs -- NAME=A1; }
sc_mlen()   { mkmod cs '{"id":"cs","source":"f","slots":{"NAME":{"max_len":2}},"placement":{"**":"root"}}'; sc_rc "$1" 2 max_len m12 single cs -- NAME=abc; }
sc_dup()    { printf '%s\n' "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{},\"slots\":{\"A\":\"d\"}}" >"$sm/bm/module.json"; sc_rc "$1" 2 duplicate m13 single bm --; }
sc_src()    { printf '%s\n' "{\"id\":\"bm\",\"source\":\"../ra/f\",$P}" >"$sm/bm/module.json"; sc_rc "$1" 2 outside m14 single bm --; }
sc_litslash(){ printf '%s\n' "{\"id\":\"bm\",\"source\":\"f\",$P,\"slots\":{\"A\":{\"literal\":\"aa/bb\"}}}" >"$sm/bm/module.json"; sc_rc "$1" 2 literal m15 single bm -- A=x; }
sc_excl()   { printf '%s\n' "{\"id\":\"bm\",\"source\":\"f\",$P,\"exclude\":[\"../x\"]}" >"$sm/bm/module.json"; sc_rc "$1" 2 exclude m16 single bm --; }
sc_fold()   { sc_rc "$1" 1 'path collision' m17 single cfd -- SERVICE=A; }
sc_lnkout() { sc_rc "$1" 0 - m18 monorepo lkm -- SERVICE=svc; }
sc_order()  { sc_rc "$1" 0 - m19 single ov -- SHORT=x LONG=y && [[ "$(cat "$tmp/mu_m19/dest/t.txt")" == 'y and x' ]]; }
sc_special(){ sc_rc "$1" 1 'setuid' m20 single sx --; }
sc_dirmode(){ local d="$tmp/vp_m21"; rm -rf "${d:?}"; mkdir -p "$d"   # umask 002: the 750 source directory stays 750 (source mode & ~umask)
  (umask 002; MODS="$mx/prod-new/modules" USE="$1" A --dest "$d/a" --layout single --module service-go --slot SERVICE=um --slot OWNER=acme) >/dev/null 2>&1 \
    && grep -q "^drwxr-x--- \./docs/priv$" <<<"$(modes "$d/a")"; }
sc_wesc()   { local o; o="$(USE="$1" direct esc)"; [[ "$o" == REFUSED* ]]; }
sc_wexcl()  { local o; o="$(USE="$1" direct excl)"; [[ "$o" == REFUSED* ]]; }
sc_sigterm(){ local d="$tmp/sg_m" r; rm -rf "$d"; mkdir -p "$d"; (ulimit -c 0; python3 -I -B "$tmp/direct.py" "$1" sig:SIGTERM "$d/dest" "$sm" >/dev/null 2>"$d/err"); r=$?
  [[ $r -eq 143 && "$(cat "$d/err")" == "assemble: interrupted -- nothing written" && "$(ls -A "$d")" == err ]]; }
mkmod lc2x '{"id":"lc2x","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/lc2x/f"; ln -s /outside "$sm/lc2x/f/d2"
mkmod lkm '{"id":"lkm","source":"f","slots":{"SERVICE":"s"},"placement":{"**":"unit"}}'; mkdir -p "$sm/lkm/f"; mkdir -p "$sm/lkm/f/sub"; ln -s ../x "$sm/lkm/f/sub/L"
mkmod sx '{"id":"sx","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/sx/f"; echo z >"$sm/sx/f/z"; chmod 4755 "$sm/sx/f/z"
mkdir -p "$sm/bm/f"; echo x >"$sm/bm/f/a"
red grammar-search 'VALUE_RX.fullmatch(v) is None' 'VALUE_RX.search(v) is None' sc_match
red grammar-service-only '    for k, v in slots.items():
        check_value(k, v)' '    for k, v in slots.items():
        if k == "SERVICE": check_value(k, v)' sc_owner
red prefix-files-only '            if pre is not None:' '            if pre is not None and plan[pre]["kind"] == "file":' sc_linkpre
red link-target-check 'if os.path.isabs(tgt) or "\0" in tgt or norm == ".." or norm.startswith("../"):' 'if False:' sc_linkchk
red requires-off '            if r not in chosen:' '            if False:' sc_req
red conflicts-off '            if c in chosen:' '            if False:' sc_conf
red unknown-key-tolerated '    if unknown:' '    if False:' sc_unk
red id-mismatch-tolerated '    if m["id"] != mid:' '    if False:' sc_idm
red strict-ignores-untracked '        stray = git_list(src, env, True)
        if stray:' '        stray = git_list(src, env, True)
        if False:' sc_strict
red length-cap-off '    if len(v) > MAX_VALUE:' '    if False:' sc_cap
red charset-off '            if k in sl and not charset_ok(cs, sl[k]):' '            if False:' sc_cset
red max-len-off '            if k in sl and len(sl[k]) > n:' '            if False:' sc_mlen
red dupkeys-off '        if k in d:' '        if False:' sc_dup
red source-rule-off '        if not (real_src == real_mod or' '        if False and not (real_src == real_mod or' sc_src
red literal-slash-off '            if "/" in v["literal"] or "\0" in v["literal"]:' '            if False:' sc_litslash
red exclude-dotdot-off '        if ".." in g or g.startswith("/") or "\0" in g:' '        if False:' sc_excl
red fold-identity '    return unicodedata.normalize("NFC", unicodedata.normalize("NFC", p).casefold())' '    return p' sc_fold
red link-by-source-path 'posixpath.normpath(posixpath.join(posixpath.dirname(out), tgt))' 'posixpath.normpath(posixpath.join(posixpath.dirname(rel), tgt))' sc_lnkout
red placeholders-unsorted 'key=lambda kv: (-len(kv[1]), kv[1])' 'key=lambda kv: kv[1]' sc_order
red special-bits-off '                if st.st_mode & SPECIAL:' '                if False:' sc_special
red dir-mode-ignores-source 'dir_modes[od] = (dstat[sd] & ~umask) | stat.S_IWUSR' 'dir_modes[od] = (0o777 & ~umask) | stat.S_IWUSR' sc_dirmode
red write-escape-off '    for out in sorted(plan):
        if escapes(tmp, out):' '    for out in sorted(plan):
        if False:' sc_wesc
red write-excl-to-trunc 'os.O_CREAT | os.O_EXCL | nofollow' 'os.O_CREAT | os.O_TRUNC | nofollow' sc_wexcl
red sigterm-unhandled '("SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT")' '("SIGINT", "SIGHUP", "SIGQUIT")' sc_sigterm


# ======================= round 4: .git, unreadable sources, cleanup, links, modes =======================
# the whole value list through the assembler's own check (one python process)
vpy="$(direct vals "$vals")"
if [[ "$vpy" == "$vexp " ]]; then pass "value grammar: ${#okv[@]} accepted + ${#badv[@]} refused values, every one as expected"
else fail "value grammar differs" "expected $vexp / assembler ${vpy% }"; fi
sc_vals() { [[ "$(USE="$1" direct vals "$vals")" == "$vexp " ]]; }
sc_names() { [[ "$(USE="$1" direct names)" == "OK " ]]; }
green sc_names && pass "reserved(): .git in any case/form, trailing dot or space, git~1 refused; .github .gitignore .gitattributes .gitkeep .gitmodules .git-hooks allowed" || fail "reserved()" "$(direct names)"

mres="$(direct mbad "$tmp/mb.bin")"
[[ "$mres" == "OK $nmb " ]] && pass "manifest refusals ($nmb in one process): each exit 2, one line naming its key, no traceback" || fail "manifest refusals" "$mres"
gmod() { # <id> <relpath>...  a walk-path module: source f holds a.txt and the given files (reset on every call)
  local id="$1" x; shift; mkmod "$id" "{\"id\":\"$id\",\"source\":\"f\",\"slots\":{},\"placement\":{\"**\":\"root\"}}"
  rm -rf "${sm:?}/${id:?}/f"; mkdir -p "$sm/$id/f"; echo a >"$sm/$id/f/a.txt"
  for x in "$@"; do mkdir -p "$sm/$id/f/$(dirname "$x")"; echo y >"$sm/$id/f/$x"; done
}
gn=0
# B1, source side: a module read by a filesystem walk that holds a .git entry is refused
for x in .git/hooks/pre-commit .GIT/hooks/pre-commit sub/.git/config; do
  gn=$((gn + 1)); gmod gh "$x"; chmod 755 "$sm/gh/f/$x"; runc "gh$gn" single gh --
  if [[ $rc -eq 1 ]] && grep -q 'module gh' "$tmp/log_gh$gn.err" && grep -q 'git checkout' "$tmp/log_gh$gn.err" && nolines "$tmp/log_gh$gn.err" && untouched "gh$gn"; then pass "walk: a source holding $x is refused (exit 1, module named), nothing written"
  else fail "source .git $x" "rc=$rc $(head -c 200 "$tmp/log_gh$gn.err") ls=$(ls -A "$tmp/gh$gn" | tr '\n' ' ')"; fi
done
gmod gh .git/hooks/pre-commit; mkmod gh '{"id":"gh","source":"f","slots":{},"placement":{".git/hooks/pre-commit":"root","a.txt":"root"}}'
runc gh9 single gh --
[[ $rc -eq 1 ]] && grep -q 'git checkout' "$tmp/log_gh9.err" && untouched gh9 && pass "walk: a manifest that NAMES .git/hooks/pre-commit in placement is refused too" || fail "explicit .git placement" "rc=$rc $(head -c 200 "$tmp/log_gh9.err")"
# B1, output side: aliases of .git are refused whatever the source looked like
for x in '.git./config' '.git /x' 'git~1/x' 'dir./y' 'sp /y'; do
  gn=$((gn + 1)); gmod gt "$x"; runc "gt$gn" single gt --
  if [[ $rc -eq 1 ]] && grep -q 'module gt' "$tmp/log_gt$gn.err" && grep -q 'reserved' "$tmp/log_gt$gn.err" && nolines "$tmp/log_gt$gn.err" && untouched "gt$gn"; then pass "output path with the component of '$x' refused (reserved), module named, nothing written"
  else fail "reserved output $x" "rc=$rc $(head -c 200 "$tmp/log_gt$gn.err")"; fi
done
gmod ga .github/workflows/ci.yml .gitignore .gitattributes .gitkeep .gitmodules gitx/a .git-hooks/h
runc ga1 single ga --
if [[ $rc -eq 0 && -f "$tmp/ga1/dest/.github/workflows/ci.yml" && -f "$tmp/ga1/dest/.gitignore" && -f "$tmp/ga1/dest/.gitattributes" && -f "$tmp/ga1/dest/.gitkeep" && -f "$tmp/ga1/dest/.gitmodules" && -f "$tmp/ga1/dest/gitx/a" && -f "$tmp/ga1/dest/.git-hooks/h" ]]; then pass ".github, .gitignore, .gitattributes, .gitkeep, .gitmodules, gitx, .git-hooks are shipped (the rule is not over-broad)"
else fail "allowed git-like names" "rc=$rc $(head -c 200 "$tmp/log_ga1.err")"; fi
# B1, the git candidate path: a module that is a git checkout never lists its own .git; a tracked alias is still refused
mkmod gtk '{"id":"gtk","source":".","slots":{},"placement":{"**":"root"}}'
mkdir -p "$sm/gtk/sub/.GIT/hooks"; echo a >"$sm/gtk/a.txt"; echo h >"$sm/gtk/sub/.GIT/hooks/x"
(cd "$sm/gtk" && git init -q && git add a.txt module.json) >/dev/null 2>&1
runc gk1 single gtk --
if { [[ $rc -eq 0 && -f "$tmp/gk1/dest/a.txt" ]] || { [[ $rc -eq 1 ]] && grep -q reserved "$tmp/log_gk1.err"; }; } && [[ -z "$(find "$tmp/gk1/dest" -iname .git 2>/dev/null)" ]]; then pass "git path: the checkout's own .git is not listed, no .git alias is shipped (a listed sub/.GIT is refused)"
else fail "git path .git" "rc=$rc $(head -c 200 "$tmp/log_gk1.err")"; fi
mkmod gtl '{"id":"gtl","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/gtl/f/trail."; echo z >"$sm/gtl/f/trail./f"; echo a >"$sm/gtl/f/a.txt"
(cd "$sm/gtl" && git init -q && git add f) >/dev/null 2>&1
runc gl1 single gtl --
[[ $rc -eq 1 ]] && grep -q 'reserved' "$tmp/log_gl1.err" && untouched gl1 && pass "git path: a TRACKED trail./f is refused by the output-side rule" || fail "git path alias" "rc=$rc $(head -c 200 "$tmp/log_gl1.err")"
gmod ghs .git/hooks/pre-commit; gmod gtd '.git./config'
sc_gsrc() { sc_rc "$1" 1 'git checkout' m34 single ghs --; }
sc_gout() { sc_rc "$1" 1 'reserved' m35 single gtd --; }
green sc_gsrc && green sc_gout || fail "git mutant scenarios do not pass on the real tool"
# reserved components planted in a copy of the template fixture are refused; the real template has none
mg="$tmp/mg"; cp -R "$mx" "$mg"
shgit() { rm -rf "${mg:?}/prod-new/template/docs/gitcase"; mkdir -p "$mg/prod-new/template/docs/gitcase/$(dirname "$1")"; echo y >"$mg/prod-new/template/docs/gitcase/$1"; VMX="$mg" vp_both gc s acme; }
for x in '.GIT/hooks/pre-commit' 'trail./x' 'sub/git~1/y' '.git:x/y' 'a:b/y'; do
  shgit "$x"
  if [[ $VA -eq 1 ]] && grep -Eq 'reserved|git checkout' "$tmp/vp_gc/a.err" && [[ ! -e "$tmp/vp_gc/a" ]]; then pass "template with $x: exit 1, nothing written"
  else fail "template reserved $x" "VA=$VA $(head -c 120 "$tmp/vp_gc/a.err")"; fi
done
[[ -z "$(find "$here/prod-new/template" \( -iname .git -o -iname 'git~1' -o -name '*.' -o -name '* ' -o -name '*:*' \))" ]] && pass "the real template holds no reserved path component and no colon" || fail "real template has a reserved component"

# B2: zero files, unreadable directory / tracked file (exit 2 in BOTH tools, one line, nothing written)
mkmod zf '{"id":"zf","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/zf/f"
sc_zf() { sc_rc "$1" 1 'yields no files' m36 single zf ra --; }
green sc_zf && pass "a module that yields zero files is refused (exit 1) even when another module has files" || fail "zero files" "$(head -c 160 "$tmp/log_mu_m36.err")"
if [[ "$(id -u)" -ne 0 ]]; then
  mkmod ud '{"id":"ud","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ud/f/sub"; echo a >"$sm/ud/f/a.txt"; echo b >"$sm/ud/f/sub/b.txt"; chmod 000 "$sm/ud/f/sub"
  sc_unr() { sc_rc "$1" 2 'unreadable source' m37 single ud -- && grep -q 'ud/f/sub' "$tmp/log_mu_m37.err" && [[ "$(wc -l <"$tmp/log_mu_m37.err")" -eq 1 ]] && untouched mu_m37; }
  green sc_unr && pass "walk: a mode-000 source directory exits 2 naming it (one line), nothing written" || fail "unreadable dir" "$(head -c 200 "$tmp/log_mu_m37.err")"
  mu="$tmp/mu"; cp -R "$mx" "$mu"; chmod 000 "$mu/prod-new/template/docs/priv"
  VMX="$mu" vp_both unr s acme
  if [[ $VA -eq 2 ]] && grep -q 'priv' "$tmp/vp_unr/a.err" && [[ ! -e "$tmp/vp_unr/a" ]]; then pass "unreadable template directory: exit 2 (names it, writes nothing)"
  else fail "unreadable template dir" "VA=$VA $(head -c 160 "$tmp/vp_unr/a.err")"; fi
  chmod 755 "$mu/prod-new/template/docs/priv"
  mkmod gtu '{"id":"gtu","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/gtu/f/sub"; echo a >"$sm/gtu/f/a.txt"; echo b >"$sm/gtu/f/sub/b.txt"
  (cd "$sm/gtu" && git init -q && git add f) >/dev/null 2>&1; chmod 000 "$sm/gtu/f/sub"
  runc gu1 single gtu --
  [[ $rc -eq 2 ]] && grep -q 'unreadable source' "$tmp/log_gu1.err" && untouched gu1 && pass "git path: a TRACKED file in an unreadable directory is an error (exit 2), not 'deleted'" || fail "git unreadable tracked" "rc=$rc $(head -c 200 "$tmp/log_gu1.err")"
  chmod 755 "$sm/gtu/f/sub"
else echo "SKIPPED unreadable-source cases: running as root, where mode 000 is readable"; sc_unr() { return 0; }; fi

# B3: a write failure, then a TERM at the start of the cleanup; the failure's code wins and nothing is left
dsc() { # <tool> <scenario>: direct.py scenario; sets r, DS (out/err/dest live there)
  local n="${2//:/_}"; DS="$tmp/ds_$n"; chmod -R u+rwx "$DS" 2>/dev/null; rm -rf "${DS:?}"; mkdir -p "$DS"
  (ulimit -c 0; python3 -I -B "$tmp/direct.py" "$1" "$2" "$DS/dest" "$sm" >"$DS/out" 2>"$DS/err"); r=$?
}
noleft() { [[ -z "$(find "$DS" -mindepth 1 -maxdepth 1 -name '.assemble-*')" ]]; }
sc_clean()   { dsc "$1" clean; [[ $r -eq 1 ]] && noleft && grep -q 'I/O error' "$DS/err" && ! grep -q interrupted "$DS/err" && [[ ! -e "$DS/dest" ]]; }
sc_commit()  { dsc "$1" commit; [[ $r -eq 0 && -f "$DS/dest/only-a" && -f "$DS/dest/CODEOWNERS" && ! -s "$DS/err" ]] && noleft; }
sc_changed() { dsc "$1" changed; [[ $r -eq 1 ]] && grep -q 'changed while assembling' "$DS/err" && ! grep -q interrupted "$DS/err" && [[ -f "$DS/dest/intruder" && ! -e "$DS/dest/only-a" ]] && noleft; }
sc_bp()      { dsc "$1" bp; [[ $r -eq 0 && ! -s "$DS/err" && -f "$DS/dest/only-a" ]]; }
sc_quit()    { local d="$tmp/sg_q" q; chmod -R u+rwx "$d" 2>/dev/null; rm -rf "${d:?}"; mkdir -p "$d"; (ulimit -c 0; python3 -I -B "$tmp/direct.py" "$1" sig:SIGQUIT "$d/dest" "$sm" >/dev/null 2>"$d/err"); q=$?
  [[ $q -eq 131 && "$(cat "$d/err")" == "assemble: interrupted -- nothing written" && "$(ls -A "$d")" == err ]]; }
green sc_clean && pass "write failure + TERM at the start of the cleanup: temp dir gone, exit 1 (the failure's code), not 143" || fail "cleanup under signal" "r=$r $(head -c 200 "$DS/err") ls=$(ls -A "$DS" | tr '\n' ' ')"
green sc_commit && pass "TERM right after the rename: exit 0, complete dest, silent (never 143 with a dest present)" || fail "TERM after rename" "r=$r $(head -c 200 "$DS/err")"
green sc_changed && pass "dest-changed check with a TERM pending: exit 1 'changed while assembling', not 143" || fail "original cause wins" "r=$r $(head -c 200 "$DS/err")"
green sc_bp && pass "stdout closed early (BrokenPipe) after success: exit 0, no message, dest complete" || fail "broken pipe" "r=$r $(head -c 200 "$DS/err")"
MODS="$sm" A --dest "$tmp/pipe1" --layout single --module ra 2>"$tmp/pipe1.err" | head -0; prc=${PIPESTATUS[0]}
[[ $prc -eq 0 && ! -s "$tmp/pipe1.err" && -f "$tmp/pipe1/only-a" ]] && pass "real pipe to 'head -0': exit 0, silent, dest complete" || fail "real broken pipe" "rc=$prc $(head -c 200 "$tmp/pipe1.err")"
green sc_quit && pass "signal SIGQUIT: exit 131, one line, nothing left" || fail "SIGQUIT"

# B4: umask 0777 (mkdtemp yields a mode-000 directory) and read-only trees
mkmod ldn '{"id":"ldn","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ldn/f/d"; echo x >"$sm/ldn/f/d/x"
sc_mk700()  { UMK=0777 sc_rc "$1" 0 - m30 single ra -- && chmod u+rwx "$tmp/mu_m30/dest" && [[ -f "$tmp/mu_m30/dest/only-a" && -z "$(find "$tmp/mu_m30" -maxdepth 1 -name '.assemble-*')" ]]; }
sc_umnest() { UMK=0777 sc_rc "$1" 1 'I/O error' m31 single ldn -- && [[ -z "$(find "$tmp/mu_m31" -maxdepth 1 -name '.assemble-*')" ]] && ! grep -q 'could not remove' "$tmp/log_mu_m31.err"; }
green sc_mk700 && pass "umask 0777: mkdtemp's mode-000 dir is opened to the owner, the run completes (exit 0), no temp dir left" || fail "umask 0777" "rc=$rc $(head -c 200 "$tmp/log_mu_m30.err")"
green sc_umnest && pass "umask 0777, nested write fails (000 directory): exit 1, the cleanup removes the unreadable tree, no .assemble-* left" || fail "umask 0777 cleanup" "rc=$rc $(head -c 200 "$tmp/log_mu_m31.err") ls=$(ls -A "$tmp/mu_m31" | tr '\n' ' ')"
# M4 / M2: directory modes, against the written-down rule (not "equal to the other tool")
mkmod rod '{"id":"rod","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/rod/f/ro"; echo x >"$sm/rod/f/ro/x"; chmod 500 "$sm/rod/f/ro"
sc_rodir()   { UMK=022 sc_rc "$1" 0 - m32 single rod -- && [[ "$(ls -ld "$tmp/mu_m32/dest/ro" | cut -c1-10)" == drwx------ ]]; }
sc_unitdir() { UMK=002 sc_rc "$1" 0 - m33 monorepo up -- SERVICE=svc && [[ "$(ls -ld "$tmp/mu_m33/dest/services" | cut -c1-10)" == drwxr-xr-x && "$(ls -ld "$tmp/mu_m33/dest/services/svc" | cut -c1-10)" == drwxr-xr-x ]]; }
green sc_rodir && pass "a 0500 source directory comes out 0700 (owner-writable: 0500 & ~umask | u+w)" || fail "u+w on directories" "rc=$rc $(ls -ld "$tmp/mu_m32/dest/ro" 2>&1 | cut -c1-10)"
green sc_unitdir && pass "monorepo services/ and services/<svc> are 0755 & ~umask | u+w under umask 002 (drwxr-xr-x), not the umask-derived 0775" || fail "unit prefix dir mode" "rc=$rc $(ls -ld "$tmp/mu_m33/dest/services" 2>&1 | cut -c1-10)"

# W1 / M1: link rules
mkmod l0 '{"id":"l0","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/l0/f"; ln -s .. "$sm/l0/f/L"
mkmod ll '{"id":"ll","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ll/f/d"; ln -s .. "$sm/ll/f/d/L1"; ln -s d/L1/.. "$sm/ll/f/E"
sc_up() { sc_rc "$1" 1 'link: L -> ..' m39 single l0 --; }
sc_ll() { sc_rc "$1" 1 'passes through planned link d/L1' m38 single ll --; }
green sc_up && pass "a link at the dest root whose target is exactly '..' is refused" || fail "link to .." "rc=$rc $(head -c 200 "$tmp/log_mu_m39.err")"
green sc_ll && pass "link-through-link refused (d/L1 -> .. then E -> d/L1/..): rule = no target may pass through or end at a planned link" || fail "link through link" "rc=$rc $(head -c 200 "$tmp/log_mu_m38.err")"

# W5: macOS cp -R copies extended attributes; neither tool may
if [[ "$(uname)" == Darwin ]] && command -v xattr >/dev/null 2>&1; then
  xset() { xattr -w parity.test 1 "$1" 2>/dev/null; }; xget() { xattr -l "$1" 2>/dev/null | grep -c 'parity.test' || true; }
elif command -v setfattr >/dev/null 2>&1; then
  xset() { setfattr -n user.paritytest -v 1 "$1" 2>/dev/null; }; xget() { getfattr -d "$1" 2>/dev/null | grep -c paritytest || true; }
else xset() { return 1; }; fi
mxa="$tmp/mxa"; cp -R "$mx" "$mxa"; xf="$mxa/prod-new/template/docs/plain.md"; echo plain >"$xf"   # no slot token: sed -i would rewrite (and so strip) a slot-bearing file's xattr
if xset "$xf" && [[ "$(xget "$xf")" == 1 ]]; then
  VMX="$mxa" vp_both xa s acme
  [[ $VA -eq 0 && "$(xget "$tmp/vp_xa/a/docs/plain.md")" == 0 ]] && pass "a source file with a user xattr: the output carries none" || fail "xattr" "VA=$VA"
else echo "SKIPPED xattr parity: no xattr/setfattr tool, or this filesystem refuses a user xattr"; fi

# mutants of this round: each guard removed in a copy must turn its scenario RED
red walk-git-source-off '                if env is None:  # SOURCE-GIT:' '                if False:  # SOURCE-GIT:' sc_gsrc
red git-output-off '            if rc_ is not None:  # OUTPUT-GIT: whatever way the candidate list was obtained' '            if False:' sc_gout
red git-casefold-off '    return fold("".join(ch for ch in c if unicodedata.category(ch) != "Cf")) == ".git"' '    return "".join(ch for ch in c if unicodedata.category(ch) != "Cf") == ".git"' sc_names
red git-trailing-dot-space-off '(c not in (".", "..") and c.endswith((".", " ")))' 'False' sc_names
red value-trailing-dot-off '[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?' '[A-Za-z0-9][A-Za-z0-9._-]*' sc_vals
red zero-files-off '        if not [r for r in cands if not (self_dir and r == "module.json")]:' '        if False:' sc_zf
[[ "$(id -u)" -ne 0 ]] && red walk-onerror-off 'os.walk(src, onerror=walk_error, followlinks=False)' 'os.walk(src, followlinks=False)' sc_unr
red cleanup-signal-mask-off '    ignore_signals()  # CLEANUP-MASK: a signal now must not abandon the removal half done' '    pass' sc_clean
red mkdtemp-chmod-off '        os.chmod(tmp, 0o700)  # MKDTEMP-CHMOD: under umask 0777 mkdtemp yields a mode-000 directory' '        pass' sc_mk700
red cleanup-dir-chmod-off '                    os.chmod(p, 0o700)' '                    pass' sc_umnest
red link-through-link-off '        if via is not None:' '        if False:' sc_ll
red link-to-dotdot-off 'or norm == ".." or norm.startswith("../")' 'or norm.startswith("../")' sc_up
red broken-pipe-off '        except (OSError, ValueError):
            # a closed pipe' '        except ZeroDivisionError:
            # a closed pipe' sc_bp
red sigquit-unhandled '("SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT")' '("SIGINT", "SIGTERM", "SIGHUP")' sc_quit
red cause-wins-off '            ignore_signals()  # CAUSE-WINS: a pending signal must not replace the real failure' '            pass' sc_changed
red commit-ignore-off '            ignore_signals()  # COMMIT-IGNORE: the tree is complete; a late signal is dropped' '            pass' sc_commit
red unit-prefix-dir-mode-off 'dir_modes[od] = (0o755 & ~umask) | stat.S_IWUSR' 'dir_modes[od] = (0o777 & ~umask) | stat.S_IWUSR' sc_unitdir
red dir-u-plus-w-off 'dir_modes[od] = (dstat[sd] & ~umask) | stat.S_IWUSR' 'dir_modes[od] = dstat[sd] & ~umask' sc_rodir
# ======================= round 5: link targets, special entries, stdout, colon, stale temp, wrapper =======================
# B2: a link TARGET is walked component by component against the same reserved predicate as output paths
mkmod lt '{"id":"lt","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/lt/f"
ln -s .git "$sm/lt/f/L1"; ln -s .git/hooks "$sm/lt/f/L2"; ln -s .GIT/hooks/pre-commit "$sm/lt/f/L3"; ln -s sub/.git "$sm/lt/f/L4"
ln -s $'.g\xe2\x80\x8bit' "$sm/lt/f/L5"; ln -s a:b "$sm/lt/f/L6"; ln -s .git. "$sm/lt/f/L7"
mkmod ltm '{"id":"ltm","source":"f","slots":{"SERVICE":"s"},"placement":{"**":"unit"}}'; mkdir -p "$sm/ltm/f"; ln -s ../../.git/hooks "$sm/ltm/f/l"
mkmod lok '{"id":"lok","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/lok/f"; ln -s .github/workflows "$sm/lok/f/l1"; ln -s .gitignore "$sm/lok/f/l2"
sc_ltgit() { local e="$tmp/log_mu_m50.err"; sc_rc "$1" 1 'target component' m50 single lt -- \
  && grep -q 'link: L1 -> \.git (module lt)' "$e" && grep -q 'link: L2 -> \.git/hooks' "$e" && grep -q 'link: L3 -> \.GIT/hooks/pre-commit' "$e" \
  && grep -q 'link: L4 -> sub/\.git' "$e" && grep -q $'link: L5 -> \\.g\xe2\x80\x8bit' "$e" && grep -q 'link: L6 -> a:b' "$e" && grep -q 'link: L7 -> \.git\.' "$e" \
  && untouched mu_m50; }
sc_ltmono() { sc_rc "$1" 1 'target component' m51 monorepo ltm -- SERVICE=s && grep -q 'link: services/s/l -> \.\./\.\./\.git/hooks (module ltm)' "$tmp/log_mu_m51.err" && untouched mu_m51; }
sc_ltok() { sc_rc "$1" 0 - m52 single lok -- && [[ "$(readlink "$tmp/mu_m52/dest/l1")" == .github/workflows && "$(readlink "$tmp/mu_m52/dest/l2")" == .gitignore ]]; }
green sc_ltgit && pass "link targets naming .git (.git, .git/hooks, .GIT/hooks/pre-commit, sub/.git, zero-width, trailing dot, a colon) refused, link and target named, nothing written" || fail "link target .git" "rc=$rc $(head -c 300 "$tmp/log_mu_m50.err")"
green sc_ltmono && pass "monorepo services/s/l -> ../../.git/hooks refused" || fail "monorepo link into .git" "rc=$rc $(head -c 200 "$tmp/log_mu_m51.err")"
green sc_ltok && pass "links to .github/workflows and .gitignore are allowed" || fail "allowed git-like link targets" "rc=$rc $(head -c 200 "$tmp/log_mu_m52.err")"

# B3: special entries and unreadable directories, one rule on both candidate paths
for id in sw sg sgi sks; do mkmod "$id" "{\"id\":\"$id\",\"source\":\"f\",\"slots\":{},\"placement\":{\"**\":\"root\"}}"; rm -rf "${sm:?}/$id/f" "${sm:?}/$id/.git"; mkdir -p "$sm/$id/f"; echo a >"$sm/$id/f/a.txt"; done
mkfifo "$sm/sw/f/q"                                                    # walk path (not a git work tree)
mkfifo "$sm/sg/f/q"; (cd "$sm/sg" && git init -q && git add f/a.txt) >/dev/null 2>&1                    # git path, untracked and NOT ignored
mkfifo "$sm/sgi/f/q"; echo q >"$sm/sgi/f/.gitignore"; (cd "$sm/sgi" && git init -q && git add f) >/dev/null 2>&1   # git path, ignored
mkdir -p "$sm/sks/f/d"; echo b >"$sm/sks/f/d/b.txt"; (cd "$sm/sks/f/d" && python3 -I -c 'import socket; socket.socket(socket.AF_UNIX).bind("s")')   # a socket, walk path
fast() { local t0=$SECONDS; "$@"; local r=$?; (( SECONDS - t0 <= 1 )) || { echo "slow: $((SECONDS - t0))s" >&2; return 1; }; return $r; }   # SECONDS ticks whole seconds: <= 1 means < 2 s
sc_spw() { fast sc_rc "$1" 1 'is not a regular file' m60 single sw -- && grep -q 'sw/f/q' "$tmp/log_mu_m60.err" && untouched mu_m60; }
sc_spg() { fast sc_rc "$1" 1 'git does not ignore it' m61 single sg -- && grep -q 'sg/f/q' "$tmp/log_mu_m61.err" && untouched mu_m61; }
sc_spi() { fast sc_rc "$1" 0 - m62 single sgi -- && [[ -f "$tmp/mu_m62/dest/a.txt" && ! -e "$tmp/mu_m62/dest/q" ]]; }
sc_spk() { fast sc_rc "$1" 1 'is not a regular file' m63 single sks -- && grep -q 'sks/f/d/s' "$tmp/log_mu_m63.err" && untouched mu_m63; }
green sc_spw && pass "walk path: a FIFO in the source is refused (exit 1, named, never opened, < 2 s), nothing written" || fail "walk FIFO" "rc=$rc $(head -c 200 "$tmp/log_mu_m60.err")"
green sc_spg && pass "git path: an untracked, not-ignored FIFO is refused (exit 1, named, < 2 s)" || fail "git FIFO" "rc=$rc $(head -c 200 "$tmp/log_mu_m61.err")"
green sc_spi && pass "git path: a git-IGNORED FIFO is build junk: skipped, not an error" || fail "ignored FIFO" "rc=$rc $(head -c 200 "$tmp/log_mu_m62.err")"
green sc_spk && pass "walk path: a socket in a subdirectory is refused (exit 1, named)" || fail "socket" "rc=$rc $(head -c 200 "$tmp/log_mu_m63.err")"
if [[ "$(id -u)" -ne 0 ]]; then
  # an UNTRACKED directory nothing can list: mode 000 and mode 0100, with and without --strict-tracked; an ignored one is junk
  mkmod su '{"id":"su","source":"f","slots":{},"placement":{"**":"root"}}'; rm -rf "${sm:?}/su"/f "${sm:?}/su/.git"; mkdir -p "$sm/su/f/un" "$sm/su/f/ig"
  echo a >"$sm/su/f/a.txt"; echo b >"$sm/su/f/un/b.txt"; echo c >"$sm/su/f/ig/c.txt"; echo 'ig/' >"$sm/su/f/.gitignore"
  (cd "$sm/su" && git init -q && git add f/a.txt f/.gitignore) >/dev/null 2>&1
  sc_unrg() { local ok=1 m
    for m in 000 100; do chmod $m "$sm/su/f/un"; chmod 000 "$sm/su/f/ig"
      sc_rc "$1" 2 'unreadable source' m64 single su -- && grep -q 'su/f/un' "$tmp/log_mu_m64.err" && untouched mu_m64 || ok=0
      AFLAGS=--strict-tracked sc_rc "$1" 2 'unreadable source' m65 single su -- || ok=0
    done
    chmod 755 "$sm/su/f/un"; chmod 000 "$sm/su/f/ig"      # now only the IGNORED directory is unreadable: junk, skipped
    sc_rc "$1" 0 - m66 single su -- && [[ ! -e "$tmp/mu_m66/dest/ig" ]] || ok=0
    chmod 755 "$sm/su/f/ig"; chmod 755 "$sm/su/f/un"; [[ $ok -eq 1 ]]; }
  green sc_unrg && pass "git path: an untracked unreadable directory (000 and 0100) is exit 2, also under --strict-tracked; an ignored one is skipped" || fail "git unreadable untracked" "rc=$rc $(head -c 200 "$tmp/log_mu_m64.err")"
else sc_unrg() { return 0; }; fi

# W: no crash with stdout closed or full; the tree is complete, so exit 0
sc_nostdout() { local d="$tmp/so_x"; chmod -R u+rwx "$d" 2>/dev/null; rm -rf "${d:?}"; mkdir -p "$d"; python3 -I -B "$1" --modules-dir "$sm" --dest "$d/dest" --layout single --module ra >&- 2>"$d/err"; local r=$?
  [[ $r -eq 0 && ! -s "$d/err" && -f "$d/dest/only-a" ]]; }
sc_full() { [[ -w /dev/full ]] || return 0; local d="$tmp/sf_x"; rm -rf "${d:?}"; mkdir -p "$d"; python3 -I -B "$1" --modules-dir "$sm" --dest "$d/dest" --layout single --module ra >/dev/full 2>"$d/err"; local r=$?
  [[ $r -eq 0 && ! -s "$d/err" && -f "$d/dest/only-a" ]]; }
green sc_nostdout && pass "stdout CLOSED (>&-): exit 0, silent, dest complete" || fail "stdout closed"
if [[ -w /dev/full ]]; then green sc_full && pass "stdout to /dev/full: exit 0, silent, dest complete" || fail "stdout full"; else echo "SKIPPED stdout to /dev/full: no /dev/full here"; fi

# W: any colon in an output path component is refused (NTFS stream spellings of .git)
gmod gc3 'a:b' '.git:x' '.git::$INDEX_ALLOCATION/x' 'git~1:x'
sc_colon() { sc_rc "$1" 1 'reserved' m67 single gc3 -- && local e="$tmp/log_mu_m67.err" && grep -q "'a:b' (module gc3)" "$e" && grep -q "'.git:x' (module gc3)" "$e" \
  && grep -q "INDEX_ALLOCATION" "$e" && grep -q "'git~1:x' (module gc3)" "$e" && untouched mu_m67; }
green sc_colon && pass "a colon in an output path component is refused (a:b, .git:x, .git::\$INDEX_ALLOCATION, git~1:x)" || fail "colon" "rc=$rc $(head -c 300 "$tmp/log_mu_m67.err")"

# W: a stale .assemble-* beside dest (a killed run): one stderr line naming it, the run continues, it is never deleted
sc_stale() { local d="$tmp/st_x"; chmod -R u+rwx "$d" 2>/dev/null; rm -rf "${d:?}"; mkdir -p "$d/.assemble-OLD"; python3 -I -B "$1" --modules-dir "$sm" --dest "$d/dest" --layout single --module ra >"$d/out" 2>"$d/err"; local r=$?
  [[ $r -eq 0 && -d "$d/.assemble-OLD" && -f "$d/dest/only-a" && "$(wc -l <"$d/err" | tr -d ' ')" == 1 ]] && grep -q '\.assemble-OLD' "$d/err"; }
green sc_stale && pass "a stale .assemble-* beside dest: one stderr line names it, the run succeeds, the leftover stays" || fail "stale temp"

# the golden fixture guard as a predicate, so it can be shown to REJECT a fixture that is the wrapper
fixture_ok() { # <file>: line 1 names the freeze, the rest is the original at that commit, and it is not the wrapper
  [[ -s "$1" && "$(head -n 1 "$1")" == *FROZEN* ]] || return 1
  cmp -s <(tail -n +2 "$1") "$inst" && return 1
  if git -C "$here" cat-file -e 8d911016b96ee2ec85fcdd403c6517438b9c6063 2>/dev/null; then
    cmp -s <(tail -n +2 "$1") <(git -C "$here" show 8d911016b96ee2ec85fcdd403c6517438b9c6063:scripts/instantiate-template.sh) || return 1
  fi
  return 0
}
{ echo '# FROZEN'; cat "$inst"; } >"$tmp/fx-wrapper.txt"; { echo '# FROZEN'; echo 'echo hi'; } >"$tmp/fx-other.txt"
if fixture_ok "$base" && ! fixture_ok "$inst" && ! fixture_ok "$tmp/fx-wrapper.txt" && ! { git -C "$here" cat-file -e 8d911016b96ee2ec85fcdd403c6517438b9c6063 2>/dev/null && fixture_ok "$tmp/fx-other.txt"; }; then
  pass "golden fixture guard: accepts the frozen original; rejects the wrapper, the wrapper behind a FROZEN line, and (commit reachable) any other text"
else fail "golden fixture guard"; fi

# the pairing helper: a mutant whose scenario is not green on the real tool is a FAIL "unpaired", not a verdict
sc_never() { return 1; }
meta="$(red meta-unpaired '    if len(v) > MAX_VALUE:' '    if False:' sc_never 2>&1)"
[[ "$meta" == *"FAIL mutant meta-unpaired: unpaired"* ]] && pass "pairing: a mutant whose scenario is not green on the real tool is reported unpaired" || fail "pairing helper accepts an unpaired mutant" "$meta"

# ---- mutants of this round
red link-target-reserved-off '                if rt is not None:  # TARGET-GIT:' '                if False:  # TARGET-GIT:' sc_ltgit
red link-target-casefold-off '                rt = next((c for c in tgt.split("/") if reserved(c)), None)' '                rt = next((c for c in tgt.split("/") if reserved(c) and c == c.lower()), None)' sc_ltgit
red link-target-reserved-off-monorepo '                if rt is not None:  # TARGET-GIT:' '                if False:  # TARGET-GIT:' sc_ltmono
red special-entry-off-walk '            elif env is None:  # SPECIAL-ENTRY (walk path)' '            elif env is None:  # SPECIAL-ENTRY (walk path)
                continue
            elif False:' sc_spw
red special-entry-off-git '    if suspects:  # SPECIAL-ENTRY (git path)' '    if False:  # SPECIAL-ENTRY (git path)' sc_spg
red special-entry-ignored-not-skipped '        loose = sorted(x for x in suspects if x not in skip)' '        loose = sorted(suspects)' sc_spi
[[ "$(id -u)" -ne 0 ]] && red unreadable-untracked-off-git '                if env is None or rel in needed or (rel + "/") not in ignored:' '                if env is None or rel in needed:' sc_unrg
red colon-rule-off '    return (":" in c or dotgit(c)' '    return (dotgit(c)' sc_colon
red stdout-none-guard-off '    if sys.stdout is not None:  # STDOUT-NONE' '    if True:  # STDOUT-NONE' sc_nostdout
red stale-warning-off '    if stale:  # STALE-TMP' '    if False:  # STALE-TMP' sc_stale
redw wrapper-monorepo 'exec python3 -I -B "$here/assemble.py" --layout single' 'exec python3 -I -B "$here/assemble.py" --layout monorepo' sc_wrap
redw wrapper-drops-owner '--slot="OWNER=${3-mselser95}"' '--slot="OWNER=mselser95"' sc_wrap
redw wrapper-empty-becomes-default '"SERVICE=${2-svc}"' '"SERVICE=${2:-svc}"' sc_wrap

# W6: nothing of this run is left in the temp root
tmp_after="$(tmpnames)"
new_tmp="$(comm -13 <(printf '%s\n' "$tmp_before") <(printf '%s\n' "$tmp_after"))"
[[ -z "$new_tmp" ]] && pass "no tmp* directory was left in the temp root" || fail "temp root polluted" "$(printf '%s ' $new_tmp)"
chmod 755 "$sm/ud/f/sub" 2>/dev/null

echo "$ok ok, $bad failed"
(( ok + bad > 0 )) || exit 2
(( bad == 0 ))
