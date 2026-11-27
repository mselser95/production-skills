#!/usr/bin/env bash
# install-hosts-selftest.sh -- install.sh --host claude|codex|both, hermetically.
#
# Everything runs against a COPY of this repo under a temp dir, with HOME,
# CLAUDE_CONFIG_DIR and CODEX_HOME all pointed under that temp dir, so nothing is
# ever written to the real home. The BASELINE installer is the committed fixture
# scripts/tests/fixtures/install.base.sh.txt (install.sh at the merge-base with master,
# NOT HEAD: HEAD's copy equals the script under test once committed and could never
# differ). It is run beside the new one to prove the default is unchanged; a guard
# case proves the fixture is not vacuous. Sequential; the only background process is
# the first of the two concurrent installs in the lock case, waited for. Mutation
# cases at the end run a scratch copy of install.sh with one behaviour broken and
# must come out RED. Every install run has HOME, CLAUDE_CONFIG_DIR and CODEX_HOME
# under the temp dir.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_HOME="${HOME:-}"
T="$(mktemp -d "${TMPDIR:-/tmp}/install-hosts.XXXXXX")" || exit 1
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
case "$T" in "$REAL_HOME"/*) echo "refusing: temp dir $T is under the real home" >&2; exit 1 ;; esac
command -v python3 >/dev/null || { echo "python3 required (TOML check)" >&2; exit 1; }

GREEN=" "; HAVE_TOML=0; python3 -I -c 'import tomllib' 2>/dev/null && HAVE_TOML=1
ok=0; bad=0; skipped=0
check() { # check <name> <fn> ; fn returns 0 when the property holds
  if "$2"; then ok=$((ok+1)); GREEN=" $GREEN$2 "; echo "ok   - $1 [${SECONDS}s]"; else bad=$((bad+1)); echo "FAIL - $1 [${SECONDS}s]"; fi
}

# --- scratch source tree: copy of the repo, new + original installers -------
S="$T/src"; mkdir -p "$S"
rsync -a --exclude .git --exclude .wt "$root"/ "$S"/ || exit 1
FIXTURE="$root/scripts/tests/fixtures/install.base.sh.txt"
cp "$FIXTURE" "$S/install.orig.sh" || exit 1
cp "$root/install.sh" "$S/install.sh"
NEW="$S/install.sh"; ORIG="$S/install.orig.sh"

n=0; HM=""; CL=""; CX=""
newhomes() { n=$((n+1)); H="$T/h$n"; HM="$H/home"; CL="$H/claude"; CX="$H/codex"; mkdir -p "$HM" "$CL" "$CX"; }
# run <script> args...  -> RC, files $T/out $T/err (raw)
run() { local sc="$1"; shift
  env HOME="$HM" CLAUDE_CONFIG_DIR="$CL" CODEX_HOME="$CX" bash "$sc" "$@" >"$T/out" 2>"$T/err"; RC=$?; }
norm() { sed -e "s|$H|<H>|g" "$1"; } # normalise only the temp path
listing() { ( cd "$1" && find . | sort ); }
# modes: permission bits per file, via python (stat -f is BSD-only: GNU stat -f prints filesystem counters).
modes() { python3 -I -c 'import os,sys
r=sys.argv[1]
for d,_,fs in os.walk(r):
    for f in fs:
        p=os.path.join(d,f)
        if not os.path.islink(p): print("%04o %s" % (os.stat(p).st_mode & 0o7777, os.path.relpath(p,r)))' "$1" | sort; }
# contents: POSIX cksum (one process per batch) so a rewrite with the same name and mode is seen too.
contents() { ( cd "$1" && find . -type f -exec cksum {} + | sort -k3 ); }
hasre() { grep -qE "$1" "$2"; }
snap() { # snap <dir> [mtime]: kind mode size sha256 path (symlinks by target; + mtime_ns when asked)
  python3 -I -c 'import os,sys,hashlib,stat
r=sys.argv[1]; mt=len(sys.argv)>2; out=[]
for d,ds,fs in os.walk(r):
    for n in ds+fs:
        p=os.path.join(d,n); st=os.lstat(p); rel=os.path.relpath(p,r)
        if stat.S_ISLNK(st.st_mode): out.append("l %s -> %s" % (rel, os.readlink(p))); continue
        reg=stat.S_ISREG(st.st_mode)
        h=hashlib.sha256(open(p,"rb").read()).hexdigest() if reg else "-"
        out.append("%s %04o %d %s %s%s" % ("f" if reg else "d", st.st_mode&0o7777, st.st_size if reg else 0, h, rel, (" %d" % st.st_mtime_ns) if mt else ""))
print("\n".join(sorted(out)))' "$@"; }
SK="prod-spec prod-review prod-incident prod-implement prod-test-synth prod-ops prod-curate prod-bootstrap prod-new"
mk=0
mkmini() { # mkmini [script]: a private copy of the mini tree whose install.sh is the script under test
  mk=$((mk+1)); MI="$T/mi$mk"; cp -R "$M" "$MI"; cp "${1:-$MNEW}" "$MI/install.sh"; rm -f "$MI/install.mut.sh"; MIS="$MI/install.sh"; }
mkcanary() { CAN="$H/canary"; mkdir -p "$CAN/sdir"; echo role > "$CAN/role.toml"; chmod 444 "$CAN/role.toml"; echo s > "$CAN/sdir/f"
  touch -t 202001010000 "$CAN/role.toml" "$CAN/sdir/f" "$CAN/sdir" "$CAN"; }
# failure-injection shim: cp/mv/chmod/rm that fail on demand (FAIL_TOOL, FAIL_PAT glob on the LAST argument,
# first match only unless FAIL_ALWAYS) or stall the first cp (SLOW_MARK). Used only per command, via PATH.
SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/.shim" <<'SH'
#!/bin/bash
t="${0##*/}"; last="${!#}"
if [[ "${FAIL_TOOL:-}" == "$t" && "$last" == $FAIL_PAT ]]; then
  if [[ -n "${FAIL_ALWAYS:-}" || ! -e "$FAIL_MARK" ]]; then : > "$FAIL_MARK"; exit 1; fi
fi
if [[ -n "${SLOW_MARK:-}" && "$t" == cp && ! -e "$SLOW_MARK" ]]; then : > "$SLOW_MARK"; sleep 1.5; fi
exec "/bin/$t" "$@"
SH
chmod +x "$SHIM/.shim"; for t in cp mv chmod rm; do ln -s .shim "$SHIM/$t"; done

echo "homes: HOME=$T/h*/home CLAUDE_CONFIG_DIR=$T/h*/claude CODEX_HOME=$T/h*/codex (real home: $REAL_HOME)"

# --- MINI source tree: same layout (nine skills, references symlinks, the 17
# mirror pairs, the real agents), a few bytes each, so the many cases below cost
# an install each in milliseconds instead of the full tree's seconds. The full
# tree is exercised by the first cases and by the codex install/role cases.
M="$T/mini"; mkdir -p "$M/_shared/probes" "$M/agents"
cp "$root/install.sh" "$M/install.sh"; MNEW="$M/install.sh"
cp "$S/install.orig.sh" "$M/install.orig.sh"; MORIG="$M/install.orig.sh"
cp "$root"/agents/*.md "$M/agents/"
echo "shared doc" > "$M/_shared/doc.md"; echo "shared probe" > "$M/_shared/probes/p.sh"
for sk in prod-spec prod-review prod-incident prod-implement prod-test-synth prod-ops prod-curate prod-bootstrap prod-new; do
  mkdir -p "$M/$sk/references/probes"; echo "skill $sk" > "$M/$sk/SKILL.md"
  ln -s ../../_shared/doc.md "$M/$sk/references/doc.md"; ln -s ../../../_shared/probes/p.sh "$M/$sk/references/probes/p.sh"
done
mirrors="$(sed -n '/^mirrors=(/,/^)/p' "$root/install.sh" | grep -oE '^  "[^"]+"' | tr -d ' "')"
[[ "$(printf '%s\n' "$mirrors" | wc -l | tr -d ' ')" -ge 15 ]] || { echo "could not extract the mirror list" >&2; exit 1; }
for m in $mirrors; do
  for f in "${m%%:*}" "${m##*:}"; do mkdir -p "$M/$(dirname "$f")"; echo "mirror ${m##*:}" > "$M/$f"; done
done

# --- 1. default == original -------------------------------------------------
c_default_identical() {
  newhomes; run "$ORIG"; local rc1=$RC; norm "$T/out" > "$T/o1"; norm "$T/err" > "$T/e1"; local H1="$H" CL1="$CL"
  newhomes; run "$NEW";  local rc2=$RC; norm "$T/out" > "$T/o2"; norm "$T/err" > "$T/e2"
  [[ $rc1 == 0 && $rc2 == 0 ]] || return 1
  cmp -s "$T/o1" "$T/o2" && cmp -s "$T/e1" "$T/e2" || return 1
  diff -r "$CL1" "$CL" >/dev/null || return 1
  [[ "$(modes "$CL1")" == "$(modes "$CL")" ]] || return 1
  [[ "$(listing "$H1/codex")" == "$(listing "$H/codex")" && "$(listing "$H/codex")" == "." ]] || return 1
  # --verify on both
  # verify each installer on the home it just installed (no third and fourth full install)
  local H2="$H" HM2="$HM" CL2="$CL" CX2="$CX"
  H="$H1"; CL="$CL1"; CX="$H1/codex"; HM="$H1/home"; run "$ORIG" --verify; rc1=$RC; norm "$T/out" > "$T/o1"; norm "$T/err" > "$T/e1"
  H="$H2"; HM="$HM2"; CL="$CL2"; CX="$CX2"; run "$NEW" --verify; rc2=$RC; norm "$T/out" > "$T/o2"; norm "$T/err" > "$T/e2"
  [[ $rc1 == 0 && $rc2 == 0 ]] && cmp -s "$T/o1" "$T/o2" && cmp -s "$T/e1" "$T/e2"
}
check "default run + --verify identical to the original installer (tree, modes, manifest, stdout, stderr)" c_default_identical

c_default_failures_identical() {
  local rcs=()
  for variant in tamper writable; do
    for sc in "$MORIG" "$MNEW"; do
      newhomes; run "$sc"
      f="$CL/skills/prod-ops/SKILL.md"
      if [[ $variant == tamper ]]; then chmod u+w "$f"; echo x >> "$f"; chmod a-w "$f"; else chmod u+w "$f"; fi
      run "$sc" --verify; rcs+=("$RC"); norm "$T/err" > "$T/e_${variant}_$(basename "$sc")"
    done
    cmp -s "$T/e_${variant}_install.orig.sh" "$T/e_${variant}_install.sh" || return 1
  done
  [[ "${rcs[*]}" == "1 1 3 3" ]]
}
check "default --verify failures (drift, writable) identical: same exit code and stderr" c_default_failures_identical

# --- helpers for per-host properties ----------------------------------------
tamper_file() { chmod u+w "$1"; echo tamper >> "$1"; chmod a-w "$1"; }
host_cfg() { [[ $1 == claude ]] && echo "$CL" || echo "$CX"; }

c_codex_install() {
  newhomes; FH="$H"; FHM="$HM"; FCL="$CL"; FCX="$CX"; run "$NEW" --host codex; [[ $RC == 0 ]] || return 1
  for s in prod-spec prod-review prod-incident prod-implement prod-test-synth prod-ops prod-curate prod-bootstrap prod-new; do
    [[ -f "$CX/skills/$s/SKILL.md" ]] || return 1
  done
  [[ "$(find "$CX/skills" -maxdepth 1 -name 'prod-*' | wc -l | tr -d ' ')" == 9 ]] || return 1
  [[ -z "$(find "$CX" -type l)" ]] || return 1                               # no symlink at all
  [[ -n "$(find "$CX/skills/prod-spec/references" -type f 2>/dev/null | head -1)" ]] || return 1  # dereferenced content
  # every source reference file is present as a real file
  local missing; missing="$( cd "$S/prod-spec/references" && find -L . -type f | while read -r f; do [[ -f "$CX/skills/prod-spec/references/$f" ]] || echo "$f"; done )"
  [[ -z "$missing" ]] || return 1
  [[ -s "$CX/prod-skills.manifest" ]] || return 1
  grep -q 'prod-spec/SKILL.md' "$CX/prod-skills.manifest" || return 1
  [[ -z "$(find "$CX/skills" "$CX/agents" -type f -perm -u+w -not -name config.sh)" ]]   # read-only
}
check "--host codex: nine skills, references dereferenced, no symlinks, manifest written, tree read-only" c_codex_install

c_codex_verify_ok() { H="$FH"; HM="$FHM"; CL="$FCL"; CX="$FCX"; run "$NEW" --verify --host codex; [[ $RC == 0 ]] && grep -q '^TCB verified: ' "$T/out"; }
check "--verify --host codex -> 0 and says TCB verified" c_codex_verify_ok

c_roles() { # the mini tree carries the real agents, so every role is converted from its real source
  newhomes
  env HOME="$HM" CODEX_HOME="$CX" CLAUDE_CONFIG_DIR="$CL" PROD_CODEX_MODEL_SCOUT="test-model-x" bash "$MNEW" --host codex >/dev/null 2>&1 || return 1
  python3 -I - "$M/agents" "$CX/agents" "$CX/prod-skills.manifest" <<'PY' || return 1
import sys, os, re, tomllib
src, dst, man = sys.argv[1:4]
mf = open(man).read()
agents = sorted(f for f in os.listdir(src) if f.endswith('.md'))
assert agents, agents
for f in agents:
    name = f[:-3]
    t = open(os.path.join(src, f)).read()
    fm, body = re.match(r'---\n(.*?)\n---\n(.*)', t, re.S).groups()
    tools = re.search(r'^tools:\s*(.*)$', fm, re.M).group(1)
    d = tomllib.load(open(os.path.join(dst, name + '.toml'), 'rb'))
    assert d['name'] == name
    assert d['description'] and '\n' not in d['description']
    di = d['developer_instructions']
    assert body.strip() in di, name + ': body missing'
    assert 'must not spawn other agents' in di, name
    ro = 'Edit' not in tools and 'Write' not in tools
    assert ('must not edit, create or delete files' in di) == ro, name
    assert ('must not run shell commands' in di) == ('Bash' not in tools), name
    assert ('model' in d) == (name == 'prod-scout'), name + ' model key'
    if name == 'prod-scout': assert d['model'] == 'test-model-x'
    assert re.search(r'  \./' + re.escape(name) + r'\.toml$', mf, re.M), name + ' not in manifest'
PY
}
check "codex roles: one TOML per agent (parses), body + restated restrictions, model omitted unless env, in manifest" c_roles

hostfail() { # hostfail <host> <drift|stale|writable>
  newhomes; run "$MNEW" --host "$1"; [[ $RC == 0 ]] || return 1
  local c; c="$(host_cfg "$1")"
  case "$2" in
    drift)    tamper_file "$c/skills/prod-ops/SKILL.md"; run "$MNEW" --verify --host "$1"
              [[ $RC == 1 ]] && grep -q 'TCB DRIFT' "$T/err" ;;
    stale)    cp "$M/prod-ops/SKILL.md" "$T/ops.bak"; printf '\n<!-- stale -->\n' >> "$M/prod-ops/SKILL.md"
              run "$MNEW" --verify --host "$1"; local r=$RC; cp "$T/ops.bak" "$M/prod-ops/SKILL.md"
              [[ $r == 2 ]] && grep -q 'STALE INSTALL' "$T/err" && grep -q 'stale: prod-ops/SKILL.md' "$T/err" ;;
    writable) chmod u+w "$c/skills/prod-ops/SKILL.md"; run "$MNEW" --verify --host "$1"
              [[ $RC == 3 ]] && grep -q 'TCB WRITABLE' "$T/err" ;;
  esac
}
c_cd() { hostfail claude drift; };  c_cs() { hostfail claude stale; };  c_cw() { hostfail claude writable; }
c_xd() { hostfail codex drift; };   c_xs() { hostfail codex stale; };   c_xw() { hostfail codex writable; }
check "claude: tampered installed skill -> exit 1 TCB DRIFT" c_cd
check "claude: changed source skill -> exit 2 STALE INSTALL (names it)" c_cs
check "claude: installed file writable -> exit 3 TCB WRITABLE" c_cw
check "codex: tampered installed skill -> exit 1 TCB DRIFT" c_xd
check "codex: changed source skill -> exit 2 STALE INSTALL (names it)" c_xs
check "codex: installed file writable -> exit 3 TCB WRITABLE" c_xw

c_codex_role_tamper() { newhomes; run "$MNEW" --host codex; tamper_file "$CX/agents/prod-scout.toml"; run "$MNEW" --verify --host codex
  [[ $RC == 1 ]] && grep -q 'prod-scout.toml' "$T/err"; }
check "codex: tampered generated role file -> exit 1 naming it" c_codex_role_tamper

c_both() {
  newhomes; run "$MNEW" --host both; [[ $RC == 0 ]] || return 1
  [[ -s "$CL/prod-skills.manifest" && -s "$CX/prod-skills.manifest" && -f "$CL/agents/prod-scout.md" && -f "$CX/agents/prod-scout.toml" ]] || return 1
  run "$MNEW" --verify --host both; [[ $RC == 0 ]] || return 1
  tamper_file "$CX/skills/prod-ops/SKILL.md"; run "$MNEW" --verify --host both
  [[ $RC == 1 ]] && grep -q 'verify FAILED for: codex(exit 1)' "$T/err" && ! grep -q 'claude(exit' "$T/err" || return 1
  tamper_file "$CL/skills/prod-ops/SKILL.md"; run "$MNEW" --verify --host both
  [[ $RC == 1 ]] && grep -q 'claude(exit 1)' "$T/err" && grep -q 'codex(exit 1)' "$T/err"
}
check "--host both installs both; --verify --host both names the failing host(s), exit 1" c_both

c_usage() {
  newhomes; run "$MNEW" --host nonsense; [[ $RC == 2 ]] && grep -q 'usage' "$T/err" || return 1
  run "$MNEW" --host; [[ $RC == 2 ]] || return 1
  run "$MNEW" --verify --host=bogus; [[ $RC == 2 ]] || return 1
  [[ "$(listing "$CL")" == "." && "$(listing "$CX")" == "." ]]
}
check "unknown host / missing value -> exit 2 usage, nothing installed" c_usage

c_isolation() {
  newhomes; run "$MNEW" --host claude; local b; b="$(listing "$CL"; modes "$CL"; contents "$CL")"
  [[ "$(listing "$CX")" == "." ]] || return 1
  run "$MNEW" --host codex; [[ "$(listing "$CL"; modes "$CL"; contents "$CL")" == "$b" ]] || return 1
  b="$(listing "$CX"; modes "$CX"; contents "$CX")"; run "$MNEW" --host claude; [[ "$(listing "$CX"; modes "$CX"; contents "$CX")" == "$b" ]] || return 1
  run "$MNEW" --verify --host both; [[ $RC == 0 ]]
}
check "a codex run leaves the Claude home untouched, and vice versa" c_isolation

c_foreign() { # a codex home that already holds other people's skills and roles
  newhomes; mkdir -p "$CX/skills/.system" "$CX/skills/mine" "$CX/agents"
  echo s > "$CX/skills/mine/SKILL.md"; echo r > "$CX/agents/mine.toml"; echo y > "$CX/config.toml"
  run "$MNEW" --host codex; [[ $RC == 0 ]] || return 1
  run "$MNEW" --verify --host codex; [[ $RC == 0 ]] || return 1
  [[ -f "$CX/skills/mine/SKILL.md" && "$(cat "$CX/agents/mine.toml")" == r && -d "$CX/skills/.system" && "$(cat "$CX/config.toml")" == y ]] || return 1
  [[ -w "$CX/agents/mine.toml" ]] && ! grep -q 'mine' "$CX/prod-skills.manifest"
}
check "codex: foreign skills/roles/config.toml survive, stay writable, stay out of the manifest" c_foreign

c_default_roots() { # no CODEX_HOME / CLAUDE_CONFIG_DIR: roots fall back to $HOME/.codex, $HOME/.claude (temp HOME)
  newhomes
  env -u CODEX_HOME -u CLAUDE_CONFIG_DIR HOME="$HM" bash "$MNEW" --host both >/dev/null 2>&1 || return 1
  [[ -s "$HM/.codex/prod-skills.manifest" && -s "$HM/.claude/prod-skills.manifest" ]] || return 1
  [[ "$(listing "$CL")" == "." && "$(listing "$CX")" == "." ]]
}
check "default roots are \$HOME/.codex and \$HOME/.claude (temp HOME); the env-named dirs stay empty" c_default_roots

# --- baseline fixture guard (B4) ---------------------------------------------
guard_baseline() { # guard_baseline <fixture file>: not vacuous, and the committed copy of the merge-base script
  local f="$1" sha
  ! cmp -s "$f" "$root/install.sh" || return 1                 # must differ from the script under test
  sha="$(sed -n 's/.*install\.sh at commit \([0-9a-f]\{40\}\).*/\1/p' "$f" | head -n 1)"; [[ -n "$sha" ]] || return 1
  if git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null; then
    sed '/^# BASELINE-FIXTURE-BEGIN/,/^# BASELINE-FIXTURE-END/d' "$f" | cmp -s - <(git -C "$root" show "$sha:install.sh") || return 1
  else echo "     (baseline commit not reachable here: content check skipped, difference check ran)"; fi
}
c_baseline() { guard_baseline "$FIXTURE"; }
check "baseline fixture differs from install.sh and equals install.sh at its named commit (when reachable)" c_baseline

