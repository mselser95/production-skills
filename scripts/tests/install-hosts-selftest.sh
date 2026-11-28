#!/usr/bin/env bash
# install-hosts-selftest.sh -- install.sh --host claude|codex|both, hermetically: BEHAVIOUR cases.
# (The mutation proofs live in install-hosts-mutations-selftest.sh, one targeted probe per mutant.)
#
# Everything runs against a COPY of this repo or a MINI tree under a temp dir, with HOME,
# CLAUDE_CONFIG_DIR and CODEX_HOME all pointed under that temp dir, so nothing is ever
# written to the real home. The BASELINE installer is the committed fixture
# scripts/tests/fixtures/install.base.sh.txt (install.sh at the merge-base with master,
# NOT HEAD: HEAD's copy equals the script under test once committed and could never
# differ). It is run beside the new one to prove the default is unchanged; a guard
# case proves the fixture is not vacuous.
#
# COST: one FULL-tree case (default vs baseline). Every other case uses the MINI tree (nine
# one-line skills, two agents) and derives read-only cases from cp -R COPIES of an install
# built once per host, instead of re-installing. Each run goes through run() (counts
# installs) or grun() (adds a per-case watchdog: a hang is RC=124, a FAIL, not a stuck suite).
# Failure injection uses one shim directory per tool, so only the faulted tool pays the
# shim's startup. Signal cases use a mv shim that signals the installer at its Nth rename.
# Sequential; the only background process is the first of the two concurrent installs in
# the lock case, waited for.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_HOME="${HOME:-}"
T="$(mktemp -d "${TMPDIR:-/tmp}/install-hosts.XXXXXX")" || exit 1
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT      # only the directory this run created
case "$T" in "$REAL_HOME"/*) echo "refusing: temp dir $T is under the real home" >&2; exit 1 ;; esac
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
REALPY="$(command -v python3)"

GREEN=" "; HAVE_TOML=0; python3 -I -c 'import tomllib' 2>/dev/null && HAVE_TOML=1
ok=0; bad=0; skipped=0
check() { # check <name> <fn> ; fn returns 0 when the property holds
  if "$2"; then ok=$((ok+1)); GREEN=" $GREEN$2 "; echo "ok   - $1 [${SECONDS}s]"; else bad=$((bad+1)); echo "FAIL - $1 [${SECONDS}s]"; fi
}
installs=0   # counted by run(): every installer invocation without --verify

n=0; HM=""; CL=""; CX=""; H=""
newhomes() { n=$((n+1)); H="$T/h$n"; HM="$H/home"; CL="$H/claude"; CX="$H/codex"; mkdir -p "$HM" "$CL" "$CX"; }
# run <script> args...  -> RC, files $T/out $T/err (raw). HOME, CLAUDE_CONFIG_DIR, CODEX_HOME always under $T.
run() { local sc="$1"; shift
  case " $* " in *" --verify "*|*" --diff "*) ;; *) installs=$((installs+1)) ;; esac
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
contents() { ( cd "$1" && find . -type f -exec cksum {} + | sort -k3 ); }
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
mkmini() { # a private copy of the mini tree whose install.sh is the script under test
  mk=$((mk+1)); MI="$T/mi$mk"; cp -R "$M" "$MI"; cp "$MNEW" "$MI/install.sh"; rm -f "$MI/install.mut.sh"; MIS="$MI/install.sh"; }
export CAN=""
mkcanary() { CAN="$H/canary"; mkdir -p "$CAN/d/references" "$CAN/sdir"; echo role > "$CAN/role.toml"; chmod 444 "$CAN/role.toml"; echo s > "$CAN/sdir/f"
  echo precious > "$CAN/d/references/userfile"; echo precious > "$CAN/file.txt"; chmod 444 "$CAN/file.txt"
  touch -t 202001010000 "$CAN/role.toml" "$CAN/sdir/f" "$CAN/sdir" "$CAN/d/references/userfile" "$CAN/d/references" "$CAN/d" "$CAN/file.txt" "$CAN"; }

# --- shims (used per command, via PATH, never globally) ---------------------
# .shim: cp/mv/chmod/rm that FAIL on demand (FAIL_TOOL, FAIL_PAT glob on the LAST argument, first match
# only unless FAIL_ALWAYS) or stall the first cp (SLOW_MARK).
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
chmod +x "$SHIM/.shim"
for t in cp mv chmod rm; do mkdir -p "$SHIM/$t"; ln -s ../.shim "$SHIM/$t/$t"; done   # one dir per tool: only the faulted tool pays the shim's bash startup
# mv shim only: SIG_AT=<N> SIG_NAME=<sig> SIG_CNT=<file> sends the signal to the installer (our parent)
# just before the Nth mv; RACE_DEST=<path> creates a directory at <path> right after the mv that moved it
# away (something appearing between the move-aside and the move-in).
SHIMMV="$T/shimmv"; mkdir -p "$SHIMMV"
cat > "$SHIMMV/mv" <<'SH'
#!/bin/bash
src_arg="${@: -2:1}"
if [[ -n "${SIG_AT:-}" ]]; then
  c=$(( $(cat "$SIG_CNT" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$SIG_CNT"
  (( c == SIG_AT )) && kill -"$SIG_NAME" "$PPID"
fi
if [[ -n "${RACE_DEST:-}" && "$src_arg" == "$RACE_DEST" ]]; then
  /bin/mv "$@"; rc=$?; mkdir "$RACE_DEST"; : > "$RACE_DEST/planted"; exit $rc
fi
exec /bin/mv "$@"
SH
chmod +x "$SHIMMV/mv"
SHIMMK="$T/shimmk"; mkdir -p "$SHIMMK"; printf '#!/bin/bash\necho "mktemp: simulated failure" >&2\nexit 1\n' > "$SHIMMK/mktemp"; chmod +x "$SHIMMK/mktemp"
# python3 that has no tomllib (what stock macOS 3.9 is): the import probe fails, everything else is the real python3
NOTOML="$T/notoml"; mkdir -p "$NOTOML"
printf '#!/bin/bash\n[[ "$*" == "-I -c import tomllib" ]] && exit 1\nexec "%s" "$@"\n' "$REALPY" > "$NOTOML/python3"; chmod +x "$NOTOML/python3"
# runner: a per-case watchdog (a hang becomes RC=124, never a stuck suite), SIGINT reset to default (a
# backgrounded parent would leave it ignored and untrappable), and, when asked, PREDICTABLE-NAME PLANTING:
# symlinks named after the OLD scheme (<dir>/.prod-*.<this very pid>.*) pointing at $CAN, created in the child
# whose pid the installer will have (it execs bash), so the pid is not guessed but known.
RUNNER="$T/runner.py"
cat > "$RUNNER" <<'PY'
import os, sys, signal
timeout, out, err, plant = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
cmd = sys.argv[5:]
SK = "prod-spec prod-review prod-incident prod-implement prod-test-synth prod-ops prod-curate prod-bootstrap prod-new".split()
pid = os.fork()
if pid == 0:
    os.setsid()
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.dup2(os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644), 1)
    os.dup2(os.open(err, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644), 2)
    if plant != '-':
        me, can = os.getpid(), os.environ['CAN']
        for cfg in plant.split(':'):
            for s in SK:
                os.symlink(can + '/d', '%s/skills/.prod-stage.%d.%s' % (cfg, me, s))
                os.symlink(can + '/d', '%s/skills/.prod-trash.%d.%s' % (cfg, me, s))
            for nm in ('.prod-stage.%d.agents', '.prod-trash.%d.agents', '.prod-work.%d'):
                os.symlink(can + '/d', cfg + '/' + nm % me)
            os.symlink(can + '/file.txt', '%s/.prod-skills.manifest.tmp.%d' % (cfg, me))
    os.execvp(cmd[0], cmd)
timed = [False]
def on_alarm(*a):
    timed[0] = True
    try: os.killpg(pid, 9)
    except OSError: pass
signal.signal(signal.SIGALRM, on_alarm); signal.alarm(timeout)
_, st = os.waitpid(pid, 0)
sys.exit(124 if timed[0] else (os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st)))
PY
# grun <seconds> <plant: cfg[:cfg]|-> <script> args...  -> RC (124 = hang), $T/out $T/err
grun() { local to="$1" pl="$2" sc="$3"; shift 3
  case " $* " in *" --verify "*|*" --diff "*) ;; *) installs=$((installs+1)) ;; esac
  python3 -I "$RUNNER" "$to" "$T/out" "$T/err" "$pl" env HOME="$HM" CLAUDE_CONFIG_DIR="$CL" CODEX_HOME="$CX" bash "$sc" "$@"; RC=$?; }

echo "homes: HOME=$T/h*/home CLAUDE_CONFIG_DIR=$T/h*/claude CODEX_HOME=$T/h*/codex (real home: $REAL_HOME)"

