#!/usr/bin/env bash
# install-hosts-mutations-selftest.sh -- the MUTATION PROOFS for install.sh's hosts/Codex work.
# Each mutant is applied to a scratch copy of install.sh and run against ONE targeted probe
# (at most one mini install), never the whole behaviour suite: the probe must be green on the
# real installer and RED on the mutant. The behaviour cases live in install-hosts-selftest.sh.
#
# Same isolation as the behaviour file: every run has HOME, CLAUDE_CONFIG_DIR and CODEX_HOME
# under a temp dir this run created; the only deletion is that one directory. The mini source
# tree, shims and runner are the behaviour file's (kept in step by hand: both are short).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_HOME="${HOME:-}"
T="$(mktemp -d "${TMPDIR:-/tmp}/install-hosts-mut.XXXXXX")" || exit 1
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
mkmini() { # mkmini [script]: a private copy of the mini tree whose install.sh is the script under test
  mk=$((mk+1)); MI="$T/mi$mk"; cp -R "$M" "$MI"; cp "${1:-$MNEW}" "$MI/install.sh"; rm -f "$MI/install.mut.sh"; MIS="$MI/install.sh"; }
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

# --- one install of the REAL installer per host pair, built once; probes work on cp -R copies --------
newhomes; BASE_C="$CL"; BASE_X="$CX"; run "$MNEW" --host both; [[ $RC == 0 ]] || { echo "setup: the real installer failed on the mini tree" >&2; cat "$T/err" >&2; exit 1; }
newhomes; run "$MORIG"; [[ $RC == 0 ]] || { echo "setup: the baseline installer failed" >&2; exit 1; }
{ echo "rc=$RC"; norm "$T/out"; norm "$T/err"; snap "$CL"; } | sed -e "s|$H|<H>|g" > "$T/def.base"
putbase() { case "$1" in claude) rmdir "$CL"; cp -R "$BASE_C" "$CL" ;; codex) rmdir "$CX"; cp -R "$BASE_X" "$CX" ;; esac; }
manifest_rewrite() {
  local c; c="$(host_cfg "$1")"
  { ( cd "$c/skills" && find $SK -type f -print0 | sort -z | xargs -0 shasum -a 256 )
    ( cd "$c/agents" && if [[ $1 == claude ]]; then find . -type f -print0; else find . -maxdepth 1 -name 'prod-*.toml' -type f -print0; fi | sort -z | xargs -0 shasum -a 256 )
  } | sort > "$c/m.new"; chmod u+w "$c/prod-skills.manifest" 2>/dev/null; mv "$c/m.new" "$c/prod-skills.manifest"; }

# --- mutation machinery: break ONE behaviour in a scratch copy of install.sh; ONE targeted probe must go RED ---
# Every probe takes the installer path as $1, returns 0 when the property HOLDS, and costs at most one mini install.
MUT="$M/install.mut.sh"
mutate() { # mutate <old> <new> [<old> <new>...] ; literal, each must match exactly once
  python3 -I - "$MNEW" "$MUT" "$@" <<'PY'
import sys
src, dst = sys.argv[1:3]
s = open(src).read()
a = sys.argv[3:]
for old, new in zip(a[0::2], a[1::2]):
    assert s.count(old) == 1, 'pattern count %d: %s' % (s.count(old), old[:60])
    s = s.replace(old, new)
open(dst, 'w').write(s)
PY
}
red() { # red <label> <probe> <old> <new> [<old> <new>...]
  local label="$1" probe="$2"; shift 2
  mutate "$@" || { bad=$((bad+1)); echo "FAIL - mutation $label: ERROR (pattern did not apply)"; return; }
  case "$GREEN" in *" $probe "*) ;; *) if ! "$probe" "$MNEW"; then bad=$((bad+1)); echo "FAIL - mutation $label: probe $probe fails on the REAL installer"; return; fi; GREEN="$GREEN$probe " ;; esac
  if "$probe" "$MUT"; then bad=$((bad+1)); echo "FAIL - mutation $label: GREEN (probe $probe cannot see it)"
  else ok=$((ok+1)); echo "ok   - mutation $label: RED [${SECONDS}s]"; fi
}
holds() { # holds <label> <probe> <old> <new>...: a defence-in-depth proof: with ONE layer broken the probe still holds (the next layer catches it)
  local label="$1" probe="$2"; shift 2
  mutate "$@" || { bad=$((bad+1)); echo "FAIL - $label: ERROR (pattern did not apply)"; return; }
  if "$probe" "$MUT"; then ok=$((ok+1)); echo "ok   - $label [${SECONDS}s]"; else bad=$((bad+1)); echo "FAIL - $label"; fi
}