# --- healthy default flows: transcript identical to the baseline -------------
flow_transcript() { # flow_transcript <script> <out>: install, verify, drift 1, writable 3, stale 2, re-install via an unknown flag
  local sc="$1" o="$2" f g
  : > "$o"; newhomes; f="$CL/skills/prod-ops/SKILL.md"; g="$CL/skills/prod-curate/SKILL.md"
  step() { run "$sc" "$@"; { echo "## $* rc=$RC"; norm "$T/out"; echo "-- stderr"; norm "$T/err"; } >> "$o"; }
  step; step --verify
  cat "$f" > "$T/ops.keep"; chmod u+w "$f"; echo x >> "$f"; chmod a-w "$f"; step --verify; chmod u+w "$f"; cp "$T/ops.keep" "$f"; chmod a-w "$f"   # drift 1
  chmod u+w "$g"; step --verify; chmod a-w "$g"                                                                                               # writable 3
  cp "$M/prod-ops/SKILL.md" "$T/ops.flow"; printf '\n<!-- stale -->\n' >> "$M/prod-ops/SKILL.md"; step --verify; cp "$T/ops.flow" "$M/prod-ops/SKILL.md"   # stale 2
  step --help
  { echo "## tree"; snap "$CL"; echo "## codex dir"; snap "$CX"; } | sed -e "s|$H|<H>|g" >> "$o"
}
p_flows() { [[ -s "$T/flow.base" ]] || flow_transcript "$MORIG" "$T/flow.base"; flow_transcript "${1:-$MNEW}" "$T/flow.new"; cmp -s "$T/flow.base" "$T/flow.new"; }
p_default_out() { # one default install: stdout, stderr, rc, tree identical to the baseline's
  if [[ ! -s "$T/def.base" ]]; then newhomes; run "$MORIG"; { echo "rc=$RC"; norm "$T/out"; norm "$T/err"; snap "$CL"; } | sed -e "s|$H|<H>|g" > "$T/def.base"; fi
  newhomes; run "${1:-$MNEW}"; { echo "rc=$RC"; norm "$T/out"; norm "$T/err"; snap "$CL"; } | sed -e "s|$H|<H>|g" > "$T/def.new"; cmp -s "$T/def.base" "$T/def.new"
}
check "healthy default flows (install, verify, drift 1, writable 3, stale 2, re-install via an unknown flag): transcript + trees identical to the baseline" p_flows

