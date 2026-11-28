#!/usr/bin/env python3
"""monorepo_check.py -- the monorepo root's repo.yaml reader and static settings check.

  monorepo_check.py check ROOT              settings check; one `file:line: RULE message` per finding
  monorepo_check.py units ROOT TARGET       TSV `id kind path has-target(1|0) mandatory(1|0)` per unit, for the runner
  monorepo_check.py validate FILE           validate one repo.yaml against docs/repo-schema.md

Exit: 0 clean - 1 findings - 2 cannot run (PyYAML missing, repo.yaml unreadable for `units`).
Reads text/JSON/YAML and asks `git ls-files` for a tracked node_modules/. No network, no pnpm.
"Unit has target T" (service, database) is make's own verdict by EXIT STATUS, nothing printed is read.
The inspection asks make about a unit in a fixed order, by EXIT STATUS only (nothing printed is read), and every question after the first carries -o <each makefile make read> (--assume-old: no makefile is remade by it, so a makefile being remade can never be the thing that answers). 1) The list pass, always first: make -C <unit> -q -f <unit makefile> -f <list makefile> <random name>; the module-owned list makefile, written into a private temp dir, records $(MAKEFILE_LIST) in a file by a parse-time $(shell printf ...) and declares .PHONY: <random control name> with no rule; the exit status of the pass is not used, and a list that is empty, or names something that does not exist as a path from the unit directory (a name with a space or a newline splits into words that do not), leaves the unit unanswerable: error, fail closed (a name that does exist is accepted, for example ../common.mk, which is also what -o names). The list pass is the one place where an included makefile that has a rule may be remade (a parse-time $(shell ...) runs there too). 2) The control question: make -C <unit> -q -f <unit makefile> -f <list makefile> -o <each listed makefile> <control name>; it answers 0 only when every makefile make read has settled; non-zero or a timeout (a makefile that make still wants to remake and cannot pin: an included makefile that is missing and whose rule does not create it, or a makefile rule that never converges) is state error, fail closed: the unit's makefiles do not settle. 3) make -C <unit> -q -o ... <target>; only if that answers 0 does it ask make -C <unit> -q -B -o ... <target> (the same question with every file considered out of date, so the verdict does not depend on whether the unit's outputs are fresh); only if the last question asked answered 2 does it ask make -C <unit> -n -o ... <target>. The random-name probe for a catch-all (a %: rule or .DEFAULT:) is asked as question 3 too, with -o. Verdict: -q 1 = present; -q 0 and -q -B 1 = present (the target was only up to date), unless a file or directory named like the target sits beside the Makefile and the rule is not .PHONY (the real run says up to date: idle, with a .PHONY hint); -q -B 0 = idle (nothing to run even with everything out of date); an answer of 2 asks -n: 0 = present, 2 = missing. A question that times out is state error (the finding says: timed out), and once one question for a unit timed out nothing more is asked for that unit in this run: a unit costs at most 5 s for the list pass plus one timeout (5 s for the control, 20 s for another question). Under -q make executes the recipe lines marked + or containing $(MAKE) of the target and of its prerequisites, each recipe at most up to its first line that is neither (an upper bound: it stops at the first out-of-date prerequisite whose recipe starts with a plain line; a file target that a + line just created may be deleted again). The -B question executes the same classes of lines, passed on to sub-makes in question mode as well, but MORE of them, since nothing counts as up to date. Under -n make walks the WHOLE recipe, so every + / $(MAKE) line of the target and of all its out-of-date prerequisites runs (a sub-make in dry-run mode runs its + lines and not its plain lines). Apart from the remake in the list pass and from -n, no plain recipe line runs under any question. The judgment is the same on GNU make 3.81 and 4.3 for every shape measured, and the same before and after a real run (an included makefile that has a rule, with no rule that runs anything for the target, is idle, and so is verify: gen.mk with gen.mk such an included makefile; the same unit with verify: build or a $(MAKE) build line is present; an included makefile that a rule creates, or a generated makefile that carries the target, is judged like a plain one), except: a recipe made only of + / $(MAKE) lines that run nothing (verify: with +true, +@echo ok, or $(MAKE) check-fast with check-fast: ;): 3.81 answers 1 to -q (present), 4.3 answers 0 to -q and to -q -B (idle, fail-closed: such a recipe verifies nothing); verify: +false differs too (3.81: -q 2 and -n 2 = missing; 4.3: -q 1 = present) and on both the root make verify ends non-zero; an included makefile that is missing and whose rule does not create it (-include gen.mk with gen.mk: ; @true) is error on 3.81 for every target (the control does not settle) and, on 4.3, judged by the target alone (idle without a recipe, present with one). What runs during the inspection was measured on GNU make 3.81 and 4.3. The units are the repository's own code,
trusted as `make check-fast` trusts them. The root Makefile and the check read the SAME function.
"""
import atexit
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    print("FAIL PARSER: PyYAML is not importable -- repo.yaml and pnpm-workspace.yaml cannot be parsed, "
          "so nothing is proven")
    sys.exit(2)

KINDS = {"service": ("services", ("go", "rust", "python")),
         "app": ("apps", ("ts",)),
         "package": ("packages", ("ts",)),
         "database": (None, ("sql",))}
ID_RX = re.compile(r"[a-z][a-z0-9-]*")
NAME_RX = re.compile(r"[a-z0-9][a-z0-9._-]*")
# ---- the allow-lists. Everything the root accepts is listed here; anything else is a finding.
# Top-level keys of pnpm-workspace.yaml: structure, then exactly the settings this module sets.
WS_STRUCT_KEYS = ("packages", "catalog", "catalogs")
REQUIRED_SETTINGS = {"catalogMode": "strict", "engineStrict": True, "strictPeerDependencies": True,
                     "strictDepBuilds": True, "blockExoticSubdeps": True, "trustPolicy": "no-downgrade"}
