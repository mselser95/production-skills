#!/usr/bin/env bash
# parity-check.sh - offline gate: the monitoring contract, the alerts, their tests and
# the exporter overlay agree with each other. Hermetic, well under 2 s.
#
#   parity-check.sh [--dir OBS_DIR] [--overlay FILE] [--lock FILE]
#
#   --dir      the observability directory (default: the directory of this script)
#   --overlay  the compose overlay (default: OBS_DIR/../compose.observability.yml)
#   --lock     the image lock (default: OBS_DIR/image.lock)
#
# Rules (each finding is one `FAIL <RULE>: ...` line; exit 1 if any):
#   UNKNOWN-METRIC   an alert expression uses a metric that is not in required-metrics.txt
#   ORPHAN-METRIC    a required metric is used by no alert and is not marked `dashboard-only`
#   NO-FIRING-TEST   an alert has no test case in which it fires
#   NO-QUIET-TEST    an alert has no test case in which it does not fire
#   ANNOTATION       an alert lacks severity / summary / description / runbook
#   RUNBOOK-ANCHOR   a runbook annotation does not point at a heading of RUNBOOK.md
#   TEST-ORPHAN      the test file names an alert the rules do not define
#   OVERLAY-*        the exporter service breaks one of the hardening rules (see below)
# Exit: 0 green · 1 findings · 2 nothing was checked (python3 or PyYAML missing, a file
# unreadable, a document that is not valid YAML): never "unchecked = ok".
set -uo pipefail

