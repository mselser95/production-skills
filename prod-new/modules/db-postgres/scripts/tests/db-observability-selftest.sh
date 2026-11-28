#!/usr/bin/env bash
# db-observability-selftest.sh - hermetic selftest of the database's monitoring bundle.
# NO Docker, no network: scripts/db-scrape-test.sh runs against a fake `docker` first on
# PATH that records every call and serves canned scrape text and a canned `docker inspect`.
# Covers:
#   1. parity-check.sh on the real tree, and one breaking case per rule. The cases run
#      IN ONE PROCESS (a python harness executes parity's own code against in-memory copies
#      of the tree: no fork per case); three runs go through the real shell wrapper;
#   2. the exporter overlay's static rules and the exporter ALLOWLIST (flags, variable
#      names, entrypoint, mounts), one breaking case each;
#   3. `promtool test rules` on the alert tests IF promtool is on PATH (else SKIP);
#   4. db-scrape-test.sh: clean, pg_up 0, a missing metric, a failing collector, a
#      published port, an elevated role, a write that works, a downgraded exporter
#      (flags, variables, mounts, entrypoint), teardown of exactly its own project,
#      --mutate revoke-monitor (RED, and a survivor), a hung docker. Scenarios that differ in
#      one fake response share ONE run (runs are cached by script + environment + arguments);
#   5. the `db-test` recipe in the repo Makefile runs the checks in the pinned order;
#   6. mutations of the checks themselves, on scratch copies. EVERY mutant is PAIRED: before
#      it is judged, the same scenario runs against an UNMUTATED copy placed the same way and
#      must be green (else `FAIL mutant NAME: its control is not green`, the suite is red),
#      its patch must change the file, and it must go RED. A meta-case proves a vacuous
#      setup is reported as such.
# Final line: `N ok, M failed[, K skipped]`. Exit 1 if any failed.
# Needs python3 + PyYAML (the same dependency as parity-check.sh); without it the run
# FAILS, it does not skip.
set -uo pipefail
src="${BASH_SOURCE[0]}"; [[ $src == */* ]] || src="./$src"
here="$(cd "${src%/*}" && pwd)"
scripts="$(cd "$here/.." && pwd)"
dbdir="$(cd "$here/../../db" && pwd)"
obs="$dbdir/observability"
scrape="$scripts/db-scrape-test.sh"
parity="$obs/parity-check.sh"
makefile="$scripts/../../../../Makefile"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dbobs-selftest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
ok=0; bad=0; skipped=0
export TMPDIR="$tmp"   # the scrape test's scratch dir lands here, never in the real /tmp
mkdir -p "$tmp/mut" "$tmp/runs" "$tmp/bin" "$tmp/empty"

if ! python3 -B -c 'import yaml' 2>/dev/null; then
  echo "FAIL prerequisite: python3 with PyYAML is required (pip install PyYAML)"
  echo "0 ok, 1 failed"; exit 1
fi

pass() { echo "ok   $1"; ok=$((ok + 1)); }
flunk() { echo "FAIL $1${2:+ ($2)}"; bad=$((bad + 1)); }
expect_ok() { # name fn args...: the case must pass
  local name="$1"; shift
  if "$@"; then pass "$name"; else flunk "$name"; fi
}
# tmo SECS cmd...: a hard wall-clock limit (no GNU timeout on a stock macOS)
tmo() {
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$s" "$@"
  else "$@"; fi
}
# replace_in FILE OLD NEW: literal, every occurrence; fails when OLD is absent or the patch
# would change nothing
replace_in() {
  local f="$1" body
  body="$(cat "$f"; printf x)"; body="${body%x}"
  [[ $body == *"$2"* ]] || { echo "selftest: anchor not found in $f: $2" >&2; return 1; }
  [[ $2 != "$3" ]] || { echo "selftest: the patch is a no-op in $f: $2" >&2; return 1; }
  printf '%s' "${body//"$2"/"$3"}" > "$f"
}
R="observability/alerts/postgres.rules.yml"
T="observability/alerts/postgres.rules.test.yml"
RM="observability/required-metrics.txt"
RB="observability/RUNBOOK.md"
OV="compose.observability.yml"
LK="observability/image.lock"
EV="observability/exporter/exporter.env"
AL="observability/exporter-allowlist.txt"
DIG="sha256:a88794758ad461c75f3825b51cde4bde730bdff04b3b24d00efe14217e41f615"

# ---- 1+2. parity-check.sh, in one process ----------------------------------------------------
# A case = (script, expected outcome, one edit of the scratch tree). Cases are REGISTERED here
# and executed together by the harness below, which exec()s the python body of each script
# against an in-memory copy of the tree (a virtual `open`), so a case costs milliseconds.
# Records: P* arrays, same index. Kinds: case (judged alone), scen (only a scenario for a
# mutant), mut (judged with its control), ctl (the unmutated copy, judged through its mutants).
PN=(); PS=(); PW=(); PF=(); PO=(); PX=(); PT=(); PK=(); PL=()
padd() { PN+=("$1"); PS+=("$2"); PW+=("$3"); PF+=("$4"); PO+=("$5"); PX+=("$6"); PT+=("$7"); PK+=("$8"); PL+=("$9"); }
pc() { padd "$1" "$parity" "$2" "$3" "$4" "$5" none case ""; }                 # NAME WANT FILE OLD NEW
pcf() { padd "$1" "$parity" "$2" "$3" "$4" "$5" fake case ""; }                # ... with a failing promtool stand-in
pfind() { local i; for i in "${!PN[@]}"; do [[ ${PN[i]} == "$1" && ${PK[i]} != mut ]] && { echo "$i"; return 0; }; done; return 1; }
pmn=0
# pmx NAME ANCHOR REPL [ANCHOR2 REPL2 ...] -- WANT FILE OLD NEW [PT]: a patched copy of parity-check.sh
# judged on the scenario after `--`, paired with the unmutated copy on the same scenario
pmx() {
  local name="$1" anchor="$2" repl="$3" f c pt; shift 3
  f="$tmp/mut/p$((pmn += 1)).sh"; cp "$parity" "$f"
  replace_in "$f" "$anchor" "$repl" || { flunk "mutant $name: anchor not found or no-op, so the mutant did not run" "$anchor"; return 0; }
  while (($#)) && [[ $1 != -- ]]; do replace_in "$f" "$1" "$2" || { flunk "mutant $name: second anchor not found" "$1"; return 0; }; shift 2; done
  shift
  pt="${5:-none}"
  cp "$parity" "$tmp/mut/p-ctl$pmn.sh"
  padd "ctl:$name" "$tmp/mut/p-ctl$pmn.sh" "$1" "$2" "$3" "$4" "$pt" ctl ""; c=$((${#PN[@]} - 1))
  padd "$name" "$f" "$1" "$2" "$3" "$4" "$pt" mut "$c"
}

# ---- the harness: run every registered parity case in ONE python process ---------------------
cat > "$tmp/h.py" <<'PYH'
import builtins, contextlib, io, os, shutil, subprocess, sys, tempfile
import yaml

casefile, obsdir, overlayfile, scratch = sys.argv[1:5]
dbroot = os.path.dirname(obsdir)
tree = {}
for root, _, names in os.walk(obsdir):
    for n in names:
        with open(os.path.join(root, n), encoding="utf-8") as f:
            tree["db/" + os.path.relpath(os.path.join(root, n), dbroot)] = f.read()
with open(overlayfile, encoding="utf-8") as f:
    tree["db/compose.observability.yml"] = f.read()

codes, cache = {}, {}
cur = [""]
real_load = yaml.load


def cached_load(text, Loader=None):
    # parsing is the cost; the key includes the script's loader source, so a mutant of the
    # loader gets its own parse
    key = (cur[0], text)
    if key not in cache:
        cache[key] = real_load(text, Loader=Loader)
    return cache[key]


yaml.load = cached_load


def code_of(path):
    if path not in codes:
        with open(path, encoding="utf-8") as f:
            src = f.read()
        body = src.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        a = body.find("class UniqueKeyLoader")
        codes[path] = (compile(body, path, "exec"), body[a:body.find("def load(")] if a >= 0 else "")
    return codes[path]


def fake_run(cmd, **kw):
    return subprocess.CompletedProcess(cmd, 1, "", "boom from the stand-in\n")


def run(script, want, f, old, new, pt):
    files = dict(tree)
    if f:
        k = "db/" + f
        if old not in files.get(k, ""):
            return "FAIL anchor not found in " + f + ": " + old[:60]
        files[k] = files[k].replace(old, new)
    code, lsrc = code_of(script)
    cur[0] = lsrc
    real_which, real_runner = shutil.which, subprocess.run
    tdir = None
    b = dict(vars(builtins))
    if pt == "real":
        tdir = tempfile.mkdtemp(dir=scratch)
        for k, v in files.items():
            p = os.path.join(tdir, k)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(v)
        base = tdir
    else:
        base = "/v"
        vf = {os.path.normpath(os.path.join(base, k)): v for k, v in files.items()}

        def vopen(path, mode="r", *a, **kw):
            p = os.path.normpath(str(path))
            if p in vf:
                return io.StringIO(vf[p])
            raise FileNotFoundError(2, "No such file or directory", str(path))

        b["open"] = vopen
        shutil.which = (lambda n, *a, **k: "/fake/promtool") if pt == "fake" else (lambda n, *a, **k: None)
        if pt == "fake":
            subprocess.run = fake_run
    g = {"__name__": "__main__", "__builtins__": b}
    sys.argv = ["parity-check", base + "/db/observability", base + "/db/compose.observability.yml", base + "/db/observability/image.lock"]
    buf = io.StringIO()
    rc = 0
    try:
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            try:
                exec(code, g)
            except SystemExit as e:
                rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
            except Exception as e:  # a crashing mutant is not a verdict about the case
                rc = 70
                buf.write("harness: " + repr(e))
    finally:
        shutil.which, subprocess.run = real_which, real_runner
        if tdir:
            shutil.rmtree(tdir, ignore_errors=True)
    out = buf.getvalue()
    if want == "OK":
        good = rc == 0 and "parity-check: OK" in out
    else:
        good = rc == 1 and all(w in out for w in want.split("\n"))
    return "PASS" if good else "FAIL rc=%s %s" % (rc, " ".join(out.split())[:200])


with open(casefile, "rb") as fh:
    fields = fh.read().decode("utf-8").split("\0")
for i in range(0, len(fields) - 1, 7):
    sc, want, f, old, new, pt, _ = fields[i:i + 7]
    print(run(sc, want, f, old, new, pt))
PYH
prun() { # runs every registered record, sets RES (same index as PN)
  local i
  for i in "${!PN[@]}"; do printf '%s\0%s\0%s\0%s\0%s\0%s\0\0' "${PS[i]}" "${PW[i]}" "${PF[i]}" "${PO[i]}" "${PX[i]}" "${PT[i]}"; done > "$tmp/pcases"
  RES=()
  while IFS= read -r i; do RES+=("$i"); done < <(python3 -B "$tmp/h.py" "$tmp/pcases" "$obs" "$dbdir/compose.observability.yml" "$tmp")
}
pjudge() {
  local i c
  ((${#RES[@]} == ${#PN[@]})) || { flunk "parity harness answered ${#RES[@]} of ${#PN[@]} cases" "${RES[*]:0:1}"; return 0; }
  for i in "${!PN[@]}"; do
    case "${PK[i]}" in
      case) if [[ ${RES[i]} == PASS ]]; then pass "${PN[i]}"; else flunk "${PN[i]}" "${RES[i]#FAIL }"; fi ;;
      mut)
        c="${PL[i]}"
        if [[ ${PN[i]} == meta:* ]]; then
          if [[ ${RES[c]} != PASS ]]; then pass "${PN[i]}: reported as: control is not green"; else flunk "${PN[i]}: a vacuous scenario was not detected"; fi
        elif [[ ${RES[c]} != PASS ]]; then flunk "mutant ${PN[i]}: its control is not green" "${RES[c]#FAIL }"
        elif [[ ${RES[i]} == PASS ]]; then flunk "mutation ${PN[i]}: GREEN (the cases did not notice)"
        else echo "RED  mutation ${PN[i]}"; ok=$((ok + 1)); fi ;;
    esac
  done
}

# ---- parity cases ------------------------------------------------------------------------------
pc "parity-check passes on the tree" OK "" "" ""
pc "unknown metric in an alert -> UNKNOWN-METRIC" 'UNKNOWN-METRIC: alert PostgresDown uses `pg_upp`' "$R" "expr: pg_up == 0" "expr: pg_upp == 0"
pc "orphan required metric -> ORPHAN-METRIC" 'ORPHAN-METRIC: required metric `pg_orphan_x`' "$RM" "pg_up  " $'pg_orphan_x # nothing uses it\npg_up  '
pc "dashboard-only orphan is allowed" OK "$RM" "pg_up  " $'pg_orphan_x # dashboard-only: panel\npg_up  '
pc "alert without a firing test -> NO-FIRING-TEST" "NO-FIRING-TEST: alert PostgresWalDirectoryLarge" "$T" $'eval_time: 20m\n        alertname: PostgresWalDirectoryLarge' $'eval_time: 20m\n        alertname: PostgresWalDirectoryLargeX'
pc "alert without a non-firing test -> NO-QUIET-TEST" "NO-QUIET-TEST: alert PostgresWalDirectoryLarge" "$T" "{eval_time: 5m, alertname: PostgresWalDirectoryLarge, exp_alerts: []}" "{eval_time: 5m, alertname: PostgresWalDirectoryLargeX, exp_alerts: []}"
pc "test for an undefined alert -> TEST-ORPHAN" "TEST-ORPHAN: the test file names alert PostgresWalDirectoryLargeX" "$T" "{eval_time: 5m, alertname: PostgresWalDirectoryLarge, exp_alerts: []}" "{eval_time: 5m, alertname: PostgresWalDirectoryLargeX, exp_alerts: []}"
pc "alert without severity -> ANNOTATION" "ANNOTATION: alert PostgresDown has no severity" "$R" $'        labels:\n          severity: critical\n        annotations:\n          summary: "PostgreSQL is not' $'        labels: {}\n        annotations:\n          summary: "PostgreSQL is not'
pc "alert with an unknown severity -> ANNOTATION" "ANNOTATION: alert PostgresDown has no severity" "$R" "severity: critical
        annotations:
          summary: \"PostgreSQL is not" "severity: page-me
        annotations:
          summary: \"PostgreSQL is not"
pc "alert without summary -> ANNOTATION" "ANNOTATION: alert PostgresDown has no summary" "$R" '          summary: "PostgreSQL is not reachable by its exporter"' '          x-summary: "PostgreSQL is not reachable by its exporter"'
pc "alert without description -> ANNOTATION" "ANNOTATION: alert PostgresDown has no description" "$R" '          description: "pg_up has been 0' '          x-description: "pg_up has been 0'
pc "alert without runbook -> ANNOTATION" "ANNOTATION: alert PostgresDown has no runbook" "$R" 'runbook: "db/observability/RUNBOOK.md#postgresdown"' 'x-runbook: "db/observability/RUNBOOK.md#postgresdown"'
pc "runbook anchor missing -> RUNBOOK-ANCHOR" "RUNBOOK-ANCHOR: alert PostgresDown" "$RB" "## PostgresDown" "## Something else"
pc "exporter image by tag -> OVERLAY-DIGEST" "OVERLAY-DIGEST: exporter image" "$OV" "@$DIG" ""
pc "exporter image :latest -> OVERLAY-DIGEST" "OVERLAY-DIGEST: exporter image" "$OV" "postgres-exporter:v0.21.1@" "postgres-exporter:latest@"
pc "overlay digest differs from image.lock -> OVERLAY-DIGEST" "differs from image.lock" "$LK" "exporter.digest = $DIG" "exporter.digest = sha256:${DIG:7:63}0"
pc "placeholder digest in the lock -> OVERLAY-DIGEST" "not a sha256 digest" "$LK" "exporter.digest = $DIG" "exporter.digest = sha256:UNRESOLVED-resolve-in-a-container"
pc "overlay read_only off -> OVERLAY-READONLY" "OVERLAY-READONLY" "$OV" "read_only: true" "read_only: false"
pc "overlay cap_drop not ALL -> OVERLAY-CAPDROP" "OVERLAY-CAPDROP" "$OV" "cap_drop: [ALL]" "cap_drop: [NET_RAW]"
pc "overlay no-new-privileges gone -> OVERLAY-NNP" "OVERLAY-NNP" "$OV" 'security_opt: ["no-new-privileges:true"]' 'security_opt: []'
pc "overlay runs as root -> OVERLAY-USER" "OVERLAY-USER" "$OV" 'user: "65534:65534"' 'user: "0:0"'
pc "overlay without a user -> OVERLAY-USER" "OVERLAY-USER" "$OV" '    user: "65534:65534"' '    x-note: none'
pc "overlay publishes a port -> OVERLAY-PORTS" "OVERLAY-PORTS" "$OV" $'    expose:\n      - "9187"' $'    expose:\n      - "9187"\n    ports:\n      - "9187:9187"'
pc "overlay without the secret -> OVERLAY-SECRET" "OVERLAY-SECRET: exporter must mount" "$OV" $'    secrets:\n      - db_monitor_password' '    secrets: []'
pc "password in the environment -> OVERLAY-SECRET" "OVERLAY-SECRET: DATA_SOURCE_PASS puts a password" "$EV" "DATA_SOURCE_USER=app_monitor" $'DATA_SOURCE_USER=app_monitor\nDATA_SOURCE_PASS=hunter2'
pc "password in the URI -> OVERLAY-SECRET" "OVERLAY-SECRET: DATA_SOURCE_URI carries a password" "$EV" "DATA_SOURCE_URI=db:5432" "DATA_SOURCE_URI=postgresql://app_monitor:hunter2@db:5432"
pc "overlay without a healthcheck -> OVERLAY-HEALTHCHECK" "OVERLAY-HEALTHCHECK" "$OV" "    healthcheck:" "    x-healthcheck:"
pc "stat_checkpointer collector off -> OVERLAY-COLLECTORS" "OVERLAY-COLLECTORS: exporter command lacks --collector.stat_checkpointer" "$OV" "      - --collector.stat_checkpointer
" ""
pc "exporter not waiting for a healthy db -> OVERLAY-DEPENDS" "OVERLAY-DEPENDS" "$OV" "condition: service_healthy" "condition: service_started"
pc "privileged exporter -> OVERLAY-PRIVILEGE" "OVERLAY-PRIVILEGE" "$OV" "    read_only: true" $'    read_only: true\n    privileged: true'

# PromQL the extractor cannot see is REFUSED, never passed
pc "metric as a __name__ matcher -> EXPR-NAME-MATCHER" "EXPR-NAME-MATCHER: alert PostgresDown: write the metric name, not a __name__ matcher" "$R" "expr: pg_up == 0" "expr: 'pg_up == 0 or {__name__=\"pg_bogus\"} > 0'"
pc "__name__ regex matcher -> EXPR-NAME-MATCHER" "EXPR-NAME-MATCHER" "$R" "expr: pg_up == 0" "expr: 'pg_up == 0 or {__name__=~\"pg_.*\"} > 0'"
pc "__name__ != matcher -> EXPR-NAME-MATCHER" "EXPR-NAME-MATCHER" "$R" "expr: pg_up == 0" "expr: 'pg_up == 0 or pg_up{__name__!=\"x\"} > 0'"
pc "selector with no metric name -> EXPR-UNSUPPORTED" "a selector with no metric name before" "$R" "expr: pg_up == 0" "expr: 'pg_up == 0 or {job=\"x\"} > 0'"
pc "unknown function -> EXPR-UNSUPPORTED" "unknown function \`pg_fn(\`" "$R" "expr: pg_up == 0" "expr: pg_fn(pg_up) == 0"
pc "unsupported character (@) -> EXPR-UNSUPPORTED" "EXPR-UNSUPPORTED: alert PostgresDown: cannot read" "$R" "expr: pg_up == 0" "expr: 'pg_up @ 100 == 0'"
pc "duration outside a range -> EXPR-UNSUPPORTED" "outside a range" "$R" "expr: pg_up == 0" "expr: pg_up == 5m"
pc "unbalanced brackets -> EXPR-UNSUPPORTED" "EXPR-UNSUPPORTED" "$R" "expr: pg_up == 0" "expr: (pg_up == 0"
pc "Inf, inf and NaN are numbers, not metrics" OK "$R" "expr: pg_up == 0" "expr: 'pg_up == 0 and pg_up < Inf and pg_up != NaN and pg_up > -inf and pg_up < 1e9'"
pc "a comment naming a bogus metric is stripped" OK "$R" "expr: pg_up == 0" "expr: |
          pg_up == 0 # pg_bogus is not a metric here"
pc "absent(x) uses x -> UNKNOWN-METRIC" 'UNKNOWN-METRIC: alert PostgresExporterAbsent uses `pg_nope`' "$R" "expr: absent(pg_up)" "expr: absent(pg_nope)"
pc "recording rule -> RECORDING-RULE" "recording rules are not checked yet" "$R" $'groups:\n' $'groups:\n  - name: rec\n    rules:\n      - record: job:pg_up:sum\n        expr: sum(pg_up)\n'
pcf "promtool check rules failing -> PROMTOOL-CHECK" "PROMTOOL-CHECK: promtool check rules failed: boom from the stand-in" "" "" ""
pc "sslmode=require -> OVERLAY-TLS" "OVERLAY-TLS" "$EV" "sslmode=verify-full" "sslmode=require"
pc "sslmode=disable -> OVERLAY-TLS" "OVERLAY-TLS" "$EV" "sslmode=verify-full" "sslmode=disable"
pc "sslmode given twice -> OVERLAY-TLS" "OVERLAY-TLS" "$EV" "sslmode=verify-full&" "sslmode=verify-full&sslmode=require&"
pc "sslmode=verify-fullx (a substring match would pass) -> OVERLAY-TLS" "OVERLAY-TLS" "$EV" "sslmode=verify-full&" "sslmode=verify-fullx&"
pc "sslrootcert missing -> OVERLAY-TLS" "exactly one non-empty sslrootcert" "$EV" "&sslrootcert=/tls/server.crt" ""
pc "exporter without cpus -> OVERLAY-LIMITS" "OVERLAY-LIMITS: exporter must set cpus" "$OV" $'    cpus: 0.5\n' ""
pc "exporter without mem_limit -> OVERLAY-LIMITS" "OVERLAY-LIMITS: exporter must set mem_limit" "$OV" $'    mem_limit: 128m\n' ""
pc "exporter without pids_limit -> OVERLAY-LIMITS" "OVERLAY-LIMITS: exporter must set pids_limit" "$OV" $'    pids_limit: 64\n' ""
pc "tls volume mounted read-write -> OVERLAY-TLS-MOUNT" "OVERLAY-TLS-MOUNT" "$OV" "dbtls:/tls:ro" "dbtls:/tls:rw"
pc "tls volume not mounted -> OVERLAY-TLS-MOUNT" "OVERLAY-TLS-MOUNT" "$OV" "      - dbtls:/tls:ro" "      - dbtls:/other:ro"

pcf "promtool check rules failing -> PROMTOOL-CHECK (stand-in)" "PROMTOOL-CHECK: promtool check rules failed: boom from the stand-in" "" "" ""
HAVE_PT=0; command -v promtool >/dev/null 2>&1 && HAVE_PT=1
if ((HAVE_PT)); then padd "a syntactically broken expression -> PROMTOOL-CHECK (real promtool)" "$parity" "PROMTOOL-CHECK" "$R" "expr: pg_up == 0" "expr: pg_up ==" real case ""
else echo "SKIP real promtool parity case: no promtool on PATH"; skipped=$((skipped + 1)); fi

# B1: the exporter's connection can only be changed through what the ALLOWLIST lists
LISTEN=$'      - --web.listen-address=:9187\n'
pc "flag --datasource.uri with sslmode=require -> OVERLAY-ARGS" 'OVERLAY-ARGS: exporter command carries `--datasource.uri` (value hidden)' "$OV" "$LISTEN" "$LISTEN      - --datasource.uri=db:5432/app?sslmode=require
"
pc "flag --datasource.uri with sslmode=disable -> OVERLAY-ARGS" 'OVERLAY-ARGS: exporter command carries `--datasource.uri` (value hidden)' "$OV" "$LISTEN" "$LISTEN      - --datasource.uri=db:5432/app?sslmode=disable
"
pc "flag --datasource.uri-file -> OVERLAY-ARGS" 'carries `--datasource.uri-file`' "$OV" "$LISTEN" "$LISTEN      - --datasource.uri-file=/x
"
pc "flag --config.file -> OVERLAY-ARGS" 'carries `--config.file`' "$OV" "$LISTEN" "$LISTEN      - --config.file=/x
"
pc "flag --web.config.file -> OVERLAY-ARGS" 'carries `--web.config.file`' "$OV" "$LISTEN" "$LISTEN      - --web.config.file=/x
"
pc "an unknown flag -> OVERLAY-ARGS" 'carries `--bogus.flag`' "$OV" "$LISTEN" "$LISTEN      - --bogus.flag
"
pc "an allowlisted flag with a changed value -> OVERLAY-ARGS" 'carries `--collector.stat_statements.limit` (value hidden)' "$OV" "--collector.stat_statements.limit=100" "--collector.stat_statements.limit=999"
pc "DATA_SOURCE_URI_FILE in exporter.env -> OVERLAY-ENV" 'OVERLAY-ENV: exporter defines the variable DATA_SOURCE_URI_FILE' "$EV" "DATA_SOURCE_USER=app_monitor" $'DATA_SOURCE_USER=app_monitor\nDATA_SOURCE_URI_FILE=/x'
pc "DATA_SOURCE_NAME in exporter.env -> OVERLAY-ENV" 'OVERLAY-ENV: exporter defines the variable DATA_SOURCE_NAME' "$EV" "DATA_SOURCE_USER=app_monitor" $'DATA_SOURCE_USER=app_monitor\nDATA_SOURCE_NAME=postgresql://u@db/app?sslmode=disable'
pc "PGSSLMODE in exporter.env -> OVERLAY-ENV" 'OVERLAY-ENV: exporter defines the variable PGSSLMODE' "$EV" "DATA_SOURCE_USER=app_monitor" $'DATA_SOURCE_USER=app_monitor\nPGSSLMODE=disable'
pc "a variable without a value in exporter.env -> OVERLAY-ENV" 'OVERLAY-ENV: exporter defines the variable PGHOST' "$EV" "DATA_SOURCE_USER=app_monitor" $'DATA_SOURCE_USER=app_monitor\nPGHOST'
pc "PGSSLMODE in the overlay environment -> OVERLAY-ENV" 'OVERLAY-ENV: exporter defines the variable PGSSLMODE' "$OV" $'    env_file:\n' $'    environment:\n      PGSSLMODE: disable\n    env_file:\n'
pc "overridden entrypoint -> OVERLAY-ENTRYPOINT" "OVERLAY-ENTRYPOINT" "$OV" '    user: "65534:65534"' $'    user: "65534:65534"\n    entrypoint: ["/bin/sh"]'
pc "an extra mount -> OVERLAY-MOUNTS" "OVERLAY-MOUNTS: exporter mounts ['/etc/x.yml']" "$OV" "      - dbtls:/tls:ro" $'      - dbtls:/tls:ro\n      - ./x.yml:/etc/x.yml:ro'
pc "an extra secret -> OVERLAY-MOUNTS" "OVERLAY-MOUNTS: exporter mounts ['/run/secrets/other']" "$OV" $'      - db_monitor_password\n' $'      - db_monitor_password\n      - other\n'
pc "a config -> OVERLAY-MOUNTS" "OVERLAY-MOUNTS: exporter must not use configs" "$OV" "    pids_limit: 64" $'    pids_limit: 64\n    configs:\n      - x'
pc "the allowlist allowing --datasource.uri -> ALLOWLIST" 'ALLOWLIST: exporter-allowlist.txt allows the flag `--datasource.uri=x`' "$AL" "arg --no-collector.xlog_location" $'arg --datasource.uri=x\narg --no-collector.xlog_location'
pc "the allowlist allowing PGSSLMODE -> ALLOWLIST" 'allows the variable `PGSSLMODE`' "$AL" "env DATA_SOURCE_USER " $'env PGSSLMODE\nenv DATA_SOURCE_USER '
pc "a malformed allowlist line -> ALLOWLIST" 'ALLOWLIST: exporter-allowlist.txt:' "$AL" "arg --no-collector.xlog_location" $'argument --x\narg --no-collector.xlog_location'

# B2: an OPERAND position never holds a keyword; subqueries; functions; query templates
KW='refused (it cannot be told from the operator)'
PQV=()   # expressions that are VALID PromQL (promtool must accept them, see below)
pe() { # NAME WANT EXPR: replace the PostgresDown expression
  [[ $2 == OK ]] && PQV+=("$3")
  pc "$1" "$2" "$R" "expr: pg_up == 0" "expr: '$3'"
}
PQV+=('pg_up == 0 or offset > 0' 'pg_up == 0 or and > 0' 'pg_up == 0 unless unless > 0' 'pg_up == 0 or by > 0')   # valid PromQL: series named like keywords
pe "keyword offset as an operand -> EXPR-UNSUPPORTED" '`offset` where an operand is expected: a metric named like a PromQL keyword is '"$KW" 'pg_up == 0 or offset > 0'
pe "keyword and as an operand -> EXPR-UNSUPPORTED" '`and` where an operand is expected' 'pg_up == 0 or and > 0'
pe "keyword unless as an operand -> EXPR-UNSUPPORTED" '`unless` where an operand is expected' 'pg_up == 0 unless unless > 0'
pe "keyword by as an operand -> EXPR-UNSUPPORTED" '`by` where an operand is expected' 'pg_up == 0 or by > 0'
pe "keyword at the start -> EXPR-UNSUPPORTED" '`on` where an operand is expected' 'on > 0'
pe "keyword after a comma -> EXPR-UNSUPPORTED" '`without` where an operand is expected' 'clamp_max(pg_up, without) == 0'
pe "keyword after on() without a label list -> EXPR-UNSUPPORTED" '`on` without a label list' 'pg_up == 0 and on > 0'
pe "a keyword where an operator belongs -> EXPR-UNSUPPORTED" 'keyword `by` in a position PromQL does not allow' 'pg_up by pg_up'
pe "offset after a selector is fine" OK 'pg_up offset 5m == 0'
pe "offset after a range, with a sign, is fine" OK 'max_over_time(pg_up[5m] offset -1h) == 0'
pe "a and b is fine" OK 'pg_up == 0 and pg_up < 5'
pe "a unless b is fine" OK 'pg_up == 0 unless pg_up > 5'
pe "a or b is fine" OK 'pg_up == 0 or pg_up < 1'
pe "set operators with on/ignoring are fine" OK 'pg_up == 0 and on(instance) pg_up < 1 unless ignoring(job) pg_up > 5 or on(a) pg_up > 2'
pe "arithmetic with on/ignoring/group_left/group_right is fine" OK 'pg_up / on(a) group_left (b) pg_up > 2 and pg_up * ignoring(c) group_right pg_up > 1'
pe "bool modifier is fine" OK 'pg_up > bool 0 == 0'
pe "aggregation by/without, prefix and postfix, are fine" OK 'sum by (a) (pg_up) > 0 and sum(pg_up) without (b) > 0'
pe "a subquery [5m:1m] is read" OK 'max_over_time(pg_up[5m:1m]) == 0'
pe "a subquery [5m:] is read" OK 'max_over_time(pg_up[5m:]) == 0'
pe "a subquery over a call is read, and its metric checked" 'UNKNOWN-METRIC: alert PostgresDown uses `pg_sub_x`' 'max_over_time(rate(pg_sub_x[5m])[30m:1m]) == 0'
pe "a subquery with an offset is read" OK 'max_over_time(pg_up[5m:1m] offset 1h) == 0'
pe "a colon outside a range -> EXPR-UNSUPPORTED" '`:` outside a range' 'pg_up == 0 :]'
# the functions the extractor must understand: each takes its metric where the tokenizer looks
FN=('quantile_over_time(0.5, @@[5m])' 'stddev_over_time(@@[5m])' 'stdvar_over_time(@@[5m])' 'hour(@@)' 'day_of_week(@@)' 'day_of_month(@@)'
    'minute(@@)' 'month(@@)' 'year(@@)' 'timestamp(@@)' 'changes(@@[5m])' 'resets(@@[5m])' 'delta(@@[5m])' 'deriv(@@[5m])'
    'predict_linear(@@[5m], 3600)' 'avg_over_time(@@[5m])' 'max_over_time(@@[5m])' 'min_over_time(@@[5m])' 'sum_over_time(@@[5m])'
    'count_over_time(@@[5m])' 'last_over_time(@@[5m])' 'present_over_time(@@[5m])' 'label_join(@@, "a", ",", "b")' 'sort(@@)'
    'sort_desc(@@)' 'round(@@, 5)' 'ceil(@@)' 'floor(@@)' 'abs(@@)' 'sgn(@@)' 'ln(@@)' 'log2(@@)' 'log10(@@)' 'exp(@@)' 'sqrt(@@)')
ex_known=""; ex_unknown=""; unk_want=""; fi_=0
for f in "${FN[@]}"; do
  fi_=$((fi_ + 1))
  ex_known="${ex_known:+$ex_known or }(${f//@@/pg_up})"; ex_unknown="${ex_unknown:+$ex_unknown or }(${f//@@/pg_fn$fi_})"
  unk_want="${unk_want:+$unk_want$'\n'}UNKNOWN-METRIC: alert PostgresDown uses \`pg_fn$fi_\`"
done
pe "every newly allowed function with a known metric is OK" OK "$ex_known"
pe "every newly allowed function reports an unknown metric (all ${#FN[@]} named)" "$unk_want" "$ex_unknown"
# an annotation template that runs a query is an expression nothing here can check
pc "a query template in an annotation -> ANNOTATION" 'ANNOTATION: alert PostgresDown: annotation summary uses a `query` template' "$R" '          summary: "PostgreSQL is not reachable by its exporter"' $'          summary: \'{{ query "pg_nope" }}\''
pc "a query template in a label -> ANNOTATION" 'label owner uses a `query` template' "$R" $'          severity: critical\n        annotations:\n          summary: "PostgreSQL is not' $'          severity: critical\n          owner: \'{{ with query "x" }}{{ end }}\'\n        annotations:\n          summary: "PostgreSQL is not'
pc "a label named query in a template is not a query call" OK "$R" '          description: "pg_up has been 0' $'          description: "{{ $labels.query }} pg_up has been 0'

# ---- parity mutants: every one paired with the unmutated copy on the same scenario -----------------
PMX_FIRE=("NO-FIRING-TEST: alert PostgresWalDirectoryLarge" "$T" $'eval_time: 20m\n        alertname: PostgresWalDirectoryLarge' $'eval_time: 20m\n        alertname: PostgresWalDirectoryLargeX')
PMX_QUIET=("NO-QUIET-TEST: alert PostgresWalDirectoryLarge" "$T" "{eval_time: 5m, alertname: PostgresWalDirectoryLarge, exp_alerts: []}" "{eval_time: 5m, alertname: PostgresWalDirectoryLargeX, exp_alerts: []}")
PMX_ORPHAN=("ORPHAN-METRIC" "$RM" "pg_up  " $'pg_orphan_x # nothing uses it\npg_up  ')
PMX_NAME=("EXPR-NAME-MATCHER" "$R" "expr: pg_up == 0" "expr: 'pg_up == 0 or {__name__=\"pg_bogus\"} > 0'")
PMX_INF=(OK "$R" "expr: pg_up == 0" "expr: 'pg_up == 0 and pg_up < Inf and pg_up != NaN and pg_up > -inf and pg_up < 1e9'")
PMX_SSL=("OVERLAY-TLS" "$EV" "sslmode=verify-full&" "sslmode=verify-fullx&")
pmx "parity rule 'alert has a firing test' removed" '    if name not in fires:' '    if False:' -- "${PMX_FIRE[@]}"
pmx "parity rule 'alert has a non-firing test' removed" '    if name not in quiet:' '    if False:' -- "${PMX_QUIET[@]}"
pmx "parity digest check removed" 'if not re.fullmatch(r"[^@\s]+:[^@\s:/]+@sha256:[0-9a-f]{64}", image) or ":latest@" in image:' 'if False:' 'if image != want:' 'if False:' -- "OVERLAY-DIGEST: exporter image" "$OV" "@$DIG" ""
pmx "parity rule 'metric is in the contract' removed" '    for m in sorted(ms - set(required)):' '    for m in []:' -- "UNKNOWN-METRIC" "$R" "expr: pg_up == 0" "expr: pg_upp == 0"
pmx "parity rule 'no orphan metric' removed" '    if m not in used and not dash:' '    if False:' -- "${PMX_ORPHAN[@]}"
pmx "port published by default: overlay ports check removed" 'if svc.get("ports"):' 'if False:' -- "OVERLAY-PORTS" "$OV" $'    expose:\n      - "9187"' $'    expose:\n      - "9187"\n    ports:\n      - "9187:9187"'
pmx "parity runbook anchor check removed" 'if not path.endswith("RUNBOOK.md") or not anchor or anchor not in anchors:' 'if False:' -- "RUNBOOK-ANCHOR" "$RB" "## PostgresDown" "## Something else"
pmx "parity: __name__ refusal removed" '    if "__name__" in expr:' '    if False:' -- "${PMX_NAME[@]}"
pmx "parity: Inf/NaN read as metrics (false positive on the clean expression)" 'if low in ("inf", "nan"):' 'if False:' -- "${PMX_INF[@]}"
pmx "parity: nameless selector accepted" 'if not prev_metric:' 'if False:' -- "a selector with no metric name before" "$R" "expr: pg_up == 0" "expr: 'pg_up == 0 or {job=\"x\"} > 0'"
pmx "parity: unknown function accepted" 'bad = f"unknown function `{text}(`"' 'bad = None' -- "unknown function" "$R" "expr: pg_up == 0" "expr: pg_fn(pg_up) == 0"
pmx "parity: promtool check rules removed" 'if promtool:' 'if False:' -- "PROMTOOL-CHECK" "" "" "" fake
pmx "parity: recording rules no longer refused" 'if isinstance(r, dict) and "record" in r:' 'if False:' -- "recording rules are not checked yet" "$R" $'groups:\n' $'groups:\n  - name: rec\n    rules:\n      - record: job:pg_up:sum\n        expr: sum(pg_up)\n'
pmx "parity: sslmode matched as a substring (verify-fullx passes)" 'if qs.get("sslmode") != ["verify-full"]:' 'if "sslmode=verify-full" not in uri:' -- "${PMX_SSL[@]}"
pmx "parity: sslmode matched as a substring (duplicate passes)" 'if qs.get("sslmode") != ["verify-full"]:' 'if "sslmode=verify-full" not in uri:' -- "OVERLAY-TLS" "$EV" "sslmode=verify-full&" "sslmode=verify-full&sslmode=require&"
pmx "parity: resource limits rule removed" '    if not svc.get(k):' '    if False:' -- "OVERLAY-LIMITS" "$OV" $'    cpus: 0.5\n' ""
pmx "parity: read-only tls mount rule removed" 'if not tls_ro:' 'if False:' -- "OVERLAY-TLS-MOUNT" "$OV" "dbtls:/tls:ro" "dbtls:/tls:rw"
# the allowlist (B1)
pmx "parity: command allowlist check removed (a --datasource.uri flag passes)" '    if c not in allow["arg"]:' '    if False:' -- 'OVERLAY-ARGS: exporter command carries `--datasource.uri`' "$OV" "$LISTEN" "$LISTEN      - --datasource.uri=db:5432/app?sslmode=require
"
pmx "parity: variable allowlist check removed (DATA_SOURCE_URI_FILE passes)" 'for k in sorted(env_names - allow["env"]):' 'for k in []:' -- 'OVERLAY-ENV: exporter defines the variable PGSSLMODE' "$EV" "DATA_SOURCE_USER=app_monitor" $'DATA_SOURCE_USER=app_monitor\nPGSSLMODE=disable'
pmx "parity: variables of a bare env_file line not counted" 'env_names.add(k.strip())' 'pass' -- 'OVERLAY-ENV: exporter defines the variable PGHOST' "$EV" "DATA_SOURCE_USER=app_monitor" $'DATA_SOURCE_USER=app_monitor\nPGHOST'
pmx "parity: mounts check removed (a config file mount passes)" 'if dests != allow["mount"]:' 'if False:' -- "OVERLAY-MOUNTS: exporter mounts ['/etc/x.yml']" "$OV" "      - dbtls:/tls:ro" $'      - dbtls:/tls:ro\n      - ./x.yml:/etc/x.yml:ro'
pmx "parity: secrets not counted as mounts" '        dests.add("/run/secrets/" + str(sc))' '        pass' -- "OVERLAY-MOUNTS: exporter mounts ['/run/secrets/other']" "$OV" $'      - db_monitor_password\n' $'      - db_monitor_password\n      - other\n'
pmx "parity: entrypoint override no longer refused" 'if "entrypoint" in svc:' 'if False:' -- "OVERLAY-ENTRYPOINT" "$OV" '    user: "65534:65534"' $'    user: "65534:65534"\n    entrypoint: ["/bin/sh"]'
pmx "parity: the allowlist may name --datasource flags" 'if a.startswith(("--datasource",' 'if a.startswith(("--zzz",' -- 'ALLOWLIST: exporter-allowlist.txt allows the flag `--datasource.uri=x`' "$AL" "arg --no-collector.xlog_location" $'arg --datasource.uri=x\narg --no-collector.xlog_location'
# the tokenizer (B2)
pmx "parity: offset accepted as an operand" 'elif text == "offset" and not expect_operand and (prev_metric or prev[0] == "close"):' 'elif text == "offset":' -- '`offset` where an operand is expected' "$R" "expr: pg_up == 0" "expr: 'pg_up == 0 or offset > 0'"
pmx "parity: and/unless/or accepted as operands" 'elif text in SETOPS and not expect_operand:' 'elif text in SETOPS:' -- '`and` where an operand is expected' "$R" "expr: pg_up == 0" "expr: 'pg_up == 0 or and > 0'"
pmx "parity: operand/operator tracking removed (a keyword is never refused)" 'elif expect_operand:' 'elif False:' -- '`by` where an operand is expected' "$R" "expr: pg_up == 0" "expr: 'pg_up == 0 or by > 0'"
pmx "parity: subqueries refused again" '  | (?P<sub>:\s*(?:""" + DURATION + r""")?\s*(?=\]))
' '' -- OK "$R" "expr: pg_up == 0" "expr: 'max_over_time(pg_up[5m:1m]) == 0'"
pmx "parity: a function dropped from the allowlist (quantile_over_time)" '"quantile_over_time", ' '' -- OK "$R" "expr: pg_up == 0" "expr: 'quantile_over_time(0.5, pg_up[5m]) == 0'"
pmx "parity: query templates no longer refused" '(?<![.\w$])query\b' '(?<![.\w$])queryX\b' -- 'annotation summary uses a `query` template' "$R" '          summary: "PostgreSQL is not reachable by its exporter"' $'          summary: \'{{ query "pg_nope" }}\''
# a meta-case: a scenario that fails on the UNMUTATED copy is reported as such, never judged RED
pmx "meta: vacuous scenario" 'if findings:' 'if False:' -- "THIS TEXT IS NEVER PRINTED" "" "" ""

prun
pjudge

# ---- the real shell wrapper: three runs (argument parsing, default paths, exit codes) --------------
out="$(bash "$parity" 2>&1)"; rc=$?
if [[ $rc == 0 && $out == *"13 alerts"* ]]; then pass "parity-check default paths: 13 alerts read"; else flunk "parity-check default paths" "rc=$rc"; fi
mkdir -p "$tmp/w/db"; cp -R "$obs" "$tmp/w/db/observability"; cp "$dbdir/compose.observability.yml" "$tmp/w/db/"
replace_in "$tmp/w/db/$OV" "@$DIG" "" && { out="$(bash "$parity" --dir "$tmp/w/db/observability" 2>&1)"; rc=$?; }
if [[ $rc == 1 && $out == *"OVERLAY-DIGEST: exporter image"* && $out == *"parity-check: RED"* ]]; then pass "parity-check --dir on a scratch copy: exit 1 with the finding"; else flunk "parity-check --dir wrapper" "rc=$rc"; fi
# a missing PyYAML must be exit 2, not a green: python3 shim that cannot import yaml
mkdir -p "$tmp/noyaml"; printf '#!/bin/sh\nexit 1\n' > "$tmp/noyaml/python3"; chmod +x "$tmp/noyaml/python3"
out="$(PATH="$tmp/noyaml:$PATH" bash "$parity" 2>&1)"; rc=$?
if [[ $rc == 2 && $out == *"PyYAML is not importable"* ]]; then pass "no PyYAML -> exit 2, never green"; else flunk "no PyYAML -> exit 2" "rc=$rc"; fi

# ---- 3. promtool ----------------------------------------------------------------------------------
# red_pair NAME FN CTL MUT: FN must pass on CTL (the unmutated copy) and fail on MUT
red_pair() {
  if ! "$2" "$3" >/dev/null 2>&1; then flunk "mutant $1: its control is not green"
  elif "$2" "$4" >/dev/null 2>&1; then flunk "mutation $1: GREEN (the cases did not notice)"
  else echo "RED  mutation $1"; ok=$((ok + 1)); fi
}
if ((HAVE_PT)); then
  pt() { (cd "$1" && promtool test rules postgres.rules.test.yml >"$tmp/pt.out" 2>&1); }
  expect_ok "promtool test rules passes on the alert tests" pt "$obs/alerts"
  # the tests must be able to go red: raise one threshold on a scratch copy (paired with an untouched copy)
  mkdir -p "$tmp/pt" "$tmp/ptc"; cp "$obs/alerts/"*.yml "$tmp/pt/"; cp "$obs/alerts/"*.yml "$tmp/ptc/"
  replace_in "$tmp/pt/postgres.rules.yml" "pg_wal_size_bytes > 4e9" "pg_wal_size_bytes > 4e19" && red_pair "alert threshold changed: promtool test goes red" pt "$tmp/ptc" "$tmp/pt"
  # the real promtool agrees that the expressions the parity cases call valid ARE valid PromQL
  # (including the ones with a series named like a keyword, which parity must refuse anyway)
  pq="$tmp/valid.rules.yml"; printf 'groups:\n  - name: g\n    rules:\n' > "$pq"; qn=0
  for e in "${PQV[@]}" "$ex_unknown"; do qn=$((qn + 1)); printf "      - alert: A%s\n        expr: '%s'\n" "$qn" "$e" >> "$pq"; done
  pqt() { promtool check rules "$1" >"$tmp/pq.out" 2>&1; }
  expect_ok "promtool accepts all ${#PQV[@]} expressions the parity cases call valid" pqt "$pq"
else
  echo "SKIP promtool test rules: no promtool on PATH (the parity check still proves every alert has a firing and a non-firing case by reading the test file; db-scrape-test.sh --promtool runs it in the pinned Prometheus image)"
  skipped=$((skipped + 1))
fi

# ---- 4. db-scrape-test.sh against a fake docker --------------------------------------------------------
# The fake answers from prepared files (no helper process per call): FAKE_METRICS for the scrape,
# FAKE_INSPECT for `docker inspect`.
cat > "$tmp/bin/docker" <<'FAKE'
#!/bin/sh
# POSIX sh on purpose: one exec per call, no `env`, no bash start-up (this is called ~15 times per run)
printf '%s\n' "$*" >> "$FAKE_LOG"
[ "${FAKE_HANG:-0}" = 1 ] && exec sleep "${FAKE_HANG_S:-60}"
args="$*"; for lastarg; do :; done
show() { while IFS= read -r l; do printf '%s\n' "$l"; done < "$1"; }
case "$1" in
  compose)
    case "$args" in
      *" down -v "*) exit 0 ;;
      *" up -d --wait"*) exit "${FAKE_UP_RC:-0}" ;;
      *" ps -q exporter"*) echo "fakeexporter0001"; exit 0 ;;
      *" port exporter 9187"*)
        if [ -n "${FAKE_PORT_OUT+x}" ]; then [ -n "$FAKE_PORT_OUT" ] && printf '%s\n' "$FAKE_PORT_OUT"; exit "${FAKE_PORT_RC:-0}"; fi
        if [ "${FAKE_PUBLISHED:-0}" = 1 ]; then echo "0.0.0.0:9187"; exit 0; fi
        echo "no port 9187/tcp for container" >&2; exit 1 ;;
      *" exec -T db wget "*)
        if [ "${FAKE_WGET_FAIL:-0}" = 1 ]; then echo "wget: error" >&2; exit 1; fi
        if [ -e "$FAKE_LOG.revoked" ] && [ "${FAKE_REVOKE_NOOP:-0}" != 1 ]; then show "$FAKE_METRICS_REVOKED"; else show "$FAKE_METRICS"; fi
        exit 0 ;;
      *" exec -T db sh -c "*)
        case "$lastarg" in
          *"REVOKE pg_monitor"*) : > "$FAKE_LOG.revoked"; exit 0 ;;
          *pg_stat_ssl*) echo "${FAKE_SSL:-1/1}"; exit 0 ;;
          *rolsuper*) echo "${FAKE_ROLSUPER:-f}"; exit 0 ;;
          "CREATE TABLE public.monitor_write_probe"* | "INSERT INTO"*)
            [ "${FAKE_WRITE_OK:-0}" = 1 ] && exit 0
            echo "ERROR:  permission denied for schema public" >&2; exit 1 ;;
        esac ;;
    esac
    exit 0 ;;
  inspect)
    # the exporter's configuration in the format the scrape test asks for (cmd/entrypoint/env/mount
    # lines); the canary stands for a secret that must never be printed
    [ "${FAKE_INSPECT_RC:-0}" = 0 ] && show "$FAKE_INSPECT"
    exit "${FAKE_INSPECT_RC:-0}" ;;
  run) exit "${FAKE_RUN_RC:-0}" ;;
esac
exit 0
FAKE
chmod +x "$tmp/bin/docker"

# canned scrapes from the REAL contract: every required name once, so a rename in
# required-metrics.txt keeps this selftest consistent
names=()
while IFS= read -r l; do
  l="${l%%#*}"; l="${l//[[:space:]]/}"; [[ -n $l ]] && names+=("$l")
done < "$obs/required-metrics.txt"
nreq=${#names[@]}
mk_scrape() { # FILE PG_UP WAL_METRICS(1|0) WAL_COLLECTOR(1|0) [EXTRA_LINE]
  local n
  { echo "# canned scrape"; echo "pg_up $2"
    for n in "${names[@]}"; do
      [[ $n == pg_up ]] && continue
      [[ $3 == 0 && $n == pg_wal_size_bytes ]] && continue
      [[ $3 == 0 && $n == pg_wal_segments ]] && continue
      echo "$n{datname=\"app\"} 1"
    done
    echo "pg_scrape_collector_success{collector=\"wal\"} $4"
    [[ -z ${5:-} ]] || echo "$5"; } > "$1"
}
mk_scrape "$tmp/m.ok" 1 1 1
mk_scrape "$tmp/m.revoked" 1 0 0                                                       # what the revoke does on the pinned images
mk_scrape "$tmp/m.revoked.pgup0" 0 0 0
mk_scrape "$tmp/m.revoked.walstat" 1 0 0 'pg_scrape_collector_success{collector="stat_statements"} 0'
# ONE scrape that is bad in every way a scenario below looks for: the cases share this run
mk_scrape "$tmp/m.allbad" 0 0 1 'pg_scrape_collector_success{collector="stat_statements"} 0'
BAD_ENV=(FAKE_METRICS="$tmp/m.allbad" FAKE_PUBLISHED=1 FAKE_ROLSUPER=t FAKE_WRITE_OK=1 FAKE_SSL=0/1)

# the canned `docker inspect`, built from the REAL allowlist so the two cannot drift apart
al_arg=(); al_ep=(); al_mount=()
while IFS= read -r l; do
  l="${l%%#*}"; [[ -n ${l//[[:space:]]/} ]] || continue
  read -r k v <<<"$l"
  case "$k" in arg) al_arg+=("$v") ;; entrypoint) al_ep+=("$v") ;; mount) al_mount+=("$v") ;; esac
done < "$obs/exporter-allowlist.txt"
GOOD_URI='db:5432/app?sslmode=verify-full&sslrootcert=/tls/server.crt'
mk_insp() { # FILE [URI [ENTRYPOINT [OMITTED-MOUNT [EXTRA-LINES]]]]
  local f="$1" uri="${2:-$GOOD_URI}" ep="${3:-${al_ep[0]}}" omit="${4:-}" extra="${5:-}" a m
  {
    for a in "${al_arg[@]}"; do printf 'cmd "%s"\n' "$a"; done
    printf 'entrypoint "%s"\n' "$ep"
    printf 'env "PATH=/usr/bin"\nenv "DATA_SOURCE_URI=%s"\nenv "DATA_SOURCE_USER=hunter2zz"\nenv "DATA_SOURCE_PASS_FILE=/run/secrets/db_monitor_password"\n' "$uri"
    for m in "${al_mount[@]}"; do [[ $m == "$omit" ]] || printf 'mount "%s"\n' "$m"; done
    [[ -z $extra ]] || printf '%s\n' "$extra"
  } > "$f"
}
mk_insp "$tmp/i.ok"
insn=0; NK=(); NP=()
# a canned inspect per scenario; the path is returned in $INSP (the same arguments give the same
# file, so the run that uses it is found in the cache)
new_insp() {
  local key="$*" i
  for i in "${!NK[@]}"; do if [[ ${NK[i]} == "$key" ]]; then INSP="${NP[i]}"; return 0; fi; done
  insn=$((insn + 1)); INSP="$tmp/i.$insn"; mk_insp "$INSP" "$@"; NK+=("$key"); NP+=("$INSP")
}

# srun SCRIPT [VAR=val...] [-- args...] -> out, rc, LOGF. A run is CACHED by (script, environment,
# arguments): scenarios that only read different lines of the same run do not pay for it twice.
# The real script runs with its default db dir; every COPY gets --db-dir (it is not next to ../db).
RK=(); RO=(); RR=(); RL=()
srun() {
  local s="$1" envs=() key i n dbarg=(); shift
  while (($#)) && [[ $1 != -- ]]; do envs+=("$1"); shift; done
  (($#)) && shift
  key="$s|${envs[*]-}|$*"
  for i in "${!RK[@]}"; do
    if [[ ${RK[i]} == "$key" ]]; then out="${RO[i]}"; rc="${RR[i]}"; LOGF="${RL[i]}"; return 0; fi
  done
  n=${#RK[@]}; LOGF="$tmp/runs/$n.log"; : > "$LOGF"
  [[ $s == "$scrape" ]] || dbarg=(--db-dir "$dbdir")
  out="$(env PATH="$tmp/bin:$PATH" FAKE_LOG="$LOGF" FAKE_METRICS="$tmp/m.ok" FAKE_METRICS_REVOKED="$tmp/m.revoked" FAKE_INSPECT="$tmp/i.ok" \
    ${envs[@]+"${envs[@]}"} bash "$s" ${dbarg[@]+"${dbarg[@]}"} "$@" 2>&1)"; rc=$?
  RK[n]="$key"; RO[n]="$out"; RR[n]="$rc"; RL[n]="$LOGF"
}
projof() { [[ $out =~ \((dbscrape-[0-9]+) ]] && echo "${BASH_REMATCH[1]}"; }
sdb() { if [[ $1 == "$scrape" ]]; then SDB=(); else SDB=(--db-dir "$dbdir"); fi; }   # the db dir argument a direct run needs

# The plain cases below run on PLAIN, a VERBATIM copy of the script (placed where every mutant is
# placed, with --db-dir), so a mutant's control IS the plain run, not a second one. Only the
# default-db-dir run (sc_clean), usage, and the no-docker cases use the script itself.
PLAIN="$tmp/mut/ctl-db-scrape-test.sh"; cp "$scrape" "$PLAIN"
NASSERT=$((nreq + 12))
sc_clean() {
  srun "$1"
  [[ $rc == 0 && $out == *"db-scrape-test: $NASSERT assertions, $NASSERT ok, 0 failed"* && $out == *"PASS exporter-args-allowlisted"* \
    && $out == *"PASS exporter-env-allowlisted"* && $out == *"PASS exporter-mounts-expected"* ]]
}
# the scenarios that read the shared, bad-in-every-way run
sc_pgup() { srun "$1" "${BAD_ENV[@]}"; [[ $rc == 1 && $out == *"FAIL pg-up: pg_up is '0'"* ]]; }
sc_missing() { srun "$1" "${BAD_ENV[@]}"; [[ $rc == 1 && $out == *"FAIL required-metric pg_wal_size_bytes"* ]]; }
sc_collector() { srun "$1" "${BAD_ENV[@]}"; [[ $rc == 1 && $out == *"FAIL collectors-succeed: failing: collector=\"stat_statements\""* ]]; }
sc_published() { srun "$1" "${BAD_ENV[@]}"; [[ $rc == 1 && $out == *"FAIL exporter-not-published"* ]]; }
sc_super() { srun "$1" "${BAD_ENV[@]}"; [[ $rc == 1 && $out == *"FAIL monitor-not-superuser"* ]]; }
sc_write() { srun "$1" "${BAD_ENV[@]}"; [[ $rc == 1 && $out == *"FAIL monitor-cannot-create"* && $out == *"FAIL monitor-cannot-write"* ]]; }
sc_ssl_bad() { srun "$1" "${BAD_ENV[@]}"; [[ $rc == 1 && $out == *"FAIL exporter-session-encrypted"* ]]; }
sc_nodocker() { sdb "$1"; out="$(env PATH="$tmp/empty" "$BASH" "$1" ${SDB[@]+"${SDB[@]}"} 2>&1)"; rc=$?; [[ $rc == 2 && $out == *"docker not found"* ]]; }
sc_usage() { out="$(bash "$1" --bogus 2>&1)"; rc=$?; [[ $rc == 2 && $out == *usage* ]]; }
# teardown: exactly one `down -v`, of the project the run printed, and no docker call at
# all outside that project; two runs never share a project name
sc_teardown() {
  local p1 p2 line downs=0 foreign=0
  srun "$1"; p1="$(projof)"; [[ $p1 =~ ^dbscrape-[0-9]+$ ]] || return 1
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    case "$line" in
      "compose -p $p1 "*) [[ $line == *" down -v "* ]] && downs=$((downs + 1)) ;;
      "inspect -f "*" fakeexporter0001") ;;  # its own exporter container
      *) foreign=$((foreign + 1)) ;;
    esac
  done < "$LOGF"
  ((downs == 1 && foreign == 0)) || return 1
  [[ $(tail -n 1 "$LOGF") == "compose -p $p1 "*" down -v --remove-orphans" ]] || return 1  # last call of all
  srun "$1" FAKE_RUN_ID=second; p2="$(projof)"; [[ -n $p2 && $p2 != "$p1" ]]
}
sc_teardown_on_failed_start() {
  srun "$1" FAKE_UP_RC=1
  [[ $rc == 2 && $out == *"FAIL START"* ]] || return 1
  grep -q -E '^compose -p dbscrape-[0-9]+ .* down -v --remove-orphans$' "$LOGF"
}
sc_teardown_on_failed_assertion() { srun "$1" "${BAD_ENV[@]}"; grep -q -E '^compose -p dbscrape-[0-9]+ .* down -v --remove-orphans$' "$LOGF"; }
sc_mutate() {
  srun "$1" -- --mutate revoke-monitor
  [[ $rc == 1 && $out == *"RED as intended"* ]] && grep -q 'REVOKE pg_monitor FROM app_monitor' "$LOGF" && grep -q -E ' down -v ' "$LOGF"
}
# the revoke is judged by its SPECIFIC effect: exit 1 only for the failures it explains
sc_mutate_broken_scrape() { srun "$1" FAKE_WGET_FAIL=1 -- --mutate revoke-monitor; [[ $rc == 3 && $out == *"broke for another reason"* && $out == *"FAIL scrape-fetched"* ]]; }
sc_mutate_pgup0() { srun "$1" FAKE_METRICS_REVOKED="$tmp/m.revoked.pgup0" -- --mutate revoke-monitor; [[ $rc == 3 && $out == *"broke for another reason"* ]]; }
sc_mutate_unrelated() { srun "$1" FAKE_ROLSUPER=t -- --mutate revoke-monitor; [[ $rc == 3 && $out == *"FAIL monitor-not-superuser"* ]]; }
sc_mutate_ssl() { srun "$1" FAKE_SSL=0/1 -- --mutate revoke-monitor; [[ $rc == 3 ]]; }
# wal missing AND a collector that is neither wal nor database fails: not explained by the revoke
sc_mutate_walstat() { srun "$1" FAKE_METRICS_REVOKED="$tmp/m.revoked.walstat" -- --mutate revoke-monitor; [[ $rc == 3 && $out == *"broke for another reason"* ]]; }
sc_mutate_nodocker() { sdb "$1"; out="$(env PATH="$tmp/empty" "$BASH" "$1" ${SDB[@]+"${SDB[@]}"} --mutate revoke-monitor 2>&1)"; rc=$?; [[ $rc == 2 && $out == *"docker not found"* ]]; }
sc_mutate_start_fails() { srun "$1" FAKE_UP_RC=1 -- --mutate revoke-monitor; [[ $rc == 2 && $out == *"FAIL START"* ]]; }
sc_mutate_survivor() { srun "$1" FAKE_REVOKE_NOOP=1 -- --mutate revoke-monitor; [[ $rc == 4 && $out == *"MUTATION SURVIVED"* ]]; }
sc_no_revoke_without_mutate() { srun "$1"; ! grep -q 'REVOKE' "$LOGF"; }
sc_hang() {
  local t0=$SECONDS; sdb "$1"
  : > "$tmp/hang.log"
  out="$(tmo 30 env PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/hang.log" FAKE_HANG=1 FAKE_HANG_S="${HANGS:-60}" DB_SCRAPE_BUDGET_S=2 DB_SCRAPE_CLEANUP_S=1 bash "$1" ${SDB[@]+"${SDB[@]}"} 2>&1)"; rc=$?
  ((SECONDS - t0 <= 8)) && [[ $rc == 2 && $out == *"FAIL START"* ]]
}
sc_hang_short() { HANGS=4 sc_hang "$1"; }
# the exporter's own connection settings, read from its container (never printed whole)
sc_tls() { # SCRIPT URI WANT-substring
  new_insp "$2"; srun "$1" "FAKE_INSPECT=$INSP"
  [[ $rc == 1 && $out == *"FAIL exporter-tls-verify-full"* && $out == *"$3"* && $out != *hunter2zz* && $out != *"DATA_SOURCE_PASS_FILE"* ]]
}
sc_tls_ok() { srun "$1"; [[ $rc == 0 && $out == *"PASS exporter-tls-verify-full: sslmode=verify-full sslrootcert=/tls/server.crt"* && $out != *hunter2zz* ]]; }
sc_ssl() { srun "$1" "FAKE_SSL=$2"; [[ $rc == 1 && $out == *"FAIL exporter-session-encrypted"* ]]; }
sc_inspect_fails() {
  srun "$1" FAKE_INSPECT_RC=1
  [[ $rc == 1 && $out == *"FAIL exporter-tls-verify-full"* && $out == *"FAIL exporter-args-allowlisted"* && $out == *"FAIL exporter-env-allowlisted"* && $out == *"FAIL exporter-mounts-expected"* ]]
}
# B1: a downgrade through anything the allowlist does not list is RED where tls-verify-full cannot look
ARGS_BAD=$'cmd "--datasource.uri=db:5432/app?sslmode=require&pw=hunter2zz"\ncmd "--datasource.uri-file=/x"\ncmd "--config.file=/x"\ncmd "--web.config.file=/y"\ncmd "--collector.stat_statements.limit=999"\ncmd "--bogus.flag"'
sc_args_bad() {
  new_insp "" "" "" "$ARGS_BAD"; srun "$1" "FAKE_INSPECT=$INSP"
  [[ $rc == 1 && $out == *"FAIL exporter-args-allowlisted"* && $out == *" --datasource.uri "* && $out == *" --datasource.uri-file "* && $out == *" --config.file "* \
    && $out == *" --web.config.file "* && $out == *" --collector.stat_statements.limit "* && $out == *" --bogus.flag"* \
    && $out == *"PASS exporter-tls-verify-full"* && $out != *"sslmode=require"* && $out != *hunter2zz* ]]
}
sc_args_disable() {
  new_insp "" "" "" 'cmd "--datasource.uri=db:5432/app?sslmode=disable"'; srun "$1" "FAKE_INSPECT=$INSP"
  [[ $rc == 1 && $out == *"FAIL exporter-args-allowlisted"* && $out == *"PASS exporter-tls-verify-full"* && $out != *"sslmode=disable"* ]]
}
ENV_BAD=$'env "DATA_SOURCE_URI_FILE=/x"\nenv "DATA_SOURCE_NAME=postgresql://u:hunter2zz@db/app?sslmode=disable"\nenv "PGSSLMODE=disable"\nenv "DATA_SOURCE_PASS=hunter2zz"\nenv "PG_EXPORTER_PASSWORD=x"'
sc_env_bad() {
  new_insp "" "" "" "$ENV_BAD"; srun "$1" "FAKE_INSPECT=$INSP"
  [[ $rc == 1 && $out == *"FAIL exporter-env-allowlisted"* && $out == *" DATA_SOURCE_URI_FILE "* && $out == *" DATA_SOURCE_NAME "* && $out == *" PGSSLMODE "* \
    && $out == *" DATA_SOURCE_PASS "* && $out == *" PG_EXPORTER_PASSWORD"* && $out != *hunter2zz* && $out != *"PASS exporter-env-allowlisted"* ]]
}
sc_mounts_bad() {
  new_insp "" "" "/tls" 'mount "/etc/exporter.yml"'; srun "$1" "FAKE_INSPECT=$INSP"
  [[ $rc == 1 && $out == *"FAIL exporter-mounts-expected: mounts: unexpected [/etc/exporter.yml] missing [/tls]"* ]]
}
sc_entrypoint_bad() {
  new_insp "" "/bin/sh"; srun "$1" "FAKE_INSPECT=$INSP"
  [[ $rc == 1 && $out == *"FAIL exporter-args-allowlisted: entrypoint is '/bin/sh'"* ]]
}
# `docker compose port` of an unpublished port prints nothing, `:0` or `invalid IP:0`
sc_port_ok() { srun "$1" "FAKE_PORT_OUT=$2"; [[ $rc == 0 && $out == *"PASS exporter-not-published"* ]]; }
sc_port_red() { srun "$1" "FAKE_PORT_OUT=$2"; [[ $rc == 1 && $out == *"FAIL exporter-not-published"* ]]; }
sc_promtool() {
  srun "$1" -- --promtool
  local runl; runl="$(grep '^run ' "$LOGF" | head -n 1)"; local p; p="$(projof)"
  [[ $rc == 0 && $runl == *"--name $p-promtool"* && $runl == *"--network none"* && $runl == *"--cpus 1"* && $runl == *"--memory 1g"* && $runl == *"--tmpfs /tmp"* \
    && $runl == *"quay.io/prometheus/prometheus:v3.16.0@sha256:"* ]] && grep -q "^rm -f $p-promtool\$" "$LOGF"
}
sc_promtool_off() { srun "$1"; ! grep -q '^run ' "$LOGF"; }
# a scenario that is vacuous BY CONSTRUCTION: it runs the script where its db dir does not exist
# (the defect the first version of this file shipped with); only the pairing can notice
sc_misplaced() { out="$(env PATH="$tmp/bin:$PATH" bash "$1" 2>&1)"; rc=$?; [[ $rc == 0 ]]; }

expect_ok "the plain-case copy of the script is verbatim" test "$(<"$PLAIN")" == "$(<"$scrape")"
expect_ok "scrape test: clean scrape -> exit 0, every assertion passed (default db dir)" sc_clean "$scrape"
expect_ok "scrape test: pg_up 0 -> RED" sc_pgup "$PLAIN"
expect_ok "scrape test: a required metric missing -> RED naming it" sc_missing "$PLAIN"
expect_ok "scrape test: a failing collector -> RED" sc_collector "$PLAIN"
expect_ok "scrape test: exporter port published on the host -> RED" sc_published "$PLAIN"
expect_ok "scrape test: monitor role elevated -> RED" sc_super "$PLAIN"
expect_ok "scrape test: monitor role can write -> RED" sc_write "$PLAIN"
expect_ok "scrape test: docker missing -> exit 2" sc_nodocker "$scrape"
expect_ok "scrape test: unknown option -> exit 2" sc_usage "$scrape"
expect_ok "scrape test: teardown is down -v of its own unique project, last, nothing foreign" sc_teardown "$PLAIN"
expect_ok "scrape test: teardown also after a failed start" sc_teardown_on_failed_start "$PLAIN"
expect_ok "scrape test: teardown also after a failed assertion" sc_teardown_on_failed_assertion "$PLAIN"
expect_ok "scrape test: no revoke without --mutate" sc_no_revoke_without_mutate "$PLAIN"
expect_ok "scrape test: --mutate revoke-monitor issues the revoke, goes RED, tears down" sc_mutate "$PLAIN"
expect_ok "scrape test: a mutation that stays green -> exit 4" sc_mutate_survivor "$PLAIN"
expect_ok "scrape test: --mutate, scrape not fetched after the revoke -> exit 3, not RED" sc_mutate_broken_scrape "$PLAIN"
expect_ok "scrape test: --mutate, pg_up 0 after the revoke -> exit 3" sc_mutate_pgup0 "$PLAIN"
expect_ok "scrape test: --mutate, an unrelated assertion fails -> exit 3" sc_mutate_unrelated "$PLAIN"
expect_ok "scrape test: --mutate, the encryption assertion fails -> exit 3" sc_mutate_ssl "$PLAIN"
expect_ok "scrape test: --mutate, wal missing and another collector failing -> exit 3, not RED" sc_mutate_walstat "$PLAIN"
expect_ok "scrape test: --mutate without docker -> exit 2" sc_mutate_nodocker "$scrape"
expect_ok "scrape test: --mutate, the stack does not start -> exit 2" sc_mutate_start_fails "$PLAIN"
expect_ok "scrape test: exporter sslmode=verify-full read from its container" sc_tls_ok "$PLAIN"
expect_ok "scrape test: exporter sslmode=require -> RED" sc_tls "$PLAIN" "db:5432/app?sslmode=require&sslrootcert=/tls/server.crt" "sslmode parameters: =require"
expect_ok "scrape test: exporter sslmode=disable -> RED" sc_tls "$PLAIN" "db:5432/app?sslmode=disable&sslrootcert=/tls/server.crt" "=disable"
expect_ok "scrape test: exporter sslmode twice -> RED" sc_tls "$PLAIN" "db:5432/app?sslmode=verify-full&sslmode=require&sslrootcert=/tls/server.crt" "=verify-full =require"
expect_ok "scrape test: exporter sslmode=verify-fullx -> RED" sc_tls "$PLAIN" "db:5432/app?sslmode=verify-fullx&sslrootcert=/tls/server.crt" "=verify-fullx"
expect_ok "scrape test: exporter without sslmode -> RED" sc_tls "$PLAIN" "db:5432/app?sslrootcert=/tls/server.crt" "none"
expect_ok "scrape test: exporter without sslrootcert -> RED" sc_tls "$PLAIN" "db:5432/app?sslmode=verify-full" "sslrootcert count 0"
expect_ok "scrape test: exporter with an empty sslrootcert -> RED" sc_tls "$PLAIN" "db:5432/app?sslmode=verify-full&sslrootcert=" "value 'empty'"
expect_ok "scrape test: docker inspect fails -> RED on all four exporter assertions" sc_inspect_fails "$PLAIN"
expect_ok "scrape test: flags --datasource.uri (require), --datasource.uri-file, --config.file, --web.config.file, a changed value, an unknown flag -> RED, values hidden" sc_args_bad "$PLAIN"
expect_ok "scrape test: flag --datasource.uri with sslmode=disable -> RED while tls-verify-full stays green" sc_args_disable "$PLAIN"
expect_ok "scrape test: DATA_SOURCE_URI_FILE, DATA_SOURCE_NAME, PGSSLMODE, DATA_SOURCE_PASS, PG_EXPORTER_PASSWORD -> RED by name, values hidden" sc_env_bad "$PLAIN"
expect_ok "scrape test: an extra mount and a missing one -> RED" sc_mounts_bad "$PLAIN"
expect_ok "scrape test: an overridden entrypoint -> RED" sc_entrypoint_bad "$PLAIN"
expect_ok "scrape test: monitor session not encrypted (ssl = f) -> RED" sc_ssl_bad "$PLAIN"
expect_ok "scrape test: one of two monitor sessions not encrypted -> RED" sc_ssl "$PLAIN" 1/2
expect_ok "scrape test: no monitor session visible -> RED" sc_ssl "$PLAIN" 0/0
expect_ok "scrape test: port output empty -> not published" sc_port_ok "$PLAIN" ""
expect_ok "scrape test: port output ':0' and 'invalid IP:0' -> not published" sc_port_ok "$PLAIN" $'invalid IP:0\n:0'
expect_ok "scrape test: port output 0.0.0.0:9187 -> published, RED" sc_port_red "$PLAIN" "0.0.0.0:9187"
expect_ok "scrape test: port output [::]:49153 -> published, RED" sc_port_red "$PLAIN" "[::]:49153"
expect_ok "scrape test: a hung docker -> gives up within the budget (exit 2)" sc_hang "$PLAIN"
expect_ok "scrape test: --promtool runs the pinned image, own name, no network, removed" sc_promtool "$PLAIN"
expect_ok "scrape test: no promtool container without --promtool" sc_promtool_off "$PLAIN"
# the call shapes the real docker needs (a fake cannot prove the real flags; these pin them)
srun "$scrape"
if grep -q -E '^compose -p dbscrape-[0-9]+ --env-file [^ ]+ -f [^ ]+/compose.yml -f [^ ]+/compose.observability.yml up -d --wait --wait-timeout [0-9]+$' "$LOGF"; then pass "up uses both compose files and a bounded --wait"; else flunk "up call shape: $(grep ' up ' "$LOGF")"; fi
if grep -q ' exec -T db wget -q -O - http://exporter:9187/metrics$' "$LOGF"; then pass "the scrape goes from the db container to the exporter by service name"; else flunk "scrape call shape"; fi
if grep -q -E '^inspect -f .*\.Config\.Cmd.*\.Config\.Entrypoint.*\.Config\.Env.*\.Mounts.* fakeexporter0001$' "$LOGF"; then pass "ONE docker inspect reads command, entrypoint, environment and mounts"; else flunk "inspect call shape"; fi

# ---- 5. the db-test recipe runs the checks in the pinned order -------------------------------------
# mk_pin MAKEFILE: in the `db-test` recipe, in this order: the parity check, the bootstrap test(s),
# the scrape test, then the --mutate line with its exit-1 requirement. A text pin of ONE recipe.
mk_pin() {
  local in=0 found=0 n=0 l ip=0 ib1=0 ib2=0 isc=0 im=0
  while IFS= read -r l; do
    if ((in)); then
      [[ $l == $'\t'* || -z $l ]] || break
      [[ -z $l ]] && continue
      n=$((n + 1))
      case "$l" in
        *db/observability/parity-check.sh*) ((ip)) || ip=$n ;;
        *db-bootstrap-test.sh*) ((ib1)) || ib1=$n; ib2=$n ;;
        *"db-scrape-test.sh --promtool"*) isc=$n ;;
        *"db-scrape-test.sh --mutate revoke-monitor"*"-eq 1"*) im=$n ;;
      esac
    elif [[ $l == "db-test:"* ]]; then in=1; found=1; fi
  done < "$1"
  ((found)) || { echo "selftest: no db-test recipe in $1" >&2; return 1; }
  ((ip > 0 && ib1 > ip && ib2 >= ib1 && isc > ib2 && im > isc))
}
if [[ -r $makefile ]]; then expect_ok "Makefile db-test: parity, bootstrap, scrape, then --mutate with its exit-1 requirement, in that order" mk_pin "$makefile"
else flunk "Makefile db-test pin" "cannot read $makefile"; fi

# ---- 6. mutations of the scrape test and the Makefile: PAIRED --------------------------------------
# vverdict NAME SRC ANCHOR REPL FN ARGS...: sets VV to
#   NOANCHOR   the patch did not apply or changed nothing
#   NOCONTROL  FN is not green on an UNMUTATED copy placed the same way (the scenario is vacuous)
#   GREEN      FN stayed green on the mutated copy (the cases did not notice)
#   RED        FN went red on the mutated copy while green on its control
CK=(); CR=(); vn=0
vverdict() {
  local src="$2" anchor="$3" repl="$4" fn="$5" base copy ctl key i res=-1; shift 5
  base="${src##*/}"; vn=$((vn + 1)); copy="$tmp/mut/m$vn-$base"; ctl="$tmp/mut/ctl-$base"
  [[ -e $ctl ]] || cp "$src" "$ctl"
  cp "$src" "$copy"
  replace_in "$copy" "$anchor" "$repl" 2>/dev/null || { VV=NOANCHOR; return 0; }
  key="$fn|$*"
  for i in "${!CK[@]}"; do [[ ${CK[i]} == "$key" ]] && res="${CR[i]}"; done
  if ((res < 0)); then
    if "$fn" "$ctl" "$@" >/dev/null 2>&1; then res=0; else res=1; fi
    CK+=("$key"); CR+=("$res")
  fi
  ((res == 0)) || { VV=NOCONTROL; return 0; }
  if "$fn" "$copy" "$@" >/dev/null 2>&1; then VV=GREEN; else VV=RED; fi
}
vmut() {
  vverdict "$@"
  case "$VV" in
    RED) echo "RED  mutation $1"; ok=$((ok + 1)) ;;
    NOANCHOR) flunk "mutant $1: anchor not found or the patch is a no-op, so the mutant did not run" "$3" ;;
    NOCONTROL) flunk "mutant $1: its control is not green" ;;
    *) flunk "mutation $1: GREEN (the cases did not notice)" ;;
  esac
}
# the meta-cases: a vacuous setup is REPORTED, and a patch that changes nothing too
vverdict "meta" "$scrape" 'proj="dbscrape-$$"' 'proj="dbscrape-fixed"' sc_misplaced
if [[ $VV == NOCONTROL ]]; then pass "meta: a scenario that fails on the unmutated copy is reported as: control is not green"; else flunk "meta: vacuous setup was judged $VV, not NOCONTROL"; fi
vverdict "meta" "$scrape" 'proj="dbscrape-$$"' 'proj="dbscrape-$$"' sc_clean
if [[ $VV == NOANCHOR ]]; then pass "meta: a patch that changes nothing is a failure, not a pass"; else flunk "meta: a no-op patch was judged $VV"; fi
vverdict "meta" "$scrape" 'THIS ANCHOR DOES NOT EXIST' 'x' sc_clean
if [[ $VV == NOANCHOR ]]; then pass "meta: an anchor that is not found is a failure"; else flunk "meta: a missing anchor was judged $VV"; fi