# --- probes ----------------------------------------------------------------------------------------
probe_manifest()   { newhomes; run "$1" --host codex; [[ -s "$CX/prod-skills.manifest" ]]; }
probe_verify0()    { newhomes; putbase codex; tamper_file "$CX/skills/prod-ops/SKILL.md"; run "$1" --verify --host codex; [[ $RC == 1 ]]; }
probe_deref()      { newhomes; run "$1" --host codex; [[ -z "$(find "$CX" -type l)" && -n "$(find "$CX/skills/prod-spec/references" -type f | head -n 1)" ]]; }
probe_default()    { newhomes; run "$1"; [[ "$(listing "$CX")" == "." && -s "$CL/prod-skills.manifest" ]]; }
probe_default_out() { newhomes; run "$1"; { echo "rc=$RC"; norm "$T/out"; norm "$T/err"; snap "$CL"; } | sed -e "s|$H|<H>|g" > "$T/def.new"; cmp -s "$T/def.base" "$T/def.new"; }
probe_restrict()   { newhomes; run "$1" --host codex; grep -q 'must not spawn other agents' "$CX/agents/prod-scout.toml" && grep -q 'must not edit' "$CX/agents/prod-scout.toml"; }
probe_isolation_c() { newhomes; putbase claude; local b; b="$(snap "$CL")"; run "$1" --host codex; [[ "$(snap "$CL")" == "$b" ]]; }
probe_isolation_x() { newhomes; putbase codex; local b; b="$(snap "$CX")"; run "$1" --host claude; [[ "$(snap "$CX")" == "$b" ]]; }
probe_sym_leaf()   { local b; newhomes; mkcanary; mkdir -p "$CX/agents"; ln -s "$CAN/role.toml" "$CX/agents/prod-scout.toml"
  b="$(snap "$CAN" mt)"; run "$1" --host codex; [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" && ! -e "$CX/prod-skills.manifest" ]]; }
probe_sym_dirs()   { local b; newhomes; mkcanary; ln -s "$CAN/sdir" "$CX/skills"; b="$(snap "$CAN" mt)"; run "$1" --host codex
  [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" ]] || return 1
  newhomes; mkcanary; ln -s "$CAN/role.toml" "$CX/prod-skills.manifest"; b="$(snap "$CAN" mt)"; run "$1" --host codex; [[ $RC == 4 && "$(snap "$CAN" mt)" == "$b" ]]; }
probe_foreign()    { local b; newhomes; mkdir -p "$CX/agents"; echo mine > "$CX/agents/prod-scout.toml"; b="$(snap "$CX")"; run "$1" --host codex
  [[ $RC == 5 && "$(snap "$CX")" == "$b" ]]; }
probe_adopt()      { newhomes; mkdir -p "$CX/agents"; echo mine > "$CX/agents/prod-scout.toml"; run "$1" --host codex --adopt
  [[ $RC == 0 && "$(cat "$CX"/.prod-backups/*/agents/prod-scout.toml 2>/dev/null)" == mine ]]; }
probe_verify_paths() { newhomes; putbase codex; chmod -R u+w "$CX/skills/prod-ops"; mkdir "$CX/skills/prod-ops/sub"; mv "$CX/skills/prod-ops/SKILL.md" "$CX/skills/prod-ops/sub/SKILL.md"
  chmod -R a-w "$CX/skills/prod-ops"; manifest_rewrite codex; run "$1" --verify --host codex; [[ $RC == 2 ]]; }
probe_first_fail() { newhomes; PATH="$SHIM/cp:$PATH" FAIL_TOOL=cp FAIL_PAT='*/stage/skills/prod-curate' FAIL_MARK="$T/ff$n" run "$1" --host codex
  [[ $RC == 7 && ! -e "$CX/prod-skills.manifest" && "$(snap "$CX")" == "" ]]; }
probe_lock_live()  { newhomes; mkdir "$CL/.prod-skills.lock"; echo "$$" > "$CL/.prod-skills.lock/pid"; run "$1" --host claude; [[ $RC == 6 ]]; }
probe_modes()      { local um; um="$(umask)"; newhomes; rmdir "$CX"; umask 000; run "$1" --host codex; umask "$um"
  [[ $RC == 0 && -z "$(find "$CX" -mindepth 1 \( -perm -g+w -o -perm -o+w \) -not -type l)" && "$(modes "$CX" | grep ' prod-skills.manifest$' | cut -d' ' -f1)" == 0444 ]] || return 1
  [[ "$(python3 -I -c 'import os,sys;print("%o"%(os.stat(sys.argv[1]).st_mode&0o777))' "$CX")" == 755 && "$(python3 -I -c 'import os,sys;print("%o"%(os.stat(sys.argv[1]).st_mode&0o777))' "$CX/agents")" == 755 ]]; }
probe_cfg_mode()   { local um; um="$(umask)"; newhomes; rmdir "$CX"; umask 000; run "$1" --host codex; umask "$um"
  [[ $RC == 0 && "$(python3 -I -c 'import os,sys;print("%o"%(os.stat(sys.argv[1]).st_mode&0o777))' "$CX")" == 755 ]]; }
probe_name_a()     { newhomes; mkmini "$1"; printf -- '---\nname: prod-other\ndescription: other\ntools: Read\n---\nbody\n' > "$MI/agents/prod-bad.md"
  run "$MIS" --host codex; [[ $RC == 1 && ! -e "$CX/agents/prod-bad.toml" ]]; }
probe_name_b()     { newhomes; mkmini "$1"; printf -- '---\nname: ../x\ndescription: d\ntools: Read\n---\nb\n' > "$MI/agents/prod-trav.md"
  run "$MIS" --host codex; [[ $RC == 1 && ! -e "$H/x.toml" ]] || return 1
  newhomes; mkmini "$1"; printf -- '---\nname: Prod-Up\ndescription: d\ntools: Read\n---\nb\n' > "$MI/agents/prod-up.md"
  run "$MIS" --host codex; [[ $RC == 1 && -z "$(find "$CX" -mindepth 1)" ]]; }
probe_toml_quote() { newhomes; mkmini "$1"; printf -- '---\nname: prod-q\ndescription: say "hi" \\ back\ntools: Read\n---\nbody "quoted"\n' > "$MI/agents/prod-q.md"
  run "$MIS" --host codex
  if [[ $RC == 0 ]]; then python3 -I - "$CX/agents/prod-q.toml" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], 'rb'))
assert d['description'] == 'say "hi" \\ back', d
PY
  else [[ $RC == 1 && ! -e "$CX/agents/prod-q.toml" ]]; fi; }