# --- scratch trees -----------------------------------------------------------
# MINI source: the nine skills the installer insists on (a SKILL.md each; prod-ops and prod-spec also carry the
# references symlinks into _shared), two tiny agents, and the 17 mirror pairs the installer checks, a few bytes
# each, so one install is ~100 forks, not ~1500.
M="$T/mini"; mkdir -p "$M/_shared/probes" "$M/agents"
cp "$root/install.sh" "$M/install.sh"; MNEW="$M/install.sh"
cp "$root/scripts/tests/fixtures/install.base.sh.txt" "$M/install.orig.sh"; MORIG="$M/install.orig.sh"
printf -- '---\nname: prod-scout\ndescription: Scout agent\ntools: Read, Grep, Glob\nmodel: haiku\n---\nScout body.\n' > "$M/agents/prod-scout.md"
printf -- '---\nname: prod-worker\ndescription: Worker agent\ntools: Read, Edit, Write, Bash, Agent\n---\nWorker body.\n' > "$M/agents/prod-worker.md"
echo "shared doc" > "$M/_shared/doc.md"; echo "shared probe" > "$M/_shared/probes/p.sh"
for sk in $SK; do
  mkdir -p "$M/$sk"; echo "skill $sk" > "$M/$sk/SKILL.md"
done
for sk in prod-ops prod-spec; do
  mkdir -p "$M/$sk/references/probes"
  ln -s ../../_shared/doc.md "$M/$sk/references/doc.md"; ln -s ../../../_shared/probes/p.sh "$M/$sk/references/probes/p.sh"
done
mirrors="$(sed -n '/^mirrors=(/,/^)/p' "$root/install.sh" | grep -oE '^  "[^"]+"' | tr -d ' "')"
[[ "$(printf '%s\n' "$mirrors" | wc -l | tr -d ' ')" -ge 15 ]] || { echo "could not extract the mirror list" >&2; exit 1; }
for m in $mirrors; do
  for f in "${m%%:*}" "${m##*:}"; do mkdir -p "$M/$(dirname "$f")"; echo "mirror ${m##*:}" > "$M/$f"; done
done
tamper_file() { chmod u+w "$1"; echo tamper >> "$1"; chmod a-w "$1"; }
host_cfg() { [[ $1 == claude ]] && echo "$CL" || echo "$CX"; }

# --- scratch FULL tree (the one full-tree case) + the frozen baseline installer ----------------------
S="$T/src"; mkdir -p "$S"
if command -v rsync >/dev/null 2>&1; then rsync -a --exclude .git --exclude .wt "$root"/ "$S"/ || exit 1
else ( cd "$root" && tar --exclude=./.git --exclude=./.wt -cf - . ) | ( cd "$S" && tar -xf - ) || exit 1; fi
FIXTURE="$root/scripts/tests/fixtures/install.base.sh.txt"
cp "$FIXTURE" "$S/install.orig.sh" || exit 1
cp "$root/install.sh" "$S/install.sh"
NEW="$S/install.sh"; ORIG="$S/install.orig.sh"

# --- shared installed bases: built ONCE; every read-only case works on a cp -R COPY ------------------
newhomes; BASE_C="$CL"; BASE_X="$CX"; run "$MNEW" --host both; BASE_RC=$RC
newhomes; BASE_O="$CL"; run "$MORIG"; BASE_ORC=$RC
putbase() { # putbase claude|codex|orig: copy the pre-built install into the current (empty) CL / CX
  case "$1" in
    claude) rmdir "$CL"; cp -R "$BASE_C" "$CL" ;;
    codex)  rmdir "$CX"; cp -R "$BASE_X" "$CX" ;;
    orig)   rmdir "$CL"; cp -R "$BASE_O" "$CL" ;;
  esac
}
manifest_rewrite() { # rebuild the manifest from the tree as it is now (a consistent-but-wrong install)
  local c; c="$(host_cfg "$1")"
  { ( cd "$c/skills" && find $SK -type f -print0 | sort -z | xargs -0 shasum -a 256 )
    ( cd "$c/agents" && if [[ $1 == claude ]]; then find . -type f -print0; else find . -maxdepth 1 -name 'prod-*.toml' -type f -print0; fi | sort -z | xargs -0 shasum -a 256 )
  } | sort > "$c/m.new"; chmod u+w "$c/prod-skills.manifest" 2>/dev/null; mv "$c/m.new" "$c/prod-skills.manifest"; }
only_ours() { # nothing but our own names in a healthy tree: no .prod-* work/lock/stage/trash/backup, no stray top-level name
  local c="$1"
  [[ -z "$(find "$c" -name '.prod-*')" ]] || return 1
  [[ -z "$(find "$c" -mindepth 1 -maxdepth 1 ! -name skills ! -name agents ! -name prod-skills.manifest)" ]] || return 1
  [[ -z "$(find "$c/skills" -mindepth 1 -maxdepth 1 ! -name 'prod-*')" && -z "$(find "$c/agents" -mindepth 1 -maxdepth 1 ! -name 'prod-*')" ]]
}