SETTING_KEYS = tuple(REQUIRED_SETTINGS) + ("onlyBuiltDependencies", "minimumReleaseAge")
ALLOWED_WS_KEYS = frozenset(WS_STRUCT_KEYS + SETTING_KEYS)
MIN_RELEASE_AGE = 1440  # minutes; the shipped value is 10080 (seven days), the floor is pnpm's own default
WS_GLOBS = ("apps/*", "packages/*")
# The values the shipped root package.json carries; the selftest asserts these equal that file.
ENGINES_EXPECTED = {"node": ">=24 <27", "pnpm": ">=10.34.3 <13"}
PM_RX = re.compile(r"pnpm@\d+\.\d+\.\d+(?:\+sha512\.[0-9a-f]+)?")
ENGINES_RX = re.compile(r">=(\d+) <(\d+)")
PKG_NAME_RX = re.compile(r"(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*")
EXACT_VERSION_RX = re.compile(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?")
CATALOG_REF_RX = re.compile(r"catalog:(?:[A-Za-z0-9_.-]*)")
REASON_RX = re.compile(r"#\s*reason:\s*\S")
DEP_FIELDS = ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies")
# package.json: an ALLOW-list of top-level keys, one for the root manifest and one for workspace packages.
# Sources: the root list is the shipped root package.json (name, private, packageManager, engines, scripts) plus the
# four dependency fields (their VALUES are rule-checked); the workspace list is the manifests of the design-system
# packages (name, version, private, type, description, engines, exports, files, scripts, dependencies,
# devDependencies) plus the plain npm metadata and entry-point keys with no resolution or install-policy effect.
# `publishConfig`, `devEngines`, `dependenciesMeta`, `workspaces`, `config`, `imports` are not needed by a shipped
# manifest and are refused with every other key.
ROOT_PKG_KEYS = frozenset(("name", "private", "packageManager", "engines", "scripts") + DEP_FIELDS)
WORKSPACE_PKG_KEYS = frozenset(("name", "version", "private", "type", "description", "license", "main", "module",
                                "types", "exports", "files", "sideEffects", "scripts", "engines", "packageManager",
                                "bin", "repository", "keywords", "author", "peerDependenciesMeta") + DEP_FIELDS)
# These five get the more specific `supply-override` message (they are the known second homes for versions).
REFUSED_PKG_FIELDS = ("resolutions", "overrides", "pnpm", "bundledDependencies", "bundleDependencies")
# Files whose EXISTENCE anywhere in the repository is refused (compared lower-case), and the rule that says so.
LOCKFILE_NAMES = frozenset(("package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "bun.lock", "bun.lockb",
                            "deno.lock"))
OTHER_REFUSED_NAMES = frozenset((".npmrc", "package.yaml", "package.json5"))
PNPMFILE_RX = re.compile(r"\.?pnpmfile\..*")
SKIP_DIRS = frozenset(("node_modules", ".git"))
# The targets a unit of each kind MUST have; the runner fails (never skips) when one is missing.
MANDATORY = {"service": ("check-fast", "verify"), "app": ("test",), "package": ("test",), "database": ()}


class Loader(yaml.SafeLoader):
    pass


def _mapping(loader, node, deep=False):
    seen = set()
    for k, _ in node.value:
        key = loader.construct_object(k, deep=True)
        if key in seen:
            raise yaml.YAMLError("duplicate key %r (line %d)" % (key, k.start_mark.line + 1))
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


Loader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)


def load_yaml(path):
    """-> (data, error). One document, no duplicate keys."""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        return None, "unreadable: %s" % e.strerror
    try:
        docs = list(yaml.load_all(text, Loader=Loader))
    except yaml.YAMLError as e:
        return None, "not valid YAML: %s" % str(e).splitlines()[0]
    if len(docs) != 1:
        return None, "%d YAML documents, want exactly 1" % len(docs)
    return docs[0], None


def unit_lines(path):
    """Line of every `units:` item (1-based), by composing the node tree. Empty on any problem."""
    try:
        with open(path, encoding="utf-8") as f:
            root = yaml.compose(f.read(), Loader=yaml.SafeLoader)
        for k, v in root.value:
            if k.value == "units" and isinstance(v, yaml.SequenceNode):
                return [item.start_mark.line + 1 for item in v.value]
    except (OSError, yaml.YAMLError, AttributeError, TypeError):
        pass
    return []


def validate_repo(data, lines):
    """-> [(line, message)] for one parsed repo.yaml."""
    out = []
    if not isinstance(data, dict):
        return [(1, "top level must be a mapping")]
    extra = sorted(set(data) - {"version", "repo", "units"})
    for k in extra:
        out.append((1, "unknown top-level key %r" % k))
    if data.get("version") != "v2":
        out.append((1, "version must be the string v2"))
    repo = data.get("repo")
    if not isinstance(repo, dict) or set(repo) != {"name", "layout"} or repo.get("layout") != "monorepo" \
            or not isinstance(repo.get("name"), str) or not NAME_RX.fullmatch(repo.get("name", "")):
        out.append((1, "repo must be {name: <kebab name>, layout: monorepo} and nothing else"))
    units = data.get("units")
    if not isinstance(units, list):
        return out + [(1, "units must be a list (empty is allowed)")]
    ids, paths = set(), set()
    for i, u in enumerate(units):
        ln = lines[i] if i < len(lines) else 1
        if not isinstance(u, dict) or set(u) != {"id", "kind", "language", "path"}:
            out.append((ln, "unit must have exactly id, kind, language, path"))
            continue
        uid, kind, lang, path = u["id"], u["kind"], u["language"], u["path"]
        if not isinstance(uid, str) or not ID_RX.fullmatch(uid):
            out.append((ln, "unit id %r must match [a-z][a-z0-9-]*" % (uid,)))
        elif uid in ids:
            out.append((ln, "duplicate unit id %r" % uid))
        else:
            ids.add(uid)
        if kind not in KINDS:
            out.append((ln, "unit %r kind %r not one of %s" % (uid, kind, "|".join(KINDS))))
            continue
        if lang not in KINDS[kind][1]:
            out.append((ln, "unit %r language %r not allowed for kind %s (%s)" % (uid, lang, kind,
                                                                               "|".join(KINDS[kind][1]))))
        if not isinstance(path, str):
            out.append((ln, "unit %r path must be a string" % (uid,)))
            continue
        top = KINDS[kind][0]
        parts = path.split("/")
        ok = (path == "db") if top is None else (len(parts) == 2 and parts[0] == top and NAME_RX.fullmatch(parts[1]) is not None)
        if not ok:
            out.append((ln, "unit %r path %r must be %s" % (uid, path, "db" if top is None else top + "/<name>")))
        elif path in paths:
            out.append((ln, "duplicate unit path %r" % path))
        paths.add(path)
    return out


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        return json.loads(text), text, None
    except (OSError, ValueError) as e:
        return None, "", "unreadable or not JSON: %s" % e


