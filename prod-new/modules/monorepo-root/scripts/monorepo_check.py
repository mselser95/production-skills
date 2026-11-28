#!/usr/bin/env python3
"""monorepo_check.py -- the monorepo root's repo.yaml reader and static settings check.

  monorepo_check.py check ROOT              settings check; one `file:line: RULE message` per finding
  monorepo_check.py units ROOT TARGET       TSV `id kind path has-target(1|0) mandatory(1|0)` per unit, for the runner
  monorepo_check.py validate FILE           validate one repo.yaml against docs/repo-schema.md

Exit: 0 clean - 1 findings - 2 cannot run (PyYAML missing, repo.yaml unreadable for `units`).
Reads text/JSON/YAML, asks `git ls-files` for a tracked node_modules/, and asks `make -n` whether a unit has a
target: no network, no pnpm. `make -n` evaluates the unit Makefile (parse-time `$(shell)`, `+` recipe lines and
`$(MAKE)` lines still execute): the units are the repository's own code, trusted as `make check-fast` trusts
them. What is guaranteed is that no unit TARGET RECIPE is run by `check` or `units`. The root Makefile and the
check read the SAME parser.
"""
import json
import os
import re
import secrets
import shutil
import subprocess
import sys

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
MAKE_MSG_RX = re.compile(r"make(?:\[\d+\])?: ")
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
    drop = ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES")
    env = {k: v for k, v in os.environ.items() if k not in drop}
    env["LC_ALL"] = "C"  # make's own notices in English, whatever the caller's locale
    return env


NOTICE_RX = re.compile(r"make(?:\[\d+\])?: (?:Entering|Leaving) directory\b")
_Q1, _Q2 = "[`'\u2018]", "['\u2019]"


def idle_rx(target, level0):
    """make's own verdict for a name with nothing to run: 3.81 (`T') and 4.x ('T') wordings, `make:` or the
    recursive `make[N]:` form."""
    t = re.escape(target)
    pre = r"make: " if level0 else r"make\[\d+\]: "
    return re.compile(pre + r"(?:Nothing to be done for %s%s%s|%s%s%s is up to date)" % (_Q1, t, _Q2, _Q1, t, _Q2))


def target_state(lines, target):
    """'idle' | 'present' from the output of a successful `make -n <target>`. A `make:` verdict for <target>
    wins over anything else printed (a `$(info)` banner); a `make[N]:` verdict is a sub-make's and only counts
    as noise, so a recipe that forwards with `$(MAKE)` is still a recipe. Otherwise a target is present when a
    line remains after removing make's directory notices."""
    top, sub = idle_rx(target, True), idle_rx(target, False)
    if any(top.match(l) for l in lines):
        return "idle"
    left = [l for l in lines if l.strip() and not NOTICE_RX.match(l) and not sub.match(l)]
    return "present" if left else "idle"


def run_make_n(unitdir, target):
    """-> (exit status, output lines) of `make -C <unit> -n <target>`, stdout and stderr together; None when
    make cannot be run. NOTE: make evaluates the Makefile; it can execute `$(shell)`, `+` and `$(MAKE)` lines."""
    try:
        r = subprocess.run(["make", "-C", unitdir, "-n", target], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
                           env=make_env(), timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.returncode, r.stdout.splitlines()


_catch_all = {}


def is_catch_all(unitdir):
    """True when the unit Makefile answers a name nobody wrote (`%:` / `.DEFAULT:`): then every target looks
    present and a mandatory one cannot be told apart from a forwarded one."""
    if unitdir not in _catch_all:
        res = run_make_n(unitdir, "__monorepo_probe_%s__" % secrets.token_hex(6))
        _catch_all[unitdir] = res is not None and res[0] == 0 and target_state(res[1], "") == "present"
    return _catch_all[unitdir]


def make_target_state(unitdir, target):
    """'present' | 'idle' | 'absent' | 'catch-all'. Decided from make's own verdict, not from "some output":
    present = exit 0, no `Nothing to be done for T` / `T is up to date`, and a command line left once make's
    directory notices are removed. idle = make ran but has nothing to run (a name only in .PHONY, an empty
    recipe, or a file named T beside a rule that is not .PHONY). absent = make failed (no rule)."""
    if is_catch_all(unitdir):
        return "catch-all"
    res = run_make_n(unitdir, target)
    if res is None or res[0] != 0:
        return "absent"
    return target_state(res[1], target)


def has_make_target(unitdir, target):
    """The ONE definition of "this unit has target T" for a service/database; the runner reads it through
    `units`. A recipe that exists and does nothing (`verify: ; true`) cannot be judged by a tool and counts as
    present."""
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
    for d in workspace_dirs(root, globs, f, "pnpm-workspace.yaml", gl_lines):
        data, text, perr = read_json(os.path.join(d, "package.json"))
        if perr:
            f.append((os.path.relpath(os.path.join(d, "package.json"), root), 1, "pm-engines", perr))
            continue
        pkgs.append((d, data, text))
    for d, data, text in pkgs:
        check_package(root, d, data, text, pm, eng, cat, cats, f)
    check_files(root, set(d for d, _, _ in pkgs), f)
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
        if u["kind"] in ("app", "package") and not os.path.isfile(os.path.join(p, "package.json")):
            f.append((u["path"] + "/package.json", 1, "unit-target", "unit %s: package.json missing" % u["id"]))
            continue
        if u["kind"] in ("service", "database") and is_catch_all(p):
            f.append((u["path"] + "/Makefile", 1, "unit-target",
                      "unit %s: Makefile catch-all rule (`%%:` / `.DEFAULT:`): targets cannot be verified" % u["id"]))
            continue
        for t in MANDATORY[u["kind"]]:
            if u["kind"] in ("service", "database"):
                st = make_target_state(p, t)
                if st == "present":
                    continue
                what = "has no %s target (`make -n %s` fails)" % (t, t)
                if st == "idle":
                    what = ("has no %s target: `make -n %s` says nothing to be done or up to date; give it a recipe and "
                            "declare `.PHONY: %s` (a file named %s beside a rule that is not .PHONY hides it)" % (t, t, t, t))
                f.append((u["path"] + "/Makefile", 1, "unit-target", "unit %s: Makefile %s" % (u["id"], what)))
            elif not unit_has(root, u, t):
                f.append((u["path"] + "/package.json", 1, "unit-target",
                          "unit %s: package.json has no `%s` script" % (u["id"], t)))
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
    for u in data["units"]:
        if u["kind"] in ("service", "database") and is_catch_all(os.path.join(root, u["path"])):
            print("monorepo-run: unit %s: Makefile catch-all rule: targets cannot be verified; refusing to run anything" % u["id"], file=sys.stderr)
            refused += 1
    if refused:
        return 2
    for u in data["units"]:
        must = 1 if target in MANDATORY[u["kind"]] else 0
        print("%s\t%s\t%s\t%d\t%d" % (u["id"], u["kind"], u["path"], 1 if unit_has(root, u, target) else 0, must))
    return 0


def cmd_validate(path):
    data, err = load_yaml(path)
    bad = [(1, err)] if err else validate_repo(data, unit_lines(path))
    for ln, msg in bad:
        print("%s:%d: repo-yaml %s" % (path, ln, msg))
    return 1 if bad else 0


def main(argv):
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