# --- 1. default == original: the ONE full-tree case ---------------------------
c_default_identical() {
  newhomes; run "$ORIG"; local rc1=$RC; norm "$T/out" > "$T/o1"; norm "$T/err" > "$T/e1"; local H1="$H" CL1="$CL"
  newhomes; run "$NEW";  local rc2=$RC; norm "$T/out" > "$T/o2"; norm "$T/err" > "$T/e2"
  [[ $rc1 == 0 && $rc2 == 0 ]] || return 1
  cmp -s "$T/o1" "$T/o2" && cmp -s "$T/e1" "$T/e2" || return 1
  diff -r "$CL1" "$CL" >/dev/null || return 1
  [[ "$(modes "$CL1")" == "$(modes "$CL")" ]] || return 1
  [[ "$(listing "$H1/codex")" == "$(listing "$H/codex")" && "$(listing "$H/codex")" == "." ]] || return 1
  # --verify on both, each on the home it just installed
  local H2="$H" HM2="$HM" CL2="$CL" CX2="$CX"
  H="$H1"; CL="$CL1"; CX="$H1/codex"; HM="$H1/home"; run "$ORIG" --verify; rc1=$RC; norm "$T/out" > "$T/o1"; norm "$T/err" > "$T/e1"
  H="$H2"; HM="$HM2"; CL="$CL2"; CX="$CX2"; run "$NEW" --verify; rc2=$RC; norm "$T/out" > "$T/o2"; norm "$T/err" > "$T/e2"
  [[ $rc1 == 0 && $rc2 == 0 ]] && cmp -s "$T/o1" "$T/o2" && cmp -s "$T/e1" "$T/e2"
}
check "FULL TREE: default run + --verify identical to the original installer (tree, modes, manifest, stdout, stderr)" c_default_identical

flow_transcript() { # flow_transcript <script> <out>: install, verify, drift 1, writable 3, stale 2, re-install via an unknown flag and via --help
  local sc="$1" o="$2" f g
  : > "$o"; newhomes; f="$CL/skills/prod-ops/SKILL.md"; g="$CL/skills/prod-curate/SKILL.md"
  step() { run "$sc" "$@"; { echo "## $* rc=$RC"; norm "$T/out"; echo "-- stderr"; norm "$T/err"; } >> "$o"; }
  step; step --verify
  cat "$f" > "$T/ops.keep"; chmod u+w "$f"; echo x >> "$f"; chmod a-w "$f"; step --verify; chmod u+w "$f"; cp "$T/ops.keep" "$f"; chmod a-w "$f"   # drift 1
  chmod u+w "$g"; step --verify; chmod a-w "$g"                                                                                               # writable 3
  cp "$M/prod-ops/SKILL.md" "$T/ops.flow"; printf '\n<!-- stale -->\n' >> "$M/prod-ops/SKILL.md"; step --verify; cp "$T/ops.flow" "$M/prod-ops/SKILL.md"   # stale 2
  step --bogus-flag; step --help
  { echo "## tree"; snap "$CL"; echo "## codex dir"; snap "$CX"; } | sed -e "s|$H|<H>|g" >> "$o"
}
p_flows() { flow_transcript "$MORIG" "$T/flow.base"; flow_transcript "$MNEW" "$T/flow.new"; cmp -s "$T/flow.base" "$T/flow.new"; }
check "healthy default flows (install, verify, drift 1, writable 3, stale 2, re-install via an unknown flag and --help): transcript + trees identical to the baseline" p_flows

# --- per-host verify failures, on COPIES of the pre-built installs --------------------------
hostfail() { # hostfail <host> <drift|stale|writable>
  newhomes; putbase "$1"; local c; c="$(host_cfg "$1")"
  case "$2" in
    drift)    tamper_file "$c/skills/prod-ops/SKILL.md"; run "$MNEW" --verify --host "$1"
              [[ $RC == 1 ]] && grep -q 'TCB DRIFT' "$T/err" ;;
    stale)    mkmini; printf '\n<!-- stale -->\n' >> "$MI/prod-ops/SKILL.md"
              run "$MIS" --verify --host "$1"
              [[ $RC == 2 ]] && grep -q 'STALE INSTALL' "$T/err" && grep -q 'stale: prod-ops/SKILL.md' "$T/err" ;;
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

c_codex_role_tamper() { newhomes; putbase codex; tamper_file "$CX/agents/prod-scout.toml"; run "$MNEW" --verify --host codex
  [[ $RC == 1 ]] && grep -q 'prod-scout.toml' "$T/err"; }
check "codex: tampered generated role file (manifest untouched) -> exit 1 naming it" c_codex_role_tamper

# Codex verify is as strong as Claude's: roles are REGENERATED from the source and compared by (hash, path).
# Mapping, same situation => same code on both hosts: installed role/agent edited + manifest rewritten to match
# => 2 (the row the source would install is not in the manifest); source agent edited, not reinstalled => 2.
c_role_consistent_tamper() { local h
  for h in codex claude; do
    newhomes; putbase "$h"; local f; [[ $h == codex ]] && f="$CX/agents/prod-scout.toml" || f="$CL/agents/prod-scout.md"
    chmod u+w "$f"; echo 'evil = 1' >> "$f"; chmod a-w "$f"; manifest_rewrite "$h"
    run "$MNEW" --verify --host "$h"
    [[ $RC == 2 ]] && grep -q 'stale: agents/prod-scout' "$T/err" || { echo "     $h: rc=$RC"; return 1; }
  done
}
check "a role/agent edited together with the manifest: verify is 2 STALE on BOTH hosts (Codex compares the regenerated file, not only the path)" c_role_consistent_tamper
c_source_agent_edited() { local h
  for h in codex claude; do
    newhomes; putbase "$h"; mkmini; printf 'more words\n' >> "$MI/agents/prod-scout.md"
    run "$MIS" --verify --host "$h"
    [[ $RC == 2 ]] && grep -q 'stale: agents/prod-scout' "$T/err" || { echo "     $h: rc=$RC"; return 1; }
  done
}
check "a source agent edited but not reinstalled: verify is 2 STALE on BOTH hosts" c_source_agent_edited
c_skill_consistent_tamper() { local h c
  for h in codex claude; do
    newhomes; putbase "$h"; c="$(host_cfg "$h")"; tamper_file "$c/skills/prod-ops/SKILL.md"; manifest_rewrite "$h"
    run "$MNEW" --verify --host "$h"; [[ $RC == 2 ]] && grep -q 'stale: prod-ops/SKILL.md' "$T/err" || return 1
  done
}
check "a skill file edited together with the manifest: verify is 2 STALE on both hosts" c_skill_consistent_tamper

