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
#   OVERLAY-*        the exporter service breaks one of the hardening rules: digest, read_only,
#                    cap_drop, no-new-privileges, user, ports, privilege, secret, healthcheck,
#                    depends_on, collectors, TLS (exactly one sslmode=verify-full and one
#                    sslrootcert), LIMITS (cpus, mem_limit, pids_limit), TLS-MOUNT (read-only)
#   EXPR-NAME-MATCHER / EXPR-UNSUPPORTED   an alert expression uses a `__name__` matcher or a
#                    construct the metric extractor cannot read (it refuses, never guesses)
#   OVERLAY-ARGS / OVERLAY-ENV / OVERLAY-ENTRYPOINT / OVERLAY-MOUNTS / ALLOWLIST
#                    the exporter's command, variable names, entrypoint and mounts must be
#                    within exporter-allowlist.txt (an ALLOW-list: db-scrape-test.sh applies the
#                    same file to the running container); the allowlist names no way to carry a
#                    connection other than the overlay's
#   OVERLAY-ENV-VALUE / OVERLAY-INTERPOLATION / OVERLAY-DOTENV / OVERLAY-MOUNT-SOURCE
#                    VALUES are pinned too: every exporter variable (env_file contents and
#                    `environment:`) equals an allow-listed NAME=VALUE exactly; a `$` (also `$$`) in
#                    the exporter's command, environment, env_file, volumes, secrets, entrypoint,
#                    image or user is refused (compose substitutes it from the host environment or
#                    a `.env`); a `db/.env` beside the compose files is refused; each mount's
#                    source -> destination and the monitor secret's file in compose.yml are pinned
#   OVERLAY-EXTENDS / OVERLAY-INCLUDE / OVERLAY-TOPLEVEL / OVERLAY-SERVICES / OVERLAY-NETWORK
#                    the overlay may only add the service `exporter`, as written: no `extends`, no
#                    `include`, no other top-level key, and none of extra_hosts / dns / links /
#                    network_mode / networks (they can re-point the name `db`)
#   BASE-EXPORTER / OVERLAY-OVERRIDE-FILE
#                    the exporter is defined in exactly ONE place, the overlay (compose merges a
#                    service key by key across files, so a base fragment could add to it): the
#                    base compose.yml may not have a service the overlay defines (even `{}`), an
#                    `extends` aimed at one or at the overlay, or an `include`; and none of
#                    compose.override.y[a]ml, docker-compose[.override].y[a]ml, compose.yaml may
#                    sit in db/ (compose or a bare `docker compose up` would merge/pick them up).
#                    With the base silent on the exporter, the overlay IS the merged service,
#                    so every overlay check above judges what compose will run.
#   RECORDING-RULE   a `record:` rule: recording rules are not checked yet
#   PROMTOOL-CHECK   `promtool check rules` failed (run only when promtool is on PATH)
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
import os, re, shutil, subprocess, sys
from urllib.parse import parse_qs
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
# A hand-written PromQL recogniser is a liability, so this one REFUSES what it cannot see
# instead of guessing: any construct outside the list below is a finding (EXPR-UNSUPPORTED),
# never a silent pass. What it understands, after strings and `#` comments are removed:
#   - metric names: an identifier that is not a keyword or a function, followed by `{`,
#     `[`, `)`, `,`, an operator or the end; label matchers `{a="b", c=~"d"}` (label names
#     and string values only); ranges `[5m]` and subqueries `[5m:1m]`, `[5m:]`;
#     `offset <duration>` after a selector, a range, a subquery or a parenthesis;
#   - numbers, including hex, exponents, `Inf` and `NaN` in any case;
#   - operators `+ - * / % ^ == != < > <= >=` and `and or unless atan2` (and `bool`); keywords
#     are case-insensitive in operator position (`a AND b`, `m OFFSET 5m`, `sum BY (x) (m)`);
#   - grouping: `by without on ignoring group_left group_right` with an optional label list;
#   - functions and aggregations from FUNCS, each followed by `(` (aggregations may be
#     followed by `by` or `without`);
#   - `absent(x)` and `absent_over_time(x[5m])` use the metric x.
# The tokenizer tracks whether an OPERAND or an OPERATOR is expected next (start, after `(`,
# `,` and after every binary or set operator an operand is expected). A keyword where an
# operand is expected, such as `pg_up == 0 or offset > 0`, is a metric NAMED like a keyword:
# valid PromQL that alerts on a series nobody listed, so it is REFUSED, not skipped.
# Refused: any `__name__` (a metric written as a label matcher is invisible here), a
# selector that starts with `{` without a metric name, an unknown function, `@`, a
# duration outside `[...]`/`offset`, unbalanced brackets, a keyword out of place, any
# character not listed.
AGG = {"sum", "avg", "min", "max", "count", "group", "stddev", "stdvar", "topk", "bottomk",
       "quantile", "count_values"}