probe_toml_refused() { newhomes; mkmini "$1"; printf -- '---\nname: prod-q\ndescription: say "hi"\ntools: Read\n---\nbody\n' > "$MI/agents/prod-q.md"
  run "$MIS" --host codex; [[ $RC == 1 && ! -e "$CX/agents/prod-q.toml" ]] && grep -q 'round-trip' "$T/err"; }
probe_planted()    { local b; newhomes; mkcanary; putbase claude; mkmini "$1"; b="$(snap "$CAN" mt)"
  grun 60 "$CL" "$MIS" --host claude; [[ $RC == 0 && "$(snap "$CAN" mt)" == "$b" ]]; }
probe_stale_work() { newhomes; putbase claude; mkdir -p "$CL/.prod-work.OLD/trash"; echo keep > "$CL/.prod-work.OLD/trash/f"; mkmini "$1"
  run "$MIS" --host claude; [[ $RC == 0 && "$(cat "$CL/.prod-work.OLD/trash/f" 2>/dev/null)" == keep ]]; }
probe_race()       { newhomes; putbase claude; mkmini "$1"
  PATH="$SHIMMV:$PATH" RACE_DEST="$CL/skills/prod-ops" run "$MIS" --host claude
  [[ $RC == 7 && -f "$CL/skills/prod-ops/planted" && ! -e "$CL/skills/prod-ops/prod-ops" ]]; }
probe_sig()        { local b; newhomes; putbase claude; mkmini "$1"; printf '\nv2\n' >> "$MI/prod-curate/SKILL.md"; b="$(snap "$CL")"; : > "$T/cnt$mk"
  PATH="$SHIMMV:$PATH" SIG_AT=11 SIG_NAME=TERM SIG_CNT="$T/cnt$mk" grun 60 - "$MIS" --host claude          # the aside of the 6th unit: moved aside, not yet moved in
  [[ $RC == 143 && "$(snap "$CL")" == "$b" ]]; }
