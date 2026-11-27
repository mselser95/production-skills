#!/usr/bin/env bash
# assemble-parity-selftest.sh -- scripts/assemble.py --layout single must equal
# scripts/instantiate-template.sh byte for byte (contents, paths, modes), and
# must refuse what instantiate refuses. Hermetic, sequential, no network.
# ASSEMBLE=<path> runs another copy of the assembler (mutation proofs).
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
A() { python3 -I -B "${USE:-$asm}" --modules-dir "${MODS:-$mods}" "$@"; }
# files, directories AND the root ("."): mode string + path
modes() { (cd "$1" && find . -exec ls -ld {} + | awk '{print substr($1,1,10), $NF}' | LC_ALL=C sort); }

parity() { # <label> <svc> <owner> <umask>   one real-template pair per umask (reused by every check)
  local d="$tmp/$1" um="$4"
  (umask "$um"; A --dest "$d/a" --layout single --module service-go --slot "SERVICE=$2" --slot "OWNER=$3" --strict-tracked) >/dev/null 2>"$d.err" \
    || { fail "$1 assemble" "$(head -c 200 "$d.err")"; return; }
  (umask "$um"; cd "$here" && bash "$inst" "$d/b" "$2" "$3") >/dev/null 2>&1 || { fail "$1 instantiate failed"; return; }
  if diff -r "$d/a" "$d/b" >"$d.diff" 2>&1; then pass "$1 diff -r empty (umask $um)"; else fail "$1 diff -r" "$(head -c 200 "$d.diff")"; fi
  local ma mb; ma="$(modes "$d/a")"; mb="$(modes "$d/b")"
  if [[ "$ma" == "$mb" ]] && grep -q '^d.* \./cmd$' <<<"$ma" && grep -q ' \.$' <<<"$ma"; then
    pass "$1 file, directory and root modes equal (umask $um)"
  else fail "$1 modes differ (files, directories or root)" "$(diff <(modes "$d/a") <(modes "$d/b") | head -c 200)"; fi
}

