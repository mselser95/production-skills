#!/usr/bin/env python3
"""monorepo_check.py -- the monorepo root's repo.yaml reader and static settings check.

  monorepo_check.py check ROOT              settings check; one `file:line: RULE message` per finding
  monorepo_check.py units ROOT TARGET       TSV `id kind path has-target(1|0)` per unit, for the root Makefile
  monorepo_check.py validate FILE           validate one repo.yaml against docs/repo-schema.md

Exit: 0 clean - 1 findings - 2 cannot run (PyYAML missing, repo.yaml unreadable for `units`).
Pure text/JSON/YAML reading: no network, no pnpm. The root Makefile and the check read the SAME parser.
"""
import json
import os
import re
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
# What the root pins; a workspace file that lacks or weakens one is a finding (rule root-settings).
REQUIRED_SETTINGS = {"catalogMode": "strict", "engineStrict": True, "strictPeerDependencies": True,
                     "strictDepBuilds": True, "blockExoticSubdeps": True, "trustPolicy": "no-downgrade"}
MIN_RELEASE_AGE = 1440  # minutes; the shipped value is 10080 (seven days), the floor is pnpm's own default
SUPPLY_KEYS = ("catalogMode", "minimumReleaseAge", "minimumReleaseAgeExclude", "trustPolicy", "trustPolicyExclude",
               "blockExoticSubdeps", "strictDepBuilds", "onlyBuiltDependencies", "ignoredBuiltDependencies",
               "allowBuilds", "strictPeerDependencies", "engineStrict", "overrides", "packageExtensions",
               "patchedDependencies", "neverBuiltDependencies", "auditConfig", "resolutionMode")