probe_lock_dead()  { newhomes; mkdir "$CL/.prod-skills.lock"; ( : ) & wait $!; echo "$!" > "$CL/.prod-skills.lock/pid"; run "$1" --host claude
  [[ $RC == 6 && -d "$CL/.prod-skills.lock" ]] && grep -q 'is not running' "$T/err"; }
probe_lock_escape() { newhomes; mkdir "$CL/.prod-skills.lock"; printf '\033[31mEVIL-OWNER\n' > "$CL/.prod-skills.lock/pid"; run "$1" --host claude
  [[ $RC == 6 ]] && ! LC_ALL=C grep -q -e EVIL -e "$(printf '\033')" "$T/err"; }
probe_notoml_utf8() { newhomes; mkmini "$1"; printf -- '---\nname: prod-u8\ndescription: bad \377 byte\ntools: Read\n---\nb\n' > "$MI/agents/prod-u8.md"
  PATH="$NOTOML:$PATH" run "$MIS" --host codex; [[ $RC == 1 && ! -e "$CX/agents/prod-u8.toml" ]]; }
probe_verify_consistent() { newhomes; putbase codex; chmod u+w "$CX/agents/prod-scout.toml"; echo 'evil = 1' >> "$CX/agents/prod-scout.toml"; chmod a-w "$CX/agents/prod-scout.toml"
  manifest_rewrite codex; run "$1" --verify --host codex; [[ $RC == 2 ]]; }
probe_trash_manifest() { local b; newhomes; putbase claude; mkmini "$1"; b="$(snap "$CL")"
  PATH="$SHIM/mv:$PATH" FAIL_TOOL=mv FAIL_PAT='*/prod-skills.manifest' FAIL_MARK="$T/fm$mk" run "$MIS" --host claude
  [[ $RC == 7 && "$(snap "$CL")" == "$b" ]]; }
probe_twohost()    { local b; newhomes; mkdir -p "$CX/agents"; echo mine > "$CX/agents/prod-scout.toml"; b="$(snap "$CX")"; run "$1" --host both
  [[ $RC == 5 && "$(snap "$CX")" == "$b" && -z "$(find "$CL" -mindepth 1)" ]]; }
probe_chmod()      { newhomes; run "$1" --host claude; [[ $RC == 0 ]] && run "$1" --verify --host claude && [[ $RC == 0 ]]; }
FIXTURE="$root/scripts/tests/fixtures/install.base.sh.txt"
guard_baseline() { # guard_baseline <fixture file>: not vacuous, and the committed copy of the merge-base script
  local f="$1" sha
  ! cmp -s "$f" "$root/install.sh" || return 1                 # must differ from the script under test
  sha="$(sed -n 's/.*install\.sh at commit \([0-9a-f]\{40\}\).*/\1/p' "$f" | head -n 1)"; [[ -n "$sha" ]] || return 1
  if git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null; then
    sed '/^# BASELINE-FIXTURE-BEGIN/,/^# BASELINE-FIXTURE-END/d' "$f" | cmp -s - <(git -C "$root" show "$sha:install.sh") || return 1
  fi
}

# --- the 21 mutations of the previous round (patterns updated to the work-directory code) ------------
red "codex manifest not written" probe_manifest \
  'mv -f "$mf" "$manifest" || fail_step "cannot move the manifest into place"' \
  'if [[ "$cur_host" == claude ]]; then mv -f "$mf" "$manifest" || fail_step "cannot move the manifest into place"; fi'
red "codex verify always 0" probe_verify0 '( verify_host ); r=$?' '( verify_host ); r=$?; [[ $h == codex ]] && r=0'
red "references not dereferenced for codex" probe_deref \
  'if [[ -d "$src/$s/references" ]]; then' 'if [[ -d "$src/$s/references" && "$cur_host" == claude ]]; then'
red "default host changed to both" probe_default 'host=claude; mode=""; adopt=0' 'host=both; mode=""; adopt=0'
red "default host changed to both (baseline transcript)" probe_default_out 'host=claude; mode=""; adopt=0' 'host=both; mode=""; adopt=0'
red "default stdout line changed (baseline transcript)" probe_default_out 'echo "installed ${#skills[@]} skills + ${#agent_files[@]} agents' 'echo "installed ${#skills[@]} skills and ${#agent_files[@]} agents'
red "role restriction block dropped" probe_restrict 'restr="$restr You must not spawn other agents."' ':'
red "claude tree modified by a codex run" probe_isolation_c \
  '  install_host; r=$?' '  install_host; r=$?; [[ $h == codex ]] && touch "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/stray"'