# --- symlinks are never written through (B1) ---------------------------------
p_sym_leaf() { local sc="${1:-$MNEW}" b
  newhomes; mkcanary; mkdir -p "$CX/agents"; ln -s "$CAN/role.toml" "$CX/agents/prod-validator.toml"
  b="$(snap "$CAN" mt)"; run "$sc" --host codex
  [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" && ! -e "$CX/prod-skills.manifest" ]] && grep -q 'destination is a symlink' "$T/err" || return 1
  [[ -z "$(find "$CX/skills" -mindepth 1 2>/dev/null)" ]] || return 1
  newhomes; mkcanary; mkdir -p "$CX/skills"; ln -s "$CAN/sdir" "$CX/skills/prod-ops"
  b="$(snap "$CAN" mt)"; run "$sc" --host codex; [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" && ! -e "$CX/prod-skills.manifest" ]] || return 1
  # after a healthy install one of OUR skills turns into a symlink: still refused, canary untouched
  newhomes; mkcanary; run "$sc" --host codex; [[ $RC == 0 ]] || return 1
  chmod -R u+w "$CX/skills/prod-review"; rm -rf "$CX/skills/prod-review"; ln -s "$CAN/sdir" "$CX/skills/prod-review"
  b="$(snap "$CAN" mt)"; run "$sc" --host codex; [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" ]]
}
check "codex: a symlinked role file or skill dir (fresh, or after an install) is refused with exit 4; the canary outside the home keeps mode, content, mtime" p_sym_leaf
p_sym_dirs() { local sc="${1:-$MNEW}" b d
  for d in skills agents; do
    newhomes; mkcanary; ln -s "$CAN/sdir" "$CX/$d"; b="$(snap "$CAN" mt)"; run "$sc" --host codex
    [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" && ! -e "$CX/prod-skills.manifest" ]] || return 1
  done
  newhomes; mkcanary; ln -s "$CAN/role.toml" "$CX/prod-skills.manifest"; b="$(snap "$CAN" mt)"; run "$sc" --host codex
  [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" ]]
}
check "codex: skills/ or agents/ or the manifest being a symlink -> exit 4, nothing written through it" p_sym_dirs
c_claude_leaf() { # the Claude path keeps its historic behaviour: the link is replaced, never followed
  newhomes; mkcanary; mkdir -p "$CL/skills"; ln -s "$CAN/sdir" "$CL/skills/prod-ops"; local b; b="$(snap "$CAN" mt)"
  run "$MNEW" --host claude; [[ $RC == 0 && "$(snap "$CAN" mt)" == "$b" && -d "$CL/skills/prod-ops" && ! -L "$CL/skills/prod-ops" ]]
}
check "claude: a leaf symlink at one of our skill names is replaced (historic), the target is never written" c_claude_leaf

# --- ownership by manifest (B2) ----------------------------------------------
p_foreign() { local sc="${1:-$MNEW}" b
  newhomes; mkmini "$sc"; mkdir -p "$CX/agents" "$CX/skills/prod-ops"; echo mine > "$CX/agents/prod-scout.toml"; echo own > "$CX/skills/prod-ops/own.txt"
  b="$(snap "$CX")"; run "$MIS" --host both
  [[ $RC == 5 ]] && grep -q 'not installed by this tool' "$T/err" && grep -q -- '--adopt' "$T/err" || return 1
  [[ "$(snap "$CX")" == "$b" && -z "$(find "$CL" -mindepth 1)" ]] || return 1          # nothing installed, on either host
  run "$MIS" --host codex --adopt; [[ $RC == 0 ]] || return 1
  [[ "$(cat "$CX"/agents/prod-scout.toml.bak.* 2>/dev/null)" == mine && "$(cat "$CX"/skills/prod-ops.bak.*/own.txt 2>/dev/null)" == own ]] || return 1
  run "$MIS" --verify --host codex; [[ $RC == 0 ]] || return 1
  run "$MIS" --host codex; [[ $RC == 0 ]] && compgen -G "$CX/agents/prod-scout.toml.bak.*" >/dev/null     # now ours: replaced without --adopt, backup kept
}
check "codex: same-named foreign role and skill -> exit 5, nothing installed on either host; --adopt backs them up (never deletes)" p_foreign
c_claude_historic() { # documented limitation: the Claude path still replaces same-named dirs
  newhomes; mkdir -p "$CL/skills/prod-ops"; echo own > "$CL/skills/prod-ops/own.txt"; run "$MNEW" --host claude
  [[ $RC == 0 && ! -e "$CL/skills/prod-ops/own.txt" && -f "$CL/skills/prod-ops/SKILL.md" ]]
}
check "claude: historic behaviour kept (a same-named dir is replaced, exit 0) -- known limitation, see _shared/hosts.md" c_claude_historic

# --- verify compares (path, hash) rows (B3c) ---------------------------------
manifest_rewrite() { # rebuild the manifest from the tree as it is now (a consistent-but-wrong install)
  local c; c="$(host_cfg "$1")"
  { ( cd "$c/skills" && find $SK -type f -print0 | sort -z | xargs -0 shasum -a 256 )
    ( cd "$c/agents" && if [[ $1 == claude ]]; then find . -type f -print0; else find . -maxdepth 1 -name 'prod-*.toml' -type f -print0; fi | sort -z | xargs -0 shasum -a 256 )
  } | sort > "$c/m.new"; chmod u+w "$c/prod-skills.manifest" 2>/dev/null; mv "$c/m.new" "$c/prod-skills.manifest"; }
p_verify_paths() { local sc="${1:-$MNEW}" h c pr
  for h in claude codex; do
    newhomes; mkmini "$sc"; run "$MIS" --host "$h"; [[ $RC == 0 ]] || return 1
    pr="$(host_cfg "$h")"; W="$T/w$mk.$h"                                                 # pristine install; each case works on a fresh copy
    wcopy() { chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; cp -R "$pr" "$W"; if [[ $h == claude ]]; then CL="$W"; else CX="$W"; fi; c="$W"; }
    wcopy; chmod -R u+w "$c/skills/prod-ops"; mkdir "$c/skills/prod-ops/sub"; mv "$c/skills/prod-ops/SKILL.md" "$c/skills/prod-ops/sub/SKILL.md"; chmod -R a-w "$c/skills/prod-ops"; manifest_rewrite "$h"
    run "$MIS" --verify --host "$h"                                                     # right hash, wrong path
    [[ $RC == 2 ]] && grep -q 'stale: prod-ops/SKILL.md' "$T/err" && grep -q 'extra: prod-ops/sub/SKILL.md' "$T/err" || return 1
    wcopy; chmod -R u+w "$c/skills/prod-ops"; echo junk > "$c/skills/prod-ops/extra.txt"; chmod -R a-w "$c/skills/prod-ops"; manifest_rewrite "$h"
    run "$MIS" --verify --host "$h"                                                     # an extra path inside one of our skill dirs
    [[ $RC == 2 ]] && grep -q 'extra: prod-ops/extra.txt' "$T/err" || return 1
    wcopy; if [[ $h == claude ]]; then rm -f "$c/agents/prod-scout.md"; else rm -f "$c/agents/prod-scout.toml"; fi; manifest_rewrite "$h"
    run "$MIS" --verify --host "$h"                                                     # a role file missing from the install
    [[ $RC == 2 ]] && grep -q 'stale: agents/prod-scout' "$T/err" || return 1
    if [[ $h == codex ]]; then
      wcopy; echo 'x' > "$c/agents/prod-extra.toml"; chmod 444 "$c/agents/prod-extra.toml"; manifest_rewrite codex
      run "$MIS" --verify --host codex; [[ $RC == 2 ]] && grep -q 'extra: agents/prod-extra.toml' "$T/err" || return 1   # a role of ours the source does not have
    fi
  done
  chmod -R u+w "$T"/w"$mk".* 2>/dev/null; return 0
}
check "verify is RED for a file at the wrong path (right hash), an extra path in a skill dir, a missing role, an extra role -- both hosts, manifest consistent with the tree" p_verify_paths

# --- lock (B3d) ---------------------------------------------------------------
p_lock() { local sc="${1:-$MNEW}" pa r1 r2 ra
  newhomes; mkmini "$sc"
  env HOME="$HM" CLAUDE_CONFIG_DIR="$CL" CODEX_HOME="$CX" PATH="$SHIM:$PATH" SLOW_MARK="$T/slow.$mk" bash "$MIS" --host both >"$T/outA" 2>"$T/errA" &
  pa=$!
  sleep 0.5                                   # one short sleep: A is inside its first (stalled) copy, holding both locks
  run "$MIS" --host codex; r1=$RC; grep -q 'another install is running' "$T/err" || r1=x
  run "$MIS" --host claude; r2=$RC
  wait "$pa"; ra=$?
  [[ $r1 == 6 && $r2 == 6 && $ra == 0 ]] || return 1
  run "$MIS" --verify --host both; [[ $RC == 0 ]] || return 1
  [[ ! -e "$CL/.prod-skills.lock" && ! -e "$CX/.prod-skills.lock" ]] || return 1                # removed on exit
  mkdir "$CL/.prod-skills.lock"; touch -t 200001010000 "$CL/.prod-skills.lock"                  # an old lock is reported, never stolen
  run "$MIS" --host claude; [[ $RC == 6 ]] && grep -q 'Not stealing' "$T/err" && [[ -d "$CL/.prod-skills.lock" ]]
}
check "two installs: the second exits 6 'another install is running'; final state verifies; locks removed on exit; an old lock is never stolen" p_lock

# --- the nested copy (B3a/b) ---------------------------------------------------
p_nested() { local sc="${1:-$MNEW}" h c
  for h in claude codex; do
    newhomes; mkmini "$sc"; run "$MIS" --host "$h"; c="$(host_cfg "$h")"
    PATH="$SHIM:$PATH" FAIL_TOOL=rm FAIL_PAT='*prod-ops*' FAIL_ALWAYS=1 FAIL_MARK="$T/fm$mk" run "$MIS" --host "$h"   # every rm of prod-ops fails (a locked file)
    [[ ! -e "$c/skills/prod-ops/prod-ops" && -f "$c/skills/prod-ops/SKILL.md" ]] || return 1
    run "$MIS" --verify --host "$h"; [[ $RC == 0 ]] || return 1
  done
}
check "a failed removal cannot produce a nested prod-ops/prod-ops copy (staging + rename); verify is 0 and SKILL.md is at the top" p_nested
c_nested_base() { # the scenario is real: the baseline installer nests under the same fault
  newhomes; run "$MORIG"
  PATH="$SHIM:$PATH" FAIL_TOOL=rm FAIL_PAT='*prod-ops*' FAIL_ALWAYS=1 FAIL_MARK="$T/fmb" run "$MORIG"; [[ -e "$CL/skills/prod-ops/prod-ops" ]]
}
check "control: the baseline installer DOES nest prod-ops/prod-ops under that fault (the case is not vacuous)" c_nested_base

# --- all-or-nothing per host (W6) ----------------------------------------------
p_inject() { local sc="${1:-$MNEW}" h kind tool pat b c
  for h in claude codex; do
    newhomes; mkmini "$sc"; run "$MIS" --host "$h"; c="$(host_cfg "$h")"; b="$(snap "$c")"       # one installed tree: every failed run must leave it as it was
    cp "$MI/prod-curate/SKILL.md" "$T/cur.bak"; printf '\nv2\n' >> "$MI/prod-curate/SKILL.md"   # the next install would change something
    kinds="stage place aside manifest chmod"; [[ $h == claude ]] && kinds="stage manifest"      # same code path on both hosts: the full list on Codex, the ends on Claude (CPU)
    for kind in $kinds; do
      case $kind in stage) tool="cp"; pat='*.prod-stage.*.prod-curate' ;; place) tool="mv"; pat='*/skills/prod-curate' ;;
                    aside) tool="mv"; pat='*.prod-trash.*.prod-ops' ;; manifest) tool="mv"; pat='*/prod-skills.manifest' ;;
                    chmod) tool="chmod"; pat='*/skills/prod-spec' ;; esac
      PATH="$SHIM:$PATH" FAIL_TOOL=$tool FAIL_PAT="$pat" FAIL_MARK="$T/fi$mk$kind" run "$MIS" --host "$h"
      [[ $RC == 7 && "$(snap "$c")" == "$b" ]] || { echo "     inject $h/$kind: rc=$RC or tree changed"; return 1; }
    done
    cp "$T/cur.bak" "$MI/prod-curate/SKILL.md"; run "$MIS" --verify --host "$h"; [[ $RC == 0 ]] || { echo "     inject $h: previous state no longer verifies"; return 1; }
    newhomes; mkmini "$sc"; PATH="$SHIM:$PATH" FAIL_TOOL=cp FAIL_PAT='*.prod-stage.*.prod-curate' FAIL_MARK="$T/ff$mk" run "$MIS" --host "$h"
    [[ $RC == 7 && "$(snap "$(host_cfg "$h")")" == "" ]] || { echo "     first install $h: left something behind"; return 1; }
  done
}
check "an injected failure (stage cp, commit mv, move-aside, manifest mv, chmod) rolls the host back: tree identical, previous state verifies; a failed first install leaves nothing" p_inject

