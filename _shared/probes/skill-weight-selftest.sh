#!/usr/bin/env bash
# skill-weight-selftest.sh — every rule in skill-weight.sh shown firing on a
# temp fixture where its property is false, plus the real repo passing.
#
# Thin wrapper. The rule cases run IN-PROCESS in skill-weight-selftest.py,
# which imports the core's run() with an injectable clock and builds each fixture
# tree itself: milliseconds per case. This file keeps only what can be proven
# through the shell wrapper: exit codes 0/1/2, --write then accept, --write
# refusing a failed measurement, the default registry path, missing PyYAML, the
# real repo under `python3 -I -W error`, and the wiring of this probe.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="$here/skill-weight.sh"
core="$here/skill-weight.py"
driver="$here/skill-weight-selftest.py"
real_root="$(cd "$here/../.." && pwd)"
[[ -r "$probe" && -r "$core" && -r "$driver" ]] || { echo "skill-weight selftest: cannot read the probe, core or driver" >&2; exit 2; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/skill-weight-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$tmp"' EXIT
pass=0 bad=0

ok_()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad_() { printf '  BAD  %s\n       %s\n' "$1" "$2"; bad=$((bad + 1)); }
oneline() { printf '%s' "$1" | tr '\n' '|' | cut -c1-400; }
run_case() { # name want_rc want_substring root [probe args...]
  local name="$1" want="$2" msg="$3" root="$4" out rc
  out="$(bash "$probe" "${@:5}" "$root" 2>&1)"; rc=$?
  if [[ $rc -eq $want && "$out" == *"$msg"* ]]; then ok_ "$name"
  else bad_ "$name" "want rc=$want containing '$msg'; got rc=$rc: $(oneline "$out")"; fi
}

# ---- the in-process driver (also builds $tmp/_tpl, a healthy nine-skill root) ------
dout="$(python3 -I -W error "$driver" "$tmp" 2>&1)"; drc=$?
printf '%s\n' "$dout" | grep -v '^DRIVER '
dline="$(printf '%s\n' "$dout" | grep '^DRIVER ' | tail -1)"
if [[ -z "$dline" ]]; then
  echo "skill-weight selftest: the in-process driver produced no result (rc=$drc)" >&2; exit 2
fi
read -r _ dpass dbad <<<"$dline"
pass=$((pass + dpass)); bad=$((bad + dbad))
tpl="$tmp/_tpl"

# ---- end to end through the wrapper ------------------------------------------------
mkdir -p "$tmp/empty"
run_case "wrapper: zero skills found exits 2" 2 "nothing checked is not a pass" "$tmp/empty"
cp -R "$tpl" "$tmp/w-ok"; rm "$tmp/w-ok/benchmarks/skill-weight-baseline.md"
run_case "wrapper: --write records a baseline" 0 "baseline recorded" "$tmp/w-ok" --write
run_case "wrapper: ...which the check then accepts" 0 "skill-weight: ok" "$tmp/w-ok"
cp -R "$tpl" "$tmp/w-bad"; rm "$tmp/w-bad/prod-ops/references/a.md"
run_case "wrapper: --write refuses to record a failed measurement" 1 "refusing to record" "$tmp/w-bad" --write
cp -R "$tpl" "$tmp/eceil"; head -c 70000 /dev/zero | tr '\0' b >"$tmp/eceil/prod-ops/references/b.md"
bash "$probe" --write "$tmp/eceil" >/dev/null 2>&1
run_case "wrapper: EAGER over the ceiling with no liability exits 1" 1 "ceiling with no live" "$tmp/eceil"
printf 'entries:\n  - id: w1\n    obligation: skill-weight\n    skill: prod-ops\n    ceiling_bytes: 75000\n    owner: t\n    created: 2026-01-01\n    expires: 2099-01-01\n    reason: x\n' >"$tmp/eceil/registries/waivers.yaml"
run_case "wrapper: the default registry path is read (liability excuses it)" 0 "1 set(s) over ceiling under live liability" "$tmp/eceil"

# ---- the wrapper: PyYAML is required, never skipped -----------------------------------
real_py="$(command -v python3)"; mkdir -p "$tmp/nopyyaml"
printf '#!/bin/sh\ncase "$*" in *"import yaml"*) exit 1;; esac\nexec "%s" "$@"\n' "$real_py" >"$tmp/nopyyaml/python3"; chmod +x "$tmp/nopyyaml/python3"
out="$(PATH="$tmp/nopyyaml:$PATH" bash "$probe" "$real_root" 2>&1)"; rc=$?
if [[ $rc -eq 1 && "$out" == *"PyYAML is unavailable"* ]]; then ok_ "missing PyYAML exits 1, not a skipped pass"; else bad_ "missing PyYAML" "rc=$rc: $(oneline "$out")"; fi

# ---- wiring of THIS probe (probe-wiring.sh also counts the --write target) ------
wiring() { # wiring <dir with Makefile and .github/workflows/pr.yaml> : prints what is missing
  local d="$1" miss="" gl ids
  # `make gates` is one line calling scripts/evidence-record.sh --run gates, which runs the `main` group
  # of its GATES: the gates line is "the recipe calls the runner" and "skill-weight is not moved out of main".
  gl="$(awk '/^gates:/{f=1;next} f&&/^[^\t]/{f=0} f' "$d/Makefile" | grep -E 'evidence-record\.sh --run gates')"
  # the recorder is ASKED which ids make up the main group (`--list main`), not read: a `POST_IDS+=(skill-weight)` anywhere moves it out
  [[ -f "$d/scripts/run-once.sh" ]] || cp "$real_root/scripts/run-once.sh" "$d/scripts/run-once.sh"
  ids="$(bash "$d/scripts/evidence-record.sh" --list main 2>/dev/null)"
  { [[ -n "$gl" && $'\n'"$ids"$'\n' == *$'\nskill-weight\n'* ]]; } || miss="$miss gates-line"
  grep -Eq '^[[:space:]]*bash _shared/probes/skill-weight-selftest\.sh[[:space:]]*$' "$d/.github/workflows/pr.yaml" || miss="$miss ci-selftest"
  grep -Eq '^[[:space:]]*bash _shared/probes/skill-weight\.sh[[:space:]]*$' "$d/.github/workflows/pr.yaml" || miss="$miss ci-probe"
  grep -Eq '^[[:space:]]*"[A-Za-z0-9_-]+\|bash _shared/probes/skill-weight\.sh"[[:space:]]*$' "$d/scripts/evidence-record.sh" || miss="$miss evidence-gates"
  printf '%s' "${miss# }"
}
w="$tmp/wire"; mkdir -p "$w/.github/workflows" "$w/scripts"
cp "$real_root/scripts/evidence-record.sh" "$w/scripts/evidence-record.sh"
cp "$real_root/Makefile" "$w/Makefile"; cp "$real_root/.github/workflows/pr.yaml" "$w/.github/workflows/pr.yaml"
m="$(wiring "$real_root")"; if [[ -z "$m" ]]; then ok_ "the repo's gates: recipe (calls the runner), pr.yaml and scripts/evidence-record.sh GATES all carry skill-weight.sh"; else bad_ "repo wiring" "missing: $m"; fi
grep -v 'evidence-record' "$real_root/Makefile" >"$w/Makefile"
m="$(wiring "$w")"; if [[ "$m" == "gates-line" ]]; then ok_ "wiring: gates: recipe that does not call the runner is caught"; else bad_ "wiring gates" "got [$m]"; fi
cp "$real_root/Makefile" "$w/Makefile"
sed 's/^POST_IDS=(/POST_IDS=(skill-weight /' "$real_root/scripts/evidence-record.sh" >"$w/scripts/evidence-record.sh"
m="$(wiring "$w")"; if [[ "$m" == "gates-line" ]]; then ok_ "wiring: skill-weight moved out of the main group (not run by --run gates) is caught"; else bad_ "wiring group" "got [$m]"; fi
sed 's/^AGG_IDS=(.*$/&\nPOST_IDS+=(skill-weight)/' "$real_root/scripts/evidence-record.sh" >"$w/scripts/evidence-record.sh"
m="$(wiring "$w")"; if [[ "$m" == "gates-line" ]]; then ok_ "wiring: a later POST_IDS+=(skill-weight) (invisible to a one-line grep) is caught, the recorder is asked"; else bad_ "wiring group append" "got [$m]"; fi
cp "$real_root/scripts/evidence-record.sh" "$w/scripts/evidence-record.sh"
grep -v 'bash _shared/probes/skill-weight.sh$' "$real_root/.github/workflows/pr.yaml" >"$w/.github/workflows/pr.yaml"
m="$(wiring "$w")"; if [[ "$m" == "ci-probe" ]]; then ok_ "wiring: pr.yaml probe line removed is caught"; else bad_ "wiring ci probe" "got [$m]"; fi
grep -v 'bash _shared/probes/skill-weight-selftest.sh$' "$real_root/.github/workflows/pr.yaml" >"$w/.github/workflows/pr.yaml"
m="$(wiring "$w")"; if [[ "$m" == "ci-selftest" ]]; then ok_ "wiring: pr.yaml selftest line removed is caught"; else bad_ "wiring ci selftest" "got [$m]"; fi

cp "$real_root/.github/workflows/pr.yaml" "$w/.github/workflows/pr.yaml"
grep -v 'skill-weight\.sh"' "$real_root/scripts/evidence-record.sh" >"$w/scripts/evidence-record.sh"
m="$(wiring "$w")"; if [[ "$m" == "gates-line evidence-gates" ]]; then ok_ "wiring: the GATES entry in scripts/evidence-record.sh removed is caught (twice: the recorder no longer lists it in main either)"; else bad_ "wiring evidence" "got [$m]"; fi

# ---- the real repo, and the core's hygiene -------------------------------------
run_case "the real repo passes" 0 "skill-weight: ok" "$real_root"
# Decision pin: prod-review tells the agent to RUN references/probes/acceptance-gap.sh directly,
# so the real script must carry its exec bit and be counted as a probe, not as read context.
out="$(bash "$probe" "$real_root" 2>&1)"
if [[ -x "$real_root/_shared/probes/acceptance-gap.sh" && "$out" != *"is not an executable .sh"* && "$out" == *"(+ probes "* ]]; then ok_ "the real repo: every probe a skill runs is executable and counted as a probe (no 'counted as read context' note)"; else bad_ "real probes executable" "$(oneline "$out")"; fi
out="$(python3 -I -W error "$core" check "$real_root" 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"skill-weight: ok"* && "$out" != *Warning* && "$out" != *Traceback* && "$out" != *"Exception ignored"* ]]; then ok_ "the core runs clean under python3 -I -W error on the real repo"; else bad_ "python -W error" "rc=$rc: $(oneline "$out")"; fi
out="$(python3 -I - "$tmp/pyc" "$core" "$driver" <<'PY' 2>&1
import ast, os, py_compile, sys
pyc = sys.argv[1]
for f in sys.argv[2:]:
    name = os.path.basename(f)
    try:
        py_compile.compile(f, cfile=os.path.join(pyc, name + "c"), doraise=True)
    except py_compile.PyCompileError as e:
        print("FAIL compile %s: %s" % (name, e)); continue
    tree = ast.parse(open(f).read())
    names = {}
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            for a in n.names:
                names[(a.asname or a.name).split(".")[0]] = 1
        elif isinstance(n, ast.ImportFrom):
            for a in n.names:
                names[a.asname or a.name] = 1
    used = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)}
    un = sorted(k for k in names if k not in used)
    print("FAIL unused imports in %s: %s" % (name, " ".join(un)) if un else "OK %s" % name)
PY
)"
if [[ "$out" == *FAIL* || "$out" != *"OK skill-weight.py"* || "$out" != *"OK skill-weight-selftest.py"* ]]; then
  bad_ "python hygiene (py_compile + unused imports)" "$(oneline "$out")"
else ok_ "the core and the driver compile (py_compile) and have no unused imports"; fi

total=$((pass + bad))
if (( total == 0 )); then echo "skill-weight selftest: ZERO cases ran"; exit 2; fi
if (( bad )); then echo "skill-weight selftest: $bad of $total case(s) failed"; exit 1; fi
echo "skill-weight selftest: ok -- $pass/$total case(s)"