def line_of(text, section, name):
    """1-based line of `"name":` after the `"section":` line; 1 when not found."""
    lines = text.split("\n")
    start = 0
    for i, l in enumerate(lines):
        if re.match(r'\s*"%s"\s*:' % re.escape(section), l):
            start = i
            break
    for i in range(start, len(lines)):
        if re.match(r'\s*"%s"\s*:' % re.escape(name), lines[i]):
            return i + 1
    return 1


def workspace_dirs(root, globs, findings, wsfile, gl_lines):
    """Directories matched by the `dir/*` globs of pnpm-workspace.yaml that hold a package.json."""
    dirs = []
    for g in globs:
        if g not in WS_GLOBS:
            findings.append((wsfile, gl_lines.get(g, 1), "workspace-glob",
                             "workspace glob %r is not one of %s" % (g, ", ".join(WS_GLOBS))))
            continue
        base = os.path.join(root, g.split("/")[0])
        if os.path.isdir(base):
            for name in sorted(os.listdir(base)):
                d = os.path.join(base, name)
                if os.path.isfile(os.path.join(d, "package.json")):
                    dirs.append(d)
    return dirs


def top_nodes(path):
    """{key: (line, value node)} of a YAML file's top-level mapping; {} on any problem."""
    try:
        with open(path, encoding="utf-8") as f:
            node = yaml.compose(f.read(), Loader=yaml.SafeLoader)
        return {k.value: (k.start_mark.line + 1, v) for k, v in node.value if isinstance(k, yaml.ScalarNode)}
    except (OSError, yaml.YAMLError, AttributeError, TypeError):
        return {}


def child_lines(node):
    """{key: line} of a mapping node; {} for anything else."""
    if not isinstance(node, yaml.MappingNode):
        return {}
    return {k.value: k.start_mark.line + 1 for k, _ in node.value if isinstance(k, yaml.ScalarNode)}


def same(a, b):
    return type(a) is type(b) and a == b


def make_env():
    """The environment of every `make -q` question: the caller's make flags are scrubbed (a root `make -n` /
    `-i` / `-k` / `-B` / `-s` must not change a unit's answer), the locale is fixed."""
    drop = ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES", "GNUMAKEFLAGS", "MAKEFILES")
    env = {k: v for k, v in os.environ.items() if k not in drop}
    env["LC_ALL"] = "C"
    return env


# ---- "does this unit have target T": make's own VERDICT, read from its EXIT STATUS and nothing else. The question
# is `make -C <unit> -q -- T` with stdout and stderr discarded, so nothing a Makefile prints (banners, `-s`,
# `.SILENT`, a `define` shaped like a rule data base) can influence the answer. Exit 1 = make WOULD run something
# for T; exit 0 = nothing to do; exit 2 = no rule / no Makefile / an error in it. Prerequisite-only targets
# (`verify: check-fast lint`), pattern rules, included files and double-colon rules are all answered by make.
def _timeout_from_env(var, default):
    """Seconds from a TEST HOOK variable, else the default; a value that is not a positive number is ignored."""
    try:
        v = float(os.environ.get(var, ""))
        return v if v > 0 else default
    except ValueError:
        return default


# Test hook: MONOREPO_QUESTION_TIMEOUT=<seconds> lowers both timeouts (a case that needs a timeout costs 2 s, not 20).
# Test hook: MONOREPO_QUESTION_LOG=<file> appends one line `<unitdir> <target> <flags>` per question actually asked.
MAKE_TIMEOUT = _timeout_from_env("MONOREPO_QUESTION_TIMEOUT", 20.0)  # seconds per question
PROBE_TIMEOUT = min(5.0, MAKE_TIMEOUT)  # the random-name probe runs first, on a unit nobody has judged yet
_rc_cache = {}
_timed_out = set()
_live_groups = set()
PROBE_NAME = "__monorepo_probe_" + secrets.token_hex(8)  # a name no unit can have as a real target
# The -B look must be about the target's own rule graph, not about makefile remaking: GNU make 3.81 remakes every
# makefile it reads that has a rule (an `-include gen.mk` with a `gen.mk:` rule) under -B and answers 1 for it. So the
# -B look names every makefile make read with -o (--assume-old): no makefile is remade, nothing is added to the unit's
# rule base (a pin rule collides with a double-colon rule for the same makefile). The names come from a first pass,
# `make -q -f <unit makefile> -f <list.mk> -- <random name>`, whose module-owned makefile writes $(MAKEFILE_LIST) into a
# file of the private directory (a parse-time $(shell printf ...)); that file, not make's output, is what is read.
LIST_MK = ("__monorepo_sq = $(subst ','\\'',$(1))\n"
           "$(shell printf '%%s\\n' $(foreach f,$(MAKEFILE_LIST),'$(call __monorepo_sq,$(f))') > '%s')\n"
           ".PHONY: %s\n")
CONTROL_NAME = "__monorepo_control_" + secrets.token_hex(8)  # .PHONY in list.mk, no rule: nothing to do on a unit that has settled
# per-unit state lives in _rc_cache too, so clearing the cache clears it: ("timeout", unit) = a question for the unit timed out (nothing more is
# asked for it in this run); ("why", unit) = "timeout" | "unsettled" | "nolist", set when makefile_names answers None
_private = {}
_defer = {"on": False, "sig": None}


def _kill_group(pgid):
    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass


def _kill_all_groups():
    for g in list(_live_groups):
        _kill_group(g)
    _live_groups.clear()


def _cleanup_private():
    d = _private.get("dir")
    if d:
        shutil.rmtree(d, True)
        _private.pop("dir", None)


def _cleanup():
    _kill_all_groups()
    _cleanup_private()


atexit.register(_cleanup)


_SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


def _die(signum):
    """Kill every live question group, remove the private directory, exit 128+signum (os._exit: nothing else runs).
    Later signals are ignored first: a process group TERM reaches this process twice (once from the group, once
    forwarded by make) and the second must not cut the cleanup short."""
    for sig in _SIGNALS:
        signal.signal(sig, signal.SIG_IGN)
    _cleanup()
    os._exit(128 + signum)


def _on_signal(signum, _frame):
    if _defer["on"]:  # a question is being spawned: its pid is not registered yet; the spawner re-raises it
        _defer["sig"] = signum
        return
    _die(signum)


def install_signal_handlers():
    """INT, TERM and HUP clean up and exit 128+n: a question runs in its OWN session, so a signal sent to this
    process (or its group) does not reach it, and the default TERM/HUP action would skip atexit."""
    for sig in _SIGNALS:
        signal.signal(sig, _on_signal)


