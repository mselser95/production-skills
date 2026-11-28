#!/usr/bin/env bash
# provenance: candidate; ttl: 2027-04-01; pinning: true
# service-python-gates-selftest.sh -- the gates and CI of prod-new/modules/service-python as a
# unit of a generated repository. Assembles the module (single layout, and monorepo for the
# placement) into a scratch dir and:
#   always (no Python env needed): the workflow lands where GitHub runs it (single: the root's
#     .github/workflows/; monorepo: the root's, once, not under the unit) and passes a static
#     policy (SHA allowlist, persist-credentials, job permissions, one working-directory per job,
#     unit-scoped concurrency, hash-pinned uv, no caller text in run:, triggers, timeouts) and goes
#     RED under one mutation per rule; the Makefiles swallow no failure and print `<t>: ok` last;
#     the uv requirement is hash-pinned; gates/audit.py fails closed (fake `uv` on PATH);
#   when `uv` can build the LOCKED environment (offline from its cache, else online under a 60 s
#     bound): `make check-fast` is green, each gate goes RED under its mutation (cross-zone import,
#     type error, unformatted file, lock drift), a dependency added to pyproject never rewrites
#     uv.lock, a test outside every lane is RED under `make test-lanes-cover`, and
#     `make -f <Makefile>` works from another directory.
# Budget: the default run is a few seconds of CPU (about 15 s wall, mostly `make check-fast`).
# Needs PyYAML (python3's, else `uv run --with pyyaml` from the cache); with neither it FAILS.
# Output: `ok`/`FAIL`/`skip` lines, final line `<N> ok, <M> failed, <K> skipped`.
# Exit: 0 all ok - 1 a case failed - 2 setup failed.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mods="$here/prod-new/modules"
T="$(mktemp -d "${TMPDIR:-/tmp}/svc-py-gates.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT

ok=0; bad=0; skipped=0
pass() { ok=$((ok + 1)); echo "ok   $1"; }
fail() { bad=$((bad + 1)); echo "FAIL $1${2:+ -- $2}"; }
skip() { skipped=$((skipped + 1)); echo "skip $1 -- $2"; }
check() { # <label> <rc> [detail]
  if [[ "$2" == 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi
}

assemble() { # <modules dir> <layout> <dest>
  python3 -I -B "$here/scripts/assemble.py" --dest "$3" --layout "$2" --module service-python \
    --modules-dir "$1" --slot SERVICE=ledger-svc --slot PACKAGE=ledger_svc --slot OWNER=acme \
    >"$T/assemble.log" 2>&1
}

A="$T/a"
assemble "$mods" single "$A" || { echo "setup: assemble failed"; tail -n 5 "$T/assemble.log"; exit 2; }
WF="$A/.github/workflows/python-unit.yml"

# ---------------------------------------------------------------- where the workflow lands
# layout_check <dest> <layout>: prints the first problem and returns 1, else returns 0.
layout_check() {
  local d="$1" unit="$1" n
  [[ "$2" == monorepo ]] && unit="$1/services/ledger-svc"
  [[ -f "$d/.github/workflows/python-unit.yml" ]] \
    || { echo "no .github/workflows/python-unit.yml at the repository root"; return 1; }
  [[ -f "$unit/Makefile" && -f "$unit/ci/uv-requirements.txt" ]] \
    || { echo "the unit (Makefile, ci/uv-requirements.txt) is not at $unit"; return 1; }
  n="$(find "$d" -name 'python-unit*.yml' | wc -l | tr -d ' ')"
  [[ "$n" == 1 ]] || { echo "$n workflow copies under the repository, want exactly 1"; return 1; }
  grep -q '^  workflow_call:' "$d/.github/workflows/python-unit.yml" \
    || { echo "the workflow is not callable (no workflow_call)"; return 1; }
  return 0
}
out="$(layout_check "$A" single)"; check "single layout: the workflow is at .github/workflows/ of the root, once, with the unit beside it" $? "$out"
M="$T/mono"
if assemble "$mods" monorepo "$M"; then out="$(layout_check "$M" monorepo)"; r=$?; else out="assemble failed"; r=1; fi
check "monorepo layout: ONE workflow at the root's .github/workflows/ (callable with a local uses:), none under the unit" "$r" "$out"
# the placement rule removed or turned into `unit` -> RED
for variant in "unit" "removed"; do
  mm="$T/mm-$variant"; mkdir -p "$mm"; cp -R "$mods/service-python" "$mm/service-python"
  python3 -I -B - "$mm/service-python/module.json" "$variant" <<'PYEOF'
import json
import sys

path, variant = sys.argv[1:3]
doc = json.load(open(path, encoding="utf-8"))
if variant == "unit":
    doc["placement"][".github/**"] = "unit"
else:
    del doc["placement"][".github/**"]
json.dump(doc, open(path, "w", encoding="utf-8"), indent=2)
PYEOF
  if assemble "$mm" monorepo "$T/mm-out-$variant"; then out="$(layout_check "$T/mm-out-$variant" monorepo)"; r=$?; else r=1; fi
  if [[ $r != 0 ]]; then r=0; else r=1; fi; check "placement rule for .github/** $variant (monorepo) -> RED" "$r"
  if [[ $variant == removed ]]; then
    if assemble "$mm" single "$T/mm-single-$variant"; then out="$(layout_check "$T/mm-single-$variant" single)"; r=$?; else r=1; fi
    if [[ $r != 0 ]]; then r=0; else r=1; fi; check "placement rule for .github/** removed (single) -> RED" "$r"
  fi
done

# ---------------------------------------------------------------- targets exist, reachable
TARGETS="check-fast verify lint fmt typecheck test test-unit test-contract test-architecture architecture test-lanes-cover lock-check audit"
for t in $TARGETS; do
  out="$(cd "$A" && make -n "$t" 2>&1)"; rc=$?
  if [[ $rc == 0 && -n "$out" && "$out" != *"No rule to make target"* ]]; then r=0; else r=1; fi; check "make -n $t resolves to a recipe from the assembled Makefile" "$r" "rc=$rc"
done
first="$(cd "$A" && make -n 2>&1 | head -n 1)"
if [[ "$first" == 'cd "./" && uv sync --locked' ]]; then r=0; else r=1; fi; check "the default goal is check-fast" "$r" "first line: $first"
for t in $TARGETS; do
  out="$(cd "$A" && make -n "$t" 2>&1)"
  if [[ "$t" == fmt || "$t" == audit || "$out" == *"$t: ok"* ]]; then r=0; else r=1; fi; check "target $t prints its one summary line" "$r"
done
out="$(cd / && make -f "$A/Makefile" -n check-fast 2>&1)"; rc=$?
if [[ $rc == 0 && "$out" == *"cd \"$A/\" && uv sync --locked"* ]]; then r=0; else r=1; fi
check "make -f <assembled>/Makefile -n check-fast works from /" "$r" "rc=$rc $(head -n 2 <<<"$out" | tr '\n' '|')"

# ---------------------------------------------------------------- a python with PyYAML
PYY=()
if python3 -I -B -c 'import yaml' >/dev/null 2>&1; then
  PYY=(python3 -I -B)
elif command -v uv >/dev/null 2>&1 \
  && uv run --offline --no-project --with pyyaml python -c 'import yaml' >/dev/null 2>&1; then
  PYY=(uv run --offline --no-project --with pyyaml python -I -B)
elif command -v uv >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 \
  && timeout 60 uv run --no-project --with pyyaml python -c 'import yaml' >/dev/null 2>&1; then
  PYY=(uv run --no-project --with pyyaml python -I -B)  # online, after the offline try failed
fi
if [[ ${#PYY[@]} == 0 ]]; then
  fail "PyYAML is available" "install PyYAML for python3, or have uv and network for `uv run --with pyyaml`"
  echo "$ok ok, $bad failed, $skipped skipped"; exit 1
fi

# ---------------------------------------------------------------- workflow policy checker
cat >"$T/cilint.py" <<'PYEOF'
import os
import re
import sys

import yaml

# action -> the exact commit SHA(s) this template pins (a silent bump or a typo is RED).
ALLOWED = {
    "actions/checkout": {"11bd71901bbe5b1630ceea73d27597364c9af683"},
    "actions/cache": {"0400d5f644dc74513175e3cd8d07132dd4860809"},
}
SELF = ".github/workflows/python-unit.yml"
WORKDIR = "${{ inputs.working-directory || '.' }}"
pin = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
inject = re.compile(r"\$\{\{\s*(github\.event\.|github\.head_ref|inputs\.)")


def read_only(perm):
    return perm == "read-all" or (
        isinstance(perm, dict) and all(v in ("read", "none") for v in perm.values())
    )


def findings(path, root):
    text = open(path, encoding="utf-8").read()
    doc = yaml.safe_load(text)
    bad = []
    on = doc.get("on", doc.get(True)) or {}
    if "pull_request_target" in on:
        bad.append("PRT: pull_request_target is forbidden")
    for trig in ("pull_request", "push"):
        if trig not in on:
            bad.append(f"TRIGGER: no {trig} trigger")
        elif not (on[trig] or {}).get("paths"):
            bad.append(f"PATHS: {trig} has no path filter")
        elif SELF not in on[trig]["paths"]:
            bad.append(f"SELFPATH: {trig} filter does not include the workflow file itself")
    if root:
        filters = (on["pull_request"] or {}).get("paths") or []
        for flt in filters:
            base = flt[:-3] if flt.endswith("/**") else flt
            if not os.path.exists(os.path.join(root, base)):
                bad.append(f"ROOTPATH: filter {flt!r} matches nothing in the assembled repository")
        default = ((on.get("workflow_call") or {}).get("inputs") or {}).get("working-directory", {})
        if default.get("default") != ".":
            bad.append("ROOTPATH: working-directory default is not '.' (the unit is the root)")
    if not read_only(doc.get("permissions")):
        bad.append(f"PERMISSIONS: top-level permissions must be read-only, got {doc.get('permissions')!r}")
    conc = doc.get("concurrency")
    if not conc:
        bad.append("CONCURRENCY: missing")
    else:
        group = str(conc.get("group", "")) if isinstance(conc, dict) else str(conc)
        if "inputs.working-directory" not in group:
            bad.append("CONCURRENCY-GROUP: the group does not name the unit (inputs.working-directory)")
        if "python-unit" not in group:
            bad.append("CONCURRENCY-GROUP: the group has no suffix unique to this workflow")
    if "TODO-PIN" in text:
        bad.append("TODO-PIN: an action is still unpinned")
    jobs = doc.get("jobs") or {}
    for need in ("check-fast", "verify"):
        if need not in jobs:
            bad.append(f"JOBS: no job {need}")
    workdirs = set()
    for name, job in jobs.items():
        if not isinstance(job.get("timeout-minutes"), int):
            bad.append(f"TIMEOUT: job {name} has no timeout-minutes")
        if "permissions" in job and not read_only(job["permissions"]):
            bad.append(f"PERMISSIONS: job {name} permissions must be read-only, got {job['permissions']!r}")
        steps = job.get("steps") or []
        if any("run" in s for s in steps):
            wd = ((job.get("defaults") or {}).get("run") or {}).get("working-directory")
            if wd is None:
                bad.append(f"WORKDIR: job {name} has no defaults.run.working-directory")
            elif wd != WORKDIR:
                bad.append(f"WORKDIR: job {name} working-directory is {wd!r}, want {WORKDIR!r}")
            workdirs.add(wd)
        for step in steps:
            use = step.get("uses")
            if use is not None:
                if not pin.match(str(use)):
                    bad.append(f"PIN: {use!r} is not pinned by a 40-hex commit SHA")
                else:
                    action, sha = str(use).split("@")
                    if action not in ALLOWED:
                        bad.append(f"SHA: action {action} is not in the allowlist")
                    elif sha not in ALLOWED[action]:
                        bad.append(f"SHA: {action}@{sha} is not a SHA this template pins")
                if str(use).startswith("actions/checkout@") \
                        and (step.get("with") or {}).get("persist-credentials") is not False:
                    bad.append(f"CHECKOUT: job {name} checkout does not set persist-credentials: false")
            run = str(step.get("run", ""))
            if inject.search(run):
                bad.append(f"INJECTION: job {name} interpolates event or input data into run:")
            if re.search(r'pip"?\s+install', run) and "--require-hashes" not in run:
                bad.append(f"HASHES: job {name} installs with pip without --require-hashes")
    if len(workdirs) > 1:
        bad.append("WORKDIR: the jobs do not share one working-directory")
    return bad


root = sys.argv[1] if sys.argv[1] != "-" else ""
for i, path in enumerate(sys.argv[2:]):
    found = findings(path, root if i == 0 else "")
    with open(path + ".out", "w", encoding="utf-8") as fh:
        fh.write("\n".join(found) if found else "cilint: clean")
    with open(path + ".rc", "w", encoding="utf-8") as fh:
        fh.write("1" if found else "0")
PYEOF
# One checker process for the real workflow and every mutant (cheap: one interpreter start).
mkdir -p "$T/m"; labels=(); needles=(); n=0
# mutate_wf <label> <old> <new> <needle> [nth]: a scratch copy with the nth <old> changed must be
# RED naming <needle>
mutate_wf() {
  local label="$1" old="$2" new="$3" needle="$4" nth="${5:-1}"
  n=$((n + 1))
  if python3 -I -B - "$WF" "$T/m/$n.yml" "$old" "$new" "$nth" <<'PYEOF'
import sys

src, dst, old, new, nth = sys.argv[1:6]
text = open(src, encoding="utf-8").read()
parts = text.split(old)
if len(parts) <= int(nth):
    sys.exit(1)
text = old.join(parts[: int(nth)]) + new + old.join(parts[int(nth) :])
open(dst, "w", encoding="utf-8").write(text)
PYEOF
  then labels[n]="$label"; needles[n]="$needle"
  else labels[n]="$label"; needles[n]="@@not-applied"; fi
}
CHK="actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683"
WDIR='    defaults:
      run:
        working-directory: ${{ inputs.working-directory || '"'.'"' }}
'
mutate_wf "unpinned action (tag instead of SHA) -> RED" "$CHK # v4.2.2" "actions/checkout@v4" "PIN:"
mutate_wf "TODO-PIN left in -> RED" "# v4.2.4" "# TODO-PIN" "TODO-PIN:"
mutate_wf "missing timeout-minutes -> RED" "    timeout-minutes: 10
" "" "TIMEOUT:"
mutate_wf "top-level permissions: write-all -> RED" "permissions:
  contents: read" "permissions: write-all" "PERMISSIONS: top-level"
mutate_wf "top-level contents: write -> RED" "  contents: read" "  contents: write" "PERMISSIONS: top-level"
mutate_wf "job-level permissions: write-all -> RED" "    timeout-minutes: 10
" "    timeout-minutes: 10
    permissions: write-all
" "PERMISSIONS: job check-fast"
mutate_wf "pull_request_target -> RED" "  pull_request:" "  pull_request_target:" "PRT:"
mutate_wf "event data interpolated into run: -> RED" "      - run: make check-fast" \
  '      - run: echo "${{ github.event.pull_request.title }}"' "INJECTION:"
mutate_wf "inputs.working-directory interpolated into run: -> RED" "      - run: make check-fast" \
  '      - run: make -C ${{ inputs.working-directory }} check-fast' "INJECTION:"
mutate_wf "no concurrency -> RED" "concurrency:" "x-concurrency:" "CONCURRENCY:"
mutate_wf "concurrency group without the unit -> RED" "group: python-unit/\${{ inputs.working-directory || '.' }}/" \
  "group: python-unit/" "CONCURRENCY-GROUP: the group does not name the unit"
mutate_wf "concurrency group without a suffix unique to this workflow -> RED" "group: python-unit/" \
  "group: \${{ github.workflow }}/" "CONCURRENCY-GROUP: the group has no suffix"
mutate_wf "path filter removed -> RED" '    paths:
      - "src/**"' "    x-paths:
      - \"src/**\"" "PATHS:"
mutate_wf "pull_request filter without the workflow file itself -> RED" '      - ".github/workflows/python-unit.yml"
' "" "SELFPATH: pull_request"
mutate_wf "push filter without the workflow file itself -> RED" '      - ".github/workflows/python-unit.yml"
' "" "SELFPATH: push" 2
mutate_wf "checkout with persist-credentials: true -> RED" "persist-credentials: false" "persist-credentials: true" "CHECKOUT:"
mutate_wf "checkout without persist-credentials -> RED" "        with:
          persist-credentials: false
" "" "CHECKOUT:"
mutate_wf "well-formed but wrong checkout SHA -> RED" "11bd71901bbe5b1630ceea73d27597364c9af683" "11bd71901bbe5b1630ceea73d27597364c9af684" "SHA: actions/checkout"
mutate_wf "well-formed but wrong cache SHA -> RED" "0400d5f644dc74513175e3cd8d07132dd4860809" "0400d5f644dc74513175e3cd8d07132dd4860808" "SHA: actions/cache"
mutate_wf "check-fast job without the working-directory default -> RED" "$WDIR" "" "WORKDIR: job check-fast has no" 1
mutate_wf "nightly job without the working-directory default -> RED" "$WDIR" "" "WORKDIR: job nightly has no" 3
mutate_wf "pip install without --require-hashes -> RED" "--require-hashes " "" "HASHES:"
mutate_wf "uv installed by version only (no hashes) -> RED" "--require-hashes --only-binary=:all: -r ci/uv-requirements.txt" '"uv==0.13.7"' "HASHES:"

"${PYY[@]}" "$T/cilint.py" "$A" "$WF" "$T"/m/*.yml
out="$(cat "$WF.out")"
if [[ "$(cat "$WF.rc")" == 0 ]]; then r=0; else r=1; fi; check "the real workflow passes the static policy (and its filters and working-directory point at the unit)" "$r" "$out"
for i in $(seq 1 "$n"); do
  o="$(cat "$T/m/$i.yml.out" 2>/dev/null)"; rc="$(cat "$T/m/$i.yml.rc" 2>/dev/null)"
  if [[ "${needles[$i]}" == "@@not-applied" ]]; then
    fail "${labels[$i]}" "mutation did not apply (old text missing)"
  else
    if [[ "$rc" == 1 && "$o" == *"${needles[$i]}"* ]]; then r=0; else r=1; fi; check "${labels[$i]}" "$r" "rc=$rc out=$o"
  fi
done

# ---------------------------------------------------------------- the uv requirement is hash-pinned
reqcheck() { # <file>: 0 when uv is pinned with at least one sha256 hash and nothing unhashed
  grep -Eq '^uv==0\.13\.7 \\$' "$1" \
    && [[ "$(grep -Ec -- '--hash=sha256:[0-9a-f]{64}' "$1")" -ge 1 ]] \
    && ! grep -Eq '^[A-Za-z]' <(grep -Ev '^uv==0\.13\.7 \\$' "$1")
}
REQ="$A/ci/uv-requirements.txt"
reqcheck "$REQ"; check "ci/uv-requirements.txt pins uv 0.13.7 with sha256 hashes" $?
sed '/--hash=/d' "$REQ" >"$T/req-nohash.txt"
reqcheck "$T/req-nohash.txt"; if [[ $? != 0 ]]; then r=0; else r=1; fi; check "uv requirement with its hashes removed -> RED" "$r"
sed 's/^uv==0\.13\.7/uv>=0.13/' "$REQ" >"$T/req-range.txt"
reqcheck "$T/req-range.txt"; if [[ $? != 0 ]]; then r=0; else r=1; fi; check "uv requirement as a range instead of a version -> RED" "$r"

# ---------------------------------------------------------------- Makefiles swallow no failure
cat >"$T/mkcheck.py" <<'PYEOF'
import re
import sys

GATES = ("check-fast verify lint typecheck test test-unit test-contract test-architecture "
         "test-lanes-cover lock-check").split()
SWALLOW = re.compile(r"\|\|\s*true|;\s*true|\|\|\s*:\s*$|\|\|\s*exit\s+0")


def findings(text):
    bad = []
    if "export UV_LOCKED" not in text:
        bad.append("LOCKED: the Makefile does not export UV_LOCKED")
    if not re.search(r"^include \$\(dir \$\(lastword \$\(MAKEFILE_LIST\)\)\)unit\.mk$", text, re.M):
        bad.append("INCLUDE: unit.mk is not included relative to the Makefile")
    recipes, cur = {}, None
    for raw in text.split("\n"):
        m = re.match(r"^([A-Za-z][A-Za-z0-9-]*):(?!=)", raw)
        if m:
            cur = m.group(1)
            recipes.setdefault(cur, [])
        elif raw.startswith("\t") and cur:
            recipes[cur].append(raw[1:].strip())
        elif raw.strip() and not raw.startswith("#"):
            cur = None
    for target, lines in recipes.items():
        for line in lines:
            if line.startswith(("-", "@-")):
                bad.append(f"DASH: {target} has a recipe line that ignores its failure: {line[:50]}")
            if SWALLOW.search(line):
                bad.append(f"SWALLOW: {target} swallows a failure: {line[:50]}")
    for target in GATES:
        lines = recipes.get(target) or []
        if not lines or not lines[-1].startswith(f'@echo "{target}: ok'):
            bad.append(f"NOOK: {target} does not end by printing '{target}: ok'")
        elif any(": ok" in line for line in lines[:-1]):
            bad.append(f"NOOK: {target} prints its ok line before the end")
    return bad


for path in sys.argv[1:]:
    found = findings(open(path, encoding="utf-8").read())
    with open(path + ".out", "w", encoding="utf-8") as fh:
        fh.write("\n".join(found) if found else "mkcheck: clean")
    with open(path + ".rc", "w", encoding="utf-8") as fh:
        fh.write("1" if found else "0")
PYEOF
mkdir -p "$T/mk"; cat "$A/Makefile" "$A/unit.mk" >"$T/mk/real.mk"
mklabels=(); mkneedles=(); k=0
mutate_mk() { # <label> <old> <new> <needle>
  local label="$1" old="$2" new="$3" needle="$4"
  k=$((k + 1))
  if python3 -I -B - "$T/mk/real.mk" "$T/mk/$k.mk" "$old" "$new" <<'PYEOF'
import sys

src, dst, old, new = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if old not in text:
    sys.exit(1)
open(dst, "w", encoding="utf-8").write(text.replace(old, new, 1))
PYEOF
  then mklabels[k]="$label"; mkneedles[k]="$needle"
  else mklabels[k]="$label"; mkneedles[k]="@@not-applied"; fi
}
mutate_mk "a '-' prefix on a recipe line -> RED" "	\$(IN) uv run mypy
	@echo \"typecheck" "	-\$(IN) uv run mypy
	@echo \"typecheck" "DASH:"
mutate_mk "a '@-' prefix on a recipe line -> RED" "	\$(IN) uv run mypy
	@echo \"typecheck" "	@-\$(IN) uv run mypy
	@echo \"typecheck" "DASH:"
mutate_mk "'|| true' on a recipe line -> RED" "	\$(IN) uv lock --check" "	\$(IN) uv lock --check || true" "SWALLOW:"
mutate_mk "'; true' on a recipe line -> RED" "	\$(IN) uv run pytest -q tests/unit" "	\$(IN) uv run pytest -q tests/unit; true" "SWALLOW:"
mutate_mk "a gate target without its ok line -> RED" '	@echo "lint: ok"
' "" "NOOK: lint"
mutate_mk "an ok line printed before the end -> RED" "	\$(IN) uv run ruff check
	\$(IN) uv run ruff format --check
	@echo \"lint: ok\"" "	@echo \"lint: ok\"
	\$(IN) uv run ruff format --check
	\$(IN) uv run ruff check" "NOOK: lint"
mutate_mk "export UV_LOCKED removed -> RED" "export UV_LOCKED := 1" "UV_LOCKED := 1" "LOCKED:"
mutate_mk "include unit.mk not relative to the Makefile -> RED" 'include $(dir $(lastword $(MAKEFILE_LIST)))unit.mk' "include unit.mk" "INCLUDE:"
"${PYY[@]}" "$T/mkcheck.py" "$T/mk/real.mk" "$T"/mk/*.mk
out="$(cat "$T/mk/real.mk.out")"
if [[ "$(cat "$T/mk/real.mk.rc")" == 0 ]]; then r=0; else r=1; fi; check "the Makefiles swallow no failure and every gate target ends by printing '<target>: ok'" "$r" "$out"
for i in $(seq 1 "$k"); do
  o="$(cat "$T/mk/$i.mk.out" 2>/dev/null)"; rc="$(cat "$T/mk/$i.mk.rc" 2>/dev/null)"
  if [[ "${mkneedles[$i]}" == "@@not-applied" ]]; then
    fail "${mklabels[$i]}" "mutation did not apply (old text missing)"
  else
    if [[ "$rc" == 1 && "$o" == *"${mkneedles[$i]}"* ]]; then r=0; else r=1; fi; check "${mklabels[$i]}" "$r" "rc=$rc out=$o"
  fi
done

# actionlint, when installed
AL=""
if command -v actionlint >/dev/null 2>&1; then
  AL="$(command -v actionlint)"
elif command -v go >/dev/null 2>&1 && [[ -x "$(go env GOPATH 2>/dev/null)/bin/actionlint" ]]; then
  AL="$(go env GOPATH)/bin/actionlint"
fi
if [[ -n "$AL" ]]; then
  out="$("$AL" "$WF" 2>&1)"; r=$?; check "actionlint accepts the workflow" "$r" "$out"
else
  skip "actionlint accepts the workflow" "actionlint is not on PATH or in \$(go env GOPATH)/bin"
fi

# ---------------------------------------------------------------- gates/audit.py (fake uv)
if python3 -I -B -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
  fb="$T/fakebin"; mkdir -p "$fb"
  cat >"$fb/uv" <<'SHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_UV_LOG"
[[ -n "${FAKE_UV_OUT:-}" ]] && cat "$FAKE_UV_OUT"
exit "${FAKE_UV_RC:-0}"
SHEOF
  chmod +x "$fb/uv"
  printf '%s\n' '{"vulnerabilities": []}' >"$T/out-clean.json"
  printf '%s\n' '{"vulnerabilities": [{"dependency": {"name": "x", "version": "1"}, "id": "GHSA-aaaa-bbbb-cccc", "display_id": "PYSEC-2099-1", "aliases": ["CVE-2099-1", "PYSEC-2099-1"]}]}' >"$T/out-find.json"
  printf '%s\n' 'not json at all' >"$T/out-junk.json"
  soon="$(python3 -I -B -c 'import datetime; print(datetime.date.today() + datetime.timedelta(days=30))')"
  far="$(python3 -I -B -c 'import datetime; print(datetime.date.today() + datetime.timedelta(days=400))')"
  W="$A/gates/audit-waivers.txt"; cp "$W" "$T/waivers.orig"
  run_audit() { # <fake rc> <fake report file>: runs the REAL gates/audit.py against the fake uv
    : >"$T/uv.log"
    PATH="$fb:$PATH" FAKE_UV_LOG="$T/uv.log" FAKE_UV_RC="$1" FAKE_UV_OUT="$2" python3 -I -B "$A/gates/audit.py" 2>&1
  }
  # audit_red <label> <needle> <rc> <report>: the audit must exit 1 and print <needle>
  audit_red() {
    local o rc
    o="$(run_audit "$3" "$4")"; rc=$?
    if [[ $rc == 1 && "$o" == *"$2"* ]]; then r=0; else r=1; fi; check "$1" "$r" "rc=$rc $o"
  }
  waiver() { cp "$T/waivers.orig" "$W"; [[ $# == 0 ]] || printf '%s\n' "$1" >>"$W"; } # [line]: reset, then append
  out="$(run_audit 0 "$T/out-clean.json")"; rc=$?
  [[ $rc == 0 && "$out" == *"audit: ok (0 waiver"* ]] && grep -q -- "audit --locked" "$T/uv.log"
  r=$?; check "audit: clean advisory service passes and runs uv audit on the lock" "$r" "rc=$rc $out"
  audit_red "audit: an unreachable or failing service FAILS CLOSED (uv rc 2 -> RED)" "audit: FAIL" 2 ""
  audit_red "audit: exit 0 with finding lines in the report is RED (never the exit code alone)" "exit" 0 "$T/out-find.json"
  audit_red "audit: exit 1 with an empty report is RED" "no finding" 1 "$T/out-clean.json"
  audit_red "audit: a report that is not JSON is RED" "cannot read" 0 "$T/out-junk.json"
  audit_red "audit: an unwaived finding is RED and named" "audit: FINDING PYSEC-2099-1" 1 "$T/out-find.json"
  waiver "GHSA-aaaa-bbbb-cccc $soon owner covers the finding by its id"
  out="$(run_audit 1 "$T/out-find.json")"; rc=$?
  if [[ $rc == 0 && "$out" == *"audit: ok (1 waiver"* ]]; then r=0; else r=1; fi; check "audit: a live waiver accepts the finding it names" "$r" "rc=$rc $out"
  waiver "CVE-2099-1 $soon owner covers the finding by an alias"
  out="$(run_audit 1 "$T/out-find.json")"; rc=$?
  if [[ $rc == 0 ]]; then r=0; else r=1; fi; check "audit: a waiver matches a finding by alias" "$r" "rc=$rc $out"
  waiver "GHSA-zzzz-zzzz-zzzz $soon owner waives a different advisory"
  audit_red "audit: a waiver for another advisory does not accept the finding" "FINDING" 1 "$T/out-find.json"
  waiver "GHSA-zzzz-zzzz-zzzz $soon owner nothing matches this"
  audit_red "audit: a STALE waiver (matches no finding, clean audit) is RED" "STALE" 0 "$T/out-clean.json"
  waiver "GHSA-aaaa-bbbb-cccc $soon owner matches
GHSA-zzzz-zzzz-zzzz $soon owner stale beside a live one"
  audit_red "audit: a STALE waiver beside a live one is RED and names the stale id" "GHSA-zzzz-zzzz-zzzz" 1 "$T/out-find.json"
  waiver "GHSA-0000-0000-0000 2000-01-01 owner reason text"
  out="$(run_audit 0 "$T/out-clean.json")"; rc=$?
  if [[ $rc == 1 && "$out" == *"expired"* && ! -s "$T/uv.log" ]]; then r=0; else r=1; fi; check "audit: an EXPIRED waiver is RED (and uv is not even called)" "$r" "rc=$rc $out"
  waiver "GHSA-0000-0000-0000 9999-99-99 owner reason"
  audit_red "audit: a malformed date is RED" "bad expiry" 0 "$T/out-clean.json"
  waiver "GHSA-0000-0000-0000 $soon"
  audit_red "audit: a waiver without owner and reason is RED" "malformed" 0 "$T/out-clean.json"
  waiver "ghsa-lower-case $soon owner id shape"
  audit_red "audit: an advisory id of the wrong shape is RED" "malformed advisory id" 0 "$T/out-clean.json"
  waiver "-GHSA-aaaa-bbbb-cccc $soon owner leading dash"
  audit_red "audit: an id with a leading '-' is RED" "malformed advisory id" 0 "$T/out-clean.json"
  waiver "--ignore $soon owner an option, not an id"
  audit_red "audit: an id that is an option is RED" "malformed advisory id" 0 "$T/out-clean.json"
  waiver "GHSA-aaaa-bbbb-cccc $soon owner first
GHSA-aaaa-bbbb-cccc $soon owner second"
  audit_red "audit: a duplicate waiver id is RED" "duplicate" 1 "$T/out-find.json"
  waiver "GHSA-aaaa-bbbb-cccc $far owner far away"
  audit_red "audit: an expiry more than 180 days ahead is RED" "more than 180 days" 1 "$T/out-find.json"
  printf '\xef\xbb\xbfGHSA-aaaa-bbbb-cccc %s owner file begins with a BOM\n' "$soon" >"$W"
  out="$(run_audit 1 "$T/out-find.json")"; rc=$?
  if [[ $rc == 0 && "$out" == *"audit: ok (1 waiver"* ]]; then r=0; else r=1; fi; check "audit: a UTF-8 BOM at the start of the waiver file is stripped" "$r" "rc=$rc $out"
  cp "$T/waivers.orig" "$W"
else
  skip "audit.py cases" "python3 older than 3.11 (the unit's floor)"
fi

# ---------------------------------------------------------------- the locked environment
# Offline from the uv cache first; else online, bounded by 60 s. In CI uv must be installed first
# (hash-pinned: pip install --require-hashes -r <module>/template/ci/uv-requirements.txt).
envok=0; envwhy="uv is not installed"
if command -v uv >/dev/null 2>&1; then
  if (cd "$A" && uv sync --locked --offline) >"$T/sync.log" 2>&1; then
    envok=1
  elif command -v timeout >/dev/null 2>&1; then
    if (cd "$A" && timeout 60 uv sync --locked) >"$T/sync-online.log" 2>&1; then
      envok=1
    else
      envwhy="the locked environment cannot be created offline or online within 60 s: $(tail -n 1 "$T/sync-online.log")"
    fi
  else
    envwhy="the locked environment cannot be created offline and there is no timeout(1) for an online try: $(tail -n 1 "$T/sync.log")"
  fi
fi
if [[ $envok == 0 ]]; then
  skip "assembled make check-fast and the gate mutations" "$envwhy"
else
  out="$(cd "$A" && make check-fast 2>&1)"; rc=$?
  if [[ $rc == 0 && "$out" == *"check-fast: ok"* ]]; then r=0; else r=1; fi; check "assembled make check-fast is green" "$r" "rc=$rc $(tail -n 3 <<<"$out" | tr '\n' '|')"
  out="$(cd / && make -f "$A/Makefile" lock-check 2>&1)"; rc=$?
  if [[ $rc == 0 && "$out" == *"lock-check: ok"* ]]; then r=0; else r=1; fi; check "make -f <assembled>/Makefile lock-check runs from /" "$r" "rc=$rc $(tail -n 2 <<<"$out" | tr '\n' '|')"
  out="$(cd "$A" && make test-lanes-cover 2>&1)"; rc=$?
  if [[ $rc == 0 && "$out" == *"test-lanes-cover: ok"* ]]; then r=0; else r=1; fi; check "make test-lanes-cover is green on the clean unit" "$r" "rc=$rc $(tail -n 2 <<<"$out" | tr '\n' '|')"

  # mutate_cmd <label> <abs file> <append|replace> <old-or-text> <new> <needle> -- <command...>:
  # the file is changed, the command run and the file restored; RED = the command failed AND its
  # output names <needle>.
  mutate_cmd() {
    local label="$1" file="$2" how="$3" old="$4" new="$5" needle="$6" o rc
    shift 7
    cp "$file" "$T/restore.bak"
    python3 -I -B - "$file" "$how" "$old" "$new" <<'PYEOF' || { cp "$T/restore.bak" "$file"; fail "$label" "mutation did not apply"; return; }
import sys

path, how, old, new = sys.argv[1:5]
text = open(path, encoding="utf-8").read()
if how == "append":
    text += old
else:
    if old not in text:
        sys.exit(1)
    text = text.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(text)
PYEOF
    o="$("$@" 2>&1)"; rc=$?
    cp "$T/restore.bak" "$file"
    if [[ $rc != 0 && "$o" == *"$needle"* ]]; then r=0; else r=1; fi; check "$label" "$r" "rc=$rc needle=[$needle] tail=$(tail -n 2 <<<"$o" | tr '\n' '|')"
  }
  mutate_env() { # <label> <file under the unit> <how> <old-or-text> <new> <make target> <needle>
    mutate_cmd "$1" "$A/$2" "$3" "$4" "$5" "$7" -- bash -c 'cd "$1" && make "$2"' _ "$A" "$6"
  }
  mutate_env "domain importing an adapter -> make test-architecture RED (zone direction)" \
    src/ledger_svc/domain/ledger.py append $'\nfrom ledger_svc.adapters.outbound import memory_store\n' "" \
    test-architecture "FAILED tests/architecture/test_boundaries.py::test_domain_imports_only_pure"
  mutate_env "type error injected -> make typecheck RED" \
    src/ledger_svc/platform/clock.py append $'\n_BAD: int = "x"\n' "" typecheck "[assignment]"
  mutate_env "unformatted file -> make check-fast RED at the format step" \
    src/ledger_svc/platform/clock.py append $'\n_X = [\'a\']\n' "" check-fast "would be reformatted"
  mutate_env "dependency in pyproject not in the lock -> make lock-check RED" \
    pyproject.toml replace 'dependencies = []' 'dependencies = ["requests"]' lock-check "uv lock"
  out="$(cd "$A" && make lock-check 2>&1)"; rc=$?
  if [[ $rc == 0 ]]; then r=0; else r=1; fi; check "after the mutations were reverted, lock-check is green again" "$r" "rc=$rc $out"
  # a dependency added to pyproject: a non-lock target FAILS and uv.lock stays byte-identical
  # (without `export UV_LOCKED`, uv re-resolves and rewrites the lock instead)
  mutate_cmd "dependency added to pyproject -> make lint FAILS and uv.lock is byte-identical" \
    "$A/pyproject.toml" replace 'dependencies = []' 'dependencies = ["requests"]' "LOCK-UNCHANGED" -- \
    bash -c 'cd "$1" && cp uv.lock "$2" && b="$(cksum <uv.lock)"; make lint 2>&1; rc=$?; a="$(cksum <uv.lock)"
      if [ "$a" = "$b" ]; then echo LOCK-UNCHANGED; else echo LOCK-REWRITTEN; fi; cp "$2" uv.lock; exit $rc' \
    _ "$A" "$T/lock.bak"
  # a test file outside every lane directory
  printf 'def test_orphan() -> None:\n    raise AssertionError("outside every lane")\n' >"$A/tests/test_orphan.py"
  out="$(cd "$A" && make test-lanes-cover 2>&1)"; rc=$?
  rm -f "$A/tests/test_orphan.py"
  if [[ $rc != 0 && "$out" == *"tests/test_orphan.py::test_orphan"* ]]; then r=0; else r=1; fi
  check "a test outside every lane -> make test-lanes-cover RED and names it" "$r" "rc=$rc $(tail -n 3 <<<"$out" | tr '\n' '|')"
  out="$(cd "$A" && make test-lanes-cover 2>&1)"; rc=$?
  if [[ $rc == 0 ]]; then r=0; else r=1; fi; check "after the orphan is removed, test-lanes-cover is green again" "$r" "rc=$rc"
fi

echo "$ok ok, $bad failed, $skipped skipped"
[[ $bad == 0 ]]