# --- explicit modes (W7) -------------------------------------------------------
p_modes() { local sc="${1:-$MNEW}" um; um="$(umask)"
  newhomes; mkmini "$sc"; umask 000; run "$MIS" --host codex; umask "$um"
  [[ $RC == 0 && -z "$(find "$CX" -mindepth 1 \( -perm -g+w -o -perm -o+w \) -not -type l)" ]] && [[ "$(modes "$CX" | grep ' prod-skills.manifest$' | cut -d' ' -f1)" == 0444 ]] \
    && [[ "$(stat -c %a "$CX/skills" 2>/dev/null || python3 -I -c 'import os,sys;print("%o"%(os.stat(sys.argv[1]).st_mode&0o777))' "$CX/skills")" == 755 ]]
}
check "codex under umask 000: skills/, agents/, every file and the manifest are not group/world-writable; manifest 0444" p_modes

# --- source-side refusals ------------------------------------------------------
c_dangling() {
  newhomes; mkmini; ln -s /nonexistent/target "$MI/prod-ops/references/dangling"
  run "$MIS" --host codex; [[ $RC == 1 ]] && grep -q 'dangling' "$T/err" && grep -q 'references/dangling' "$T/err" && [[ -z "$(find "$CX" -mindepth 1)" ]] || return 1
  run "$MIS" --host claude; [[ $RC == 0 ]]                                              # Claude keeps dropping it silently (documented)
}
check "a dangling symlink in the source: codex refuses naming it (exit 1, nothing written); claude keeps its historic behaviour" c_dangling
c_nonprod() {
  newhomes; mkmini; printf -- '---\nname: extra\ndescription: not ours\ntools: Read\n---\nbody\n' > "$MI/agents/extra.md"
  run "$MIS" --host codex; [[ $RC == 0 && ! -e "$CX/agents/extra.toml" ]] && grep -q 'not a prod-\* agent' "$T/err" || return 1
  run "$MIS" --verify --host codex; [[ $RC == 0 ]] || return 1
  run "$MIS" --host claude; [[ $RC == 0 && -f "$CL/agents/extra.md" ]] && { run "$MIS" --verify --host claude; [[ $RC == 0 ]]; }
}
check "a non-prod agent file: not installed, hashed or locked for codex (stderr says so); the claude side still copies it" c_nonprod
c_both_claude_only() {
  newhomes; run "$MNEW" --host both; tamper_file "$CL/skills/prod-ops/SKILL.md"; run "$MNEW" --verify --host both
  [[ $RC == 1 ]] && grep -q 'verify FAILED for: claude(exit 1)' "$T/err" && ! grep -q 'codex(exit' "$T/err"
}
check "--verify --host both with only the Claude side failing names only claude" c_both_claude_only