def private_dir():
    """The private temp directory (list.mk and its output), made on first use, removed at exit and on a signal."""
    if "dir" not in _private:
        _private["dir"] = tempfile.mkdtemp(prefix="monorepo-q-")
    return _private["dir"]


def makefile_names(unitdir):
    """The makefiles make reads for the unit (its MAKEFILE_LIST, minus the module's own list.mk), or None when the list
    pass wrote nothing or names something that is not a file beside the unit (a name with a space, a newline...):
    the caller fails closed. Exit status of the pass is not used. One pass per unit."""
    if ("names", unitdir) in _rc_cache:
        return _rc_cache[("names", unitdir)]
    names = None
    mk = unit_makefile(unitdir)
    if mk is None:
        names = []  # no makefile: nothing to name, nothing to remake; make answers 2 to every question
    else:
        d = private_dir()
        out, lm = os.path.join(d, "list.out"), os.path.join(d, "list.mk")
        with open(lm, "w", encoding="utf-8") as fh:
            fh.write(LIST_MK % (out.replace("'", "'\\''"), CONTROL_NAME))
        try:
            os.unlink(out)
        except OSError:
            pass
        make_ask(unitdir, PROBE_NAME, "-q", "-f", mk, "-f", lm, cache=False, assume_old=False)
        try:
            with open(out, encoding="utf-8", errors="replace") as fh:
                names = [n for n in fh.read().split("\n") if n and n != lm]
        except OSError:
            names = None
        if names is not None and (not names or any(not os.path.lexists(os.path.join(unitdir, n)) for n in names)):
            names = None
        if names is None:
            _rc_cache[("why", unitdir)] = "nolist"
        if names is not None:  # the control question: -o every listed makefile; a phony name with no rule answers 0 only
            o = []         # when every makefile make read has settled (none left that it wants to remake and cannot pin)
            for n in names:
                o += ["-o", n]
            rc = make_ask(unitdir, CONTROL_NAME, "-q", "-f", mk, "-f", lm, *o, cache=False, assume_old=False)
            if rc != 0:
                names = None
                _rc_cache[("why", unitdir)] = "timeout" if rc is None and _rc_cache.get(("timeout", unitdir)) else "unsettled"
    _rc_cache[("names", unitdir)] = names
    return names


def unit_makefile(unitdir):
    """The makefile make reads in unitdir when no -f is given, in make's documented order; None when there is none."""
    try:
        have = set(os.listdir(unitdir))  # exact names: `exists("makefile")` is true for `Makefile` on a case-insensitive disk
    except OSError:
        return None
    for name in ("GNUmakefile", "makefile", "Makefile"):
        if name in have:
            return name
    return None


def make_ask(unitdir, target, *flags, cache=True, assume_old=True):
    """make's exit status for `make -C unitdir <flags> -- target` (flags: -q, -q -B -o NAME..., -n, or the list pass's
    -q -f NAME -f list.mk), or None when make could not be run, was killed by a signal or did not answer in time.
    One call per (unitdir, target, flags) unless cache=False. The question runs in its own session; whatever is left
    in that process group afterwards (a timed-out make's children, a background job of a `+` line) is killed with
    SIGKILL, on every path out. A signal that arrives while the question is being spawned is held until its group is
    registered, then acted on (the handler kills the registered groups)."""
    key = (unitdir, target, flags)
    if cache and key in _rc_cache:
        return _rc_cache[key]
    if _rc_cache.get(("timeout", unitdir)):
        return None  # one timeout per unit per run
    o = []
    if assume_old:  # every question but the list pass: -o <each makefile make read>, so none is remade and none answers
        names = makefile_names(unitdir)
        if names is None:
            return None  # fail closed: the names cannot be had, or the control did not settle
        for n in names:
            o += ["-o", n]
    cmd = ["make", "-C", unitdir, *flags, *o, "--", target]
    log = os.environ.get("MONOREPO_QUESTION_LOG")
    if log:
        try:
            with open(log, "a", encoding="utf-8") as fh:
                fh.write("%s %s %s\n" % (unitdir, target, " ".join(flags)))
        except OSError:
            pass
    rc = None
    timeout = PROBE_TIMEOUT if target in (PROBE_NAME, CONTROL_NAME) else MAKE_TIMEOUT
    proc = None
    try:
        _defer["on"], _defer["sig"] = True, None
        try:
            proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    env=make_env(), start_new_session=True)
            _live_groups.add(proc.pid)
        finally:
            _defer["on"] = False
        if _defer["sig"] is not None:
            _on_signal(_defer["sig"], None)
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _timed_out.add(key)
            if assume_old or target == CONTROL_NAME:
                _rc_cache[("timeout", unitdir)] = True
    except (OSError, subprocess.SubprocessError):
        pass
    finally:
        if proc is not None:
            _kill_group(proc.pid)
            _live_groups.discard(proc.pid)
            try:
                proc.wait(timeout=5)
            except (OSError, subprocess.SubprocessError):
                pass
    result = rc if rc is not None and rc >= 0 else None
    if cache:
        _rc_cache[key] = result
    return result


def make_rc(unitdir, target):
    """The first question, `make -q -- target`: 1 = would run something, 0 = nothing to do (nothing out of date, or
    nothing to run), 2 = no rule / error / (GNU make 3.81) a recipe whose first line, `+` or `$(MAKE)`, make executes
    in question mode and that answered 1 (4.3 answers 1 there, or 0 when that line has nothing to do)."""
    return make_ask(unitdir, target, "-q")


def make_rc_always(unitdir, target):
    """The second look, asked ONLY when the first answered 0: `make -q -B -o <makefile>... -- target` (--always-make:
    every file is considered out of date, except the makefiles named with --assume-old, which are not remade), the
    names from makefile_names (one list pass). 1 (or 2, then the -n question) = make has work for the target when
    nothing is up to date, so the rule graph is real and the target was merely up to date; 0 = nothing to run even
    then. None (fail closed: 'error') when the makefile names cannot be had."""
    return make_ask(unitdir, target, "-q", "-B")


def make_rc_dry(unitdir, target):
    """The `make -n -- target` question, asked ONLY after the last question asked answered 2. 0 = make has a rule
    graph for the target and could plan it (on 3.81 the -q error came from an executed `$(MAKE)`/`+` line), 2 = no
    rule, a missing prerequisite, a syntax error, no Makefile, or a `+`/`$(MAKE)` line that fails under -n too."""
    return make_ask(unitdir, target, "-n")