c_both() {
  [[ $BASE_RC == 0 && -s "$BASE_C/prod-skills.manifest" && -s "$BASE_X/prod-skills.manifest" && -f "$BASE_C/agents/prod-scout.md" && -f "$BASE_X/agents/prod-scout.toml" ]] || return 1
  newhomes; putbase claude; putbase codex; run "$MNEW" --verify --host both; [[ $RC == 0 ]] || return 1
  tamper_file "$CX/skills/prod-ops/SKILL.md"; run "$MNEW" --verify --host both
  [[ $RC == 1 ]] && grep -q 'verify FAILED for: codex(exit 1)' "$T/err" && ! grep -q 'claude(exit' "$T/err" || return 1
  tamper_file "$CL/skills/prod-ops/SKILL.md"; run "$MNEW" --verify --host both
  [[ $RC == 1 ]] && grep -q 'claude(exit 1)' "$T/err" && grep -q 'codex(exit 1)' "$T/err"
}
check "--host both installed both; --verify --host both names the failing host(s), exit 1" c_both
c_both_claude_only() {
  newhomes; putbase claude; putbase codex; tamper_file "$CL/skills/prod-ops/SKILL.md"; run "$MNEW" --verify --host both
  [[ $RC == 1 ]] && grep -q 'verify FAILED for: claude(exit 1)' "$T/err" && ! grep -q 'codex(exit' "$T/err"
}
check "--verify --host both with only the Claude side failing names only claude" c_both_claude_only

c_usage() {
  newhomes; run "$MNEW" --host nonsense; [[ $RC == 2 ]] && grep -q 'usage' "$T/err" || return 1
  run "$MNEW" --host; [[ $RC == 2 ]] || return 1
  run "$MNEW" --verify --host=bogus; [[ $RC == 2 ]] || return 1
  [[ "$(listing "$CL")" == "." && "$(listing "$CX")" == "." ]]
}
check "unknown host / missing value -> exit 2 usage, nothing installed" c_usage

c_isolation() {
  newhomes; putbase claude; local b; b="$(snap "$CL")"
  run "$MNEW" --host codex; [[ $RC == 0 && "$(snap "$CL")" == "$b" ]] || return 1
  run "$MNEW" --verify --host both; [[ $RC == 0 ]]            # (the converse, a claude run leaving the Codex home alone, is a mutation probe)
}
check "a codex run leaves the Claude home untouched, and vice versa" c_isolation

c_structure() { # the installer only ever leaves OUR names behind: destinations and the manifest
  only_ours "$BASE_C" && only_ours "$BASE_X" || return 1
  [[ "$(find "$BASE_X/skills" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 9 && "$(find "$BASE_X/agents" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 2 ]]
}
check "after a healthy install the home holds only the destinations and the manifest: no work dir, lock, stage, trash or backup names" c_structure

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
  newhomes; installs=$((installs+1))
  env -u CODEX_HOME -u CLAUDE_CONFIG_DIR HOME="$HM" bash "$MNEW" --host both >/dev/null 2>&1 || return 1
  [[ -s "$HM/.codex/prod-skills.manifest" && -s "$HM/.claude/prod-skills.manifest" ]] || return 1
  [[ "$(listing "$CL")" == "." && "$(listing "$CX")" == "." ]]
}
check "default roots are \$HOME/.codex and \$HOME/.claude (temp HOME); the env-named dirs stay empty" c_default_roots

# --- baseline fixture guard ---------------------------------------------------------------------------
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