red "codex tree modified by a claude run" probe_isolation_x \
  '  install_host; r=$?' '  install_host; r=$?; [[ $h == claude ]] && touch "${CODEX_HOME:-$HOME/.codex}/stray"'
red "symlink guard removed (leaf: role file, skill dir)" probe_sym_leaf '  if [[ -L "$1" ]]; then' '  if false; then'
red "symlink guard removed (intermediate: skills/, agents/, manifest)" probe_sym_dirs \
  'for d in "$cfg/skills" "$cfg/agents" "$manifest"; do' 'for d in; do'
red "ownership check removed" probe_foreign 'elif [[ -e "$1" ]] && ! owned_in_manifest "$2"; then' 'elif false; then'
red "--adopt deletes instead of backing up" probe_adopt 'old="$bk/$kind/$base"' 'old="$work/trash/$kind/$base"'
red "verify back to hash-only" probe_verify_paths \
  "man_skill_rows=\$(grep -v '  \\./' \"\$manifest\" | LC_ALL=C sort)" "man_skill_rows=\$(grep -v '  \\./' \"\$manifest\" | awk '{print \$1}' | LC_ALL=C sort)" \
  '-exec shasum -a 256 {} + 2>/dev/null | LC_ALL=C sort)' "-exec shasum -a 256 {} + 2>/dev/null | awk '{print \$1}' | LC_ALL=C sort)"
red "manifest written before the copy finished" probe_first_fail \
  '|| fail_step "cannot create $cfg/skills and $cfg/agents"' '|| fail_step "cannot create $cfg/skills and $cfg/agents"
echo premature > "$manifest"'
red "lock removed" probe_lock_live 'for h in "${hosts[@]}"; do set_host "$h"; lock_host; done' ':'
if guard_baseline "$FIXTURE"; then ok=$((ok+1)); echo "ok   - baseline fixture guard accepts the real fixture"; else bad=$((bad+1)); echo "FAIL - fixture guard rejects the real fixture"; fi
c_baseline_mutant() { ! guard_baseline "$root/install.sh"; }   # the fixture replaced by the current script (what HEAD:install.sh is once committed)
if c_baseline_mutant; then ok=$((ok+1)); echo "ok   - mutation baseline fixture replaced by HEAD: RED"; else bad=$((bad+1)); echo "FAIL - mutation baseline fixture replaced by HEAD: GREEN"; fi
red "explicit modes removed (umask AND the explicit chmods)" probe_modes \
  'host_umask() { if [[ "$cur_host" == codex ]]; then umask 022; else umask "$orig_umask"; fi; }' 'host_umask() { :; }' \
  'made_dirs+=("$cfg"); [[ "$cur_host" == codex ]] && chmod 0755 "$cfg"' 'made_dirs+=("$cfg")' \
  '(( mk_s )) && { chmod 0755 "$cfg/skills" || fail_step "cannot chmod $cfg/skills"; }' ':' \
  '(( mk_a )) && { chmod 0755 "$cfg/agents" || fail_step "cannot chmod $cfg/agents"; }' ':'
red "name validation skipped" probe_name_a 'valid_role_name() { [[ "$1" =~ ^[a-z][a-z0-9-]*$ && "$1" == "$2" ]]; }' 'valid_role_name() { true; }'
red "name validation skipped (traversal)" probe_name_b 'valid_role_name() { [[ "$1" =~ ^[a-z][a-z0-9-]*$ && "$1" == "$2" ]]; }' 'valid_role_name() { true; }'
if (( HAVE_TOML )); then
  red "TOML parse check skipped (with a broken quote escaper: an unparseable role would be written)" probe_toml_quote \
    '  toml_check_all "$work/chk"; rc=$?' '  rc=0' \
    'else if (ch == "\"") o = o "\\\""; else if (ch in c)' 'else if (ch in c)'
  holds "TOML escaper broken ALONE (quotes unescaped): the parse check refuses the role, nothing written (the second layer holds)" probe_toml_refused \
    'else if (ch == "\"") o = o "\\\""; else if (ch in c)' 'else if (ch in c)'
else skipped=$((skipped+2)); echo "skip - TOML parse-check mutations: python3 has no tomllib here"; fi