def make_answer(unitdir, target):
    """(first answer, -n answer or None): the -n answer is asked only when the first is 2; the probe uses this."""
    q = make_rc(unitdir, target)
    return q, (make_rc_dry(unitdir, target) if q == 2 else None)


def make_look(unitdir, target):
    """(first answer, -B answer or None, -n answer or None): -B only when the first is 0, -n only when the last
    question asked answered 2. Only the questions asked are cached and run."""
    q = make_rc(unitdir, target)
    qb = make_rc_always(unitdir, target) if q == 0 else None
    last = qb if q == 0 else q
    return q, qb, (make_rc_dry(unitdir, target) if last == 2 else None)


def unit_catch_all(unitdir):
    """True when the unit answers for a name nobody can have defined (a match-anything rule or `.DEFAULT`): an
    explicit rule cannot be told apart from it by exit status, so such a unit is refused. The probe name goes
    through the first question and the -n question, never -B (a catch-all whose recipe starts with `$(MAKE)` answers
    -q 2, -n 0 on 3.81 and -q 1 on 4.3; an ordinary unit answers 2 and 2)."""
    q, n = make_answer(unitdir, PROBE_NAME)
    return q in (0, 1) or (q == 2 and n == 0)  # a timeout is not a catch-all: the state is 'error' (unit_why: timeout)


def unit_why(unitdir):
    """'timeout' | 'unsettled' | None: why the unit could not be asked (state 'error')."""
    if _rc_cache.get(("timeout", unitdir)):
        return "timeout"
    return _rc_cache.get(("why", unitdir))


def make_target_state(unitdir, target):
    """'present' | 'idle' | 'norule' | 'error' | 'catch-all'. The verdict is read from make's exit status only; the
    -B look names every makefile make read with -o (--assume-old; the names come from one list pass), so remaking
    an included makefile (GNU make 3.81) cannot flip it and no rule is added to the unit; a makefile that is a
    PREREQUISITE of T counts as old, so such a T is idle (see README, limits). The list failing closes to 'error'.
    present = make would run something for T (-q exit 1), or -q 0 and `-q -B` 1 (T was only up to date) unless a file
    named T sits beside the Makefile, or the last question asked answered 2 and `make -n` exit 0 (a recipe that starts
    with `$(MAKE)`/`+`: see make_rc_dry).
    idle = make has nothing to run for T even with everything considered out of date (-q 0 and -q -B 0: no recipe, a
    name only in `.PHONY`, prerequisites without recipes), or -q 0 and the name is a FILE beside the Makefile whose
    rule is not `.PHONY` (the real run says up to date).
    norule = the last question asked answered 2 and -n exit 2 (no rule for T, no Makefile, an error in the Makefile,
    a recipe that fails already under `make -n`). error = make could not be run, was killed or timed out.
    catch-all = the unit answers for any name (unit_catch_all)."""
    if unit_catch_all(unitdir):
        return "catch-all"
    q, qb, n = make_look(unitdir, target)
    if q == 1:
        return "present"
    if q == 0:
        if qb == 0:
            return "idle"
        if qb == 1 or (qb == 2 and n == 0):
            return "idle" if os.path.lexists(os.path.join(unitdir, target)) else "present"
        return "norule" if (qb == 2 and n == 2) else "error"
    if q == 2:
        if n == 0:
            return "present"
        return "norule" if n == 2 else "error"
    return "error"


def has_make_target(unitdir, target):
    """The ONE definition of "this unit has target T" for a service/database; the runner reads it through
    `units`. What it cannot tell is what the recipe does (see README, limits)."""
    return make_target_state(unitdir, target) == "present"


def has_script(pkgdir, target):
    data, _, err = read_json(os.path.join(pkgdir, "package.json"))
    return err is None and isinstance(data, dict) and isinstance(data.get("scripts"), dict) and target in data["scripts"]


def unit_has(root, unit, target):
    p = os.path.join(root, unit["path"])
    if unit["kind"] in ("service", "database"):
        return has_make_target(p, target)
    return has_script(p, target)


def path_problem(root, rel):
    """None, or why a unit path may not be executed in: a symlink on the way, or a real path outside root."""
    cur = root
    for part in rel.split("/"):
        cur = os.path.join(cur, part)
        if os.path.islink(cur):
            return "%s is a symlink" % os.path.relpath(cur, root)
    real = os.path.realpath(root)
    rp = os.path.realpath(os.path.join(root, rel))
    if rp != real and not rp.startswith(real + os.sep):
        return "resolves outside the repository"
    return None