# --- TOML generation (W1, W3, W4) ----------------------------------------------
mkweird() { python3 -I - "$MI/agents" <<'PY'
import sys
d = sys.argv[1]
body = ("Body with ''' and \"\"\" and a \\ backslash and a literal \\n.\n"
        "Tab:\there, CR:\rmid, bell:\x07, DEL:\x7f, ctl:\x01, non-ascii: h\u00e9llo \u2713 \u65e5\u672c\n"
        "---\n\nlast line  \n")
fm = ('---\nname: prod-weird\ndescription: He said "hi" \\ back\tslash \'x\' cr\rhere\n'
      'tools: "Read", \'Grep\', Bash\n---\n')
open(d + '/prod-weird.md', 'wb').write((fm + body).encode('utf-8'))
open(d + '/prod-notools.md', 'wb').write(b'---\nname: prod-notools\ndescription: no tools line\n---\nplain body\n')
PY
}
p_toml_roundtrip() { local sc="${1:-$MNEW}"
  newhomes; mkmini "$sc"; mkweird; run "$MIS" --host codex; [[ $RC == 0 ]] || return 1
  python3 -I - "$MI/agents" "$CX/agents" <<'PY'
import sys, tomllib, re
src, dst = sys.argv[1:3]
raw = open(src + '/prod-weird.md', 'rb').read().decode('utf-8')
fm, body = re.match(r'---\n(.*?)\n---\n(.*)', raw, re.S).groups()
desc = re.search(r'^description:[ \t]*(.*)$', fm, re.M).group(1)
d = tomllib.load(open(dst + '/prod-weird.toml', 'rb'))
assert d['name'] == 'prod-weird' and d['description'] == desc, (d['description'], desc)
di = d['developer_instructions']
assert di.startswith(body.rstrip('\n') + '\n\n## Host restrictions (Codex)\n'), repr(di[:200])
assert 'allow-list of this role ("Read", \'Grep\', Bash)' in di
n = tomllib.load(open(dst + '/prod-notools.toml', 'rb'))['developer_instructions']
assert 'declares no tool restriction' in n and 'must not' not in n, n
PY
}
p_toml_refusals() { local sc="${1:-$MNEW}" f
  newhomes; mkmini "$sc"; printf -- '---\nname: prod-nul\ndescription: nul\ntools: Read\n---\nbo\000dy\n' > "$MI/agents/prod-nul.md"
  run "$MIS" --host codex; [[ $RC == 1 ]] && grep -q 'NUL' "$T/err" && [[ -z "$(find "$CX" -mindepth 1)" ]] || return 1
  newhomes; mkmini "$sc"; printf -- '---\nname: prod-bad\ndescription: other\ntools: Read\n---\nbody\n' > "$MI/agents/prod-bad.md"
  sed -i.bak 's/^name: prod-bad/name: prod-other/' "$MI/agents/prod-bad.md"; rm -f "$MI/agents/prod-bad.md.bak"   # name differs from the file name
  run "$MIS" --host codex; [[ $RC == 1 && ! -e "$CX/agents/prod-bad.toml" && -z "$(find "$CX" -mindepth 1)" ]] || return 1
  return 0
}
p_name_traversal() { local sc="${1:-$MNEW}"
  newhomes; mkmini "$sc"; printf -- '---\nname: ../x\ndescription: d\ntools: Read\n---\nb\n' > "$MI/agents/prod-trav.md"
  run "$MIS" --host codex; [[ $RC == 1 && -z "$(find "$CX" -mindepth 1)" && ! -e "$H/x.toml" ]] || return 1
  newhomes; mkmini "$sc"; printf -- '---\nname: Prod-Up\ndescription: d\ntools: Read\n---\nb\n' > "$MI/agents/prod-up.md"
  run "$MIS" --host codex; [[ $RC == 1 && -z "$(find "$CX" -mindepth 1)" ]]
}
p_toml_utf8() { local sc="${1:-$MNEW}"
  newhomes; mkmini "$sc"; printf -- '---\nname: prod-u8\ndescription: bad \377 byte\ntools: Read\n---\nb\n' > "$MI/agents/prod-u8.md"
  run "$MIS" --host codex; [[ $RC == 1 && ! -e "$CX/agents/prod-u8.toml" && -z "$(find "$CX" -mindepth 1)" ]] && grep -q 'round-trip' "$T/err"
}
if (( HAVE_TOML )); then
  check "TOML: a body with ''' and \"\"\", backslashes, CR, tab, bell, DEL, non-ASCII and a quoted tools line round-trips exactly; no tools line says so" p_toml_roundtrip
  check "TOML: a file that does not parse back to the intended values (invalid UTF-8) is refused, nothing written" p_toml_utf8
