#!/usr/bin/env bash
# provenance: candidate; ttl: 2027-04-01; pinning: true
# service-python-gates-selftest.sh -- the gates and CI of prod-new/modules/service-python as a
# unit of a generated repository. Assembles the module (single layout) into a scratch dir and:
#   always (no Python env needed): the targets exist and are reachable from the Makefile; the
#     workflow passes a static policy (pins, timeouts, permissions, triggers, injection) and
#     goes RED under one mutation per rule; gates/audit.py fails closed (fake `uv` on PATH);
#   when `uv` can build the LOCKED environment offline: `make check-fast` is green, and each
#     gate goes RED under its mutation (cross-zone import, type error, unformatted file, lock
#     drift).
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

A="$T/a"
python3 -I -B "$here/scripts/assemble.py" --dest "$A" --layout single --module service-python \
  --modules-dir "$mods" --slot SERVICE=ledger-svc --slot PACKAGE=ledger_svc --slot OWNER=acme \
  >"$T/assemble.log" 2>&1 || { echo "setup: assemble failed"; tail -n 5 "$T/assemble.log"; exit 2; }
WF="$A/ci/python-unit.yml"
[[ -f "$WF" ]] || { echo "setup: ci/python-unit.yml was not placed"; exit 2; }

# ---------------------------------------------------------------- targets exist, reachable
TARGETS="check-fast verify lint fmt typecheck test test-unit test-contract test-architecture lock-check audit"
for t in $TARGETS; do
  out="$(cd "$A" && make -n "$t" 2>&1)"; rc=$?
  if [[ $rc == 0 && -n "$out" && "$out" != *"No rule to make target"* ]]; then r=0; else r=1; fi; check "make -n $t resolves to a recipe from the assembled Makefile" "$r" "rc=$rc"
done
first="$(cd "$A" && make -n 2>&1 | head -n 1)"
if [[ "$first" == "uv sync --locked" ]]; then r=0; else r=1; fi; check "the default goal is check-fast" "$r" "first line: $first"
for t in $TARGETS; do
  out="$(cd "$A" && make -n "$t" 2>&1)"
  [[ "$t" == fmt || "$t" == audit || "$out" == *"$t: ok"* ]]; check "target $t prints its one summary line" $?
done

# ---------------------------------------------------------------- a python with PyYAML
PYY=()
if python3 -I -B -c 'import yaml' >/dev/null 2>&1; then
  PYY=(python3 -I -B)
elif command -v uv >/dev/null 2>&1 \
  && uv run --offline --no-project --with pyyaml python -c 'import yaml' >/dev/null 2>&1; then
  PYY=(uv run --offline --no-project --with pyyaml python -I -B)