def check_workspace(root, f):
    """The allow-list check of pnpm-workspace.yaml -> (catalog, catalogs, globs, glob line map)."""
    wsfile = "pnpm-workspace.yaml"
    path = os.path.join(root, wsfile)
    ws, err = load_yaml(path)
    if err or not isinstance(ws, dict):
        f.append((wsfile, 1, "root-settings", err or "must be a mapping"))
        return {}, {}, [], {}
    nodes = top_nodes(path)
    ln = lambda k: nodes[k][0] if k in nodes else 1
    for k in sorted(ws, key=lambda x: (ln(x), str(x))):
        if k not in ALLOWED_WS_KEYS:
            f.append((wsfile, ln(k), "root-settings", "key %r is not allowed; the root accepts only %s" % (
                k, ", ".join(sorted(ALLOWED_WS_KEYS)))))
    for k, want in REQUIRED_SETTINGS.items():
        if not same(ws.get(k), want):
            f.append((wsfile, ln(k), "root-settings", "%s must be %r (found %r)" % (k, want, ws.get(k))))
    mra = ws.get("minimumReleaseAge")
    if not isinstance(mra, int) or isinstance(mra, bool) or mra < MIN_RELEASE_AGE:
        f.append((wsfile, ln("minimumReleaseAge"), "root-settings",
                  "minimumReleaseAge must be an integer >= %d minutes" % MIN_RELEASE_AGE))
    obd = ws.get("onlyBuiltDependencies")
    if not isinstance(obd, list):
        f.append((wsfile, ln("onlyBuiltDependencies"), "root-settings",
                  "onlyBuiltDependencies must be a list (empty means no install script runs)"))
    elif obd:
        node = nodes.get("onlyBuiltDependencies", (1, None))[1]
        try:
            with open(path, encoding="utf-8") as fh:
                src = fh.read().split("\n")
        except OSError:
            src = []
        if getattr(node, "flow_style", False):
            f.append((wsfile, ln("onlyBuiltDependencies"), "root-settings",
                      "onlyBuiltDependencies must be a block list, one entry per line, each with a `# reason: ...` comment"))
        else:
            for item, sn in zip(obd, node.value if isinstance(node, yaml.SequenceNode) else []):
                il = sn.start_mark.line + 1
                if not isinstance(item, str) or not PKG_NAME_RX.fullmatch(item):
                    f.append((wsfile, il, "root-settings",
                              "onlyBuiltDependencies entry %r must be a plain package name (no *, no glob, no version)" % (item,)))
                elif not (il <= len(src) and REASON_RX.search(src[il - 1])):
                    f.append((wsfile, il, "root-settings",
                              "onlyBuiltDependencies entry %r needs a `# reason: <why it may run scripts>` comment on its line" % item))
    cat, cats = ws.get("catalog", {}), ws.get("catalogs", {})
    cat = {} if cat is None else cat
    cats = {} if cats is None else cats
    if not isinstance(cat, dict) or not isinstance(cats, dict):
        f.append((wsfile, ln("catalog"), "root-settings", "catalog / catalogs must be mappings"))
        cat, cats = {}, {}
    pools = [("catalog", cat, child_lines(nodes.get("catalog", (1, None))[1]))]
    cnode = nodes.get("catalogs", (1, None))[1]
    for cname, pool in cats.items():
        sub = None
        if isinstance(cnode, yaml.MappingNode):
            sub = next((v for k, v in cnode.value if isinstance(k, yaml.ScalarNode) and k.value == cname), None)
        if not isinstance(pool, dict):
            f.append((wsfile, child_lines(cnode).get(cname, 1), "root-settings", "catalogs.%s must be a mapping" % cname))
            continue
        pools.append(("catalogs.%s" % cname, pool, child_lines(sub)))
    for label, pool, lines in pools:
        for name, ver in pool.items():
            if not isinstance(ver, str) or not EXACT_VERSION_RX.fullmatch(ver):
                f.append((wsfile, lines.get(name, 1), "catalog-spec",
                          "%s %s: %r is not an exact version (no range, alias, tag, file:, link:, URL)" % (label, name, ver)))
    globs = ws.get("packages")
    if not isinstance(globs, list):
        f.append((wsfile, ln("packages"), "root-settings", "packages must be a list"))
        globs = []
    gl_lines = {}
    pnode = nodes.get("packages", (1, None))[1]
    if isinstance(pnode, yaml.SequenceNode):
        for g, sn in zip(globs, pnode.value):
            gl_lines.setdefault(g if isinstance(g, str) else repr(g), sn.start_mark.line + 1)
    return cat, cats, [g if isinstance(g, str) else repr(g) for g in globs], gl_lines


def check_package(root, d, data, text, pm, eng, cat, cats, f):
    pf = os.path.relpath(os.path.join(d, "package.json"), root)
    if not isinstance(data, dict):
        f.append((pf, 1, "pm-engines", "package.json must be an object"))
        return
    allowed = ROOT_PKG_KEYS if d == root else WORKSPACE_PKG_KEYS
    for fld in data:
        if fld in REFUSED_PKG_FIELDS:
            f.append((pf, line_of(text, fld, fld), "supply-override",
                      "the `%s` field is refused: it writes versions or install policy outside the catalog / root workspace file" % fld))
        elif fld not in allowed:
            f.append((pf, line_of(text, fld, fld), "pkg-key", "package.json key %r is not allowed in a %s manifest; it accepts only %s" % (
                fld, "root" if d == root else "workspace package", ", ".join(sorted(allowed)))))
    meta = data.get("peerDependenciesMeta")
    if meta is not None:
        if not isinstance(meta, dict):
            f.append((pf, line_of(text, "peerDependenciesMeta", "peerDependenciesMeta"), "pkg-key", "peerDependenciesMeta must be an object"))
        else:
            for name, m in meta.items():
                if not isinstance(m, dict) or set(m) - {"optional"} or not all(isinstance(v, bool) for v in m.values()):
                    f.append((pf, line_of(text, "peerDependenciesMeta", name), "pkg-key",
                              "peerDependenciesMeta.%s must be {optional: true|false} and nothing else" % name))
    for fld in DEP_FIELDS:
        deps = data.get(fld)
        if deps is None:
            continue
        if not isinstance(deps, dict):
            f.append((pf, line_of(text, fld, fld), "non-catalog-dep", "%s must be an object" % fld))
            continue
        for name, ver in deps.items():
            ln = line_of(text, fld, name)
            if not isinstance(ver, str):
                f.append((pf, ln, "non-catalog-dep", "%s %s: version must be a string" % (fld, name)))
            elif ver == "workspace:*":
                continue
            elif CATALOG_REF_RX.fullmatch(ver):
                cname = ver[len("catalog:"):]
                pool = cat if cname in ("", "default") else cats.get(cname)
                if not isinstance(pool, dict) or name not in pool:
                    f.append((pf, ln, "catalog-missing", "%s %s: %r has no entry in pnpm-workspace.yaml" % (fld, name, ver)))
            else:
                f.append((pf, ln, "non-catalog-dep", "%s %s: %r is not catalog: / catalog:<name> / workspace:*" % (fld, name, ver)))
    if d != root:
        if "packageManager" in data and data["packageManager"] != pm:
            f.append((pf, line_of(text, "packageManager", "packageManager"), "pm-engines", "packageManager differs from the root's"))
        pe = data.get("engines")
        if isinstance(pe, dict):
            for k, v in pe.items():
                if not isinstance(eng, dict) or k not in eng or v != eng[k]:
                    f.append((pf, line_of(text, "engines", k), "pm-engines", "engines.%s %r differs from the root's" % (k, v)))
        elif pe is not None:
            f.append((pf, line_of(text, "engines", "engines"), "pm-engines", "engines must be an object"))


