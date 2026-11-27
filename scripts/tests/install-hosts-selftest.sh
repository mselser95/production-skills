#!/usr/bin/env bash
# install-hosts-selftest.sh -- install.sh --host claude|codex|both, hermetically.
#
# Everything runs against a COPY of this repo under a temp dir, with HOME,
# CLAUDE_CONFIG_DIR and CODEX_HOME all pointed under that temp dir, so nothing is
# ever written to the real home. The ORIGINAL installer (git show HEAD:install.sh)
# is run beside the new one to prove the default is byte-for-byte unchanged.
# Sequential, no background work. Mutation cases at the end run a scratch copy of
# install.sh with one behaviour broken and must come out RED.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_HOME="${HOME:-}"
T="$(mktemp -d "${TMPDIR:-/tmp}/install-hosts.XXXXXX")" || exit 1
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
case "$T" in "$REAL_HOME"/*) echo "refusing: temp dir $T is under the real home" >&2; exit 1 ;; esac
command -v python3 >/dev/null || { echo "python3 required (TOML check)" >&2; exit 1; }

ok=0; bad=0
check() { # check <name> <fn> ; fn returns 0 when the property holds
  if "$2"; then ok=$((ok+1)); echo "ok   - $1 [${SECONDS}s]"; else bad=$((bad+1)); echo "FAIL - $1 [${SECONDS}s]"; fi
}

# --- scratch source tree: copy of the repo, new + original installers -------
S="$T/src"; mkdir -p "$S"
rsync -a --exclude .git --exclude .wt "$root"/ "$S"/ || exit 1
git -C "$root" show HEAD:install.sh > "$S/install.orig.sh" || exit 1
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

# --- mutations: break one behaviour in a scratch copy, the probe must go RED ----
MUT="$M/install.mut.sh"
mutate() { # mutate <old> <new> ; literal, must change the file
  python3 -I - "$MNEW" "$MUT" "$1" "$2" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
assert s.count(old) == 1, 'pattern count %d' % s.count(old)
open(dst, 'w').write(s.replace(old, new))
PY
}
probe_manifest()   { newhomes; run "$1" --host codex; [[ -s "$CX/prod-skills.manifest" ]]; }
probe_verify()     { newhomes; run "$1" --host codex; tamper_file "$CX/skills/prod-ops/SKILL.md"; run "$1" --verify --host codex; [[ $RC == 1 ]]; }
probe_deref()      { newhomes; run "$1" --host codex; [[ -z "$(find "$CX" -type l)" && -n "$(find "$CX/skills/prod-spec/references" -type f | head -1)" ]]; }
probe_default()    { newhomes; run "$1"; [[ "$(listing "$CX")" == "." && -s "$CL/prod-skills.manifest" ]]; }
probe_restrict()   { newhomes; run "$1" --host codex; grep -q 'must not spawn other agents' "$CX/agents/prod-scout.toml" && grep -q 'must not edit' "$CX/agents/prod-scout.toml"; }
probe_isolation()  { newhomes; run "$1" --host claude; local b; b="$(listing "$CL")"; run "$1" --host codex; [[ "$(listing "$CL")" == "$b" ]]; }
probe_isolation_cx() { newhomes; run "$1" --host codex; local b; b="$(listing "$CX")"; run "$1" --host claude; [[ "$(listing "$CX")" == "$b" ]]; }
red() { # red <label> <probe> <old> <new>
  mutate "$3" "$4" || { bad=$((bad+1)); echo "FAIL - mutation $1: ERROR (pattern did not apply)"; return; }
  if ! "$2" "$MNEW" ; then bad=$((bad+1)); echo "FAIL - mutation $1: probe fails on the REAL installer"; return; fi
  if "$2" "$MUT"; then bad=$((bad+1)); echo "FAIL - mutation $1: GREEN (probe cannot see it)"
  else ok=$((ok+1)); echo "ok   - mutation $1: RED"; fi
}
red "codex manifest not written" probe_manifest \
  '{ hash_tree "$cfg/skills" "${skills[@]}"; agents_hash; } | sort > "$manifest"' \
  '{ hash_tree "$cfg/skills" "${skills[@]}"; agents_hash; } | sort > "$([[ $cur_host == claude ]] && echo "$manifest" || echo /dev/null)"'
red "codex verify always 0" probe_verify '( verify_host ); r=$?' '( verify_host ); r=$?; [[ $h == codex ]] && r=0'
red "references not dereferenced for codex" probe_deref \
  'if [[ -d "$src/$s/references" ]]; then' 'if [[ -d "$src/$s/references" && "$cur_host" == claude ]]; then'
red "default host changed to both" probe_default 'host=claude; mode=""' 'host=both; mode=""'
red "role restriction block dropped" probe_restrict "  printf '\\n## Host restrictions (Codex)" "  : printf '\\n## Host restrictions (Codex)"
red "claude tree modified by a codex run" probe_isolation \
  '  install_host || exit $?' '  install_host || exit $?; [[ $h == codex ]] && touch "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/stray"'
red "codex tree modified by a claude run" probe_isolation_cx \
  '  install_host || exit $?' '  install_host || exit $?; [[ $h == claude ]] && touch "${CODEX_HOME:-$HOME/.codex}/stray"'

# --- nothing escaped to the real home -----------------------------------------
c_home_clean() { # every run had HOME under $T; the only things ever created there are the default-root case's
  [[ -z "$(find "$T"/h*/home -mindepth 1 -not -path '*/.codex*' -not -path '*/.claude*' 2>/dev/null)" ]]
}
check "HOME stayed empty except the default-roots case's .codex/.claude" c_home_clean

echo "$ok ok, $bad failed"
[[ $bad == 0 ]]