FUNCS = AGG | {"rate", "increase", "irate", "delta", "idelta", "deriv", "predict_linear",
               "absent", "absent_over_time", "present_over_time", "clamp", "clamp_min",
               "clamp_max", "time", "vector", "scalar", "abs", "ceil", "floor", "round",
               "sqrt", "exp", "ln", "log2", "log10", "label_replace", "label_join", "sort",
               "sort_desc", "histogram_quantile", "avg_over_time", "sum_over_time",
               "min_over_time", "max_over_time", "count_over_time", "last_over_time",
               "changes", "resets", "timestamp", "quantile_over_time", "stddev_over_time",
               "stdvar_over_time", "hour", "day_of_week", "day_of_month", "minute", "month",
               "year", "sgn"}
SETOPS = {"and", "or", "unless", "atan2"}
CMPOPS = {"==", "!=", "<", "<=", ">", ">="}
BINOPS = CMPOPS | {"+", "-", "*", "/", "%", "^"}
KEYWORDS = SETOPS | {"by", "without", "on", "ignoring", "group_left", "group_right", "bool", "offset"}
DURATION = r"(?:[0-9]+(?:ms|s|m|h|d|w|y))+"
TOK = re.compile(r"""
    (?P<ws>\s+)
  | (?P<str>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`[^`]*`)
  | (?P<comment>\#[^\n]*)
  | (?P<dur>""" + DURATION + r"""(?![A-Za-z0-9_.]))
  | (?P<num>(?:0[xX][0-9a-fA-F]+|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)(?![A-Za-z0-9_:.]))
  | (?P<sub>:\s*(?:""" + DURATION + r""")?\s*(?=\]))
  | (?P<id>[A-Za-z_:][A-Za-z0-9_:]*)
  | (?P<op>==|!=|<=|>=|=~|!~|[-+*/%^<>=,:])
  | (?P<open>[(\[{])
  | (?P<close>[)\]}])
""", re.X)


def metrics_of(expr):
    """-> (set of metric names, list of (rule, message) refusals)."""
    refusals = []
    if "__name__" in expr:
        refusals.append(("EXPR-NAME-MATCHER", "write the metric name, not a __name__ matcher"))
    toks, pos = [], 0
    while pos < len(expr):
        m = TOK.match(expr, pos)
        if not m:
            refusals.append(("EXPR-UNSUPPORTED", f"cannot read `{expr[pos:pos + 12].strip()}` (unsupported character)"))
            return set(), refusals
        pos = m.end()
        if m.lastgroup not in ("ws", "comment"):
            toks.append((m.lastgroup, m.group(0)))
    out, stack = set(), []
    prev = prev2 = ("", "")    # the two previous tokens
    prev_metric = False        # the previous token was a metric name
    pending_group = ""         # the kind of label list the next `(` opens
    agg_pending = False        # an aggregation name waits for its `(`
    after_agg = False          # the previous token was an aggregation name
    expect_operand = True      # an operand (not an operator) comes next
    mods = set()               # keywords that are legal right here
    for i, (kind, text) in enumerate(toks):
        nxt = toks[i + 1] if i + 1 < len(toks) else ("", "")
        top = stack[-1] if stack else ""
        bad = None
        n_expect, n_mods, n_after_agg = expect_operand, set(), False
        if top == "{":
            if kind == "id":
                pass
            elif kind == "op" and text in ("=", "!=", "=~", "!~", ","):
                pass
            elif kind == "str":
                pass
            elif kind == "close" and text == "}":
                stack.pop()
                n_expect = False
            else:
                bad = f"`{text}` inside a label matcher"
        elif top.startswith("g"):
            if kind == "id" or (kind == "op" and text == ","):
                pass
            elif kind == "close" and text == ")":
                stack.pop()
                n_expect = top != "g:post"   # `sum(x) by (l)` is followed by an operator
                if top == "g:on":
                    n_mods = {"group_left", "group_right"}
            else:
                bad = f"`{text}` inside a grouping label list"
        elif top == "[":
            if kind == "dur" or (kind == "sub" and prev[0] == "dur"):
                pass
            elif kind == "close" and text == "]":
                stack.pop()
                n_expect = False
            else:
                bad = f"`{text}` inside a range"
        elif kind == "id":
            low = text.lower()
            if low in ("inf", "nan"):
                n_expect = False
            elif low in KEYWORDS:   # PromQL keywords are case-insensitive: `a AND b`, `m OFFSET 5m`
                if low in mods:
                    if low in ("by", "without", "on", "ignoring"):
                        if nxt != ("open", "("):
                            bad = f"`{text}` without a label list"
                        elif low in ("on", "ignoring"):
                            pending_group = "g:on"
                        else:
                            pending_group = "g:pre" if after_agg else "g:post"
                    elif low in ("group_left", "group_right"):
                        if nxt == ("open", "("):
                            pending_group = "g:grp"
                        n_expect = True
                    else:   # bool
                        n_expect, n_mods = True, {"on", "ignoring"}
                elif low in SETOPS and not expect_operand:
                    n_expect, n_mods = True, {"on", "ignoring"}
                elif low == "offset" and not expect_operand and (prev_metric or prev[0] == "close"):
                    n_expect = False
                elif expect_operand:
                    bad = (f"`{text}` where an operand is expected: a metric named like a PromQL "
                           "keyword is refused (it cannot be told from the operator)")
                else:
                    bad = f"keyword `{text}` in a position PromQL does not allow"
            elif (text in FUNCS or low in AGG) and (nxt == ("open", "(") or (low in AGG and nxt[0] == "id" and nxt[1].lower() in ("by", "without"))):
                # Prometheus's lexer lowercases keywords, and the aggregation operators are
                # keywords (`SUM by (x) (m)` parses); function names are looked up exactly
                # (`Rate(m[5m])` is an unknown function), so only AGG is matched in any case
                n_expect, n_after_agg = True, low in AGG
                if low in AGG:
                    agg_pending = True
                    n_mods = {"by", "without"}
            elif nxt == ("open", "("):
                bad = f"unknown function `{text}(`"
            else:
                out.add(text)
                n_expect = False
                prev_metric = True
                prev2, prev = prev, (kind, text)
                expect_operand, mods, after_agg = n_expect, n_mods, False
                continue
        elif kind in ("num", "str"):
            n_expect = False
        elif kind == "dur":
            if not ((prev[0] == "id" and prev[1].lower() == "offset") or (prev == ("op", "-") and prev2[0] == "id" and prev2[1].lower() == "offset")):
                bad = f"duration `{text}` outside a range and `offset`"
            n_expect = False
        elif kind == "sub":
            bad = "`:` outside a range"
        elif kind == "op":
            if text in BINOPS and not expect_operand:
                n_expect, n_mods = True, {"on", "ignoring"} | ({"bool"} if text in CMPOPS else set())
            elif text in BINOPS or text == ",":
                n_expect = True
        elif kind == "open":
            if text == "{":
                if not prev_metric:
                    bad = "a selector with no metric name before `{`"
                else:
                    stack.append("{")
            elif text == "[":
                if prev_metric or prev == ("close", "}") or prev == ("close", ")"):
                    stack.append("[")
                else:
                    bad = "`[` that does not follow a selector"
            else:
                if pending_group:
                    stack.append(pending_group)
                elif agg_pending:
                    stack.append("A")
                    agg_pending = False
                else:
                    stack.append("(")
                pending_group = ""
                n_expect = True
        elif kind == "close":
            if text == ")" and top in ("(", "A"):
                stack.pop()
                n_expect = False
                if top == "A":
                    n_mods = {"by", "without"}
            else:
                bad = f"unbalanced `{text}`"
        if bad:
            refusals.append(("EXPR-UNSUPPORTED", bad))
            return out, refusals
        prev_metric = False
        prev2, prev = prev, (kind, text)
        expect_operand, mods, after_agg = n_expect, n_mods, n_after_agg
    if stack:
        refusals.append(("EXPR-UNSUPPORTED", "unbalanced brackets"))
    return out, refusals