# --- symlinks are never written through --------------------------------------------------------
p_sym_leaf() { local b
  newhomes; mkcanary; mkdir -p "$CX/agents"; ln -s "$CAN/role.toml" "$CX/agents/prod-scout.toml"
  b="$(snap "$CAN" mt)"; run "$MNEW" --host codex
  [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" && ! -e "$CX/prod-skills.manifest" ]] && grep -q 'destination is a symlink' "$T/err" || return 1
  [[ -z "$(find "$CX/skills" -mindepth 1 2>/dev/null)" ]] || return 1
  newhomes; mkcanary; mkdir -p "$CX/skills"; ln -s "$CAN/sdir" "$CX/skills/prod-ops"
  b="$(snap "$CAN" mt)"; run "$MNEW" --host codex; [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" && ! -e "$CX/prod-skills.manifest" ]] || return 1
  # after a healthy install one of OUR skills turns into a symlink: still refused, canary untouched
  newhomes; mkcanary; putbase codex
  chmod -R u+w "$CX/skills/prod-review"; rm -rf "$CX/skills/prod-review"; ln -s "$CAN/sdir" "$CX/skills/prod-review"
  b="$(snap "$CAN" mt)"; run "$MNEW" --host codex; [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" ]]
}
check "codex: a symlinked role file or skill dir (fresh, or after an install) is refused with exit 4; the canary outside the home keeps mode, content, mtime" p_sym_leaf
p_sym_dirs() { local b d
  for d in skills agents; do
    newhomes; mkcanary; ln -s "$CAN/sdir" "$CX/$d"; b="$(snap "$CAN" mt)"; run "$MNEW" --host codex
    [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" && ! -e "$CX/prod-skills.manifest" ]] || return 1
  done
  newhomes; mkcanary; ln -s "$CAN/role.toml" "$CX/prod-skills.manifest"; b="$(snap "$CAN" mt)"; run "$MNEW" --host codex
  [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" ]]
}
check "codex: skills/ or agents/ or the manifest being a symlink -> exit 4, nothing written through it" p_sym_dirs
c_claude_leaf() { # the Claude path keeps its historic behaviour: a link is replaced, never followed; a same-named real dir is replaced (known limitation)
  newhomes; mkcanary; mkdir -p "$CL/skills/prod-ops" "$CL/skills/prod-review"; echo own > "$CL/skills/prod-ops/own.txt"
  ln -s "$CAN/sdir" "$CL/skills/prod-review"; local b; b="$(snap "$CAN" mt)"
  run "$MNEW" --host claude; [[ $RC == 0 && "$(snap "$CAN" mt)" == "$b" && -d "$CL/skills/prod-review" && ! -L "$CL/skills/prod-review" ]] || return 1
  [[ ! -e "$CL/skills/prod-ops/own.txt" && -f "$CL/skills/prod-ops/SKILL.md" ]]
}
check "claude: a leaf symlink at one of our skill names is replaced and a same-named real dir is replaced (historic, see _shared/hosts.md); the link's target is never written" c_claude_leaf
c_manifest_symlink_claude() { # a manifest that is a symlink to a DIRECTORY: mv would move INTO it; the link is replaced, the target untouched
  local b
  newhomes; mkcanary; putbase claude; rm -f "$CL/prod-skills.manifest"; ln -s "$CAN/sdir" "$CL/prod-skills.manifest"; b="$(snap "$CAN" mt)"
  run "$MNEW" --host claude; [[ $RC == 0 && "$(snap "$CAN" mt)" == "$b" && -f "$CL/prod-skills.manifest" && ! -L "$CL/prod-skills.manifest" ]]
}
check "claude: a manifest that is a symlink to a directory is replaced by rename; the canary keeps mode, content, mtime" c_manifest_symlink_claude

# --- ownership by manifest ----------------------------------------------------------------------
only_ours_except_backups() { [[ -z "$(find "$CX" -name '.prod-*' ! -path '*/.prod-backups*')" ]]; }

p_foreign() { local b
  newhomes; mkmini; mkdir -p "$CX/agents" "$CX/skills/prod-ops"; echo mine > "$CX/agents/prod-scout.toml"; echo own > "$CX/skills/prod-ops/own.txt"
  b="$(snap "$CX")"; run "$MIS" --host both
  [[ $RC == 5 ]] && grep -q 'not installed by this tool' "$T/err" && grep -q -- '--adopt' "$T/err" || return 1
  [[ "$(snap "$CX")" == "$b" && -z "$(find "$CL" -mindepth 1)" ]] || return 1          # nothing installed, on either host
  run "$MIS" --host codex --adopt; [[ $RC == 0 ]] || return 1
  [[ "$(cat "$CX"/.prod-backups/*/agents/prod-scout.toml 2>/dev/null)" == mine && "$(cat "$CX"/.prod-backups/*/skills/prod-ops/own.txt 2>/dev/null)" == own ]] || return 1
  grep -q "adopted files were moved under $CX/.prod-backups/" "$T/out" || return 1      # the path is printed
  [[ -z "$(find "$CX/skills" "$CX/agents" -name '*.bak*')" ]] || return 1               # never discoverable as a skill/role
  run "$MIS" --verify --host codex; [[ $RC == 0 ]] || return 1
  run "$MIS" --host codex; [[ $RC == 0 && "$(find "$CX/.prod-backups" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 1 ]] || return 1   # now ours: replaced without --adopt, no new backup
  chmod u+w "$CX/prod-skills.manifest"; rm -f "$CX/prod-skills.manifest"                  # everything is "not ours" again: a second --adopt, within the same second
  run "$MIS" --host codex --adopt; [[ $RC == 0 ]] || return 1
  [[ "$(find "$CX/.prod-backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 2 ]] || return 1          # two distinct backup directories
  [[ "$(cat "$CX"/.prod-backups/*/skills/prod-ops/own.txt 2>/dev/null | sort -u)" == own ]] || return 1             # the first backup still holds the original
  [[ -z "$(find "$CX/skills" "$CX/agents" -name '*.bak*')" ]] && only_ours_except_backups
}
check "codex: same-named foreign role and skill -> exit 5, nothing installed on either host; --adopt backs them up under .prod-backups (never deletes, never under skills/); a second --adopt makes a second, distinct backup directory" p_foreign
# --- verify compares (path, hash) rows ---------------------------------------------------------
p_verify_paths() { local h c pr
  for h in claude codex; do
    newhomes; mkmini; putbase "$h"
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

# --- lock ----------------------------------------------------------------------------------------
p_lock() { local pa r1 r2 ra
  newhomes; mkmini
  env HOME="$HM" CLAUDE_CONFIG_DIR="$CL" CODEX_HOME="$CX" PATH="$SHIM/cp:$PATH" SLOW_MARK="$T/slow.$mk" bash "$MIS" --host both >"$T/outA" 2>"$T/errA" &
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
p_pidfiles() { local kind err_size
  for kind in fifo symlink big escape dead live; do
    newhomes; mkmini; mkcanary; mkdir "$CL/.prod-skills.lock"
    case "$kind" in
      fifo)    mkfifo "$CL/.prod-skills.lock/pid" ;;
      symlink) echo 4242 > "$CAN/pidtarget"; ln -s "$CAN/pidtarget" "$CL/.prod-skills.lock/pid" ;;
      big)     python3 -I -c 'import sys; sys.stdout.write("AB" * (2500 * 1024))' > "$CL/.prod-skills.lock/pid" ;;     # 5 MB
      escape)  printf '\033[31mEVIL-OWNER\033]0;pwned\007\n' > "$CL/.prod-skills.lock/pid" ;;
      dead)    ( : ) & wait $!; echo "$!" > "$CL/.prod-skills.lock/pid" ;;                                              # a pid that has exited
      live)    echo "$$" > "$CL/.prod-skills.lock/pid" ;;
    esac
    grun 20 - "$MIS" --host claude
    [[ $RC == 6 ]] || { echo "     $kind: rc=$RC (124 = hang)"; return 1; }
    err_size="$(wc -c < "$T/err" | tr -d ' ')"; (( err_size < 700 )) || { echo "     $kind: $err_size bytes on stderr"; return 1; }
    case "$kind" in dead|live) ;; *) ! LC_ALL=C grep -q -e 'EVIL' -e 'ABAB' -e "$(printf '\033')" -e 4242 "$T/err" || { echo "     $kind: file content echoed"; return 1; } ;; esac
    [[ -d "$CL/.prod-skills.lock" ]] || { echo "     $kind: the lock was removed"; return 1; }
    case "$kind" in
      dead) grep -q 'stale lock' "$T/err" && grep -q 'is not running' "$T/err" && grep -q "rm -rf '$CL/.prod-skills.lock'" "$T/err" || return 1 ;;
      live) grep -q 'another install is running' "$T/err" || return 1 ;;
      *)    grep -q 'owner is unreadable' "$T/err" && grep -q 'Not stealing' "$T/err" || return 1 ;;
    esac
  done
}
check "lock: a FIFO / symlink / 5 MB / escape-sequence pid file never hangs or echoes raw (exit 6); a dead owner is named with the removal command; a live one is 'running'; the lock is never stolen" p_pidfiles
p_lock_create() {
  newhomes; mkmini; chmod 555 "$CL"
  if [[ -w "$CL" ]]; then chmod 755 "$CL"; echo "     (skipped: permissions are not enforced here, e.g. root)"; skipped=$((skipped+1)); return 0; fi
  run "$MIS" --host claude; chmod 755 "$CL"
  [[ $RC == 7 ]] && grep -q 'cannot create the lock directory' "$T/err" && grep -qi 'permission denied' "$T/err" && ! grep -q 'another install' "$T/err"
}
check "a read-only config dir: exit 7 'cannot create the lock directory' with the reason, not 'another install is running'" p_lock_create
p_work_create() {
  newhomes; mkmini
  PATH="$SHIMMK:$PATH" run "$MIS" --host claude
  [[ $RC == 7 ]] && grep -q 'cannot create a private work directory' "$T/err" && grep -q 'simulated failure' "$T/err" && ! grep -q 'another install' "$T/err" || return 1
  [[ -z "$(find "$CL" -mindepth 1)" ]]                                                    # lock and dirs removed again
}
check "mktemp failing for the private work directory: exit 7 with its message; nothing left behind" p_work_create