parity p1 payments acme 022
parity p2 order-book some-org 002
parity p3 ledger9 acme.io 077

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
# mutant <from> <to> <out>: exact-once text replacement in a copy of the assembler (a rename makes this FAIL loudly)
mutant() {
  python3 -I - "$asm" "$1" "$2" "$3" <<'PY' || { fail "mutant marker missing: $1"; return 1; }
import sys
s = open(sys.argv[1]).read()
assert s.count(sys.argv[2]) == 1, sys.argv[2]
open(sys.argv[4], "w").write(s.replace(sys.argv[2], sys.argv[3]))
PY
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

# ---- value-grammar parity: both tools accept/refuse the same values, accepted ones are identical
mx="$tmp/mx"; mt="$mx/prod-new/template"; mkdir -p "$mx/prod-new/modules" "$mt/cmd/<SERVICE>" "$mt/scripts"
cp -R "$mods/service-go" "$mx/prod-new/modules/"
printf 'package main // <SERVICE> <OWNER>\n' >"$mt/cmd/<SERVICE>/main.go"; printf '* @<OWNER>\n' >"$mt/CODEOWNERS"
printf '#!/bin/sh\necho <SERVICE>\n' >"$mt/scripts/run.sh"; chmod 755 "$mt/scripts/run.sh"; printf '# <SERVICE>\n' >"$mt/README.md"
# directory fixtures: a 750 directory (source mode rule), an empty nested directory (dropped by both tools)
mkdir -p "$mt/docs/priv" "$mt/docs/hollow/deep"; printf 'x <SERVICE>\n' >"$mt/docs/priv/x.md"
find "$mt" -type d -exec chmod 755 {} +; chmod 750 "$mt/docs/priv"
# vp_both <label> <svc> <owner>: both tools on the fixture template under umask ${UM:-022}.
# Sets VA/VI (exit codes) and VEQ (0 only when both succeeded and trees + modes are equal).
# Overrides: VMX (fixture root), USE (assembler copy), INSTU (shell tool copy).
vp_both() {
  local d="$tmp/vp_$1" f="${VMX:-$mx}"; rm -rf "$d"; mkdir -p "$d"
  (umask "${UM:-022}"; MODS="$f/prod-new/modules" A --dest "$d/a" --layout single --module service-go --slot "SERVICE=$2" --slot "OWNER=$3") >/dev/null 2>"$d/a.err"; VA=$?
  (umask "${UM:-022}"; cd "$f" && bash "${INSTU:-$inst}" "$d/b" "$2" "$3") >/dev/null 2>"$d/b.err"; VI=$?
  VEQ=1
  if [[ $VA -eq 0 && $VI -eq 0 ]] && diff -r "$d/a" "$d/b" >/dev/null && [[ "$(modes "$d/a")" == "$(modes "$d/b")" ]]; then VEQ=0; fi
}
vparity() { # <label> <expect ok|refuse> <svc> <owner>
  vp_both "$1" "$3" "$4"
  local da=refuse di=refuse; [[ $VA -eq 0 ]] && da=ok; [[ $VI -eq 0 ]] && di=ok
  if [[ "$da" != "$2" || "$di" != "$2" ]]; then fail "value $1" "expected $2, assembler=$da template=$di"
  elif [[ "$2" == ok && $VEQ -ne 0 ]]; then fail "value $1" "accepted by both but trees differ"
  else pass "value $1: both tools $2"; fi
}
long65="$(printf 'z%.0s' $(seq 1 65))"
# end to end (both real tools, trees compared) for a few values; the WHOLE list is compared below in ONE python
# process (the assembler's own check_value) and ONE shell loop (the shell tool's own valid_value)
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
vv="$(sed -n '/^valid_value()/,/^}/p' "$inst")"; eval "$vv"
vsh=""; for v in "${okv[@]}" "${badv[@]}"; do if valid_value "$v"; then vsh+="1"; else vsh+="0"; fi; done

# ======================= round 2: umask matrix, fixed slot options, signals, folds =======================
# ---- B3: directory modes. Rule: dir = (source dir & ~umask) | u+w, root 0777 & ~umask (cp -R does the same)
for um in 002 077; do UM=$um vp_both "um$um" um acme
  mu="$(modes "$tmp/vp_um$um/a")"
  if [[ $VEQ -eq 0 ]] && grep -q ' \./docs/priv$' <<<"$mu"; then pass "fixture parity under umask $um: files, directories (750 docs/priv) and root equal"
  else fail "fixture parity umask $um" "VA=$VA VI=$VI $(diff <(modes "$tmp/vp_um$um/a") <(modes "$tmp/vp_um$um/b") | head -c 160)"; fi
done
UM=022 vp_both um022 um acme
[[ $VEQ -eq 0 && ! -e "$tmp/vp_um022/a/docs/hollow" && ! -e "$tmp/vp_um022/b/docs/hollow" ]] && pass "empty source directories are dropped by BOTH tools (docs/hollow/deep)" || fail "empty directory rule" "VA=$VA VI=$VI"
mz="$tmp/mz"; cp -R "$mx" "$mz"; chmod 1750 "$mz/prod-new/template/docs/priv"
VMX="$mz" vp_both st1 s acme
sa="$(modes "$tmp/vp_st1/a")"; sb="$(modes "$tmp/vp_st1/b")"
[[ $VEQ -eq 0 ]] && grep -Eq '^d.{8}[^tT] \./docs/priv$' <<<"$sa" && grep -Eq '^d.{8}[^tT] \./docs/priv$' <<<"$sb" && pass "sticky source directory: both tools clear the bit and agree" || fail "sticky directory" "VA=$VA VI=$VI"

# ---- W6: special bits refused by both tools; exclude globs
my="$tmp/my"; cp -R "$mx" "$my"; chmod 4755 "$my/prod-new/template/scripts/run.sh"
VMX="$my" vp_both sp1 s acme
if [[ $VA -eq 1 && $VI -eq 1 ]] && grep -q 'run.sh' "$tmp/vp_sp1/a.err" && grep -q 'run.sh' "$tmp/vp_sp1/b.err" && [[ ! -e "$tmp/vp_sp1/a" ]]; then pass "setuid source file: both tools exit 1 naming it"
else fail "setuid file" "VA=$VA VI=$VI"; fi
chmod 1755 "$my/prod-new/template/scripts/run.sh"; VMX="$my" vp_both sp2 s acme
[[ $VA -eq 1 && $VI -eq 1 ]] && pass "sticky source file: both tools exit 1" || fail "sticky file" "VA=$VA VI=$VI"
mbatch excl-dotdot "{\"id\":\"bm\",\"source\":\"f\",$P,\"exclude\":[\"../x\"]}" "'exclude'"
mbatch excl-abs "{\"id\":\"bm\",\"source\":\"f\",$P,\"exclude\":[\"/x\"]}" "'exclude'"

# ---- B1: pattern is gone; the old ReDoS input exits 2 fast; 65 chars refused by both tools
mkmod rx '{"id":"rx","source":"f","slots":{"NAME":{"description":"n","pattern":"(a+)+$"}},"placement":{"**":"root"}}'; mkdir -p "$sm/rx/f"; echo '<NAME>' >"$sm/rx/f/t"
t0=$(date +%s); run rx1 single rx -- NAME=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-; t1=$(date +%s)
[[ $rc -eq 2 ]] && grep -q 'pattern' "$tmp/rx1.err" && (( t1 - t0 <= 1 )) && pass "manifest with a regex pattern: exit 2 naming the key, no regex ever runs (ReDoS input fast)" || fail "pattern key" "rc=$rc t=$((t1 - t0))s $(head -c 160 "$tmp/rx1.err")"
run lv1 single esc -- "SERVICE=$long65"
[[ $rc -eq 2 ]] && grep -q 'cap is 64' "$tmp/lv1.err" && pass "65-character value: exit 2 naming the cap" || fail "length cap" "rc=$rc $(head -c 160 "$tmp/lv1.err")"
run lv2 single esc -- "SERVICE=$(printf 'z%.0s' $(seq 1 64))"; [[ $rc -eq 0 ]] && pass "64-character value accepted" || fail "64 chars" "rc=$rc"
(cd "$mx" && bash "$inst" "$tmp/lvs" "$long65" acme) >/dev/null 2>"$tmp/lvs.err"; rc=$?
[[ $rc -eq 2 ]] && grep -q 'outside the value grammar' "$tmp/lvs.err" && [[ ! -e "$tmp/lvs" ]] && pass "shell tool: 65-character value exit 2, nothing written" || fail "shell cap" "rc=$rc"
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

# ---- W4: an explicit empty value is an error in both tools; an omitted argument keeps its default
run em1 single esc -- SERVICE=; [[ $rc -eq 2 ]] && pass "assemble: empty --slot value exit 2" || fail "empty slot" "rc=$rc"
(cd "$mx" && bash "$inst" "$tmp/em2" "" acme) >/dev/null 2>&1; r1=$?
(cd "$mx" && bash "$inst" "$tmp/em3" svc "") >/dev/null 2>&1; r2=$?
(cd "$mx" && bash "$inst" "$tmp/em4") >/dev/null 2>&1; r3=$?
if [[ $r1 -eq 2 && $r2 -eq 2 && $r3 -eq 0 && -f "$tmp/em4/cmd/svc/main.go" && ! -e "$tmp/em2" && ! -e "$tmp/em3" ]]; then pass "shell tool: empty service/owner exit 2; omitted arguments keep the defaults"
else fail "shell empty vs omitted" "$r1/$r2/$r3"; fi

# ---- M4: byte >= 0x80 under a Latin-1 locale (the class is enumerated, so the locale cannot widen it)
lat=""; for l in de_DE.ISO8859-1 de_DE.iso88591 en_US.ISO8859-1; do [[ " $(locale -a 2>/dev/null | tr 'A-Z\n' 'a-z ') " == *" $(tr 'A-Z' 'a-z' <<<"$l") "* ]] && { lat="$l"; break; }; done
if [[ -n "$lat" ]]; then
  (cd "$mx" && LC_ALL="$lat" LANG="$lat" bash "$inst" "$tmp/lat" $'a\xe9' acme) >/dev/null 2>&1; rc=$?
  [[ $rc -eq 2 && ! -e "$tmp/lat" ]] && pass "shell tool under $lat: byte 0xE9 refused, exit 2" || fail "latin-1 locale" "rc=$rc"
else echo "SKIPPED shell tool under a Latin-1 locale: no ISO8859-1 locale installed; the equivalent check follows (no range in the class)"; fi
if grep -Eq '[A-Za-z0-9]-[A-Za-z0-9]' <<<"$vv"; then fail "valid_value uses a locale-dependent character range"
else pass "valid_value has no character range (bytewise by construction, locale independent)"; fi

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

# ---- W1: link targets are validated by their OUTPUT location, the target is never substituted
mkmod lk '{"id":"lk","source":"f","slots":{"SERVICE":"s"},"placement":{"**":"unit"}}'; mkdir -p "$sm/lk/f"; ln -s ../../x "$sm/lk/f/L"
run lk1 monorepo lk -- SERVICE=svc
if [[ $rc -eq 0 && "$(readlink "$tmp/lk1/services/svc/L")" == ../../x ]]; then pass "link ../../x placed under services/svc stays inside dest: accepted, target not substituted"
else fail "output-based link (inside)" "rc=$rc $(head -c 160 "$tmp/lk1.err")"; fi
rm "$sm/lk/f/L"; ln -s ../../../x "$sm/lk/f/L"
run lk2 monorepo lk -- SERVICE=svc
[[ $rc -eq 1 ]] && grep -q 'link: services/svc/L -> ../../../x' "$tmp/lk2.err" && [[ ! -e "$tmp/lk2" ]] && pass "link leaving dest from its OUTPUT location refused" || fail "output-based link (escape)" "rc=$rc $(head -c 160 "$tmp/lk2.err")"
mkdir -p "$sm/lk/f/d"; rm "$sm/lk/f/L"; ln -s ../../x "$sm/lk/f/d/L"
run lk3 single lk -- SERVICE=svc
[[ $rc -eq 1 ]] && grep -q 'link: d/L' "$tmp/lk3.err" && pass "link d/L -> ../../x leaves dest in layout single: refused" || fail "link depth" "rc=$rc"

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

# ---- mutants of this round: each guard removed in a copy must turn its case RED
# red <label> <from> <to> <scenario-function>  (the scenario returns 0 when the guard holds; the real tool must pass it)
red() {
  local lb="$1" f="$tmp/mr-$1.py"
  mutant "$2" "$3" "$f" || return
  "$4" "$asm" || { fail "mutant $lb: the scenario does not pass on the real tool"; return; }
  if "$4" "$f"; then fail "mutant $lb stayed GREEN"; else pass "mutant $lb: RED"; fi
}
redk() { # like red, for a scenario whose IDENTICAL invocation already passed on the real tool in a case above
  local lb="$1" f="$tmp/mr-$1.py"
  mutant "$2" "$3" "$f" || return
  if "$4" "$f"; then fail "mutant $lb stayed GREEN"; else pass "mutant $lb: RED"; fi
}
redsh() { # same for the shell tool: <label> <from> <to> <scenario(tool-path)>
  local lb="$1" f="$tmp/mr-$1.sh"
  python3 -I - "$inst" "$2" "$3" "$f" <<'PY' || { fail "shell mutant marker missing: $2"; return; }
import sys
s = open(sys.argv[1]).read(); assert s.count(sys.argv[2]) == 1, sys.argv[2]
open(sys.argv[4], "w").write(s.replace(sys.argv[2], sys.argv[3]))
PY
  "$4" "$inst" || { fail "shell mutant $lb: the scenario does not pass on the real tool"; return; }
  if "$4" "$f"; then fail "shell mutant $lb stayed GREEN"; else pass "shell mutant $lb: RED"; fi
}
redshk() { # like redsh, for a scenario whose identical invocation already passed on the real tool above
  local lb="$1" f="$tmp/mr-$1.sh"
  python3 -I - "$inst" "$2" "$3" "$f" <<'PY' || { fail "shell mutant marker missing: $2"; return; }
import sys
s = open(sys.argv[1]).read(); assert s.count(sys.argv[2]) == 1, sys.argv[2]
open(sys.argv[4], "w").write(s.replace(sys.argv[2], sys.argv[3]))
PY
  if "$4" "$f"; then fail "shell mutant $lb stayed GREEN"; else pass "shell mutant $lb: RED"; fi
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
sc_dirmode(){ local d="$tmp/vp_m21"; rm -rf "${d:?}"; mkdir -p "$d"   # the assembler alone, against the shell tool's tree from the umask-002 case above
  (umask 002; MODS="$mx/prod-new/modules" USE="$1" A --dest "$d/a" --layout single --module service-go --slot SERVICE=um --slot OWNER=acme) >/dev/null 2>&1 \
    && diff -r "$d/a" "$tmp/vp_um002/b" >/dev/null && [[ "$(modes "$d/a")" == "$(modes "$tmp/vp_um002/b")" ]]; }
sc_wesc()   { local o; o="$(USE="$1" direct esc)"; [[ "$o" == REFUSED* ]]; }
sc_wexcl()  { local o; o="$(USE="$1" direct excl)"; [[ "$o" == REFUSED* ]]; }
sc_sigterm(){ local d="$tmp/sg_m" r; rm -rf "$d"; mkdir -p "$d"; (ulimit -c 0; python3 -I -B "$tmp/direct.py" "$1" sig:SIGTERM "$d/dest" "$sm" >/dev/null 2>"$d/err"); r=$?
  [[ $r -eq 143 && "$(cat "$d/err")" == "assemble: interrupted -- nothing written" && "$(ls -A "$d")" == err ]]; }
mkmod lc2x '{"id":"lc2x","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/lc2x/f"; ln -s /outside "$sm/lc2x/f/d2"
mkmod lkm '{"id":"lkm","source":"f","slots":{"SERVICE":"s"},"placement":{"**":"unit"}}'; mkdir -p "$sm/lkm/f"; ln -s ../../x "$sm/lkm/f/L"
mkmod sx '{"id":"sx","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/sx/f"; echo z >"$sm/sx/f/z"; chmod 4755 "$sm/sx/f/z"
mkdir -p "$sm/bm/f"; echo x >"$sm/bm/f/a"
red grammar-search 'VALUE_RX.fullmatch(v) is None' 'VALUE_RX.search(v) is None' sc_match
red grammar-service-only '    for k, v in slots.items():
        check_value(k, v)' '    for k, v in slots.items():
        if k == "SERVICE": check_value(k, v)' sc_owner
redk prefix-files-only '            if pre is not None:' '            if pre is not None and plan[pre]["kind"] == "file":' sc_linkpre
red link-target-check 'if os.path.isabs(tgt) or "\0" in tgt or norm == ".." or norm.startswith("../"):' 'if False:' sc_linkchk
redk requires-off '            if r not in chosen:' '            if False:' sc_req
redk conflicts-off '            if c in chosen:' '            if False:' sc_conf
redk unknown-key-tolerated '    if unknown:' '    if False:' sc_unk
redk id-mismatch-tolerated '    if m["id"] != mid:' '    if False:' sc_idm
redk strict-ignores-untracked '        stray = git_list(src, env, True)
        if stray:' '        stray = git_list(src, env, True)
        if False:' sc_strict
redk length-cap-off '    if len(v) > MAX_VALUE:' '    if False:' sc_cap
red charset-off '            if k in slots and not charset_ok(cs, slots[k]):' '            if False:' sc_cset
red max-len-off '            if k in slots and len(slots[k]) > n:' '            if False:' sc_mlen
red dupkeys-off '        if k in d:' '        if False:' sc_dup
redk source-rule-off '        if not (real_src == real_mod or' '        if False and not (real_src == real_mod or' sc_src
red literal-slash-off '            if "/" in v["literal"] or "\0" in v["literal"]:' '            if False:' sc_litslash
red exclude-dotdot-off '        if ".." in g or g.startswith("/") or "\0" in g:' '        if False:' sc_excl
redk fold-identity '    return unicodedata.normalize("NFC", unicodedata.normalize("NFC", p).casefold())' '    return p' sc_fold
red link-by-source-path 'posixpath.normpath(posixpath.join(posixpath.dirname(out), tgt))' 'posixpath.normpath(posixpath.join(posixpath.dirname(rel), tgt))' sc_lnkout
redk placeholders-unsorted 'key=lambda kv: (-len(kv[1]), kv[1])' 'key=lambda kv: kv[1]' sc_order
red special-bits-off '                if st.st_mode & SPECIAL:' '                if False:' sc_special
redk dir-mode-ignores-source 'dir_modes[od] = (dstat[sd] & ~umask) | stat.S_IWUSR' 'dir_modes[od] = (0o777 & ~umask) | stat.S_IWUSR' sc_dirmode
redk write-escape-off '    for out in sorted(plan):
        if escapes(tmp, out):' '    for out in sorted(plan):
        if False:' sc_wesc
redk write-excl-to-trunc 'os.O_CREAT | os.O_EXCL | nofollow' 'os.O_CREAT | os.O_TRUNC | nofollow' sc_wexcl
redk sigterm-unhandled '("SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT")' '("SIGINT", "SIGHUP", "SIGQUIT")' sc_sigterm
sh_empty() { (cd "$mx" && bash "$1" "$tmp/shm_e" "" acme) >/dev/null 2>&1; local r=$?; rm -rf "$tmp/shm_e"; [[ $r -eq 2 ]]; }
sh_cap()   { (cd "$mx" && bash "$1" "$tmp/shm_c" "$long65" acme) >/dev/null 2>&1; local r=$?; rm -rf "$tmp/shm_c"; [[ $r -eq 2 ]]; }
sh_empdir(){ INSTU="$1" vp_both m22 um acme; [[ $VEQ -eq 0 ]]; }
sh_stkdir(){ INSTU="$1" VMX="$mz" vp_both m23 s acme; [[ $VEQ -eq 0 ]]; }
sh_special(){ INSTU="$1" VMX="$my" vp_both m24 s acme; [[ $VI -eq 1 ]]; }
redsh shell-empty-defaults '(( $# >= 2 )) && svc="$2"' 'svc="${2:-svc}"' sh_empty
redsh shell-length-cap '  (( ${#1} <= 64 )) && [[ "$1" =~ $re ]]' '  [[ "$1" =~ $re ]]' sh_cap
redshk shell-keeps-empty-dirs '(cd "$dest" && find . -mindepth 1 -depth -type d -empty -exec rmdir {} \;) || exit 2' ':' sh_empdir
redshk shell-keeps-sticky-dir-bit 'chmod -R u+w,u-s,g-s,-t "$dest"' 'chmod -R u+w "$dest"' sh_stkdir
redshk shell-accepts-setuid-file 'if [[ -n "$special" ]]; then' 'if false; then' sh_special


# ======================= round 4: .git, unreadable sources, cleanup, links, modes =======================
# the whole value list through BOTH tools' own checks (one python process, one shell loop)
vpy="$(direct vals "$vals")"
if [[ "$vpy" == "$vexp " && "$vsh" == "$vexp" ]]; then pass "value grammar: ${#okv[@]} accepted + ${#badv[@]} refused values, assembler and shell tool agree on every one"
else fail "value grammar differs" "expected $vexp / assembler ${vpy% } / shell $vsh"; fi
sc_vals() { [[ "$(USE="$1" direct vals "$vals")" == "$vexp " ]]; }
sc_names() { [[ "$(USE="$1" direct names)" == "OK " ]]; }
sc_names "$asm" && pass "reserved(): .git in any case/form, trailing dot or space, git~1 refused; .github .gitignore .gitattributes .gitkeep .gitmodules .git-hooks allowed" || fail "reserved()" "$(direct names)"

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
sc_gsrc "$asm" && sc_gout "$asm" || fail "git mutant scenarios do not pass on the real tool"
# the shell tool refuses the same, and the real template has none
mg="$tmp/mg"; cp -R "$mx" "$mg"
shgit() { rm -rf "${mg:?}/prod-new/template/docs/gitcase"; mkdir -p "$mg/prod-new/template/docs/gitcase/$(dirname "$1")"; echo y >"$mg/prod-new/template/docs/gitcase/$1"; VMX="$mg" vp_both gc s acme; }
for x in '.GIT/hooks/pre-commit' 'trail./x' 'sub/git~1/y'; do
  shgit "$x"
  if [[ $VA -eq 1 && $VI -eq 1 ]] && grep -Eq 'reserved|git checkout' "$tmp/vp_gc/a.err" && grep -q 'reserved' "$tmp/vp_gc/b.err" && [[ ! -e "$tmp/vp_gc/b" && ! -e "$tmp/vp_gc/a" ]]; then pass "template with $x: both tools exit 1 naming the reserved path, nothing written"
  else fail "template reserved $x" "VA=$VA VI=$VI $(head -c 120 "$tmp/vp_gc/a.err") / $(head -c 120 "$tmp/vp_gc/b.err")"; fi
done
[[ -z "$(find "$here/prod-new/template" \( -iname .git -o -iname 'git~1' -o -name '*.' -o -name '* ' \))" ]] && pass "the real template holds no reserved path component" || fail "real template has a reserved component"
sh_gitref() { INSTU="$1" shgit '.GIT/hooks/pre-commit'; [[ $VI -eq 1 ]]; }

# B2: zero files, unreadable directory / tracked file (exit 2 in BOTH tools, one line, nothing written)
mkmod zf '{"id":"zf","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/zf/f"
sc_zf() { sc_rc "$1" 1 'yields no files' m36 single zf ra --; }
sc_zf "$asm" && pass "a module that yields zero files is refused (exit 1) even when another module has files" || fail "zero files" "$(head -c 160 "$tmp/log_mu_m36.err")"
if [[ "$(id -u)" -ne 0 ]]; then
  mkmod ud '{"id":"ud","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ud/f/sub"; echo a >"$sm/ud/f/a.txt"; echo b >"$sm/ud/f/sub/b.txt"; chmod 000 "$sm/ud/f/sub"
  sc_unr() { sc_rc "$1" 2 'unreadable source' m37 single ud -- && grep -q 'ud/f/sub' "$tmp/log_mu_m37.err" && [[ "$(wc -l <"$tmp/log_mu_m37.err")" -eq 1 ]] && untouched mu_m37; }
  sc_unr "$asm" && pass "walk: a mode-000 source directory exits 2 naming it (one line), nothing written" || fail "unreadable dir" "$(head -c 200 "$tmp/log_mu_m37.err")"
  mu="$tmp/mu"; cp -R "$mx" "$mu"; chmod 000 "$mu/prod-new/template/docs/priv"
  VMX="$mu" vp_both unr s acme
  if [[ $VA -eq 2 && $VI -eq 2 ]] && grep -q 'priv' "$tmp/vp_unr/a.err" && [[ ! -e "$tmp/vp_unr/a" ]]; then pass "unreadable template directory: both tools exit 2 (assembler names it, writes nothing)"
  else fail "unreadable template dir" "VA=$VA VI=$VI $(head -c 160 "$tmp/vp_unr/a.err")"; fi
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
sc_clean "$asm" && pass "write failure + TERM at the start of the cleanup: temp dir gone, exit 1 (the failure's code), not 143" || fail "cleanup under signal" "r=$r $(head -c 200 "$DS/err") ls=$(ls -A "$DS" | tr '\n' ' ')"
sc_commit "$asm" && pass "TERM right after the rename: exit 0, complete dest, silent (never 143 with a dest present)" || fail "TERM after rename" "r=$r $(head -c 200 "$DS/err")"
sc_changed "$asm" && pass "dest-changed check with a TERM pending: exit 1 'changed while assembling', not 143" || fail "original cause wins" "r=$r $(head -c 200 "$DS/err")"
sc_bp "$asm" && pass "stdout closed early (BrokenPipe) after success: exit 0, no message, dest complete" || fail "broken pipe" "r=$r $(head -c 200 "$DS/err")"
MODS="$sm" A --dest "$tmp/pipe1" --layout single --module ra 2>"$tmp/pipe1.err" | head -0; prc=${PIPESTATUS[0]}
[[ $prc -eq 0 && ! -s "$tmp/pipe1.err" && -f "$tmp/pipe1/only-a" ]] && pass "real pipe to 'head -0': exit 0, silent, dest complete" || fail "real broken pipe" "rc=$prc $(head -c 200 "$tmp/pipe1.err")"
sc_quit "$asm" && pass "signal SIGQUIT: exit 131, one line, nothing left" || fail "SIGQUIT"

# B4: umask 0777 (mkdtemp yields a mode-000 directory) and read-only trees
mkmod ldn '{"id":"ldn","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ldn/f/d"; echo x >"$sm/ldn/f/d/x"
sc_mk700()  { UMK=0777 sc_rc "$1" 0 - m30 single ra -- && chmod u+rwx "$tmp/mu_m30/dest" && [[ -f "$tmp/mu_m30/dest/only-a" && -z "$(find "$tmp/mu_m30" -maxdepth 1 -name '.assemble-*')" ]]; }
sc_umnest() { UMK=0777 sc_rc "$1" 1 'I/O error' m31 single ldn -- && [[ -z "$(find "$tmp/mu_m31" -maxdepth 1 -name '.assemble-*')" ]] && ! grep -q 'could not remove' "$tmp/log_mu_m31.err"; }
sc_mk700 "$asm" && pass "umask 0777: mkdtemp's mode-000 dir is opened to the owner, the run completes (exit 0), no temp dir left" || fail "umask 0777" "rc=$rc $(head -c 200 "$tmp/log_mu_m30.err")"
sc_umnest "$asm" && pass "umask 0777, nested write fails (000 directory): exit 1, the cleanup removes the unreadable tree, no .assemble-* left" || fail "umask 0777 cleanup" "rc=$rc $(head -c 200 "$tmp/log_mu_m31.err") ls=$(ls -A "$tmp/mu_m31" | tr '\n' ' ')"
# M4 / M2: directory modes, against the written-down rule (not "equal to the other tool")
mkmod rod '{"id":"rod","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/rod/f/ro"; echo x >"$sm/rod/f/ro/x"; chmod 500 "$sm/rod/f/ro"
sc_rodir()   { UMK=022 sc_rc "$1" 0 - m32 single rod -- && [[ "$(ls -ld "$tmp/mu_m32/dest/ro" | cut -c1-10)" == drwx------ ]]; }
sc_unitdir() { UMK=002 sc_rc "$1" 0 - m33 monorepo up -- SERVICE=svc && [[ "$(ls -ld "$tmp/mu_m33/dest/services" | cut -c1-10)" == drwxr-xr-x && "$(ls -ld "$tmp/mu_m33/dest/services/svc" | cut -c1-10)" == drwxr-xr-x ]]; }
sc_rodir "$asm" && pass "a 0500 source directory comes out 0700 (owner-writable: 0500 & ~umask | u+w)" || fail "u+w on directories" "rc=$rc $(ls -ld "$tmp/mu_m32/dest/ro" 2>&1 | cut -c1-10)"
sc_unitdir "$asm" && pass "monorepo services/ and services/<svc> are 0755 & ~umask | u+w under umask 002 (drwxr-xr-x), not the umask-derived 0775" || fail "unit prefix dir mode" "rc=$rc $(ls -ld "$tmp/mu_m33/dest/services" 2>&1 | cut -c1-10)"

# W1 / M1: link rules
mkmod l0 '{"id":"l0","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/l0/f"; ln -s .. "$sm/l0/f/L"
mkmod ll '{"id":"ll","source":"f","slots":{},"placement":{"**":"root"}}'; mkdir -p "$sm/ll/f/d"; ln -s .. "$sm/ll/f/d/L1"; ln -s d/L1/.. "$sm/ll/f/E"
sc_up() { sc_rc "$1" 1 'link: L -> ..' m39 single l0 --; }
sc_ll() { sc_rc "$1" 1 'passes through planned link d/L1' m38 single ll --; }
sc_up "$asm" && pass "a link at the dest root whose target is exactly '..' is refused" || fail "link to .." "rc=$rc $(head -c 200 "$tmp/log_mu_m39.err")"
sc_ll "$asm" && pass "link-through-link refused (d/L1 -> .. then E -> d/L1/..): rule = no target may pass through or end at a planned link" || fail "link through link" "rc=$rc $(head -c 200 "$tmp/log_mu_m38.err")"

# W5: macOS cp -R copies extended attributes; neither tool may
xok=0
if [[ "$(uname)" == Darwin ]] && command -v xattr >/dev/null 2>&1; then
  xset() { xattr -w parity.test 1 "$1" 2>/dev/null; }; xget() { xattr -l "$1" 2>/dev/null | grep -c 'parity.test' || true; }
elif command -v setfattr >/dev/null 2>&1; then
  xset() { setfattr -n user.paritytest -v 1 "$1" 2>/dev/null; }; xget() { getfattr -d "$1" 2>/dev/null | grep -c paritytest || true; }
else xset() { return 1; }; fi
mxa="$tmp/mxa"; cp -R "$mx" "$mxa"; xf="$mxa/prod-new/template/docs/plain.md"; echo plain >"$xf"   # no slot token: sed -i would rewrite (and so strip) a slot-bearing file's xattr
if xset "$xf" && [[ "$(xget "$xf")" == 1 ]]; then
  xok=1; VMX="$mxa" vp_both xa s acme
  [[ $VEQ -eq 0 && "$(xget "$tmp/vp_xa/a/docs/plain.md")" == 0 && "$(xget "$tmp/vp_xa/b/docs/plain.md")" == 0 ]] && pass "a source file with a user xattr: NEITHER output carries it, trees equal" || fail "xattr copied" "VEQ=$VEQ a=$(xget "$tmp/vp_xa/a/docs/plain.md") b=$(xget "$tmp/vp_xa/b/docs/plain.md")"
else echo "SKIPPED xattr parity: no xattr/setfattr tool, or this filesystem refuses a user xattr"; fi
sh_xattr() { INSTU="$1" VMX="$mxa" vp_both m40 s acme; [[ "$(xget "$tmp/vp_m40/b/docs/plain.md")" == 0 ]]; }

# mutants of this round: each guard removed in a copy must turn its scenario RED
# (the scenario has just passed on the real tool, so redk/redshk skip the second real run)
redk walk-git-source-off '            if dotgit(n):  # SOURCE-GIT: a module directory that is a git checkout' '            if False:' sc_gsrc
redk git-output-off '            if rc_ is not None:  # OUTPUT-GIT: whatever way the candidate list was obtained' '            if False:' sc_gout
redk git-casefold-off '    return fold("".join(ch for ch in c if unicodedata.category(ch) != "Cf")) == ".git"' '    return "".join(ch for ch in c if unicodedata.category(ch) != "Cf") == ".git"' sc_names
redk git-trailing-dot-space-off '    return dotgit(c) or (c not in (".", "..") and c.endswith((".", " "))) or fold(c) == "git~1"' '    return dotgit(c) or fold(c) == "git~1"' sc_names
redk value-trailing-dot-off '[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?' '[A-Za-z0-9][A-Za-z0-9._-]*' sc_vals
redk zero-files-off '        if not [r for r in cands if not (self_dir and r == "module.json")]:' '        if False:' sc_zf
[[ "$(id -u)" -ne 0 ]] && redk walk-onerror-off '    for dp, dns, fns in os.walk(src, onerror=walk_error):' '    for dp, dns, fns in os.walk(src):' sc_unr
redk cleanup-signal-mask-off '    ignore_signals()  # CLEANUP-MASK: a signal now must not abandon the removal half done' '    pass' sc_clean
redk mkdtemp-chmod-off '        os.chmod(tmp, 0o700)  # MKDTEMP-CHMOD: under umask 0777 mkdtemp yields a mode-000 directory' '        pass' sc_mk700
redk cleanup-dir-chmod-off '                    os.chmod(p, 0o700)' '                    pass' sc_umnest
redk link-through-link-off '        if via is not None:' '        if False:' sc_ll
redk link-to-dotdot-off 'or norm == ".." or norm.startswith("../")' 'or norm.startswith("../")' sc_up
redk broken-pipe-off '    except BrokenPipeError:  # the reader went away; the tree is complete, so this is success' '    except ZeroDivisionError:' sc_bp
redk sigquit-unhandled '("SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT")' '("SIGINT", "SIGTERM", "SIGHUP")' sc_quit
redk cause-wins-off '            ignore_signals()  # CAUSE-WINS: a pending signal must not replace the real failure' '            pass' sc_changed
redk commit-ignore-off '            ignore_signals()  # COMMIT-IGNORE: the tree is complete; a late signal is dropped' '            pass' sc_commit
redk unit-prefix-dir-mode-off 'dir_modes[od] = (0o755 & ~umask) | stat.S_IWUSR' 'dir_modes[od] = (0o777 & ~umask) | stat.S_IWUSR' sc_unitdir
redk dir-u-plus-w-off 'dir_modes[od] = (dstat[sd] & ~umask) | stat.S_IWUSR' 'dir_modes[od] = dstat[sd] & ~umask' sc_rodir
redshk shell-git-refusal-off 'if [[ -n "$reserved" ]]; then' 'if false; then' sh_gitref
if [[ $xok -eq 1 && "$(uname)" == Darwin ]]; then redshk shell-copies-xattrs '[[ "$(uname)" == Darwin ]] && cpflags=-RX' ':' sh_xattr
else echo "SKIPPED shell mutant shell-copies-xattrs: GNU cp does not copy xattrs, so the flag has no effect there"; fi

# W6: nothing of this run is left in the temp root
tmp_after="$(tmpnames)"
new_tmp="$(comm -13 <(printf '%s\n' "$tmp_before") <(printf '%s\n' "$tmp_after"))"
[[ -z "$new_tmp" ]] && pass "no tmp* directory was left in the temp root" || fail "temp root polluted" "$(printf '%s ' $new_tmp)"
chmod 755 "$sm/ud/f/sub" 2>/dev/null

echo "$ok ok, $bad failed"
(( ok + bad > 0 )) || exit 2
(( bad == 0 ))
