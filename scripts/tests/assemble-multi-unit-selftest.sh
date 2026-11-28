#!/usr/bin/env bash
# assemble-multi-unit-selftest.sh -- scripts/assemble.py builds a monorepo with MORE THAN ONE unit
# (--unit MODULE:ID[,K=V...]). Scratch modules in a temp --modules-dir; the real service-go only for the
# non-regression diff against the previous assembler and the wrapper. Hermetic, sequential, no network.
# ASSEMBLE=<path> runs another copy of the assembler (mutation proofs). Exit: 0 ok - 1 a case failed - 2 no case ran.
# --print-golden prints the frozen-digest fixture (scripts/tests/fixtures/assemble-golden-d020897.txt) from the current assembler.
# Final line: "<N> ok, <M> failed[, K skipped]".
# derived-from: the assemble.py header (UNIT INSTANCES, REPO INVENTORY, DECLARED UNITS) -- candidate, pinning: false, ttl: 2027-06-30
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

# Refusal cases that only check exit code + message are QUEUED (rq) and run in ONE python process that calls the
# assembler's main() in-process, each in a fresh temp dir (the cheap path: ~90 interpreters cost 20+ s of CPU).
# Cases that need a real process (signals, the wrapper, golden digests, content checks) keep `run`.
res="$tmp/res"; qf="$tmp/queue"; mkdir -p "$res"; : >"$qf"; qn=()
cat >"$tmp/batch.py" <<'PY'
import io, os, re, shutil, sys, tempfile
asm, mods, res, qf, base = sys.argv[1:6]
recs, cur = [], []
for f in open(qf, "rb").read().split(b"\0")[:-1]:
    f = f.decode("utf-8", "surrogateescape")
    if f == "\x01END":
        recs.append(cur)
        cur = []
    else:
        cur.append(f)
code = compile(open(asm, encoding="utf-8").read(), asm, "exec")
for desc, name, want, pat, *args in recs:
    work = tempfile.mkdtemp(prefix="c-", dir=base)
    ns = {"__name__": "assemble_inproc", "__file__": asm}
    exec(code, ns)
    old = sys.argv, sys.stderr, sys.stdout
    sys.argv = ["assemble.py", "--modules-dir", mods, "--dest", os.path.join(work, "d")] + args
    sys.stderr = sys.stdout = io.StringIO()
    try:
        ns["main"]()
        rc = 0
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    finally:
        err = sys.stderr.getvalue()
        sys.argv, sys.stderr, sys.stdout = old
    why = ""
    if rc != int(want):
        why = "exit %d, want %s: %s" % (rc, want, err[:200])
    elif pat != "-" and not re.search(pat, err):
        why = "stderr lacks /%s/: %s" % (pat, err[:200])
    elif int(want) != 0 and os.listdir(work):
        why = "something was left behind: %s" % os.listdir(work)
    shutil.rmtree(work, ignore_errors=True)
    open(os.path.join(res, name), "w").write("bad" if why else "ok")
    if why:
        print("FAIL %s -- %s" % (name, why))
    elif desc != "-":
        print("ok   " + desc)
PY
flushq() {   # run every queued case in one process; count and echo their results
  [[ -s "$qf" ]] || return 0
  local line
  while IFS= read -r line; do
    case "$line" in "ok   "*) ok=$((ok + 1)) ;; FAIL*) bad=$((bad + 1)) ;; esac
    echo "$line"
  done < <(python3 -I -B "$tmp/batch.py" "$asm" "$mods" "$res" "$qf" "$tmp" 2>&1)
  : >"$qf"
}
# rq <description|-> <name> <rc> <stderr-grep|-> <args...>: queue one case ("-" = silent, judged later by qok)
rq() {
  local desc="$1" name="$2"; shift 2
  [[ "$desc" == - ]] && qn+=("$name")
  printf '%s\0' "$desc" "$name" "$@" $'\x01END' >>"$qf"
}
qok() {   # every silent case queued since the last qok passed
  flushq
  local x r=0
  for x in ${qn[@]+"${qn[@]}"}; do [[ "$(cat "$res/$x" 2>/dev/null)" == ok ]] || r=1; done
  qn=()
  return $r
}