# --- the private work directory: nothing predictable, nothing planted is ever followed -------------
p_planted() { local b
  newhomes; mkcanary; mkmini; putbase claude; putbase codex
  b="$(snap "$CAN" mt)"
  mkdir -p "$H/before"; ( find "$CL" "$CX" ! -type l | sort ) > "$H/before/list"
  grun 60 "$CL:$CX" "$MIS" --host both
  [[ $RC == 0 ]] || { echo "     rc=$RC"; head -n 3 "$T/err"; return 1; }
  [[ "$(snap "$CAN" mt)" == "$b" ]] || { echo "     canary changed"; return 1; }      # content, mode, mtime, the user file under d/references
  # the planted links (every OLD predictable name for the installer's real pid) are untouched, and nothing else was added
  ( find "$CL" "$CX" ! -type l | sort ) > "$H/before/after"; cmp -s "$H/before/list" "$H/before/after" || { echo "     names changed"; diff "$H/before/list" "$H/before/after" | head -5; return 1; }
  [[ "$(find "$CL" "$CX" -type l | wc -l | tr -d ' ')" == "$(( 2 * (9 * 2 + 3 + 1) ))" ]] || return 1
  run "$MIS" --verify --host both; [[ $RC == 0 ]]
}
check "planted symlinks with every OLD predictable name (.prod-stage/.prod-trash/.prod-work.<pid>, manifest temp) pointing at a canary: exit 0, canary byte-identical (mode, mtime, user file), links untouched, no new name in either home" p_planted
p_planted_trash_codex() { # the same, but the install REPLACES units (new source): the trash path is exercised too
  local b
  newhomes; mkcanary; putbase codex; mkmini; printf '\nv2\n' >> "$MI/prod-curate/SKILL.md"; b="$(snap "$CAN" mt)"
  grun 60 "$CX" "$MIS" --host codex; [[ $RC == 0 && "$(snap "$CAN" mt)" == "$b" ]] || return 1
  run "$MIS" --verify --host codex; [[ $RC == 0 ]] && grep -q v2 "$CX/skills/prod-curate/SKILL.md"
}
check "planted names + a changed source (units are moved to the trash): canary untouched, new content installed" p_planted_trash_codex
p_stale_work() { local n1
  newhomes; mkmini; putbase codex; mkdir -p "$CX/.prod-work.OLD/trash/skills/x"; echo keep > "$CX/.prod-work.OLD/trash/skills/x/f"; chmod 500 "$CX/.prod-work.OLD/trash/skills/x"
  run "$MIS" --host codex; [[ $RC == 0 ]] || return 1
  n1="$(grep -c 'stale work directory from an interrupted install' "$T/err")"
  [[ "$n1" == 1 ]] && grep -q "$CX/.prod-work.OLD; it is safe to delete" "$T/err" || return 1
  [[ "$(cat "$CX/.prod-work.OLD/trash/skills/x/f")" == keep && "$(find "$CX" -maxdepth 1 -name '.prod-work.*' | wc -l | tr -d ' ')" == 1 ]]
  local r=$?; chmod -R u+w "$CX/.prod-work.OLD"; return $r
}
check "a .prod-work.OLD left by a killed run: one stderr line names it, it is not touched, ours is gone" p_stale_work

# --- signals: all-or-nothing at the Nth rename ------------------------------------------------------
UNITS=$(( 9 + $(find "$M/agents" -name '*.md' | wc -l | tr -d ' ') ))
sigcase() { # sigcase <host> <TERM|INT|HUP> <N>: reinstall with a changed source; signal the installer at its Nth mv
  local h="$1" sg="$2" N="$3" c b code
  newhomes; putbase "$h"; c="$(host_cfg "$h")"; mkmini; printf '\nv2\n' >> "$MI/prod-curate/SKILL.md"
  b="$(snap "$c")"; : > "$T/cnt$mk"
  PATH="$SHIMMV:$PATH" SIG_AT="$N" SIG_NAME="$sg" SIG_CNT="$T/cnt$mk" grun 60 - "$MIS" --host "$h"
  case "$sg" in TERM) code=143 ;; INT) code=130 ;; HUP) code=129 ;; esac
  if (( N == 2 * UNITS + 1 )); then                 # during the manifest rename: the commit point is passed, the install completes
    [[ $RC == 0 ]] || { echo "     $h $sg@$N: rc=$RC"; return 1; }
    run "$MIS" --verify --host "$h"; [[ $RC == 0 ]] || return 1
  else
    [[ $RC == "$code" && "$(snap "$c")" == "$b" ]] || { echo "     $h $sg@$N: rc=$RC (want $code) or the tree changed"; return 1; }
    cp "$M/prod-curate/SKILL.md" "$MI/prod-curate/SKILL.md"; run "$MIS" --verify --host "$h"
    [[ $RC == 0 ]] || { echo "     $h $sg@$N: the previous install no longer verifies"; return 1; }
  fi
  only_ours "$c"
}
p_sig() { local N; for N in 1 $((UNITS + 1)) $((2 * UNITS + 1)); do sigcase codex "$1" "$N" || return 1; done; }
p_sig_term() { p_sig TERM; }; p_sig_int() { p_sig INT; }; p_sig_hup() { p_sig HUP; }
p_sig_claude() { sigcase claude TERM $((UNITS + 1)); }
check "SIGTERM at the 1st, middle and last rename (codex): rolled back (143) or committed (0); the old install is intact and verifies; no work dir or lock left" p_sig_term
check "SIGINT at the 1st, middle and last rename (codex): rolled back (130) or committed (0); the old install is intact and verifies" p_sig_int
check "SIGHUP at the 1st, middle and last rename (codex): rolled back (129) or committed (0); the old install is intact and verifies" p_sig_hup
check "SIGTERM in the middle of the commit (claude): rolled back (143), tree identical, verifies" p_sig_claude

# --- the replaced copies and the nested copy --------------------------------------------------------
p_nested() { local h c
  for h in claude codex; do
    newhomes; mkmini; putbase "$h"; c="$(host_cfg "$h")"
    PATH="$SHIM/rm:$PATH" FAIL_TOOL=rm FAIL_PAT='*prod-ops*' FAIL_ALWAYS=1 FAIL_MARK="$T/fm$mk" run "$MIS" --host "$h"   # every rm of prod-ops fails (a locked file)
    [[ ! -e "$c/skills/prod-ops/prod-ops" && -f "$c/skills/prod-ops/SKILL.md" ]] || return 1
    run "$MIS" --verify --host "$h"; [[ $RC == 0 ]] || return 1
  done
}
check "a failed removal cannot produce a nested prod-ops/prod-ops copy (staging + rename); verify is 0 and SKILL.md is at the top" p_nested
c_nested_base() { # the scenario is real: the baseline installer nests under the same fault
  [[ $BASE_ORC == 0 ]] || return 1
  newhomes; putbase orig
  PATH="$SHIM/rm:$PATH" FAIL_TOOL=rm FAIL_PAT='*prod-ops*' FAIL_ALWAYS=1 FAIL_MARK="$T/fmb" run "$MORIG"; [[ -e "$CL/skills/prod-ops/prod-ops" ]]
}
check "control: the baseline installer DOES nest prod-ops/prod-ops under that fault (the case is not vacuous)" c_nested_base