# ---- the alert rules --------------------------------------------------------------
rules_doc = load(os.path.join(obs, "alerts", "postgres.rules.yml"))
alerts = {}  # name -> rule
for g in (rules_doc or {}).get("groups") or []:
    for r in g.get("rules") or []:
        if isinstance(r, dict) and "record" in r:
            fail("RECORDING-RULE", f"recording rule `{r['record']}`: recording rules are not checked yet")
        elif isinstance(r, dict) and "alert" in r:
            if r["alert"] in alerts:
                fail("ANNOTATION", f"alert {r['alert']} is defined twice")
            alerts[r["alert"]] = r
        else:
            fail("RECORDING-RULE", "a rule that is neither `alert:` nor `record:` is not checked")
if not alerts:
    die("postgres.rules.yml defines no alert")

used = set()
runbook = read(os.path.join(obs, "RUNBOOK.md"))
anchors = set()
for m in re.finditer(r"^#{1,6}\s+(.+?)\s*$", runbook, re.M):
    anchors.add(re.sub(r"[^\w\- ]", "", m.group(1).lower()).replace(" ", "-"))

SEVERITIES = {"critical", "warning", "info"}
for name, r in alerts.items():
    ms, refused = metrics_of(str(r.get("expr", "")))
    used |= ms
    for rule_name, why in refused:
        fail(rule_name, f"alert {name}: {why}")
    for m in sorted(ms - set(required)):
        fail("UNKNOWN-METRIC", f"alert {name} uses `{m}`, which is not in required-metrics.txt")
    labels = r.get("labels") or {}
    ann = r.get("annotations") or {}
    if labels.get("severity") not in SEVERITIES:
        fail("ANNOTATION", f"alert {name} has no severity label in {sorted(SEVERITIES)}")
    for k in ("summary", "description", "runbook"):
        if not str(ann.get(k, "")).strip():
            fail("ANNOTATION", f"alert {name} has no {k} annotation")
    for where, vals in (("label", labels), ("annotation", ann)):
        for k, v in vals.items():
            if re.search(r"\{\{[^}]*?(?<![.\w$])query\b", str(v), re.S):
                fail("ANNOTATION", f"alert {name}: {where} {k} uses a `query` template, an expression nothing here can check")
    rb = str(ann.get("runbook", "")).strip()
    if rb:
        path, _, anchor = rb.partition("#")
        if not path.endswith("RUNBOOK.md") or not anchor or anchor not in anchors:
            fail("RUNBOOK-ANCHOR", f"alert {name}: runbook `{rb}` does not point at a heading of RUNBOOK.md")