SKIP_DIRS = {"node_modules", ".git", "target", ".venv", "__pycache__", "dist", "coverage"}
LOCKFILES = ("package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "bun.lock", "bun.lockb")
DEP_FIELDS = ("dependencies", "devDependencies", "optionalDependencies")
ENGINES_RX = re.compile(r">=(\d+) <(\d+)")


def kebab(key):
    return re.sub(r"[A-Z]", lambda m: "-" + m.group(0).lower(), key)


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


def workspace_dirs(root, globs, findings, wsfile):
    """Directories matched by the `dir/*` globs of pnpm-workspace.yaml that hold a package.json."""
    dirs = []
    for g in globs:
        m = re.fullmatch(r"([a-z0-9_-]+)/\*", g) if isinstance(g, str) else None
        if not m:
            findings.append((wsfile, 1, "workspace-glob", "unsupported workspace glob %r (only dir/*)" % (g,)))
            continue
        base = os.path.join(root, m.group(1))
        if os.path.isdir(base):
            for name in sorted(os.listdir(base)):
                d = os.path.join(base, name)
                if os.path.isfile(os.path.join(d, "package.json")):
                    dirs.append(d)
    return dirs


def has_make_target(makefile, target):
    try:
        with open(makefile, encoding="utf-8", errors="replace") as f:
            return re.search(r"^%s[ \t]*:(?!=)" % re.escape(target), f.read(), re.M) is not None
    except OSError:
        return False


def has_script(pkgdir, target):
    data, _, err = read_json(os.path.join(pkgdir, "package.json"))
    return err is None and isinstance(data, dict) and isinstance(data.get("scripts"), dict) and target in data["scripts"]


def unit_has(root, unit, target):
    p = os.path.join(root, unit["path"])
    if unit["kind"] in ("service", "database"):
        return has_make_target(os.path.join(p, "Makefile"), target)
    return has_script(p, target)


def check(root):
    f = []  # (file, line, rule, message)
    rel = lambda p: os.path.relpath(p, root)

    # --- root package.json: packageManager and engines pinned
    rpkg_path = os.path.join(root, "package.json")
    rpkg, rtext, err = read_json(rpkg_path)
    if err:
        f.append(("package.json", 1, "pm-engines", err))
        rpkg = {}
    pm = rpkg.get("packageManager")
    if not isinstance(pm, str) or not re.fullmatch(r"pnpm@\d+\.\d+\.\d+", pm):
        f.append(("package.json", 1, "pm-engines", "packageManager missing or not pnpm@<exact version>"))
    eng = rpkg.get("engines")
    if not isinstance(eng, dict) or not isinstance(eng.get("node"), str) or not isinstance(eng.get("pnpm"), str):
        f.append(("package.json", line_of(rtext, "engines", "engines"), "pm-engines", "engines.node and engines.pnpm are required"))
        eng = {}
    nm = ENGINES_RX.fullmatch(eng.get("node", "")) if eng else None
    nvm = os.path.join(root, ".nvmrc")
    if eng and not nm:
        f.append(("package.json", line_of(rtext, "engines", "node"), "pm-engines", "engines.node must look like '>=24 <27'"))
    try:
        with open(nvm, encoding="utf-8") as fh:
            nv = fh.read().strip()
    except OSError:
        nv = None
        f.append((".nvmrc", 1, "nvmrc", ".nvmrc missing"))
    if nv is not None and nm:
        mj = re.fullmatch(r"v?(\d+)(?:\.\d+){0,2}", nv)
        if not mj or not int(nm.group(1)) <= int(mj.group(1)) < int(nm.group(2)):
            f.append((".nvmrc", 1, "nvmrc", ".nvmrc %r is outside engines.node %r" % (nv, eng["node"])))

    # --- root pnpm-workspace.yaml: the settings the root pins
    wsfile = "pnpm-workspace.yaml"
    ws, err = load_yaml(os.path.join(root, wsfile))
    if err or not isinstance(ws, dict):
        f.append((wsfile, 1, "root-settings", err or "must be a mapping"))
        ws = {}
    for k, want in REQUIRED_SETTINGS.items():
        if ws.get(k) != want:
            f.append((wsfile, 1, "root-settings", "%s must be %r (found %r)" % (k, want, ws.get(k))))
    mra = ws.get("minimumReleaseAge")
    if not isinstance(mra, int) or isinstance(mra, bool) or mra < MIN_RELEASE_AGE:
        f.append((wsfile, 1, "root-settings", "minimumReleaseAge must be an integer >= %d minutes" % MIN_RELEASE_AGE))
    if not isinstance(ws.get("onlyBuiltDependencies"), list):
        f.append((wsfile, 1, "root-settings", "onlyBuiltDependencies must be a list (empty means no install script runs)"))
    cat, cats = ws.get("catalog") or {}, ws.get("catalogs") or {}
    if not isinstance(cat, dict) or not isinstance(cats, dict):
        f.append((wsfile, 1, "root-settings", "catalog / catalogs must be mappings"))
        cat, cats = {}, {}
    globs = ws.get("packages")
    if not isinstance(globs, list):
        f.append((wsfile, 1, "root-settings", "packages must be a list"))
        globs = []

    # --- every workspace package.json (root included)
    pkgs = [(root, rpkg, rtext)] if not err else []
    for d in workspace_dirs(root, globs, f, wsfile):
        data, text, perr = read_json(os.path.join(d, "package.json"))
        if perr:
            f.append((rel(os.path.join(d, "package.json")), 1, "pm-engines", perr))
            continue
        pkgs.append((d, data, text))
    for d, data, text in pkgs:
        pf = rel(os.path.join(d, "package.json"))
        if not isinstance(data, dict):
            f.append((pf, 1, "pm-engines", "package.json must be an object"))
            continue
        for fld in DEP_FIELDS:
            deps = data.get(fld) or {}
            if not isinstance(deps, dict):
                f.append((pf, line_of(text, fld, fld), "non-catalog-dep", "%s must be an object" % fld))
                continue
            for name, ver in deps.items():
                ln = line_of(text, fld, name)
                if not isinstance(ver, str):
                    f.append((pf, ln, "non-catalog-dep", "%s %s: version must be a string" % (fld, name)))
                elif ver == "workspace:*":
                    continue
                elif ver == "catalog:" or ver.startswith("catalog:"):
                    cname = ver[len("catalog:"):]
                    pool = cat if cname in ("", "default") else cats.get(cname)
                    if not isinstance(pool, dict) or name not in pool:
                        f.append((pf, ln, "catalog-missing", "%s %s: %r has no entry in pnpm-workspace.yaml" % (fld, name, ver)))
                else:
                    f.append((pf, ln, "non-catalog-dep", "%s %s: %r is not catalog: or workspace:*" % (fld, name, ver)))
        if d != root:
            if "packageManager" in data and data["packageManager"] != pm:
                f.append((pf, line_of(text, "packageManager", "packageManager"), "pm-engines", "packageManager differs from the root's"))
            pe = data.get("engines")
            if isinstance(pe, dict):
                for k, v in pe.items():
                    if k not in eng or v != eng[k]:
                        f.append((pf, line_of(text, "engines", k), "pm-engines", "engines.%s %r differs from the root's" % (k, v)))
            elif pe is not None:
                f.append((pf, 1, "pm-engines", "engines must be an object"))
        if "pnpm" in data:
            f.append((pf, line_of(text, "pnpm", "pnpm"), "supply-override", "a `pnpm` field re-states install policy; only the root workspace file may"))

    # --- lockfiles, nested workspace files, .npmrc settings
    for cur, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for name in sorted(files):
            p = os.path.join(cur, name)
            isroot = cur == root
            if name in LOCKFILES or (name == "pnpm-lock.yaml" and not isroot):
                f.append((rel(p), 1, "second-lockfile", "%s: the one lockfile is the root pnpm-lock.yaml" % name))
            elif name == "pnpm-workspace.yaml" and not isroot:
                f.append((rel(p), 1, "supply-override", "a nested pnpm-workspace.yaml overrides the root's settings"))
            elif name == ".npmrc":
                try:
                    with open(p, encoding="utf-8", errors="replace") as fh:
                        for i, l in enumerate(fh, 1):
                            k = l.split("=", 1)[0].strip().lower()
                            if "=" in l and not l.lstrip().startswith(("#", ";")) and k in {kebab(s) for s in SUPPLY_KEYS} | {s.lower() for s in SUPPLY_KEYS}:
                                f.append((rel(p), i, "supply-override", ".npmrc sets %s; settings live in the root pnpm-workspace.yaml" % k))
                except OSError:
                    pass

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
        if not os.path.isdir(p):
            f.append(("repo.yaml", ln, "unit-path", "unit %s: path %s does not exist" % (u["id"], u["path"])))
            continue
        if u["kind"] == "service":
            for t in ("check-fast", "verify"):
                if not has_make_target(os.path.join(p, "Makefile"), t):
                    f.append((u["path"] + "/Makefile", 1, "unit-target", "unit %s: Makefile has no %s target" % (u["id"], t)))
        elif u["kind"] in ("app", "package"):
            pj = os.path.join(p, "package.json")
            if not os.path.isfile(pj):
                f.append((u["path"] + "/package.json", 1, "unit-target", "unit %s: package.json missing" % u["id"]))
            elif not has_script(p, "test"):
                f.append((u["path"] + "/package.json", 1, "unit-target", "unit %s: no `test` script" % u["id"]))
    if not err and not [1 for _, _, r, _ in f if r == "repo-yaml"]:
        for top in ("apps", "packages", "services"):
            base = os.path.join(root, top)
            if os.path.isdir(base):
                for name in sorted(os.listdir(base)):
                    if os.path.isdir(os.path.join(base, name)) and "%s/%s" % (top, name) not in listed:
                        f.append(("repo.yaml", 1, "unit-unlisted", "%s/%s is not a unit in repo.yaml" % (top, name)))
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
    for u in data["units"]:
        print("%s\t%s\t%s\t%d" % (u["id"], u["kind"], u["path"], 1 if unit_has(root, u, target) else 0))
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