# --- all-or-nothing per host ------------------------------------------------------------------------
p_inject() { local h kind tool pat b c kinds
  for h in claude codex; do
    newhomes; mkmini; putbase "$h"; c="$(host_cfg "$h")"; b="$(snap "$c")"                      # one installed tree: every failed run must leave it as it was
    printf '\nv2\n' >> "$MI/prod-curate/SKILL.md"                                               # the next install would change something
    kinds="stage place aside manifest chmod"; [[ $h == claude ]] && kinds="place manifest"      # same code path on both hosts: the full list on Codex, the ends on Claude (CPU)
    for kind in $kinds; do
      case $kind in stage) tool="cp"; pat='*/stage/skills/prod-curate' ;; place) tool="mv"; pat="$c/skills/prod-curate" ;;
                    aside) tool="mv"; pat='*/trash/skills/prod-ops' ;; manifest) tool="mv"; pat='*/prod-skills.manifest' ;;
                    chmod) tool="chmod"; pat='*/skills/prod-new' ;; esac
      PATH="$SHIM/$tool:$PATH" FAIL_TOOL=$tool FAIL_PAT="$pat" FAIL_MARK="$T/fi$mk$kind" run "$MIS" --host "$h"
      [[ $RC == 7 && "$(snap "$c")" == "$b" ]] || { echo "     inject $h/$kind: rc=$RC or tree changed"; return 1; }
    done
    printf '%s\n' "skill prod-curate" > "$MI/prod-curate/SKILL.md"; run "$MIS" --verify --host "$h"; [[ $RC == 0 ]] || { echo "     inject $h: previous state no longer verifies"; return 1; }
    newhomes; mkmini; PATH="$SHIM/cp:$PATH" FAIL_TOOL=cp FAIL_PAT='*/stage/skills/prod-curate' FAIL_MARK="$T/ff$mk" run "$MIS" --host "$h"
    [[ $RC == 7 && "$(snap "$(host_cfg "$h")")" == "" ]] || { echo "     first install $h: left something behind"; return 1; }
  done
}
check "an injected failure (stage cp, commit mv, move-aside, manifest mv, chmod) rolls the host back: tree identical, previous state verifies; a failed first install leaves nothing" p_inject
p_both_fail() {
  newhomes; mkmini
  PATH="$SHIM/cp:$PATH" FAIL_TOOL=cp FAIL_PAT="$CX/.prod-work.*/stage/skills/prod-curate" FAIL_MARK="$T/fb$mk" run "$MIS" --host both
  [[ $RC == 7 ]] && grep -q 'claude: installed; codex: rolled back' "$T/err" || { echo "     rc=$RC"; return 1; }
  run "$MIS" --verify --host claude; [[ $RC == 0 ]] || return 1                               # host one stays installed
  [[ "$(snap "$CX")" == "" ]]                                                                # host two left nothing
}
check "--host both with host two failing: exit is host two's (7), the message names both ('claude: installed; codex: rolled back'), claude verifies, codex left nothing" p_both_fail

p_trash_fail() { # the new install is complete and recorded; only the removal of the replaced copies fails
  newhomes; mkmini; putbase claude
  PATH="$SHIM/rm:$PATH" FAIL_TOOL=rm FAIL_PAT='*/.prod-work.????????' FAIL_ALWAYS=1 FAIL_MARK="$T/ft$mk" run "$MIS" --host claude
  [[ $RC == 7 ]] && grep -q 'the new install is complete' "$T/err" || { echo "     rc=$RC"; return 1; }
  run "$MIS" --verify --host claude; local r=$RC; chmod -R u+w "$CL" 2>/dev/null; [[ $r == 0 ]]
}
check "the replaced copies cannot be removed: exit 7 says the new install is complete, and it verifies" p_trash_fail

# --- explicit modes ---------------------------------------------------------------------------------
p_modes() { local um; um="$(umask)"
  newhomes; mkmini; rmdir "$CX"; umask 000; run "$MIS" --host codex; umask "$um"        # $CODEX_HOME does not exist yet: the installer creates it
  [[ $RC == 0 && -z "$(find "$CX" -mindepth 1 \( -perm -g+w -o -perm -o+w \) -not -type l)" ]] && [[ "$(modes "$CX" | grep ' prod-skills.manifest$' | cut -d' ' -f1)" == 0444 ]] || return 1
  [[ "$(python3 -I -c 'import os,sys;print("%o"%(os.stat(sys.argv[1]).st_mode&0o777))' "$CX")" == 755 \
     && "$(python3 -I -c 'import os,sys;print("%o"%(os.stat(sys.argv[1]).st_mode&0o777))' "$CX/skills")" == 755 \
     && "$(python3 -I -c 'import os,sys;print("%o"%(os.stat(sys.argv[1]).st_mode&0o777))' "$CX/agents")" == 755 ]]
}
check "codex under umask 000 with a CODEX_HOME that does not exist: it, skills/ and agents/ are 0755 (created before anything else), nothing group/world-writable, manifest 0444" p_modes

# --- source-side refusals ---------------------------------------------------------------------------
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