else skipped=$((skipped+2)); echo "skip - TOML round-trip cases: python3 has no tomllib (the installer then relies on its escaper alone)"; fi
check "a NUL byte, or a frontmatter name different from the file name, is refused (exit 1) with nothing written" p_toml_refusals
check "a frontmatter name with / or .., or upper case, is refused before any path is built; no stage file is left" p_name_traversal

# --- mutations: break one behaviour in a scratch copy, the probe must go RED ----
MUT="$M/install.mut.sh"
mutate() { # mutate <old> <new> [<old> <new>...] ; literal, each must match exactly once
  python3 -I - "$MNEW" "$MUT" "$@" <<'PY'
import sys
src, dst = sys.argv[1:3]
s = open(src).read()
a = sys.argv[3:]
for old, new in zip(a[0::2], a[1::2]):
    assert s.count(old) == 1, 'pattern count %d: %s' % (s.count(old), old[:50])
    s = s.replace(old, new)
open(dst, 'w').write(s)
PY
}
probe_manifest()   { newhomes; run "$1" --host codex; [[ -s "$CX/prod-skills.manifest" ]]; }
probe_verify()     { newhomes; run "$1" --host codex; tamper_file "$CX/skills/prod-ops/SKILL.md"; run "$1" --verify --host codex; [[ $RC == 1 ]]; }
probe_deref()      { newhomes; run "$1" --host codex; [[ -z "$(find "$CX" -type l)" && -n "$(find "$CX/skills/prod-spec/references" -type f | head -1)" ]]; }
probe_default()    { newhomes; run "$1"; [[ "$(listing "$CX")" == "." && -s "$CL/prod-skills.manifest" ]]; }
probe_restrict()   { newhomes; run "$1" --host codex; grep -q 'must not spawn other agents' "$CX/agents/prod-scout.toml" && grep -q 'must not edit' "$CX/agents/prod-scout.toml"; }
probe_isolation()  { newhomes; run "$1" --host claude; local b; b="$(listing "$CL")"; run "$1" --host codex; [[ "$(listing "$CL")" == "$b" ]]; }
probe_isolation_cx() { newhomes; run "$1" --host codex; local b; b="$(listing "$CX")"; run "$1" --host claude; [[ "$(listing "$CX")" == "$b" ]]; }
red() { # red <label> <probe> <old> <new> [<old> <new>...]
  local label="$1" probe="$2"; shift 2
  mutate "$@" || { bad=$((bad+1)); echo "FAIL - mutation $label: ERROR (pattern did not apply)"; return; }
  case "$GREEN" in *" $probe "*) ;; *) if ! "$probe" "$MNEW"; then bad=$((bad+1)); echo "FAIL - mutation $label: probe fails on the REAL installer"; return; fi ;; esac   # already proven green by its own check
  if "$probe" "$MUT"; then bad=$((bad+1)); echo "FAIL - mutation $label: GREEN (probe cannot see it)"
  else ok=$((ok+1)); echo "ok   - mutation $label: RED"; fi
}
red "codex manifest not written" probe_manifest \
  'mv "$mt" "$manifest" || fail_step "cannot move the manifest into place"' \
  'if [[ "$cur_host" == claude ]]; then mv "$mt" "$manifest" || fail_step "cannot move the manifest into place"; fi'