# --- the new mutations of this round -------------------------------------------------------------------
red "work dir created with a PREDICTABLE name (.prod-work.<pid>, mkdir)" probe_planted \
  'work="$(mktemp -d "$cfg/.prod-work.XXXXXXXX" 2>&1)" ||' 'work="$cfg/.prod-work.$$"; mkdir "$work" 2>&1 ||'
red "stage created OUTSIDE the work dir (predictable .prod-stage.<pid>.<name>, cp -R)" probe_planted \
  '  st="$work/stage/skills/$s"' '  st="$cfg/skills/.prod-stage.$$.$s"'
red "stage created with a clobbering mkdir -p at a predictable name" probe_planted \
  '  st="$work/stage/skills/$s"' '  st="$cfg/skills/.prod-stage.$$.$s"' \
  '  cp -R "$src/$s" "$st" || fail_step "cannot copy skill $s"' '  mkdir -p "$st" && cp -R "$src/$s/." "$st/" || fail_step "cannot copy skill $s"'
red "cleanup globs .prod-work.* (deletes a leftover it did not create)" probe_stale_work \
  '  for p in "${locks[@]:-}"; do [[ -n "$p" ]] && { rm -f "$p/pid"; rmdir "$p" 2>/dev/null; }; done' \
  '  rm -rf "$cfg"/.prod-work.* 2>/dev/null
  for p in "${locks[@]:-}"; do [[ -n "$p" ]] && { rm -f "$p/pid"; rmdir "$p" 2>/dev/null; }; done'
red "rename into an existing destination without the free-name re-check" probe_race \
  '  [[ ! -e "$d" && ! -L "$d" ]] || fail_step "$d appeared while installing; not moving anything into it"' ':'
red "signal handler exits immediately (between move-aside and move-in)" probe_sig "trap 'sig=143' TERM" "trap 'exit 143' TERM"
red "lock stolen when its owner is dead" probe_lock_dead \
  'echo "install: stale lock $lk$old: its owner, pid $pid, is not running. Not stealing it: remove it with:  rm -rf '"'"'$lk'"'"'" >&2; exit 6' \
  'rm -rf "$lk"; mkdir "$lk"; return 0'
red "pid file content echoed raw" probe_lock_escape \
  'and its owner is unreadable (a stale lock' 'and its owner is unreadable ($(cat "$lk/pid" 2>/dev/null)) (a stale lock'
red "no-tomllib path writes a role without the UTF-8 check" probe_notoml_utf8 'valid_utf8 "$f" || {' 'true || {'
red "codex verify compares paths only (expected row taken from the manifest)" probe_verify_consistent \
  "\$(cd \"\$vw\" && shasum -a 256 \"\$n.toml\" | sed 's|  |  ./|')" "\$(printf '%s\\n' \"\$man_agent_rows\" | grep -F \"  ./\$n.toml\")"
red "umask set only AFTER the first mkdir (and no explicit chmod of the new config dir)" probe_cfg_mode \
  '  host_umask   # before the FIRST mkdir: $cfg itself may be created just below
' '' \
  'made_dirs+=("$cfg"); [[ "$cur_host" == codex ]] && chmod 0755 "$cfg"' 'made_dirs+=("$cfg"); host_umask'
red "trash removed before the manifest rename (rollback has nothing to restore)" probe_trash_manifest \
  'mv -f "$mf" "$manifest" || fail_step "cannot move the manifest into place"' 'rm -rf "$work/trash"; mv -f "$mf" "$manifest" || fail_step "cannot move the manifest into place"'
red "host-two pre-check moved after host one's commit" probe_twohost \
  'for h in "${hosts[@]}"; do set_host "$h"; precheck_host; done' ':' \
  '  install_host; r=$?' '  precheck_host; (( refuse_foreign )) && exit 5; install_host; r=$?'
red "chmod a-w of the skills skipped" probe_chmod 'chmod -R a-w "${sp[@]}" || fail_step "cannot make the skills under $cfg/skills read-only"' ':'

# --- nothing escaped to the real home ---------------------------------------------------------------
c_home_clean() { [[ -z "$(find "$T"/h*/home -mindepth 1 2>/dev/null)" ]]; }
if c_home_clean; then ok=$((ok+1)); echo "ok   - HOME stayed empty in every run"; else bad=$((bad+1)); echo "FAIL - something was written under a temp HOME"; fi

echo "installer runs (without --verify): $installs"
echo "$ok ok, $bad failed, $skipped skipped"
[[ $bad == 0 ]]