# --- TOML generation -----------------------------------------------------------------------------------
c_roles() { # the REAL agents of this repo are converted from their real sources
  newhomes; mkmini; rm -f "$MI"/agents/*.md; cp "$root"/agents/*.md "$MI/agents/"
  installs=$((installs+1))
  env HOME="$HM" CODEX_HOME="$CX" CLAUDE_CONFIG_DIR="$CL" PROD_CODEX_MODEL_SCOUT="test-model-x" bash "$MIS" --host codex >/dev/null 2>&1 || return 1
  python3 -I - "$MI/agents" "$CX/agents" "$CX/prod-skills.manifest" <<'PY' || return 1
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
if (( HAVE_TOML )); then
  check "codex roles from the REAL agents: one TOML per agent (parses), body + restated restrictions, model omitted unless env, in manifest" c_roles
else skipped=$((skipped+1)); echo "skip - real-agent role conversion check: python3 has no tomllib"; fi

mkweird() { python3 -I - "$MI/agents" <<'PY'
import sys
d = sys.argv[1]
body = ("Body with ''' and \"\"\" and a \\ backslash and a literal \\n.\n"
        "Tab:\there, CR:\rmid, bell:\x07, DEL:\x7f, ctl:\x01, non-ascii: h\u00e9llo \u2713 \u65e5\u672c \U0001F600 C1:\u0085\n"
        "---\n\nlast line  \n")
fm = ('---\nname: prod-weird\ndescription: He said "hi" \\ back\tslash \'x\' cr\rhere\n'
      'tools: "Read", \'Grep\', Bash\n---\n')
open(d + '/prod-weird.md', 'wb').write((fm + body).encode('utf-8'))
open(d + '/prod-notools.md', 'wb').write(b'---\nname: prod-notools\ndescription: no tools line\n---\nplain body\n')
PY
}
# strict reader of EXACTLY the subset the generator emits: lines `key = "<basic string>"`, key in
# name/description/model/developer_instructions, escapes only \\ \" \n \uXXXX, no raw control characters.
cat > "$T/rt.py" <<'PY'
import sys, re
def strict(path):
    raw = open(path, 'rb').read().decode('utf-8')
    assert raw.endswith('\n') and '\r' not in raw
    out = {}
    pat = re.compile(r'(name|description|model|developer_instructions) = "((?:[^"\\\x00-\x1f\x7f]|\\(?:[\\"n]|u[0-9A-F]{4}))*)"')
    for line in raw[:-1].split('\n'):
        m = pat.fullmatch(line)
        assert m, 'outside the generator subset: %r' % line[:60]
        k, v = m.groups(); assert k not in out, k
        out[k] = re.sub(r'\\(u[0-9A-F]{4}|.)', lambda x: {'\\': '\\', '"': '"', 'n': '\n'}[x.group(1)] if len(x.group(1)) == 1 else chr(int(x.group(1)[1:], 16)), v)
    return out
src, dst = sys.argv[1:3]
raw = open(src + '/prod-weird.md', 'rb').read().decode('utf-8')
fm, body = re.match(r'---\n(.*?)\n---\n(.*)', raw, re.S).groups()
desc = re.search(r'^description:[ \t]*(.*)$', fm, re.M).group(1)
d = strict(dst + '/prod-weird.toml')
assert d['name'] == 'prod-weird' and d['description'] == desc, (d['description'], desc)
assert d['developer_instructions'].startswith(body.rstrip('\n') + '\n\n## Host restrictions (Codex)\n')
assert 'allow-list of this role ("Read", \'Grep\', Bash)' in d['developer_instructions']
n = strict(dst + '/prod-notools.toml')['developer_instructions']
assert 'declares no tool restriction' in n and 'must not' not in n, n
try:
    import tomllib
except ImportError:
    sys.exit(0)
for f in ('prod-weird', 'prod-notools'):
    assert tomllib.load(open('%s/%s.toml' % (dst, f), 'rb')) == strict('%s/%s.toml' % (dst, f)), f   # the strict reader IS a faithful TOML reader here
PY
p_toml_roundtrip() { local h1
  newhomes; mkmini; mkweird; run "$MIS" --host codex; [[ $RC == 0 ]] || return 1
  python3 -I "$T/rt.py" "$MI/agents" "$CX/agents" || return 1
  h1="$CX"; newhomes
  PATH="$NOTOML:$PATH" run "$MIS" --host codex; [[ $RC == 0 ]] && grep -q 'tomllib not found' "$T/err" || return 1       # no tomllib: UTF-8 check + escaper only
  python3 -I "$T/rt.py" "$MI/agents" "$CX/agents" || return 1
  cmp -s "$h1/agents/prod-weird.toml" "$CX/agents/prod-weird.toml" && cmp -s "$h1/agents/prod-notools.toml" "$CX/agents/prod-notools.toml"
}
check "TOML round trip, with AND without tomllib: ''' / \"\"\" / backslashes / CR / tab / bell / DEL / C1 / non-ASCII / emoji parse back exactly (strict reader of the generator's subset); both installs write identical files" p_toml_roundtrip
p_toml_refusals() {
  newhomes; mkmini; printf -- '---\nname: prod-nul\ndescription: nul\ntools: Read\n---\nbo\000dy\n' > "$MI/agents/prod-nul.md"
  run "$MIS" --host codex; [[ $RC == 1 ]] && grep -q 'NUL' "$T/err" && [[ -z "$(find "$CX" -mindepth 1)" ]] || return 1
  newhomes; mkmini; printf -- '---\nname: prod-other\ndescription: other\ntools: Read\n---\nbody\n' > "$MI/agents/prod-bad.md"   # name differs from the file name
  run "$MIS" --host codex; [[ $RC == 1 && ! -e "$CX/agents/prod-bad.toml" && -z "$(find "$CX" -mindepth 1)" ]] || return 1
  return 0
}
p_name_traversal() {
  newhomes; mkmini; printf -- '---\nname: ../x\ndescription: d\ntools: Read\n---\nb\n' > "$MI/agents/prod-trav.md"
  run "$MIS" --host codex; [[ $RC == 1 && -z "$(find "$CX" -mindepth 1)" && ! -e "$H/x.toml" ]] || return 1
  newhomes; mkmini; printf -- '---\nname: Prod-Up\ndescription: d\ntools: Read\n---\nb\n' > "$MI/agents/prod-up.md"
  run "$MIS" --host codex; [[ $RC == 1 && -z "$(find "$CX" -mindepth 1)" ]]
}
p_toml_utf8() { local variant
  for variant in tomllib notomllib; do
    newhomes; mkmini; printf -- '---\nname: prod-u8\ndescription: bad \377 byte\ntools: Read\n---\nb\n' > "$MI/agents/prod-u8.md"
    if [[ $variant == notomllib ]]; then PATH="$NOTOML:$PATH" run "$MIS" --host codex; else run "$MIS" --host codex; fi
    [[ $RC == 1 && ! -e "$CX/agents/prod-u8.toml" && -z "$(find "$CX" -mindepth 1)" ]] && grep -q 'not valid UTF-8' "$T/err" || { echo "     $variant: rc=$RC"; return 1; }
    newhomes; mkmini; printf -- '---\nname: prod-u8\ndescription: ok\ntools: Read\n---\nbody with a surrogate \355\240\200 and an overlong \300\257\n' > "$MI/agents/prod-u8.md"
    if [[ $variant == notomllib ]]; then PATH="$NOTOML:$PATH" run "$MIS" --host codex; else run "$MIS" --host codex; fi
    [[ $RC == 1 && -z "$(find "$CX" -mindepth 1)" ]] || { echo "     $variant surrogate: rc=$RC"; return 1; }
  done
}
p_toml_big() {
  newhomes; mkmini; python3 -I - "$MI/agents" <<'PY'
import sys
body = "".join("line %d of a very long role body\n" % i for i in range(70000))   # ~2.3 MB
open(sys.argv[1] + "/prod-big.md", "w").write("---\nname: prod-big\ndescription: big\ntools: Read\n---\n" + body)
PY
  run "$MIS" --host codex; [[ $RC == 0 ]] && ! grep -q 'Argument list' "$T/err" || { echo "     rc=$RC"; head -n 2 "$T/err"; return 1; }
  python3 -I - "$MI/agents/prod-big.md" "$CX/agents/prod-big.toml" <<'PY'
import sys, re
raw = open(sys.argv[1]).read(); body = raw.split('---\n', 2)[2]
t = open(sys.argv[2], 'rb').read().decode('utf-8')
m = re.search(r'^developer_instructions = "(.*)"$', t, re.M)
v = m.group(1).replace('\\n', '\n')
assert len(t) > 2000000 and v.startswith(body.rstrip('\n')), (len(t),)
PY
}
check "a name that differs from the file name, or has a NUL, is refused (exit 1) with nothing written" p_toml_refusals
check "a frontmatter name with / or .., or upper case, is refused before any path is built; no stage file is left" p_name_traversal
check "invalid UTF-8 (a stray byte, a surrogate, an overlong) in a role is refused, with AND without tomllib; nothing written" p_toml_utf8
check "a 2.3 MB role body installs (texts travel in files, not argv) and parses back" p_toml_big

# --- nothing escaped to the real home ---------------------------------------------------------------
c_home_clean() { # every run had HOME under $T; the only things ever created there are the default-root case's
  [[ -z "$(find "$T"/h*/home -mindepth 1 -not -path '*/.codex*' -not -path '*/.claude*' 2>/dev/null)" ]]
}
check "HOME stayed empty except the default-roots case's .codex/.claude" c_home_clean

echo "installer runs (without --verify): $installs"
echo "$ok ok, $bad failed, $skipped skipped"
[[ $bad == 0 ]]