def check_tracked_node_modules(root, f):
    """A COMMITTED node_modules/ is an install nobody pinned: refuse every tracked file under one. Needs git; a
    tree that is not a git repository cannot tell a committed node_modules from an install, so no finding."""
    if not os.path.exists(os.path.join(root, ".git")):
        return  # the root is not a git repository root (no .git): nothing to ask, and no process to start
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        r = subprocess.run(["git", "-C", root, "ls-files", "-z"], stdin=subprocess.DEVNULL, capture_output=True,
                           env=env, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return
    if r.returncode != 0:
        return
    seen = set()
    for p in sorted(r.stdout.decode("utf-8", "replace").split("\0")):
        parts = p.split("/")
        if "node_modules" in parts[:-1]:
            top = "/".join(parts[:parts.index("node_modules") + 1])
            if top not in seen:
                seen.add(top)
                f.append((p, 1, "tracked-node-modules", "%s/ is tracked by git: a committed node_modules is an install "
                          "nobody pinned; `git rm -r --cached` it and ignore it" % top))


def check_files(root, pkg_dirs, f):
    """Existence rules by file name, over every file below root (only node_modules/ and .git/ are skipped).
    A package.json outside the root and the workspace packages is `stray-package-json`."""
    for cur, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for name in sorted(files):
            p = os.path.join(cur, name)
            isroot = cur == root
            low = name.lower()
            if low == "package.json" and cur not in pkg_dirs:
                f.append((os.path.relpath(p, root), 1, "stray-package-json",
                          "a package.json outside apps/* and packages/* is not checked: make it a workspace package deliberately"))
            if low in LOCKFILE_NAMES or (low == "pnpm-lock.yaml" and not isroot):
                f.append((os.path.relpath(p, root), 1, "second-lockfile", "%s: the one lockfile is the root pnpm-lock.yaml" % name))
            elif low == "pnpm-workspace.yaml" and not isroot:
                f.append((os.path.relpath(p, root), 1, "supply-override", "a nested pnpm-workspace.yaml overrides the root's settings"))
            elif low in OTHER_REFUSED_NAMES or PNPMFILE_RX.fullmatch(low):
                f.append((os.path.relpath(p, root), 1, "supply-override",
                          "%s is refused anywhere in the repository: it is a second home for settings or resolution" % name))


def check(root):
    f = []  # (file, line, rule, message)

    # --- root package.json: packageManager and engines pinned
    rpkg, rtext, err = read_json(os.path.join(root, "package.json"))
    if err:
        f.append(("package.json", 1, "pm-engines", err))
        rpkg = {}
    if not isinstance(rpkg, dict):
        f.append(("package.json", 1, "pm-engines", "package.json must be an object"))
        rpkg = {}
    pm = rpkg.get("packageManager")
    if not isinstance(pm, str) or not PM_RX.fullmatch(pm):
        f.append(("package.json", 1, "pm-engines", "packageManager missing or not pnpm@<exact version>[+sha512.<hex>]"))
    eng = rpkg.get("engines")
    if eng != ENGINES_EXPECTED:
        f.append(("package.json", line_of(rtext, "engines", "engines"), "pm-engines",
                  "engines must be exactly %s (found %s)" % (json.dumps(ENGINES_EXPECTED), json.dumps(eng))))
    nm = ENGINES_RX.fullmatch(ENGINES_EXPECTED["node"])
    try:
        with open(os.path.join(root, ".nvmrc"), encoding="utf-8") as fh:
            nv = fh.read().strip()
    except OSError:
        nv = None
        f.append((".nvmrc", 1, "nvmrc", ".nvmrc missing"))
    if nv is not None:
        mj = re.fullmatch(r"v?(\d+)(?:\.\d+){0,2}", nv)
        if not mj or not int(nm.group(1)) <= int(mj.group(1)) < int(nm.group(2)):
            f.append((".nvmrc", 1, "nvmrc", ".nvmrc %r is outside engines.node %r" % (nv, ENGINES_EXPECTED["node"])))

    # --- the root workspace file, then every package.json (root included)
    cat, cats, globs, gl_lines = check_workspace(root, f)
    pkgs = [(root, rpkg, rtext)]
    parse_failed = set()  # workspace package dirs whose package.json does not parse: ONE `pkg-parse` finding each
    wsdirs = workspace_dirs(root, globs, f, "pnpm-workspace.yaml", gl_lines)
    for d in wsdirs:
        data, text, perr = read_json(os.path.join(d, "package.json"))
        if perr:
            parse_failed.add(d)
            f.append((os.path.relpath(os.path.join(d, "package.json"), root), 1, "pkg-parse", perr))
            continue
        pkgs.append((d, data, text))
    for d, data, text in pkgs:
        check_package(root, d, data, text, pm, eng, cat, cats, f)
    check_files(root, set(d for d, _, _ in pkgs) | parse_failed, f)
    if wsdirs and os.path.isfile(os.path.join(root, "pnpm-workspace.yaml")) \
            and not os.path.isfile(os.path.join(root, "pnpm-lock.yaml")):
        f.append(("pnpm-lock.yaml", 1, "lockfile-missing",
                  "the workspace has JS packages but the root has no pnpm-lock.yaml: run `make lock` and commit the result"))
    check_tracked_node_modules(root, f)

    # --- repo.yaml and the units
    ryaml = os.path.join(root, "repo.yaml")
    data, err = load_yaml(ryaml)
    units = []
    if err:
        f.append(("repo.yaml", 1, "repo-yaml", err))
    else:
        bad = validate_repo(data, unit_lines(ryaml))
        for ln, msg in bad:
            f.append(("repo.yaml", ln, "repo-yaml", msg))
        if not bad:
            units = data["units"]
    lines = unit_lines(ryaml)
    listed = set()
    for i, u in enumerate(units):
        ln = lines[i] if i < len(lines) else 1
        listed.add(u["path"])
        p = os.path.join(root, u["path"])
        pp = path_problem(root, u["path"])
        if pp:
            f.append(("repo.yaml", ln, "unit-path", "unit %s: path %s: %s" % (u["id"], u["path"], pp)))
            continue
        if not os.path.isdir(p):
            f.append(("repo.yaml", ln, "unit-path", "unit %s: path %s does not exist" % (u["id"], u["path"])))
            continue
        if u["kind"] in ("app", "package"):
            pj = os.path.join(p, "package.json")
            if not os.path.isfile(pj):
                f.append((u["path"] + "/package.json", 1, "unit-target", "unit %s: package.json missing" % u["id"]))
                continue
            _, _, perr = read_json(pj)
            if perr:  # one finding for a manifest that does not parse; the rules that read it are skipped
                if p not in parse_failed:
                    parse_failed.add(p)
                    f.append((u["path"] + "/package.json", 1, "pkg-parse", perr))
                continue
            for t in MANDATORY[u["kind"]]:
                if not unit_has(root, u, t):
                    f.append((u["path"] + "/package.json", 1, "unit-target",
                              "unit %s: package.json has no `%s` script" % (u["id"], t)))
            continue
        mk = u["path"] + "/Makefile"
        if unit_catch_all(p):
            f.append((mk, 1, "unit-target",
                      "unit %s: Makefile answers for any target name (a `%%:` rule or `.DEFAULT:`): targets cannot be "
                      "verified" % u["id"]))
            continue
        for t in MANDATORY[u["kind"]]:
            st = make_target_state(p, t)
            if st == "present":
                continue
            why = unit_why(p) if st == "error" else None
            if why == "timeout":
                f.append((mk, 1, "unit-target", "unit %s: timed out asking make about the %s target (a question did not answer in %g s; "
                          "nothing more is asked for this unit in this run)" % (u["id"], t, MAKE_TIMEOUT)))
                continue
            if why == "nolist":
                f.append((mk, 1, "unit-target", "unit %s: Makefile has no %s target: make could not answer for %s (the makefiles make read "
                          "could not be listed: a name with a space or newline, a file that is not beside the unit, or no list "
                          "written)" % (u["id"], t, t)))
                continue
            if why == "unsettled":
                f.append((mk, 1, "unit-target", "unit %s: the unit's makefiles do not settle: make still wants to remake one of them "
                          "(an included makefile that is missing and whose rule does not create it?)" % u["id"]))
                continue
            rc, rb, rn = make_look(p, t)
            if st == "idle" and rb != 0 and os.path.lexists(os.path.join(p, t)):
                what = ("make has nothing to do for %s (exit status 0): a file named %s beside a rule that is not "
                        ".PHONY makes make say \"up to date\"; declare `.PHONY: %s`" % (t, t, t))
            elif st == "idle":
                what = ("make has nothing to run for %s even with everything considered out of date (exit status 0 for "
                        "`make -q` and for `make -q -B`). Usual causes: the name only in `.PHONY`; an empty recipe "
                        "(`%s: ;`); prerequisites that have no recipe of their own. Give %s a recipe, or prerequisites "
                        "that have one" % (t, t, t))
            elif st == "norule":
                what = ("make has no rule for %s, the Makefile has an error, or the recipe fails already under "
                        "`make -n` (%s)" % (t, "make -q: 0, make -q -B: 2, make -n: 2" if rc == 0 else "make -q: 2, make -n: 2"))
            elif rc == 0 and rb is None and _rc_cache.get(("names", p), 0) is None:
                what = ("make could not answer for %s (the makefiles make read could not be listed: a name with a space "
                        "or newline, a file that is not beside the unit, or no list written)" % t)
            elif rc == 0:
                what = ("make could not answer for %s (%s)" % (t, "timed out, was killed or could not be run"
                                                              if rb is None or (rb == 2 and rn is None)
                                                              else "make -q: 0, make -q -B: %d" % rb if rb != 2 else
                                                              "make -q: 0, make -q -B: 2, make -n: %d" % rn))
            else:
                what = "make could not answer for %s (%s)" % (t, "timed out, was killed or could not be run"
                                                              if rc is None or (rc == 2 and rn is None)
                                                              else "exit status %d" % rc if rc != 2 else
                                                              "make -q: 2, make -n: %d" % rn)
            f.append((mk, 1, "unit-target", "unit %s: Makefile has no %s target: %s" % (u["id"], t, what)))
    if not err and not [1 for _, _, r, _ in f if r == "repo-yaml"]:
        for top in ("apps", "packages", "services"):
            base = os.path.join(root, top)
            if os.path.isdir(base):
                for name in sorted(os.listdir(base)):
                    if os.path.isdir(os.path.join(base, name)) and "%s/%s" % (top, name) not in listed:
                        f.append(("repo.yaml", 1, "unit-unlisted", "%s/%s is not a unit in repo.yaml" % (top, name)))
        if os.path.isdir(os.path.join(root, "db")) and "db" not in listed:
            f.append(("repo.yaml", 1, "unit-unlisted", "db is not a unit in repo.yaml (kind database, path db)"))
    return f


def cmd_check(root):
    findings = check(root)
    for file, line, rule, msg in findings:
        print("%s:%d: %s %s" % (file, line, rule, msg))
    if findings:
        print("FAIL monorepo-settings-check: %d finding(s)" % len(findings))
        return 1
    print("OK monorepo-settings-check")
    return 0


def cmd_units(root, target):
    ryaml = os.path.join(root, "repo.yaml")
    data, err = load_yaml(ryaml)
    bad = validate_repo(data, unit_lines(ryaml)) if not err else [(1, err)]
    if bad:
        for ln, msg in bad:
            print("repo.yaml:%d: %s" % (ln, msg), file=sys.stderr)
        return 2
    refused = 0
    for u in data["units"]:
        pp = path_problem(root, u["path"])
        if pp:
            print("monorepo-run: unit %s: path %s: %s; refusing to run anything" % (u["id"], u["path"], pp), file=sys.stderr)
            refused += 1
    if refused:
        return 2
    if shutil.which("make") is None:
        print("monorepo-run: make is not installed; cannot decide which units have %s" % target, file=sys.stderr)
        return 2
    has = {}
    for u in data["units"]:
        if u["kind"] in ("service", "database"):
            st = make_target_state(os.path.join(root, u["path"]), target)
            if st == "catch-all":
                print("monorepo-run: unit %s: Makefile answers for any target name: targets cannot be verified; refusing to run anything" % u["id"], file=sys.stderr)
                refused += 1
            has[u["id"]] = st == "present"
        else:
            has[u["id"]] = unit_has(root, u, target)
    if refused:
        return 2
    for u in data["units"]:
        must = 1 if target in MANDATORY[u["kind"]] else 0
        print("%s\t%s\t%s\t%d\t%d" % (u["id"], u["kind"], u["path"], 1 if has[u["id"]] else 0, must))
    return 0


def cmd_validate(path):
    data, err = load_yaml(path)
    bad = [(1, err)] if err else validate_repo(data, unit_lines(path))
    for ln, msg in bad:
        print("%s:%d: repo-yaml %s" % (path, ln, msg))
    return 1 if bad else 0


def main(argv):
    install_signal_handlers()
    if len(argv) == 3 and argv[1] == "check":
        return cmd_check(argv[2])
    if len(argv) == 4 and argv[1] == "units":
        return cmd_units(argv[2], argv[3])
    if len(argv) == 3 and argv[1] == "validate":
        return cmd_validate(argv[2])
    print(__doc__.strip().splitlines()[2], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