red "codex verify always 0" probe_verify '( verify_host ); r=$?' '( verify_host ); r=$?; [[ $h == codex ]] && r=0'
red "references not dereferenced for codex" probe_deref \
  'if [[ -d "$src/$s/references" ]]; then' 'if [[ -d "$src/$s/references" && "$cur_host" == claude ]]; then'
red "default host changed to both" probe_default 'host=claude; mode=""; adopt=0' 'host=both; mode=""; adopt=0'
red "default host changed to both (baseline transcript)" p_default_out 'host=claude; mode=""; adopt=0' 'host=both; mode=""; adopt=0'
red "default stdout line changed (baseline transcript)" p_default_out 'echo "installed ${#skills[@]} skills + $(ls' 'echo "installed ${#skills[@]} skills and $(ls'
red "role restriction block dropped" probe_restrict 'restr="$restr You must not spawn other agents."' ':'
red "claude tree modified by a codex run" probe_isolation \
  '  install_host || exit $?' '  install_host || exit $?; [[ $h == codex ]] && touch "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/stray"'
red "codex tree modified by a claude run" probe_isolation_cx \
  '  install_host || exit $?' '  install_host || exit $?; [[ $h == claude ]] && touch "${CODEX_HOME:-$HOME/.codex}/stray"'
red "symlink guard removed (leaf: role file, skill dir)" p_sym_leaf '  if [[ -L "$1" ]]; then' '  if false; then'
red "symlink guard removed (intermediate: skills/, agents/, manifest)" p_sym_dirs \
  'for d in "$cfg/skills" "$cfg/agents" "$manifest"; do' 'for d in; do'