# mk <id> <json-without-id/source> <file>...: a scratch module (source "."), files as path=content (\n expanded)
mk() {
  local id="$1" json="$2" f; shift 2
  flushq
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
mkr() { mk "$1" "$RS" "repo.yaml=$2"; }   # mkr <module> <repo.yaml content>
mkr rrdup 'repo: <REPO>\nunits: []\nunits: 1\n'
mkr rrmap 'repo: <REPO>\nunits: []\nunits: {x: 1}\n'
mkr rrdoc 'a: 1\n---\nunits: []\n'
mkr rrdocb 'a: 1\n--- |\nunits: []\n'
mkr rrquote 'k: "abc\nunits: []\n"\n'
mkr rrflow 'k: {\nunits: []\n}\n'
mkr rrcrlf 'repo: <REPO>\r\nunits: []\r\n'
mkr rrbom '\xef\xbb\xbfrepo: <REPO>\nunits: []\n'
mkr rrtab 'repo:\t<REPO>\nunits: []\n'
mkr rrnonl 'repo: <REPO>\nunits: []'
mkr rrbare 'a:\nunits: []\n'
mkr rrorph '  b: 1\nunits: []\n'
mkr rrtrail 'repo: <REPO> # note\nunits: []\n'
mkr rranchor 'a: &x 1\nunits: []\n'
mkr rrkey 'a: 1\na: 2\nunits: []\n'
mkr rrchild 'a:\n  b: 1\n  b: 2\nunits: []\n'
mkr rrblock 'a: |\n  text\nunits: []\n'
mkr rrls 'a: 1\n# x\xe2\x80\xa8units: {z: 1}\nunits: []\n'
mkr rrok 'version: v2\nrepo:\n  name: <REPO>\n  layout: monorepo\n\n# note: here\nq: "a: b # c"\nunits: []\n'

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
rq "2: slot missing for one instance: exit 2, instance named" c2a 2 'svcx\[b\].*EXTRA' --layout monorepo --unit svcx:a,EXTRA=1 --unit svcx:b --slot OWNER=o
rq "2: overriding the unit slot: exit 2" c2b 2 'unit slot' --layout monorepo --unit svc:a,SERVICE=z --slot OWNER=o
rq "2: slot the module does not declare: exit 2" c2c 2 'does not declare slot NOPE' --layout monorepo --unit svc:a,NOPE=z --slot OWNER=o
rq "2: module narrowing (charset) applies to the unit id" c2d 2 'charset' --layout monorepo --unit svcnarrow:Abc --slot OWNER=o

# 3. duplicate / case-only / equal dirs: exit 2, nothing written
rq "3: duplicate id refused" c3a 2 'same id' --layout monorepo --unit svc:a --unit svc:a --slot OWNER=o
rq "3: ids differing only by case refused" c3b 2 'same id' --layout monorepo --unit svc:foo --unit svc:FOO --slot OWNER=o
rq "3: same id in two modules refused" c3c 2 'same id' --layout monorepo --unit svc:a --unit svcnk:A --slot OWNER=o
rq "3: two instances with equal unit dirs (database kind) refused" c3d 2 'share the unit directory' --layout monorepo --unit dbm:x --unit dbm:y --slot OWNER=o
rq "3: layout single: two units share the root, refused" c3e 2 'share the unit directory' --layout single --unit svc:a --unit svc:b --slot OWNER=o
rq "3: --module and --unit at one dir refused" c3f 2 'share the unit directory' --layout monorepo --module svc --unit svc:b --slot SERVICE=b --slot OWNER=o
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
cat >"$tmp/dig.py" <<'PY'
import hashlib, os, stat, subprocess, sys
asm, mods, mod, lay, dest = sys.argv[1:6]
slots = ["--slot", "SERVICE=payments", "--slot", "OWNER=acme"]
if mod == "service-python":
    slots += ["--slot", "PACKAGE=paylib"]
r = subprocess.run([sys.executable, "-I", "-B", asm, "--modules-dir", mods, "--dest", dest, "--layout", lay, "--module", mod] + slots,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
if r.returncode:
    sys.exit("assemble failed for %s/%s: %s" % (mod, lay, r.stderr.decode()[:200]))
lines, n = [], 0
for dp, dns, fns in os.walk(dest):
    for name in dns + fns:
        full = os.path.join(dp, name); rel = os.path.relpath(full, dest); st = os.lstat(full)
        if stat.S_ISDIR(st.st_mode):
            lines.append("%s\t%o\td" % (rel, stat.S_IMODE(st.st_mode)))
        else:
            n += 1
            data = os.readlink(full).encode() if stat.S_ISLNK(st.st_mode) else open(full, "rb").read()
            lines.append("%s\t%o\t%s" % (rel, stat.S_IMODE(st.st_mode), hashlib.sha256(data).hexdigest()))
print("%s %s %d %s" % (mod, lay, n, hashlib.sha256("\n".join(sorted(lines)).encode()).hexdigest()))
PY
gold="$here/scripts/tests/fixtures/assemble-golden-d020897.txt"
golden_lines() {
  local m l
  for m in service-go service-rust service-python; do for l in single monorepo; do
    python3 -I -B "$tmp/dig.py" "$asm" "$here/prod-new/modules" "$m" "$l" "$tmp/g-$m-$l" || return 1
  done; done
}
if [[ "${1:-}" == --print-golden ]]; then head -n 1 "$gold"; golden_lines; exit $?; fi

# 4. --module and --unit mixed; --module alone equals --unit; the real modules' output is FROZEN (digests of d020897)
if python3 -I -B "$asm" --modules-dir "$here/prod-new/modules" --dest "$tmp/nm" --layout monorepo --module service-go --slot SERVICE=payments --slot OWNER=acme >/dev/null 2>&1 \
  && python3 -I -B "$asm" --modules-dir "$here/prod-new/modules" --dest "$tmp/nu" --layout monorepo --unit service-go:payments --slot OWNER=acme >/dev/null 2>&1 \
  && diff -r "$tmp/nm" "$tmp/nu" >/dev/null 2>&1; then pass "4: real service-go: --unit service-go:payments equals --module"
else fail "4: --unit vs --module on the real service-go"; fi
got="$(golden_lines 2>&1)"; want="$(grep -v '^#' "$gold")"
if [[ "$got" == "$want" && -n "$want" ]]; then
  pass "4: service-go, service-rust, service-python x single/monorepo: tree, modes and contents equal the frozen digests of d020897 ($(echo "$want" | wc -l | tr -d ' ') digests)"
else fail "4: frozen digests differ (module layout files sha256), < frozen > now" "$(diff <(echo "$want") <(echo "$got") | head -n 6 | tr '\n' '|') -- if a module changed on purpose, regenerate: bash scripts/tests/assemble-multi-unit-selftest.sh --print-golden > scripts/tests/fixtures/assemble-golden-d020897.txt"; fi

# 5. root files from several instances
run c5a 0 - --layout monorepo --unit svcm:a --unit svcm:b --slot OWNER=o && has "$D/.gitignore" $'common\na-bin\nb-bin' && pass "5: root_merge union-lines by every contributor: merged once, no repeated line" || fail "5: merge" "$(cat "$D/.gitignore" 2>/dev/null | tr '\n' '|')"
run c5b 1 'ci\.yml.*svcci\[a\].*svcci\[b\]|ci\.yml.*svcci\[b\].*svcci\[a\]' --layout monorepo --unit svcci:a --unit svcci:b --slot OWNER=o && grep -q 'per-unit file at the root' "$out/c5b.err" && pass "5: slot-dependent root file from two instances: exit 1, path and both unit ids named, per-unit message" || fail "5: conflict message" "$(head -c 200 "$out/c5b.err")"
run c5c 0 - --layout monorepo --unit svcci:a --slot OWNER=o && has "$D/ci.yml" "name: ci a" && pass "5: the same module once is no conflict" || true

# 6. every security rule per instance
zw="$(printf 'a\xe2\x80\x8bb')"
n=0
for id in .git .GIT a. "$zw" 'git~1' a:b '.git:x' 'a b'; do
  n=$((n + 1))
  rq - "c6id$n" 2 - --layout monorepo --unit svc:ok --unit "svc:$id" --slot OWNER=o
done
qok && pass "6: a unit id that is or reaches .git (any case, trailing dot, zero-width, git~1, colon) or has a space: exit 2, nothing written" || fail "6: reserved unit ids"
n=0
for v in .. /abs a/b ../x; do
  n=$((n + 1))
  rq - "c6sl$n" 2 - --layout monorepo --unit svc:a,OWNER="$v" --slot OWNER=o
done
qok && pass "6: a per-instance slot value escaping the unit dir (.., absolute, with /): exit 2, nothing written" || fail "6: slot escape"
rq "6: a link from one unit into another unit's directory: refused (exit 1), nothing written" c6l 1 'couples' --layout monorepo --unit lnk:a --unit lnk:b --slot OWNER=o
rq "6: a link that leaves its unit for the repo root: refused (exit 1)" c6k 1 'outside the unit directory' --layout monorepo --unit lnkok:a --unit lnkok:b --slot OWNER=o
mk lnkin "$SL,\"placement\":{\"README.md\":\"unit\",\"ln.txt\":\"unit\"}" 'README.md=<SERVICE>\n'
ln -s README.md "$mods/lnkin/ln.txt"
run c6m 0 - --layout monorepo --unit lnkin:a --unit lnkin:b --slot OWNER=o && [[ -L "$D/services/a/ln.txt" && -L "$D/services/b/ln.txt" ]] && pass "6: a link inside its own unit stays allowed (control of the link cases)" || fail "6: link control"
for t in .. ../..; do
  tn="${t//\//}"; tn="${tn//./d}"
  mk lnkanc "$SL,\"placement\":{\"README.md\":\"unit\",\"l\":\"unit\"}" 'README.md=<SERVICE>\n'
  rm -f "$mods/lnkanc/l"; ln -s "$t" "$mods/lnkanc/l"
  run "c6anc$tn" 1 'outside the unit directory' --layout monorepo --unit lnkanc:a --unit lnkanc:b --slot OWNER=o && pass "6: a unit link to an ANCESTOR ($t), which reaches the other unit through it: refused" || true
done
mk lnkanc "$SL,\"placement\":{\"README.md\":\"unit\",\"l\":\"unit\"}" 'README.md=<SERVICE>\n'
rm -f "$mods/lnkanc/l"; ln -s . "$mods/lnkanc/l"
run c6anc0 0 - --layout monorepo --unit lnkanc:a --unit lnkanc:b --slot OWNER=o && pass "6: a unit link to its own directory (.) is allowed (control of the ancestor cases)" || true
run c6sg 0 - --layout single --unit lnkin:a --slot OWNER=o && [[ -L "$D/ln.txt" ]] && pass "6: layout single: the link rule is unchanged (the unit dir is the root)" || fail "6: single link"

# 7. repo.yaml inventory
want="$(printf '# header\nversion: v2\nrepo:\n  name: demo\n  layout: monorepo\nunits:\n  - { id: "main", kind: "database", language: "sql", path: "db" }\n  - { id: "ui", kind: "package", language: "ts", path: "packages/ui" }\n  - { id: "a", kind: "service", language: "go", path: "services/a" }\n  - { id: "b", kind: "service", language: "go", path: "services/b" }')"
if run c7a 0 - --layout monorepo --unit svc:b --unit dbm:main --unit svc:a --unit pkgm:ui --module rr --slot REPO=demo --slot OWNER=o && has "$D/repo.yaml" "$want"; then
  pass "7: repo.yaml entries exact (id, kind, language, path), sorted by path"
else fail "7: repo.yaml" "$(cat "${D:-/nonexistent}/repo.yaml" 2>/dev/null | tail -n 5 | tr '\n' '|')"; fi
yp=""; for c in "${PYYAML_PYTHON:-}" "$HOME/.cache/production-skills-tools/venv/bin/python3" python3; do
  [[ -n "$c" ]] && "$c" -c 'import yaml' 2>/dev/null && { yp="$c"; break; }
done
specials=(true null yes 123 1e3 a.b a_b 0x1f off My.Svc)
if python3 -I -B - "$asm" "${specials[@]}" >"$tmp/rows.txt" <<'PY'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("asm", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
ents = [(s, "svc", "services/" + s, {"kind": "service", "language": "go"}) for s in sys.argv[2:]]
rows = m.inv_rows(ents)
print("units:"); print("\n".join(rows))
assert m.inventory_problem(("repo: x\n" + "units:\n" + "\n".join(rows) + "\n").encode(), generated=True) is None
PY
then
  sp=1; for s in "${specials[@]}"; do grep -qxF "  - { id: \"$s\", kind: \"service\", language: \"go\", path: \"services/$s\" }" "$tmp/rows.txt" || sp=0; done
  [[ $sp -eq 1 ]] && pass "7: the writer emits ids true/null/yes/123/1e3/0x1f/off/a.b/a_b/My.Svc double-quoted, and its own line check accepts them" || fail "7: quoting" "$(tail -n 3 "$tmp/rows.txt")"
  if [[ -n "$yp" ]]; then
    "$yp" -I -B - "$tmp/rows.txt" "${specials[@]}" <<'PY' && pass "7: PyYAML loads every quoted id as a string, paths as services/<id>" || fail "7: PyYAML"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
u = d["units"]
assert sorted(x["id"] for x in u) == sorted(sys.argv[2:]) and all(type(x["id"]) is str for x in u)
assert all(set(x) == {"id", "kind", "language", "path"} for x in u)
PY
  else skipped=$((skipped + 1)); echo "skip 7: PyYAML is not importable"; fi
else fail "7: writer" "$(head -c 200 "$tmp/rows.txt")"; fi
rq "7: unit files but no kind/language declared (repo.yaml present): exit 2, module named" c7c 2 'svcnk.*declares no .unit' --layout monorepo --unit svcnk:a --module rr --slot REPO=demo --slot OWNER=o
run c7d 0 - --layout monorepo --unit svcnk:a --slot OWNER=o && pass "7: no repo.yaml contributed: no kind needed, nothing generated" || true
ri() { rq "$1" "$2" 2 "$3" --layout monorepo --unit svc:a --module "$4" --slot REPO=d --slot OWNER=o; }   # ri <description> <case> <stderr-grep> <repo.yaml module>
ri "7: repo.yaml without a units: [] line: exit 2" c7e 'exactly one line.*found 0' rrnone
ri "7: a comment holding units: [] and a real flow units: {}: exit 2 at the flow line" c7f 'line 2.*forbidden character' rrcomment
ri "7: two units: [] lines: exit 2, line 2" c7g 'line 2.*`units` appears twice' rrtwo
ri "7: an indented units: []: exit 2" c7h 'line 2.*forbidden character' rrindent
# the four inputs of the review, then the rest of the allow-list (message names the line and the reason)
ri "7: units: [] then a second units: {x: 1}: exit 2" c7r1 'line 3.*forbidden character' rrmap
ri "7: units: [] then a second plain units: 1: exit 2 (duplicate key)" c7r1b 'line 3.*`units` appears twice' rrdup
ri "7: a two-document file (---): exit 2" c7r2 'line 2.*document marker' rrdoc
ri "7: --- | before units: []: exit 2" c7r3 'line 2.*document marker' rrdocb
ri "7: a multi-line quoted scalar holding the line: exit 2" c7r4 'line 1.*not one of the allowed shapes' rrquote
ri "7: a multi-line flow mapping holding the line: exit 2" c7r5 'line 1.*forbidden character' rrflow
ri "7: CRLF: exit 2" c7s1 'line 1.*U\+000D' rrcrlf
ri "7: a BOM: exit 2" c7s2 'line 1.*U\+FEFF' rrbom
ri "7: a tab: exit 2" c7s3 'line 1.*U\+0009' rrtab
ri "7: no newline at the end: exit 2" c7s4 'must end with a newline' rrnonl
ri "7: a mapping opener without children: exit 2" c7s5 'no child line' rrbare
ri "7: a child line without an opener: exit 2" c7s6 'line 1.*indented line' rrorph
ri "7: a trailing comment on a scalar line: exit 2" c7s7 'line 1.*not one of the allowed shapes' rrtrail
ri "7: an anchor: exit 2" c7s8 'line 1.*forbidden character' rranchor
ri "7: a top-level key twice: exit 2" c7s9 'line 2.*`a` appears twice' rrkey
ri "7: a child key twice: exit 2" c7s10 'line 3.*child key .b. appears twice' rrchild
ri "7: a block scalar (a: |): exit 2" c7s11 'line 1.*forbidden character' rrblock
ri "7: a Unicode line break inside a comment: exit 2" c7s12 'line 2.*U\+2028' rrls
run c7ok 0 - --layout monorepo --unit svc:a --module rrok --slot REPO=d --slot OWNER=o && grep -qxF '  - { id: "a", kind: "service", language: "go", path: "services/a" }' "$D/repo.yaml" && grep -qxF 'q: "a: b # c"' "$D/repo.yaml" && pass "7: blank lines, comments, a quoted scalar and a nested mapping are accepted" || fail "7: allow-list control"
# the real monorepo-root repo.yaml shape (comments, `version: v2`, a one-level `repo:` mapping)
printf '# Inventory.\n# Schema: x\nversion: v2\nrepo:\n  name: repo-name\n  layout: monorepo\nunits: []\n' >"$tmp/real.yaml"
if python3 -I -B - "$asm" "$tmp/real.yaml" <<'PY'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("asm", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
assert m.inventory_problem(open(sys.argv[2], "rb").read()) is None
assert m.inventory_problem(b"units: []\n") is None and m.inventory_problem(b"") is not None
assert m.inventory_problem(b"a: 1\n") == (0, "must hold exactly one line `units: []` (found 0)")
PY
then pass "7: the shape of the real monorepo-root repo.yaml is accepted by the allow-list"; else fail "7: real repo.yaml shape"; fi
# ids vs the inventory schema
for badid in My.Svc 123 a_b A 9x; do
  rq - "c7id$badid" 2 "unit id '$badid'.*\\^\\[a-z\\]" --layout monorepo --unit "svc:$badid" --module rr --slot REPO=d --slot OWNER=o
done
qok && pass "7: ids outside the inventory schema (My.Svc, 123, a_b, A, 9x) with an inventory in layout monorepo: exit 2, id named" || fail "7: id rule"
run c7ids 0 - --layout single --unit svc:My.Svc --module rr --slot REPO=d --slot OWNER=o && pass "7: layout single is unchanged (no inventory, any grammar id)" || fail "7: id rule single"
run c7idn 0 - --layout monorepo --unit svc:My.Svc --unit svcnk:true --slot OWNER=o && pass "7: without a repo.yaml any grammar id is still accepted" || fail "7: id rule without repo.yaml"
# the self-check: a writer that emits a bad entry must be caught before the rename
cat >"$tmp/drv2.py" <<'PY'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("asm", sys.argv[1]); asm = importlib.util.module_from_spec(sp); sp.loader.exec_module(asm)
asm.inv_rows = lambda ents: ["  - { id: " + '"x", kind: "k", language: "l", path: "p"' + " }  # extra"]
sys.argv = ["assemble.py"] + sys.argv[2:]
asm.main()
PY
python3 -I -B "$tmp/drv2.py" "$asm" --modules-dir "$mods" --dest "$out/c7self" --layout monorepo --unit svc:a --module rr --slot REPO=d --slot OWNER=o >/dev/null 2>"$out/c7self.err"; rc=$?
if [[ $rc -eq 2 && ! -e "$out/c7self" ]] && ! compgen -G "$out/.assemble-*" >/dev/null && grep -q 'internal error.*own line check' "$out/c7self.err"; then
  pass "7: a generated repo.yaml that fails the assembler's own line check: internal error, exit 2, nothing written"
else fail "7: self-check" "rc=$rc $(head -c 200 "$out/c7self.err")"; fi
run c7i 0 - --layout monorepo --module rr --slot REPO=demo && has "$D/repo.yaml" "$(printf '# header\nversion: v2\nrepo:\n  name: demo\n  layout: monorepo\nunits: []')" && pass "7: no unit instance: units: [] untouched" || fail "7: empty inventory"
run c7j 0 - --layout single --unit svc:a --module rr --slot REPO=demo --slot OWNER=o && grep -qx 'units: \[\]' "$D/repo.yaml" && pass "7: layout single never generates the inventory" || fail "7: single"

# 8. atomicity and signals with two instances
mk svcbad "$SL,\"placement\":{\"README.md\":\"unit\"}" 'README.md=<SERVICE>\n' 'extra.txt=x\n'
rq "8: a failure in the SECOND instance leaves no dest and no temp dir" c8a 1 'unplaced: extra.txt' --layout monorepo --unit svc:a --unit svcbad:b --slot OWNER=o
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

# 10. root files inside a unit directory
mk rootin '"placement":{"packages/ui/y":"root"}' 'packages/ui/y=x\n'
mk rootdb '"placement":{"db/x.sql":"root"}' 'db/x.sql=x\n'
rq "10: another module's root file packages/ui/y inside the package unit ui: exit 1, path, module and unit named" c10a 1 'packages/ui/y.*rootin.*pkgm\[ui\]' --layout monorepo --unit pkgm:ui --module rootin --slot OWNER=o
rq "10: another module's root file db/x.sql inside the database unit: exit 1" c10b 1 'db/x.sql.*rootdb.*dbm\[main\]' --layout monorepo --unit dbm:main --module rootdb --slot OWNER=o
run c10c 0 - --layout monorepo --unit pkgm:other --unit dbm:main --module rootin --slot OWNER=o && [[ -f "$D/packages/ui/y" ]] && pass "10: the same root file beside different units is fine (control)" || fail "10: control"

# 11. messages and parsing
rq "11: --unit sv:c:a: exit 2, the whole argument named" c11a 2 "bad --unit 'sv:c:a'.*':'" --layout monorepo --unit sv:c:a --slot OWNER=o
run c11b 2 'module svcnk places unit files' --layout monorepo --module svcnk --module rr --slot SERVICE=a --slot OWNER=o --slot REPO=d && ! grep -q 'None' "$out/c11b.err" && pass "11: a --module instance without a unit declaration: no (unit None) in the message" || fail "11: unit None" "$(head -c 200 "$out/c11b.err")"
mk fifom "$SL,\"placement\":{\"README.md\":\"unit\",\"pipe\":\"unit\"}" 'README.md=x\n'
if mkfifo "$mods/fifom/pipe" 2>/dev/null; then
  run c11c 1 'fifom\[a\].*FIFO' --layout monorepo --unit fifom:a --slot OWNER=o && pass "11: a FIFO in a module source names module[id]" || true
  rm -f "$mods/fifom/pipe"
else skipped=$((skipped + 1)); echo "skip 11: mkfifo is not available"; fi

# 12. a path that BECOMES .git after substitution
mk gslotu '"slots":{"SERVICE":"s"},"placement":{".g<SERVICE>/**":"unit"}' '.g<SERVICE>/hooks/pre-commit=x\n'
mk gslotr '"slots":{"SERVICE":"s"},"placement":{".g<SERVICE>/**":"root"}' '.g<SERVICE>/hooks/pre-commit=x\n'
mk gslotl '"slots":{"SERVICE":"s"},"placement":{".g<SERVICE>":"unit"}'
ln -s x "$mods/gslotl/.g<SERVICE>"
rq "12: unit file .g<SERVICE>/hooks/pre-commit with the unit id it: refused (exit 1), nothing written" c12a 1 'reserved' --layout monorepo --unit gslotu:it
rq "12: root file .g<SERVICE>/hooks/pre-commit with SERVICE=it: refused" c12b 1 'reserved' --layout monorepo --module gslotr --slot SERVICE=it
rq "12: a unit LINK named .g<SERVICE> becoming .git: refused" c12c 1 'reserved' --layout monorepo --unit gslotl:it
run c12d 0 - --layout monorepo --unit gslotu:ok --module gslotr --slot SERVICE=ok && pass "12: the same scenario with a harmless value (control)" || true
run c12e 0 - --layout monorepo --unit gslotl:ok && [[ -L "$D/services/ok/.gok" ]] && pass "12: the same link scenario with a harmless value (control)" || fail "12: link control"

# 13. root_merge declared by only ONE of two contributors
mk rm-a '"placement":{".gitignore":"root"},"root_merge":{".gitignore":"union-lines"}' '.gitignore=a\n'
mk rm-b '"placement":{".gitignore":"root"}' '.gitignore=b\n'
mk rm-c '"placement":{".gitignore":"root"},"root_merge":{".gitignore":"union-lines"}' '.gitignore=c\n'
rq "13: root_merge declared by the first contributor only: exit 1" c13a 1 'both place .gitignore' --layout monorepo --module rm-a --module rm-b
rq "13: root_merge declared by the second contributor only: exit 1" c13b 1 'both place .gitignore' --layout monorepo --module rm-b --module rm-a
run c13c 0 - --layout monorepo --module rm-a --module rm-c && has "$D/.gitignore" $'a\nc' && pass "13: declared by both: merged (control)" || fail "13: control"

# 14. a module that ships several fixed units (manifest key units)
DU='"units":[{"id":"tokens","kind":"package","language":"ts","path":"packages/tokens"},{"id":"theme","kind":"package","language":"ts","path":"packages/theme"}]'
dsp='"placement":{"packages/tokens/**":"root","packages/theme/**":"root"}'
mk dsys "$dsp,$DU" 'packages/tokens/package.json=t\n' 'packages/theme/package.json=h\n'
want="$(printf '# header\nversion: v2\nrepo:\n  name: d\n  layout: monorepo\nunits:\n  - { id: "theme", kind: "package", language: "ts", path: "packages/theme" }\n  - { id: "tokens", kind: "package", language: "ts", path: "packages/tokens" }\n  - { id: "a", kind: "service", language: "go", path: "services/a" }')"
run c14a 0 - --layout monorepo --module dsys --module rr --unit svc:a --slot REPO=d --slot OWNER=o && [[ -f "$D/packages/tokens/package.json" ]] && has "$D/repo.yaml" "$want" \
  && pass "14: two declared package units + a service instance: three inventory entries, sorted by path" || fail "14: declared units" "$(tail -n 4 "$D/repo.yaml" 2>/dev/null | tr '\n' '|')"
if [[ -n "$yp" && -f "$D/repo.yaml" ]] && "$yp" -I -B - "$D/repo.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert [(u["id"], u["path"]) for u in d["units"]] == [("theme", "packages/theme"), ("tokens", "packages/tokens"), ("a", "services/a")]
PY
then pass "14: PyYAML loads the three entries"; else fail "14: PyYAML (or no interpreter with yaml)"; fi
mk dboth "\"unit\":{\"kind\":\"service\",\"language\":\"go\"},$dsp,$DU" 'packages/tokens/package.json=t\n' 'packages/theme/package.json=h\n'
rq "14: unit and units together: exit 2" c14b 2 'mutually exclusive' --layout monorepo --module dboth
mk dpath "$dsp,\"units\":[{\"id\":\"tokens\",\"kind\":\"package\",\"language\":\"ts\",\"path\":\"packages/other\"}]" 'packages/tokens/package.json=t\n'
rq "14: a declared path that is not the kind's directory: exit 2" c14c 2 "path 'packages/other' must be 'packages/tokens'" --layout monorepo --module dpath
mk dnofile "$dsp,$DU" 'packages/tokens/package.json=t\n'
rq "14: a declared unit with no file inside: exit 2" c14d 2 'unit theme at packages/theme, but places no file' --layout monorepo --module dnofile
rq "14: --unit svc:tokens vs the declared package tokens (other directories, same id): exit 2" c14e 2 'same id' --layout monorepo --module dsys --unit svc:tokens --slot OWNER=o
mk ddup "$dsp,\"units\":[{\"id\":\"tokens\",\"kind\":\"package\",\"language\":\"ts\",\"path\":\"packages/tokens\"},{\"id\":\"tokens\",\"kind\":\"app\",\"language\":\"ts\",\"path\":\"apps/tokens\"}]" 'packages/tokens/package.json=t\n' 'apps/tokens/package.json=h\n'
rq "14: the same id twice in one manifest (two kinds): exit 2" c14f 2 'same id' --layout monorepo --module ddup
mk rootd '"placement":{"packages/tokens/extra":"root"}' 'packages/tokens/extra=x\n'
rq "14: another module's root file inside a declared unit directory: exit 1" c14g 1 'packages/tokens/extra.*rootd.*dsys\[tokens\]' --layout monorepo --module dsys --module rootd
mk rootd2 '"placement":{"docs/extra":"root"}' 'docs/extra=x\n'
run c14h 0 - --layout monorepo --module dsys --module rootd2 && pass "14: another module's root file outside the declared directories (control)" || true
mk dslot '"slots":{"X":"x"},"placement":{"packages/<X>/**":"root"},"units":[{"id":"tokens","kind":"package","language":"ts","path":"packages/<X>"}]' 'packages/<X>/package.json=t\n'
rq "14: a slot placeholder in a declared path: exit 2" c14i 2 'slot placeholder' --layout monorepo --module dslot --slot X=tokens
run c14j 0 - --layout single --module dsys --module rr --slot REPO=d && grep -qx 'units: \[\]' "$D/repo.yaml" && [[ -f "$D/packages/tokens/package.json" ]] && pass "14: layout single accepts units and generates no inventory" || fail "14: single"
mk ddb '"placement":{"db/**":"root"},"units":[{"id":"core","kind":"database","language":"sql","path":"db"}]' 'db/s.sql=x\n'
rq "14: a declared unit directory equal to an instance's unit directory (ids differ): exit 2" c14m 2 'share the unit directory' --layout monorepo --module ddb --unit dbm:main --slot OWNER=o
run c14n 0 - --layout monorepo --module ddb --unit svc:a --slot OWNER=o && pass "14: a declared database unit beside a service instance (control)" || fail "14: control"
rq "14: --unit on a module with declared units: exit 2" c14k 2 'use --module dsys' --layout monorepo --unit dsys:x
rq "14: the path rule still validates in layout single" c14l 2 'must be' --layout single --module dpath

# 15. the inventory alphabet: printable ASCII and newlines, nothing else (an allow-list, comments and quoted values too)
mkr rrfec '# a\xef\xbf\xbeb\nunits: []\n'
mkr rrfeq 'k: "a\xef\xbf\xbeb"\nunits: []\n'
mkr rrffc '# a\xef\xbf\xbfb\nunits: []\n'
mkr rrffq 'k: "a\xef\xbf\xbfb"\nunits: []\n'
mkr rreec '# caf\xc3\xa9\nunits: []\n'
mkr rreeq 'k: "caf\xc3\xa9"\nunits: []\n'
mkr rrastral '# a\xf0\x9f\x98\x80b\nunits: []\n'
mkr rrnbsp '# a\xc2\xa0b\nunits: []\n'
mkr rrinv '# a\xffb\nunits: []\n'
mkr rrsur '# a\xed\xa0\x80b\nunits: []\n'
mkr rrdel '# a\x7fb\nunits: []\n'
ri "15: U+FFFE in a comment: exit 2, line and code point named" c15a 'line 1.*U\+FFFE' rrfec
ri "15: U+FFFE in a quoted value: exit 2" c15b 'line 1.*U\+FFFE' rrfeq
ri "15: U+FFFF in a comment: exit 2" c15c 'line 1.*U\+FFFF' rrffc
ri "15: U+FFFF in a quoted value: exit 2" c15d 'line 1.*U\+FFFF' rrffq
ri "15: an accented letter in a comment: exit 2 (the earlier non-ASCII allowance is gone)" c15e 'line 1.*U\+00E9' rreec
ri "15: an accented letter in a quoted value: exit 2" c15f 'line 1.*U\+00E9' rreeq
ri "15: an astral character: exit 2" c15g 'line 1.*U\+1F600' rrastral
ri "15: NBSP: exit 2" c15h 'line 1.*U\+00A0' rrnbsp
ri "15: invalid UTF-8 byte: exit 2" c15i 'not valid UTF-8' rrinv
ri "15: a lone surrogate (CESU bytes): exit 2" c15j 'not valid UTF-8' rrsur
ri "15: DEL: exit 2" c15k 'line 1.*U\+007F' rrdel
# every accepted class at once: all printable ASCII in a comment and in a quoted value; PyYAML must load the output
mk rrall "$RS"
python3 -I -B - "$mods/rrall/repo.yaml" "$tmp/q.txt" <<'PY'
import sys
allp = [chr(c) for c in range(0x20, 0x7f)]
q = "".join(c for c in allp if c not in '|>&*!%@\\`{}[]"')
open(sys.argv[1], "w").write("# " + "".join(allp) + "\nversion: v2\nk: \"" + q + "\"\nunits: []\n")
open(sys.argv[2], "w").write(q)
PY
if run c15z 0 - --layout monorepo --unit svc:a --module rrall --slot OWNER=o --slot REPO=d; then
  if [[ -n "$yp" ]]; then
    "$yp" -I -B - "$D/repo.yaml" "$tmp/q.txt" <<'PY' && pass "15: every accepted class (all printable ASCII, comment and quoted value): output loads in PyYAML and equals the expected structure" || fail "15: PyYAML on the all-classes output"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
q = open(sys.argv[2]).read()
assert d == {"version": "v2", "k": q, "units": [{"id": "a", "kind": "service", "language": "go", "path": "services/a"}]}, d
PY
  else skipped=$((skipped + 1)); echo "skip 15: PyYAML is not importable"; fi
else fail "15: the all-classes file was refused"; fi

# 16. links inside ANY unit directory (declared units too) stay inside their own unit; root links do not couple to a unit
DU2='"units":[{"id":"ui","kind":"package","language":"ts","path":"packages/ui"},{"id":"core","kind":"package","language":"ts","path":"packages/core"}]'
dpl='"placement":{"packages/ui/**":"root","packages/core/**":"root"}'
mkl() { mk "$1" "$dpl,$DU2" 'packages/ui/README.md=u\n' 'packages/core/README.md=c\n' 'packages/core/b.ts=b\n'; ln -s "$2" "$mods/$1/packages/ui/l"; }   # mkl <module> <link target>
mkl dl1 ../../services/a/README.md
mkl dl2 ../core/b.ts
mkl dl3 ..
mkl dl4 ../../x
mkl dl5 README.md
mkl dl6 ../../.git
rq "16: a declared-unit link into another unit's file: exit 1, couples" c16a 1 'couples' --layout monorepo --unit svc:a --module dl1 --slot OWNER=o
rq "16: a declared-unit link into its sibling declared unit: exit 1, couples" c16b 1 'couples' --layout monorepo --module dl2
rq "16: a declared-unit link to its parent directory (..): exit 1" c16c 1 'outside the unit directory' --layout monorepo --module dl3
rq "16: a declared-unit link to ../../x: exit 1" c16d 1 'outside the unit directory' --layout monorepo --module dl4
rq "16: a declared-unit link to .git: exit 1 (older rule)" c16f 1 'reserved' --layout monorepo --module dl6
run c16e 0 - --layout monorepo --module dl5 && [[ -L "$D/packages/ui/l" ]] && pass "16: a declared-unit link inside the same declared unit is allowed (control)" || fail "16: control"
for n in 1 2 3 4 5; do rq - "c16s$n" 0 - --layout single --module "dl$n"; done
rq - c16s6 1 'reserved' --layout single --module dl6
qok && pass "16: layout single: the same links behave as before (allowed, .git still refused)" || fail "16: single links"
mk rtl '"placement":{"LICENSE":"root","l":"root"}' 'LICENSE=MIT\n'
ln -s services/a/README.md "$mods/rtl/l"
mk rtl2 '"placement":{"LICENSE":"root","l":"root"}' 'LICENSE=MIT\n'
ln -s LICENSE "$mods/rtl2/l"
rq "16: a ROOT link whose target is inside a unit directory: exit 1, couples the root to a unit" c16g 1 'root link.*services/a' --layout monorepo --unit svc:a --module rtl --slot OWNER=o
run c16h 0 - --layout monorepo --unit svc:a --module rtl2 --slot OWNER=o && [[ -L "$D/l" ]] && pass "16: a root link to a root file is allowed (control)" || fail "16: root link control"
rq "16: layout single: a root link to a path under the service stays allowed" c16i 0 - --layout single --unit svc:a --module rtl --slot OWNER=o

# 17. declared units beside a service in layout single (the service's unit directory is the root)
mk dcol '"placement":{"db/**":"root","README.md":"root"},"units":[{"id":"db","kind":"database","language":"sql","path":"db"}]' 'db/s.sql=x\n' 'README.md=other\n'
mk ddb2 '"placement":{"db/**":"root"},"units":[{"id":"store","kind":"database","language":"sql","path":"db"}]' 'db/t.sql=y\n'
mk dlk '"placement":{"db/**":"root"},"units":[{"id":"db","kind":"database","language":"sql","path":"db"}]' 'db/s.sql=x\n'
ln -s ../x "$mods/dlk/db/l"
run c17a 0 - --layout single --module svc --module ddb --module rr --slot SERVICE=a --slot OWNER=o --slot REPO=d && [[ -f "$D/db/s.sql" && -f "$D/README.md" ]] && grep -qx 'units: \[\]' "$D/repo.yaml" \
  && pass "17: single: a service and a declared database unit assemble together; no inventory generated" || fail "17: single service + declared unit" "$(head -c 200 "$out/c17a.err")"
run c17b 0 - --layout monorepo --unit svc:a --module ddb --module rr --slot OWNER=o --slot REPO=d && [[ -f "$D/db/s.sql" ]] && grep -qF 'path: "db" }' "$D/repo.yaml" && grep -qF 'path: "services/a" }' "$D/repo.yaml" \
  && pass "17: monorepo: the same pair assembles and both are in the inventory" || fail "17: monorepo pair" "$(head -c 200 "$out/c17b.err")"
rq "17: single: the declared-unit module and the service place README.md with different content: exit 1 (file collision)" c17c 1 'README.md' --layout single --module svc --module dcol --slot SERVICE=a --slot OWNER=o
rq "17: single: two modules declaring the same directory db: exit 2" c17d 2 'share the unit directory' --layout single --module ddb --module ddb2
rq "17: monorepo: a service at the root-nested dir is unchanged, two modules declaring db: exit 2" c17e 2 'share the unit directory' --layout monorepo --module ddb --module ddb2
rq "17: monorepo: a declared database unit at db and an instance of a database module at db: exit 2 (the single exemption does not leak)" c17g 2 'share the unit directory' --layout monorepo --module ddb --unit dbm:main --slot OWNER=o
rq "17: single: a link db/l -> ../x inside a declared directory: allowed" c17f 0 - --layout single --module svc --module dlk --slot SERVICE=a --slot OWNER=o

flushq

echo "$ok ok, $bad failed${skipped:+, $skipped skipped}" | sed 's/, 0 skipped//'
[[ $((ok + bad)) -gt 0 ]] || exit 2
[[ $bad -eq 0 ]]