src="${BASH_SOURCE[0]}"; [[ $src == */* ]] || src="./$src"
here="$(cd "${src%/*}" && pwd)"
dir="$here"; overlay=""; lock=""
while (($#)); do
  case "$1" in
    --dir) dir="${2:-}"; shift ;;
    --overlay) overlay="${2:-}"; shift ;;
    --lock) lock="${2:-}"; shift ;;
    *) echo "usage: parity-check.sh [--dir OBS_DIR] [--overlay FILE] [--lock FILE]" >&2; exit 2 ;;
  esac
  shift
done
[[ -n $overlay ]] || overlay="$dir/../compose.observability.yml"
[[ -n $lock ]] || lock="$dir/image.lock"
command -v python3 >/dev/null 2>&1 || { echo "parity-check: python3 is not available, nothing was checked" >&2; exit 2; }
python3 -B -c 'import yaml' 2>/dev/null || { echo "parity-check: PyYAML is not importable, nothing was checked (pip install PyYAML)" >&2; exit 2; }

exec python3 -B - "$dir" "$overlay" "$lock" <<'PY'
import os, re, sys
import yaml

obs, overlay_path, lock_path = sys.argv[1:4]
findings = []


def fail(rule, msg):
    findings.append(f"FAIL {rule}: {msg}")


def die(msg):
    print(f"parity-check: {msg}, nothing was checked", file=sys.stderr)
    sys.exit(2)


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        die(f"cannot read {path}: {e.strerror}")


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def _map(loader, node, deep=False):
    seen = set()
    for k, _ in node.value:
        key = loader.construct_object(k, deep=True)
        if key in seen:
            raise yaml.YAMLError(f"duplicate key {key!r}")
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _map)


def load(path):
    text = read(path)
    try:
        return yaml.load(text, Loader=UniqueKeyLoader)
    except yaml.YAMLError as e:
        die(f"{path} is not valid YAML ({e})")


# ---- required-metrics.txt -------------------------------------------------------
required = {}  # name -> dashboard_only
for n, raw in enumerate(read(os.path.join(obs, "required-metrics.txt")).splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    name, _, comment = line.partition("#")
    name = name.strip()
    if not re.fullmatch(r"[a-zA-Z_:][a-zA-Z0-9_:]*", name):
        fail("REQUIRED-FORMAT", f"required-metrics.txt:{n}: `{name}` is not a metric name")
        continue
    if name in required:
        fail("REQUIRED-FORMAT", f"required-metrics.txt:{n}: `{name}` is listed twice")
    required[name] = "dashboard-only" in comment.lower()
if not required:
    die("required-metrics.txt lists no metric")

# ---- PromQL metric names ---------------------------------------------------------
KEYWORDS = {"and", "or", "unless", "bool", "by", "without", "on", "ignoring", "group_left",
            "group_right", "offset", "inf", "nan", "start", "end", "atan2"}


def metrics_of(expr):
    s = re.sub(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'', '""', expr)
    s = re.sub(r"\[[^\]]*\]", "", s)
    s = re.sub(r"\{[^}]*\}", "", s)
    s = re.sub(r"\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", " ", s)
    out = set()
    for m in re.finditer(r"(?<![0-9a-zA-Z_:.])[a-zA-Z_:][a-zA-Z0-9_:]*", s):
        if m.group(0) in KEYWORDS or re.match(r"\s*\(", s[m.end():]):
            continue
        out.add(m.group(0))
    return out


# ---- the alert rules --------------------------------------------------------------
rules_doc = load(os.path.join(obs, "alerts", "postgres.rules.yml"))
alerts = {}  # name -> rule
for g in (rules_doc or {}).get("groups") or []:
    for r in g.get("rules") or []:
        if isinstance(r, dict) and "alert" in r:
            if r["alert"] in alerts:
                fail("ANNOTATION", f"alert {r['alert']} is defined twice")
            alerts[r["alert"]] = r
if not alerts:
    die("postgres.rules.yml defines no alert")

used = set()
runbook = read(os.path.join(obs, "RUNBOOK.md"))
anchors = set()
for m in re.finditer(r"^#{1,6}\s+(.+?)\s*$", runbook, re.M):
    anchors.add(re.sub(r"[^\w\- ]", "", m.group(1).lower()).replace(" ", "-"))

SEVERITIES = {"critical", "warning", "info"}
for name, r in alerts.items():
    ms = metrics_of(str(r.get("expr", "")))
    used |= ms
    for m in sorted(ms - set(required)):
        fail("UNKNOWN-METRIC", f"alert {name} uses `{m}`, which is not in required-metrics.txt")
    labels = r.get("labels") or {}
    ann = r.get("annotations") or {}
    if labels.get("severity") not in SEVERITIES:
        fail("ANNOTATION", f"alert {name} has no severity label in {sorted(SEVERITIES)}")
    for k in ("summary", "description", "runbook"):
        if not str(ann.get(k, "")).strip():
            fail("ANNOTATION", f"alert {name} has no {k} annotation")
    rb = str(ann.get("runbook", "")).strip()
    if rb:
        path, _, anchor = rb.partition("#")
        if not path.endswith("RUNBOOK.md") or not anchor or anchor not in anchors:
            fail("RUNBOOK-ANCHOR", f"alert {name}: runbook `{rb}` does not point at a heading of RUNBOOK.md")

for m, dash in sorted(required.items()):
    if m not in used and not dash:
        fail("ORPHAN-METRIC", f"required metric `{m}` is used by no alert and is not marked dashboard-only")

# ---- the alert tests (read, not run: promtool runs them where it exists) -------------
tests_doc = load(os.path.join(obs, "alerts", "postgres.rules.test.yml"))
fires, quiet = {}, {}
for t in (tests_doc or {}).get("tests") or []:
    for c in (t or {}).get("alert_rule_test") or []:
        n = c.get("alertname")
        if not n:
            continue
        (fires if c.get("exp_alerts") else quiet)[n] = True
for name in alerts:
    if name not in fires:
        fail("NO-FIRING-TEST", f"alert {name} has no test case in which it fires")
    if name not in quiet:
        fail("NO-QUIET-TEST", f"alert {name} has no test case in which it does not fire")
for n in sorted(set(fires) | set(quiet)):
    if n not in alerts:
        fail("TEST-ORPHAN", f"the test file names alert {n}, which postgres.rules.yml does not define")

# ---- the image lock and the overlay ---------------------------------------------------
lk = {}
for raw in read(lock_path).splitlines():
    line = raw.strip()
    if line and not line.startswith("#") and "=" in line:
        k, _, v = line.partition("=")
        lk[k.strip()] = v.strip()
for k in ("exporter.image", "exporter.tag", "exporter.digest"):
    if not lk.get(k):
        die(f"{lock_path} has no value for {k}")
if not re.fullmatch(r"sha256:[0-9a-f]{64}", lk["exporter.digest"]):
    fail("OVERLAY-DIGEST", f"{lock_path}: exporter.digest is not a sha256 digest (a placeholder?)")
if lk["exporter.tag"] == "latest":
    fail("OVERLAY-DIGEST", f"{lock_path}: exporter.tag is latest")

ov = load(overlay_path)
svc = ((ov or {}).get("services") or {}).get("exporter") if isinstance(ov, dict) else None
if not isinstance(svc, dict):
    die(f"{overlay_path} has no service `exporter`")

image = str(svc.get("image", ""))
if not re.fullmatch(r"[^@\s]+:[^@\s:/]+@sha256:[0-9a-f]{64}", image) or ":latest@" in image:
    fail("OVERLAY-DIGEST", f"exporter image `{image}` is not pinned by tag AND sha256 digest")
want = f"{lk['exporter.image']}:{lk['exporter.tag']}@{lk['exporter.digest']}"
if image != want:
    fail("OVERLAY-DIGEST", f"exporter image `{image}` differs from image.lock `{want}`")
if svc.get("read_only") is not True:
    fail("OVERLAY-READONLY", "exporter must set read_only: true")
if [str(c).upper() for c in svc.get("cap_drop") or []] != ["ALL"]:
    fail("OVERLAY-CAPDROP", "exporter must set cap_drop: [ALL]")
if svc.get("cap_add"):
    fail("OVERLAY-CAPDROP", "exporter must not add capabilities")
if "no-new-privileges:true" not in [str(s).replace(" ", "") for s in svc.get("security_opt") or []]:
    fail("OVERLAY-NNP", "exporter must set security_opt: [no-new-privileges:true]")
user = str(svc.get("user", "")).strip()
uid = user.split(":")[0]
if not user or uid in ("0", "root") or not (uid.isdigit() or uid.isidentifier()):
    fail("OVERLAY-USER", f"exporter must run as a non-root user (user: `{user}`)")
if svc.get("ports"):
    fail("OVERLAY-PORTS", "exporter publishes a host port by default; opt-in belongs in the operator's own override")
if svc.get("privileged") or svc.get("network_mode") == "host" or svc.get("pid") == "host":
    fail("OVERLAY-PRIVILEGE", "exporter is privileged or shares the host network or pid namespace")
if "db_monitor_password" not in (svc.get("secrets") or []):
    fail("OVERLAY-SECRET", "exporter must mount the db_monitor_password secret as a file")
hc = svc.get("healthcheck") or {}
if not hc.get("test"):
    fail("OVERLAY-HEALTHCHECK", "exporter has no healthcheck")
dep = ((svc.get("depends_on") or {}).get("db") or {}) if isinstance(svc.get("depends_on"), dict) else {}
if dep.get("condition") != "service_healthy":
    fail("OVERLAY-DEPENDS", "exporter must depend on db with condition: service_healthy")
cmd = [str(c) for c in svc.get("command") or []]
for flag in ("--collector.stat_statements", "--collector.stat_checkpointer",
             "--collector.database_wraparound", "--collector.long_running_transactions"):
    if flag not in cmd:
        fail("OVERLAY-COLLECTORS", f"exporter command lacks {flag}, which a required metric needs")
if "--collector.stat_statements.include_query" in cmd:
    fail("OVERLAY-COLLECTORS", "exporter must not export query text (include_query)")
# The connection: non-secret settings from an env file, the password only as a file.
env_vars = {}
for ef in svc.get("env_file") or []:
    p = os.path.normpath(os.path.join(os.path.dirname(overlay_path), str(ef)))
    for raw in read(p).splitlines():
        line = raw.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            env_vars[k.strip()] = v.strip()
env = svc.get("environment") or {}
if isinstance(env, list):
    env = dict(str(e).partition("=")[::2] for e in env)
env_vars.update({str(k): str(v) for k, v in env.items()})
if "sslmode=verify-full" not in env_vars.get("DATA_SOURCE_URI", ""):
    fail("OVERLAY-TLS", "DATA_SOURCE_URI must carry sslmode=verify-full")
if not env_vars.get("DATA_SOURCE_PASS_FILE", "").startswith("/run/secrets/"):
    fail("OVERLAY-SECRET", "DATA_SOURCE_PASS_FILE must name a file under /run/secrets")
if env_vars.get("DATA_SOURCE_USER") != "app_monitor":
    fail("OVERLAY-SECRET", "DATA_SOURCE_USER must be app_monitor, the least-privilege role")
for k in ("DATA_SOURCE_PASS", "DATA_SOURCE_NAME", "PG_EXPORTER_PASSWORD"):
    if k in env_vars:
        fail("OVERLAY-SECRET", f"{k} puts a password in the environment; use DATA_SOURCE_PASS_FILE")
if re.search(r"://[^/@]*:[^/@]+@", env_vars.get("DATA_SOURCE_URI", "")):
    fail("OVERLAY-SECRET", "DATA_SOURCE_URI carries a password")

if findings:
    print("\n".join(findings))
    print(f"parity-check: RED ({len(findings)} findings)")
    sys.exit(1)
dash = sum(1 for v in required.values() if v)
print(f"parity-check: OK ({len(alerts)} alerts, {len(required)} required metrics, {dash} dashboard-only, exporter {want.split('@')[0]})")
PY