red "ownership check removed" p_foreign 'elif [[ -e "$1" ]] && ! owned_in_manifest "$2"; then' 'elif false; then'
red "--adopt deletes instead of backing up" p_foreign \
  'u_old[$i]="$d.bak.$ts"; [[ -e "${u_old[$i]}" ]] && u_old[$i]="$d.bak.$ts.$$"' \
  'u_old[$i]="$(dirname "$d")/.prod-trash.$$.$(basename "$d")"; tmp_paths+=("${u_old[$i]}")'
red "verify back to hash-only" p_verify_paths \
  "man_skill_rows=\$(grep -v '  \\./' \"\$manifest\" | LC_ALL=C sort)" "man_skill_rows=\$(grep -v '  \\./' \"\$manifest\" | awk '{print \$1}' | LC_ALL=C sort)" \
  '-exec shasum -a 256 {} + 2>/dev/null | LC_ALL=C sort)' "-exec shasum -a 256 {} + 2>/dev/null | awk '{print \$1}' | LC_ALL=C sort)"
red "manifest written before the copy finished" p_inject \
  '|| fail_step "cannot create $cfg/skills and $cfg/agents"' '|| fail_step "cannot create $cfg/skills and $cfg/agents"
echo premature > "$manifest"'
red "lock removed" p_lock 'for h in "${hosts[@]}"; do set_host "$h"; lock_host; done' ':'
c_baseline_mutant() { ! guard_baseline "$MNEW"; }        # the fixture replaced by the current script (what HEAD:install.sh is once committed)
if c_baseline_mutant; then ok=$((ok+1)); echo "ok   - mutation baseline fixture replaced by HEAD: RED"; else bad=$((bad+1)); echo "FAIL - mutation baseline fixture replaced by HEAD: GREEN"; fi
red "explicit modes removed" p_modes '[[ "$cur_host" == codex ]] && umask 022' ':'
red "name validation skipped" p_toml_refusals 'valid_role_name() { [[ "$1" =~ ^[a-z][a-z0-9-]*$ && "$1" == "$2" ]]; }' 'valid_role_name() { true; }'
red "name validation skipped (traversal)" p_name_traversal 'valid_role_name() { [[ "$1" =~ ^[a-z][a-z0-9-]*$ && "$1" == "$2" ]]; }' 'valid_role_name() { true; }'
if (( HAVE_TOML )); then
  red "TOML validation skipped" p_toml_utf8 'toml_check_all "${chk_args[@]}"; rc=$?' 'rc=0'
else skipped=$((skipped+1)); echo "skip - mutation TOML validation skipped: no tomllib here"; fi

# --- nothing escaped to the real home -----------------------------------------
c_home_clean() { # every run had HOME under $T; the only things ever created there are the default-root case's
  [[ -z "$(find "$T"/h*/home -mindepth 1 -not -path '*/.codex*' -not -path '*/.claude*' 2>/dev/null)" ]]
}
check "HOME stayed empty except the default-roots case's .codex/.claude" c_home_clean

echo "$ok ok, $bad failed, $skipped skipped"
[[ $bad == 0 ]]