fi
if [[ ${#PYY[@]} == 0 ]]; then
  fail "PyYAML is available" "install PyYAML for python3, or have uv with pyyaml in its cache"
  echo "$ok ok, $bad failed, $skipped skipped"; exit 1
fi

# ---------------------------------------------------------------- workflow policy checker
cat >"$T/cilint.py" <<'PYEOF'
import re
import sys

import yaml

pin = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
inject = re.compile(r"\$\{\{\s*(github\.event\.|github\.head_ref|inputs\.)")


def findings(path):
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
    perm = doc.get("permissions")
    ro = isinstance(perm, dict) and all(v in ("read", "none") for v in perm.values())
    if not (perm == "read-all" or ro):
        bad.append(f"PERMISSIONS: top-level permissions must be read-only, got {perm!r}")
    if not doc.get("concurrency"):
        bad.append("CONCURRENCY: missing")
    if "TODO-PIN" in text:
        bad.append("TODO-PIN: an action is still unpinned")
    jobs = doc.get("jobs") or {}
    for need in ("check-fast", "verify"):
        if need not in jobs:
            bad.append(f"JOBS: no job {need}")
    for name, job in jobs.items():
        if not isinstance(job.get("timeout-minutes"), int):
            bad.append(f"TIMEOUT: job {name} has no timeout-minutes")
        for step in job.get("steps") or []:
            use = step.get("uses")
            if use is not None and not pin.match(str(use)):
                bad.append(f"PIN: {use!r} is not pinned by a 40-hex commit SHA")
            if inject.search(str(step.get("run", ""))):
                bad.append(f"INJECTION: job {name} interpolates event data into run:")
    return bad


for path in sys.argv[1:]:
    found = findings(path)
    with open(path + ".out", "w", encoding="utf-8") as fh:
        fh.write("\n".join(found) if found else "cilint: clean")
    with open(path + ".rc", "w", encoding="utf-8") as fh:
        fh.write("1" if found else "0")
PYEOF
# One checker process for the real workflow and every mutant (cheap: one interpreter start).
mkdir -p "$T/m"; labels=(); needles=(); n=0
# mutate_wf <label> <old> <new> <needle>: a scratch copy with ONE change must be RED naming <needle>
mutate_wf() {
  local label="$1" old="$2" new="$3" needle="$4"
  n=$((n + 1))
  if python3 -I -B - "$WF" "$T/m/$n.yml" "$old" "$new" <<'PYEOF'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if old not in text:
    sys.exit(1)
open(dst, "w", encoding="utf-8").write(text.replace(old, new, 1))
PYEOF
  then labels[n]="$label"; needles[n]="$needle"
  else labels[n]="$label"; needles[n]="@@not-applied"; fi
}
mutate_wf "unpinned action (tag instead of SHA) -> RED" \
  "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2" "actions/checkout@v4" "PIN:"
mutate_wf "TODO-PIN left in -> RED" "# v4.2.4" "# TODO-PIN" "TODO-PIN:"
mutate_wf "missing timeout-minutes -> RED" "    timeout-minutes: 10
" "" "TIMEOUT:"
mutate_wf "permissions: write-all -> RED" "permissions:
  contents: read" "permissions: write-all" "PERMISSIONS:"
mutate_wf "contents: write -> RED" "  contents: read" "  contents: write" "PERMISSIONS:"
mutate_wf "pull_request_target -> RED" "  pull_request:" "  pull_request_target:" "PRT:"
mutate_wf "event data interpolated into run: -> RED" "      - run: make check-fast" \
  '      - run: echo "${{ github.event.pull_request.title }}"' "INJECTION:"
mutate_wf "no concurrency -> RED" "concurrency:" "x-concurrency:" "CONCURRENCY:"
mutate_wf "path filter removed -> RED" '    paths:
      - "src/**"' "    x-paths:
      - \"src/**\"" "PATHS:"


"${PYY[@]}" "$T/cilint.py" "$WF" "$T"/m/*.yml
out="$(cat "$WF.out")"
if [[ "$(cat "$WF.rc")" == 0 ]]; then r=0; else r=1; fi; check "the real workflow passes the static policy" "$r" "$out"
for i in $(seq 1 "$n"); do
  o="$(cat "$T/m/$i.yml.out" 2>/dev/null)"; rc="$(cat "$T/m/$i.yml.rc" 2>/dev/null)"
  if [[ "${needles[$i]}" == "@@not-applied" ]]; then
    fail "${labels[$i]}" "mutation did not apply (old text missing)"
  else
    if [[ "$rc" == 1 && "$o" == *"${needles[$i]}"* ]]; then r=0; else r=1; fi; check "${labels[$i]}" "$r" "rc=$rc out=$o"
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
exit "${FAKE_UV_RC:-0}"
SHEOF
  chmod +x "$fb/uv"
  W="$A/gates/audit-waivers.txt"; cp "$W" "$T/waivers.orig"
  run_audit() { # <fake rc>: runs the REAL gates/audit.py against the fake uv
    : >"$T/uv.log"
    PATH="$fb:$PATH" FAKE_UV_LOG="$T/uv.log" FAKE_UV_RC="$1" python3 -I -B "$A/gates/audit.py" 2>&1
  }
  out="$(run_audit 0)"; rc=$?
  [[ $rc == 0 && "$out" == *"audit: ok (0 waiver"* ]] && grep -q -- "audit --locked" "$T/uv.log"
  r=$?; check "audit: clean advisory service passes and runs uv audit on the lock" "$r" "rc=$rc $out"
  out="$(run_audit 2)"; rc=$?
  if [[ $rc == 1 && "$out" == *"audit: FAIL"* ]]; then r=0; else r=1; fi; check "audit: an unreachable or failing service FAILS CLOSED (uv rc 2 -> RED)" "$r" "rc=$rc $out"
  printf 'GHSA-0000-0000-0000 2000-01-01 owner reason text\n' >>"$W"
  out="$(run_audit 0)"; rc=$?
  if [[ $rc == 1 && "$out" == *"expired"* && ! -s "$T/uv.log" ]]; then r=0; else r=1; fi; check "audit: an EXPIRED waiver is RED (and uv is not even called)" "$r" "rc=$rc $out"
  cp "$T/waivers.orig" "$W"; printf 'GHSA-0000-0000-0000 9999-99-99 owner reason\n' >>"$W"
  out="$(run_audit 0)"; rc=$?
  if [[ $rc == 1 && "$out" == *"bad expiry"* ]]; then r=0; else r=1; fi; check "audit: a malformed date is RED" "$r" "rc=$rc $out"
  cp "$T/waivers.orig" "$W"; printf 'GHSA-0000-0000-0000 2999-01-01\n' >>"$W"
  out="$(run_audit 0)"; rc=$?
  if [[ $rc == 1 && "$out" == *"malformed"* ]]; then r=0; else r=1; fi; check "audit: a waiver without owner and reason is RED" "$r" "rc=$rc $out"
  cp "$T/waivers.orig" "$W"; printf 'GHSA-1111-1111-1111 2999-01-01 owner a live waiver\n' >>"$W"
  out="$(run_audit 0)"; rc=$?
  [[ $rc == 0 ]] && grep -q -- "--ignore GHSA-1111-1111-1111" "$T/uv.log"
  r=$?; check "audit: a live waiver is passed to uv as --ignore" "$r" "rc=$rc $out"
  cp "$T/waivers.orig" "$W"
else
  skip "audit.py cases" "python3 older than 3.11 (the unit's floor)"
fi

# ---------------------------------------------------------------- the locked environment
if ! command -v uv >/dev/null 2>&1; then
  skip "assembled make check-fast and the gate mutations" "uv is not installed"
elif ! (cd "$A" && uv sync --locked --offline) >"$T/sync.log" 2>&1; then
  skip "assembled make check-fast and the gate mutations" \
    "the locked environment cannot be created offline from the uv cache: $(tail -n 1 "$T/sync.log")"
else
  out="$(cd "$A" && make check-fast 2>&1)"; rc=$?
  if [[ $rc == 0 && "$out" == *"check-fast: ok"* ]]; then r=0; else r=1; fi; check "assembled make check-fast is green" "$r" "rc=$rc $(tail -n 3 <<<"$out" | tr '\n' '|')"

  # mutate_env <label> <file> <how: append|replace> <old-or-text> <new> <target> <needle>
  mutate_env() {
    local label="$1" file="$A/$2" how="$3" old="$4" new="$5" target="$6" needle="$7" o rc
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
    o="$(cd "$A" && make "$target" 2>&1)"; rc=$?
    cp "$T/restore.bak" "$file"
    if [[ $rc != 0 && "$o" == *"$needle"* ]]; then r=0; else r=1; fi; check "$label" "$r" "rc=$rc needle=[$needle] tail=$(tail -n 2 <<<"$o" | tr '\n' '|')"
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
  skip "make coverage RED under a raised threshold" "no coverage gate: coverage.py is not in the locked set (NOT DONE)"
fi

echo "$ok ok, $bad failed, $skipped skipped"
[[ $bad == 0 ]]