for m, dash in sorted(required.items()):
    if m not in used and not dash:
        fail("ORPHAN-METRIC", f"required metric `{m}` is used by no alert and is not marked dashboard-only")

# `promtool check rules` catches what the extractor cannot: a syntactically broken expression.
promtool = shutil.which("promtool")
if promtool:
    try:
        pr = subprocess.run([promtool, "check", "rules", os.path.join(obs, "alerts", "postgres.rules.yml")],
                            capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        die(f"promtool could not run ({e})")
    if pr.returncode != 0:
        fail("PROMTOOL-CHECK", "promtool check rules failed: " + " ".join((pr.stdout + pr.stderr).split())[:300])
else:
    print("parity-check: promtool is not on PATH, `promtool check rules` skipped")

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

# exporter-allowlist.txt: the one list db-scrape-test.sh applies to the RUNNING container.
allow = {"arg": set(), "env": {}, "image-env": set(), "entrypoint": set(), "mount": set(), "secret-file": {}}
SHAPE = {"mount": 2, "secret-file": 2}   # words after the kind; every other kind carries one
for n, raw in enumerate(read(os.path.join(obs, "exporter-allowlist.txt")).splitlines(), 1):
    line = raw.partition("#")[0].strip()
    if not line:
        continue
    kind, _, value = line.partition(" ")
    value = value.strip()
    parts = value.split()
    if kind not in allow or len(parts) != SHAPE.get(kind, 1):
        fail("ALLOWLIST", f"exporter-allowlist.txt:{n}: `{line}` is not `<kind> <value>` of a known kind")
        continue
    if kind == "env":
        name, eq, val = value.partition("=")
        if not eq or not name:
            fail("ALLOWLIST", f"exporter-allowlist.txt:{n}: an `env` line is `NAME=VALUE` (the value is pinned too)")
        elif name in allow["env"]:
            fail("ALLOWLIST", f"exporter-allowlist.txt:{n}: `{name}` is pinned twice")
        else:
            allow["env"][name] = val
    elif kind == "mount":
        allow["mount"].add((parts[0], parts[1]))
    elif kind == "secret-file":
        allow["secret-file"][parts[0]] = parts[1]
    else:
        allow[kind].add(value)
# The allowlist itself may never name a way to carry a connection other than the
# overlay's: those are the downgrades it exists to refuse.
for a in sorted(allow["arg"]):
    if a.startswith(("--datasource", "--config.file", "--web.config.file", "--extend.query-path",
                     "--auto-discover-databases", "--collector.stat_statements.include_query")):
        fail("ALLOWLIST", f"exporter-allowlist.txt allows the flag `{a}`, a way to change the connection or export query text")
for v in sorted(set(allow["env"]) | allow["image-env"]):
    if v in ("DATA_SOURCE_NAME", "DATA_SOURCE_URI_FILE", "DATA_SOURCE_PASS", "DATA_SOURCE_USER_FILE") or v.startswith(("PG", "PG_EXPORTER_", "LD_")):
        fail("ALLOWLIST", f"exporter-allowlist.txt allows the variable `{v}`, a way to change the connection or to load code")
for v in sorted(allow["env"]):
    if "$" in allow["env"][v]:
        fail("ALLOWLIST", f"exporter-allowlist.txt: the value pinned for `{v}` contains `$` (compose would substitute it)")
for v in sorted(allow["entrypoint"]):
    if v != "/bin/postgres_exporter":
        fail("ALLOWLIST", f"exporter-allowlist.txt allows the entrypoint `{v}`, not the image's /bin/postgres_exporter")
for src, dst in sorted(allow["mount"]):
    if src.startswith("secret:") and src[7:] not in allow["secret-file"]:
        fail("ALLOWLIST", f"exporter-allowlist.txt: `mount {src}` has no `secret-file {src[7:]} <file>` line pinning where the secret comes from")

ov = load(overlay_path)
svc = ((ov or {}).get("services") or {}).get("exporter") if isinstance(ov, dict) else None
if not isinstance(svc, dict):
    die(f"{overlay_path} has no service `exporter`")

# Everything compose could take from somewhere else than THIS file: another file, the host
# environment, a `.env`. The service is judged as written; these refusals keep it that way.
overlay_dir = os.path.dirname(overlay_path)


def nonregular(path):
    # a directory, or a symlink to nothing: it cannot be read as a compose file
    return os.path.isdir(path) or (os.path.lexists(path) and not os.path.exists(path))


def exists(path):
    try:
        open(path, "rb").close()
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return True


if exists(os.path.join(overlay_dir, ".env")):
    fail("OVERLAY-DOTENV", "a `.env` file sits beside the compose files: compose loads it on its own and substitutes `${VAR}` from it, so the exporter could connect elsewhere (delete it, or pass variables with an explicit --env-file)")
for k in sorted(str(k) for k in ov):
    if k == "include":
        fail("OVERLAY-INCLUDE", "the overlay has a top-level `include:` (another file this check does not read)")
    elif k not in ("services", "name") and not k.startswith("x-"):
        fail("OVERLAY-TOPLEVEL", f"the overlay defines a top-level `{k}:`; it may only add the service (a redefined secret or volume changes what the exporter mounts)")
    if k in ("secrets", "volumes", "configs", "networks") and "$" in str(ov.get(k)):
        fail("OVERLAY-INTERPOLATION", f"top-level `{k}:` contains `$` (compose substitutes it from the host environment or `.env`)")
for k in sorted(str(k) for k in ov["services"]):
    if k != "exporter":
        fail("OVERLAY-SERVICES", f"the overlay defines the service `{k}`; it may only add `exporter`")
if "extends" in svc:
    fail("OVERLAY-EXTENDS", "exporter uses `extends:` (the service is then built from a file this check does not read)")
for k in ("extra_hosts", "dns", "dns_search", "dns_opt", "links", "external_links", "network_mode", "networks"):
    if k in svc:
        fail("OVERLAY-NETWORK", f"exporter sets `{k}`, which can re-point the name `db` the connection uses")
for k in ("command", "environment", "volumes", "secrets", "entrypoint", "image", "user"):
    if "$" in str(svc.get(k)):
        fail("OVERLAY-INTERPOLATION", f"exporter `{k}` contains `$` (compose substitutes it from the host environment or `.env`)")

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
if not isinstance(svc.get("command") or [], list):
    fail("OVERLAY-ARGS", "exporter command must be a list of arguments")
cmd = [str(c) for c in (svc.get("command") if isinstance(svc.get("command"), list) else [])]
for c in cmd:
    if c not in allow["arg"]:
        fail("OVERLAY-ARGS", f"exporter command carries `{c.partition('=')[0]}` (value hidden), which is not in exporter-allowlist.txt as written (any other flag, or another value, can change the connection)")
if "entrypoint" in svc:
    fail("OVERLAY-ENTRYPOINT", "exporter must not override the image's entrypoint")
for flag in ("--collector.stat_statements", "--collector.stat_checkpointer",
             "--collector.database_wraparound", "--collector.long_running_transactions"):
    if flag not in cmd:
        fail("OVERLAY-COLLECTORS", f"exporter command lacks {flag}, which a required metric needs")
if "--collector.stat_statements.include_query" in cmd:
    fail("OVERLAY-COLLECTORS", "exporter must not export query text (include_query)")
# The connection: non-secret settings from an env file, the password only as a file. Every
# entry (env_file content AND `environment:`, mapping and list forms) must equal an allow-listed
# NAME=VALUE exactly; a name without a value is taken from the host by compose, so it never equals.
env_entries = []   # (name, value or None, where)
efs = svc.get("env_file") or []
for ef in [efs] if isinstance(efs, (str, dict)) else efs:
    efp = str(ef.get("path", "") if isinstance(ef, dict) else ef)
    if "$" in efp:
        fail("OVERLAY-INTERPOLATION", "exporter `env_file` path contains `$`")
        continue
    p = os.path.normpath(os.path.join(overlay_dir, efp))
    for raw in read(p).splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            if "$" in line:
                fail("OVERLAY-INTERPOLATION", f"exporter `env_file` contents contain `$` on the line of `{line.partition('=')[0].strip()}` (value hidden; compose substitutes it from the host environment or `.env`)")
            k, eq, v = line.partition("=")
            env_entries.append((k.strip(), v.strip() if eq else None, "env_file"))
env = svc.get("environment") or {}
if isinstance(env, list):
    for e in env:
        k, eq, v = str(e).partition("=")
        env_entries.append((k, v if eq else None, "environment"))
else:
    for k, v in env.items():
        env_entries.append((str(k), None if v is None else str(v), "environment"))
env_vars = {k: v for k, v, _ in env_entries if v is not None}
for k in sorted({k for k, _, _ in env_entries} - set(allow["env"])):
    fail("OVERLAY-ENV", f"exporter defines the variable {k}, which is not in exporter-allowlist.txt (it can change the connection)")
for k, v, where in env_entries:
    if k in allow["env"] and v != allow["env"][k]:
        fail("OVERLAY-ENV-VALUE", f"exporter variable {k} ({where}) is not the value pinned in exporter-allowlist.txt (value hidden)")
uri = env_vars.get("DATA_SOURCE_URI", "")
qs = parse_qs(uri.partition("?")[2], keep_blank_values=True)
# An independent FLOOR under the allow-list (a consistent edit of allow-list + env file must not
# move the exporter): host `db`, port 5432, a plain database name, and a query string of exactly
# the two TLS parameters, each once, and nothing else (`user`, `options`, `host`, a repeat ...).
m_uri = re.fullmatch(r"db:5432/([A-Za-z_][A-Za-z0-9_]*)\?(.*)", uri, re.S)
if not m_uri:
    fail("OVERLAY-URI", "DATA_SOURCE_URI must be exactly db:5432/<identifier>?<query> (host db, port 5432)")
elif sorted(m_uri.group(2).split("&")) != ["sslmode=verify-full", "sslrootcert=/tls/server.crt"]:
    fail("OVERLAY-URI", "DATA_SOURCE_URI's query may carry only sslmode=verify-full and sslrootcert=/tls/server.crt, each once")
if qs.get("sslmode") != ["verify-full"]:
    fail("OVERLAY-TLS", f"DATA_SOURCE_URI must carry exactly one sslmode, verify-full (found {qs.get('sslmode')})")
rootcert = qs.get("sslrootcert") or []
if len(rootcert) != 1 or not rootcert[0].strip():
    fail("OVERLAY-TLS", "DATA_SOURCE_URI must carry exactly one non-empty sslrootcert")
for k in ("cpus", "mem_limit", "pids_limit"):
    if not svc.get(k):
        fail("OVERLAY-LIMITS", f"exporter must set {k}")
tls_ro = False
for v in svc.get("volumes") or []:
    if isinstance(v, dict):
        target, ro = str(v.get("target", "")), v.get("read_only") is True
    else:
        parts = str(v).split(":")
        target, ro = (parts[1] if len(parts) > 1 else ""), "ro" in parts[2:]
    if rootcert and target and rootcert[0].startswith(target.rstrip("/") + "/") and ro:
        tls_ro = True
# Mounts must equal the shipped set EXACTLY, source -> destination: a config file mounted in
# could carry auth_modules, and the password secret must be the MONITOR's.
pairs = []   # (source, destination)
for v in svc.get("volumes") or []:
    if isinstance(v, dict):
        kind_, src_, dst_ = str(v.get("type", "volume")), str(v.get("source", "")), str(v.get("target", ""))
        pairs.append((("bind:" if kind_ == "bind" else f"{kind_}:") + src_, dst_))
    else:
        parts = str(v).split(":")
        src_, dst_ = (parts[0], parts[1]) if len(parts) > 1 else ("", parts[0])
        pairs.append((("bind:" if src_.startswith((".", "/", "~")) or "/" in src_ else "volume:") + src_, dst_))
for sc in svc.get("secrets") or []:
    if isinstance(sc, dict):
        tgt_ = str(sc.get("target") or sc.get("source", ""))   # a relative target lives under /run/secrets
        pairs.append(("secret:" + str(sc.get("source", "")), tgt_ if tgt_.startswith("/") else "/run/secrets/" + tgt_))
    else:
        pairs.append(("secret:" + str(sc), "/run/secrets/" + str(sc)))
dests = {d for _, d in pairs}
want_dests = {d for _, d in allow["mount"]}
if svc.get("configs") or svc.get("volumes_from"):
    fail("OVERLAY-MOUNTS", "exporter must not use configs or volumes_from (a mounted file can change the connection)")
if dests != want_dests:
    fail("OVERLAY-MOUNTS", f"exporter mounts {sorted(dests - want_dests)} that exporter-allowlist.txt does not list; missing {sorted(want_dests - dests)}")
for src_, dst_ in pairs:
    if dst_ in want_dests and (src_, dst_) not in allow["mount"]:
        want_src = sorted(s_ for s_, d_ in allow["mount"] if d_ == dst_)
        fail("OVERLAY-MOUNT-SOURCE", f"the mount at {dst_} comes from `{src_}`, exporter-allowlist.txt says {want_src}")
# The top-level definitions behind those mounts live in compose.yml (the overlay has none).
base_path = os.path.join(overlay_dir, "compose.yml")
base = load(base_path)
base = base if isinstance(base, dict) else {}
for src_, _ in pairs:
    kind_, _, name_ = src_.partition(":")
    if kind_ == "volume":
        if "$" in str((base.get("volumes") or {}).get(name_)):
            fail("OVERLAY-INTERPOLATION", f"compose.yml top-level volume `{name_}` contains `$`")
    elif kind_ == "secret" and name_ in allow["secret-file"]:
        entry = (base.get("secrets") or {}).get(name_)
        got = str(entry.get("file")) if isinstance(entry, dict) and "file" in entry else None
        if got != allow["secret-file"][name_] or (isinstance(entry, dict) and set(entry) != {"file"}):
            fail("OVERLAY-MOUNT-SOURCE", f"compose.yml top-level secret `{name_}` is not `file: {allow['secret-file'][name_]}` as exporter-allowlist.txt pins it (it must be the monitor's own password file)")
# The exporter lives ONLY in the overlay: compose merges a service across files key by key, so a
# fragment of it in the base (or an auto-merged file) would add keys this check never reads.
ov_services = {str(k) for k in ov["services"]}
# EVERY compose-named file in db/ (the overlay aside) is judged by one rule: it may say nothing about a
# service the overlay defines, extend one, or include another file. A CLOSED list of compose files may
# exist at all: a new one is a visible change to this list, not a silent extra merge source.
COMPOSE_CLOSED = ("compose.yml", "compose.timescale.yml", "compose.observability.yml")
AUTO_MERGED = ("compose.override.yml", "compose.override.yaml", "docker-compose.override.yml",
               "docker-compose.override.yaml", "docker-compose.yml", "docker-compose.yaml", "compose.yaml")
ov_name = os.path.basename(overlay_path)
try:
    listing = sorted(os.listdir(overlay_dir))
except OSError:
    listing = []
for name_ in AUTO_MERGED:
    if name_ in listing or exists(os.path.join(overlay_dir, name_)):
        fail("OVERLAY-OVERRIDE-FILE", f"`{name_}` sits beside the compose files: compose merges or picks it up on its own, outside this check (delete it)")
for name_ in listing:
    if not re.fullmatch(r"(docker-)?compose.*\.ya?ml", name_, re.I) or name_ == ov_name:
        continue
    if name_ not in COMPOSE_CLOSED and name_ not in AUTO_MERGED:
        fail("COMPOSE-UNKNOWN-FILE", f"`{name_}` is a compose file this check does not know (the closed list is {', '.join(COMPOSE_CLOSED)}); add it to the list in parity-check.sh and the README, or delete it")
    if nonregular(os.path.join(overlay_dir, name_)):
        fail("COMPOSE-UNKNOWN-FILE", f"`{name_}` is not a regular file (a directory or a dangling link named like a compose file): compose would try to read it; delete it")
        continue
    cf = load(os.path.join(overlay_dir, name_))
    cf = cf if isinstance(cf, dict) else {}
    if "include" in cf:
        fail("BASE-EXPORTER", f"{name_} has a top-level `include:` (another file this check does not read)")
    csvc = cf.get("services") if isinstance(cf.get("services"), dict) else {}
    for k, v in csvc.items():
        if str(k) in ov_services:
            fail("BASE-EXPORTER", f"{name_} defines the service `{k}`, which the overlay defines: compose would merge the two and this check reads only the overlay (define it in one place)")
        ext = v.get("extends") if isinstance(v, dict) else None
        if ext is not None and (str(ext.get("service", "") if isinstance(ext, dict) else ext) in ov_services or "observability" in str(ext)):
            fail("BASE-EXPORTER", f"{name_} service `{k}` extends the overlay or one of its services")
# COMPOSE MENTIONS, by an ALLOW-LIST of command shapes. A deny-list of the spellings of "use this
# file" (`--file`, `--file=x`, `-fx`, a `\` continuation, `--profile x -f`, `COMPOSE_FILE=`,
# `docker-compose`, `podman compose`...) always misses one. So: join `\` continuations; a "mention" is
# any logical line where `compose` follows docker/podman/nerdctl, or the token `docker-compose`, or a
# COMPOSE_FILE / COMPOSE_ENV_FILES / COMPOSE_PROFILES / COMPOSE_PROJECT_NAME name; every mention must be
#     docker compose( -f <bare file name on the closed list>){0,3}( <subcommand and its arguments>)?
# (the `-f` in exactly that spelling, distinct files, no path, no quotes, no `=`; the rest has no token
# starting with -f, --file, --project-directory, --profile, --env-file, --project-name or -p), or be one
# of the two shapes the container scripts build their command with (pinned below). Anything else is a
# COMPOSE-DOC-FILE finding naming file:line and the offending token.
DOC_SOURCES = [("README.md", os.path.join(overlay_dir, "..", "README.md")),
               ("observability/RUNBOOK.md", None)]
DOC_SOURCES += [(n_, os.path.join(overlay_dir, n_)) for n_ in listing if re.fullmatch(r"(docker-)?compose.*\.ya?ml", n_, re.I) and not nonregular(os.path.join(overlay_dir, n_))]
SCRIPT_SOURCES = [("scripts/db-scrape-test.sh", "../scripts/db-scrape-test.sh"), ("scripts/db-bootstrap-test.sh", "../scripts/db-bootstrap-test.sh")]
DOC_SOURCES += [(l_, os.path.join(overlay_dir, r_)) for l_, r_ in SCRIPT_SOURCES]
COMPOSE_MENTION = re.compile(r"(?<![\w-])(?:(?:docker|podman|nerdctl)\s+compose\b|docker-compose(?=\s|$))", re.I)
COMPOSE_ENVNAME = re.compile(r"COMPOSE_(?:FILE|ENV_FILES|PROFILES|PROJECT_NAME)")
SCRIPT_PINS = (  # the shell constructions the two scripts build their command with, literally
    re.compile(r'dc\(\) \{ docker compose -p "\$proj" --env-file "\$envf" "\$\{files\[@\]\}" "\$@"; \}\Z'),
    re.compile(r'DC=\(docker compose -p "\$proj" --env-file "\$envf"(?: -f "\$dbdir/[^"\s]+")+\)\Z'),
)
BAD_FLAG_PREFIX = ("-f", "--file", "--project-directory", "--profile", "--env-file", "--project-name", "-p")


def logical_lines(raw):
    out, cur, start = [], None, 0
    for n_, line_ in enumerate(raw.split("\n"), 1):
        if cur is None:
            start = n_
            cur = ""
        else:
            line_ = re.sub(r"^\s*(?:#\s?)?", "", line_)   # the next line of a comment continuation
        if line_.rstrip().endswith("\\"):
            cur += line_.rstrip()[:-1] + " "
            continue
        out.append((start, cur + line_))
        cur = None
    if cur is not None:
        out.append((start, cur))
    return out


def judge_mention(tail):
    """None when the command is an accepted shape, else (what is wrong, the offending token)."""
    toks = tail.replace("[", " ").replace("]", " ").split()
    if toks[0].lower() != "docker" or len(toks) < 2 or toks[1].lower() != "compose":
        return ("only `docker compose` is a documented command (not docker-compose, podman, nerdctl)", toks[0])
    i, seen = 2, []
    while i < len(toks) and toks[i] == "-f":
        if i + 1 >= len(toks):
            return ("`-f` without a file name", "-f")
        f_ = toks[i + 1]
        if "/" in f_ or f_.startswith((".", "~", "$")):
            return ("write the bare file name (no path, no ./)", f_)
        if f_ not in COMPOSE_CLOSED:
            return ("NOTCLOSED", f_)
        if f_ in seen:
            return ("the same -f file twice", f_)
        seen.append(f_)
        i += 2
    if len(seen) > 3:
        return ("more than three -f files", "-f")
    for t_ in toks[i:]:
        u_ = t_.strip("\"'")
        if u_.startswith(BAD_FLAG_PREFIX):
            return ("a flag that names a file, directory, profile or project is not a documented shape (only `-f <closed-list file>` right after `docker compose`)", u_)
    return None


for label_, p_ in DOC_SOURCES:
    if p_ is None:
        raw_ = runbook
    elif exists(p_):
        raw_ = read(p_)
    else:
        continue
    is_script_ = label_.startswith("scripts/")
    for ln_, text_ in logical_lines(raw_):
        env_ = COMPOSE_ENVNAME.search(text_)
        if env_:
            fail("COMPOSE-DOC-FILE", f"{label_}:{ln_} mentions `{env_.group(0)}`, which can name a compose file outside the closed list; the documented shape is `docker compose [-f <file>]... <subcommand>`")
            continue
        if is_script_ and any(pin_.match(text_.strip()) for pin_ in SCRIPT_PINS):
            continue
        for m_ in COMPOSE_MENTION.finditer(text_):
            tail_ = re.split(r"[`);|&]|\s#", text_[m_.start():], maxsplit=1)[0]
            bad_ = judge_mention(tail_)
            if bad_ is None:
                continue
            why_, tok_ = bad_
            if why_ == "NOTCLOSED":
                fail("COMPOSE-DOC-FILE", f"{label_} {'runs' if is_script_ else 'documents'} `docker compose -f {tok_}`, which is not on the closed list ({', '.join(COMPOSE_CLOSED)}) (line {ln_})")
            else:
                fail("COMPOSE-DOC-FILE", f"{label_}:{ln_} `{tok_}`: {why_}")
for label_, rel_ in (("scripts/db-scrape-test.sh", "../scripts/db-scrape-test.sh"), ("scripts/db-bootstrap-test.sh", "../scripts/db-bootstrap-test.sh")):
    p_ = os.path.join(overlay_dir, rel_)
    if exists(p_):
        for f_ in re.findall(r'-f\s+"\$dbdir/([^"]+)"', read(p_)):
            if f_ not in COMPOSE_CLOSED:
                fail("COMPOSE-DOC-FILE", f"{label_} runs `docker compose -f {f_}`, which is not on the closed list ({', '.join(COMPOSE_CLOSED)})")
if not tls_ro:
    fail("OVERLAY-TLS-MOUNT", "the directory holding sslrootcert must be mounted read-only into the exporter")
if env_vars.get("DATA_SOURCE_PASS_FILE", "") != "/run/secrets/db_monitor_password":
    fail("OVERLAY-SECRET", "DATA_SOURCE_PASS_FILE must be exactly /run/secrets/db_monitor_password, the monitor's own password file")
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