PORT_RE=':[1-9][0-9]*[[:space:]]*$'   # the scrape test's published-port regex, literally
vmut "scrape test: required-metric check removed" "$scrape" 'if [[ $l == "PASS "* ]]; then emit PASS "required-metric ${l#PASS }"; else emit FAIL "required-metric ${l#FAIL }" "absent from the scrape"; fi' 'emit PASS "required-metric ${l#* }"' sc_missing
vmut "scrape test: pg_up check removed" "$scrape" 'if [[ $up == 1 ]]; then' 'if true; then' sc_pgup
vmut "scrape test: cleanup/project with a fixed name instead of the unique one" "$scrape" 'proj="dbscrape-$$"' 'proj="dbscrape-fixed"' sc_teardown
vmut "scrape test: teardown trap removed" "$scrape" 'trap cleanup EXIT' ':' sc_teardown
vmut "scrape test: published-port check removed" "$scrape" "grep -Eq '$PORT_RE' \"\$last\"; then" 'false; then' sc_published
vmut "scrape test: port regex ':[0-9]+' reads 'invalid IP:0' as published" "$scrape" "grep -Eq '$PORT_RE'" "grep -Eq ':[0-9]+'" sc_port_ok $'invalid IP:0\n:0'
vmut "scrape test: promtool container without a writable /tmp" "$scrape" '--tmpfs /tmp:rw,noexec,nosuid,size=64m ' '' sc_promtool
vmut "scrape test: exporter TLS assertion removed" "$scrape" 'if exporter_tls; then' 'if true; then' sc_tls "db:5432/app?sslmode=require&sslrootcert=/tls/server.crt" "sslmode"
vmut "scrape test: duplicated sslmode accepted" "$scrape" '((nmodes == 1 && nvf == 1 && nroot == 1))' '((nvf >= 1 && nroot == 1))' sc_tls "db:5432/app?sslmode=verify-full&sslmode=require&sslrootcert=/tls/server.crt" "sslmode"
vmut "scrape test: encryption assertion ignores unencrypted sessions" "$scrape" '[[ ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" ]]; then' 'true; then' sc_ssl_bad
vmut "scrape test: any failure counts as the revoke being detected" "$scrape" '    if ((broke == 0)); then' '    if true; then' sc_mutate_broken_scrape
vmut "scrape test: --mutate no longer revokes" "$scrape" 'if ! sup_psql '"'"'REVOKE pg_monitor FROM app_monitor'"'"'; then' 'if false; then' sc_mutate
vmut "scrape test: a surviving mutation reported as RED" "$scrape" 'so the test is vacuous"; exit 4' 'so the test is vacuous"; exit 1' sc_mutate_survivor
# the watchdog no longer kills: each hung call runs its full 4 s, three calls exceed the 8 s allowance
vmut "scrape test: watchdog kill removed (hung docker is no longer bounded)" "$scrape" 'kill -KILL "$pid" 2>/dev/null' 'true' sc_hang_short
# B1: the allowlist applied to the RUNNING container
vmut "scrape test: command allowlist check removed (a --datasource.uri flag passes)" "$scrape" 'in_list "$a" ${a_arg[@]+"${a_arg[@]}"} || bad="$bad ${a%%=*}"' 'true' sc_args_bad
vmut "scrape test: command allowlist check removed (sslmode=disable flag passes)" "$scrape" 'in_list "$a" ${a_arg[@]+"${a_arg[@]}"} || bad="$bad ${a%%=*}"' 'true' sc_args_disable
vmut "scrape test: variable allowlist check removed (DATA_SOURCE_URI_FILE passes)" "$scrape" 'in_list "$n" ${a_env[@]+"${a_env[@]}"} ${a_ienv[@]+"${a_ienv[@]}"} || bad="$bad $n"' 'true' sc_env_bad
vmut "scrape test: image-baked variables not allowed (PATH reported)" "$scrape" ' ${a_ienv[@]+"${a_ienv[@]}"} ||' ' ||' sc_clean
vmut "scrape test: mount check removed (a config file mount passes)" "$scrape" '[[ -z $bad && -z $miss ]] ||' 'true ||' sc_mounts_bad
vmut "scrape test: missing mounts not noticed" "$scrape" 'for m in ${a_mount[@]+"${a_mount[@]}"}; do in_list "$m" ${mounts[@]+"${mounts[@]}"} || miss="$miss $m"; done' ':' sc_mounts_bad
vmut "scrape test: entrypoint comparison removed" "$scrape" '[[ $e == "$w" ]] ||' 'true ||' sc_entrypoint_bad
vmut "scrape test: argument values printed (a value could carry a password)" "$scrape" 'bad="$bad ${a%%=*}"' 'bad="$bad $a"' sc_args_bad
vmut "scrape test: variable values kept with their names (and printed)" "$scrape" 'env_names+=("${v%%=*}")' 'env_names+=("$v")' sc_env_bad
vmut "scrape test: a failing inspect passes the exporter assertions" "$scrape" 'insp_err="docker inspect failed"; : > "$last"; return 1; fi' 'insp_err="docker inspect failed"; : > "$last"; return 0; fi' sc_inspect_fails
vmut "scrape test: a third failing collector explained by the revoke" "$scrape" '[[ -n $bad && -z $rest ]] || broke=1' ':' sc_mutate_walstat
# the Makefile pin
vmut "Makefile: the parity line removed from db-test" "$makefile" $'\t@bash prod-new/modules/db-postgres/db/observability/parity-check.sh\n' '' mk_pin
vmut "Makefile: the scrape test removed from db-test" "$makefile" $'\t@bash prod-new/modules/db-postgres/scripts/db-scrape-test.sh --promtool\n' '' mk_pin
vmut "Makefile: the --mutate exit-1 requirement removed" "$makefile" '[ $$rc -eq 1 ]' 'true' mk_pin
vmut "Makefile: parity moved after the bootstrap tests" "$makefile" $'\t@bash prod-new/modules/db-postgres/db/observability/parity-check.sh\n\t@bash prod-new/modules/db-postgres/scripts/db-bootstrap-test.sh --variant plain\n' $'\t@bash prod-new/modules/db-postgres/scripts/db-bootstrap-test.sh --variant plain\n\t@bash prod-new/modules/db-postgres/db/observability/parity-check.sh\n' mk_pin
if ((skipped > 0)); then echo "$ok ok, $bad failed, $skipped skipped"; else echo "$ok ok, $bad failed"; fi
((bad == 0))
