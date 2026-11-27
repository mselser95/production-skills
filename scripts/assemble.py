#!/usr/bin/env python3
"""assemble.py -- build a repo tree from prod-new modules.

Usage:
  python3 -I -B scripts/assemble.py --dest DIR --layout single|monorepo \
      --module ID [--module ID ...] --slot NAME=VALUE [--slot ...] \
      [--modules-dir DIR]

A module is prod-new/modules/<id>/module.json: `source` (relative to the module
dir), `slots`, and `placement` (ordered glob -> "root" | "unit", first match
wins). Every source file must match a glob (no catch-all, so a dropped glob is
an error, not a silent relocation). Layout `single`: root and unit are the repo
root. Layout `monorepo`: unit is services/<SERVICE>.

Slots are literal token replacement of <NAME> in contents (bytes) and in paths,
as instantiate-template.sh does. Nothing is written until every check passed.
Exit: 0 ok - 1 refused (leftover slot, unplaced file, dest not empty, root-file
collision, unused literal slot) - 2 usage.

Manifest keys (all but id/source/placement optional):
  exclude       [globs] never placed, never reported unplaced. When `source` is
                the module dir itself, module.json at its root is always excluded.
  root_merge    {glob: "union-lines"} destinations that may be merged when two
                modules place different bytes there (stable de-duplicated union
                of lines, first-seen order). The only strategy; any other name
                is exit 2. Every contributing module must declare the glob.
  strict_slots  true: any leftover <[A-Z][A-Z0-9_]*> token in file CONTENTS is a
                refusal (paths are always checked), unless listed in slot_allow.
  slot_allow    [tokens] names (without <>) tolerated by strict_slots.
  slots         NAME -> description string (placeholder <NAME>) or
                {"description": .., "literal": L}: placeholder is the literal L
                (contents and paths). A literal that never occurs is an error.

Candidate files: inside a git work tree, `git ls-files --cached --others
--exclude-standard` restricted to the source dir (git-ignored build output is
never assembled; tracked-but-deleted files are skipped). Outside git: a
filesystem walk. Two modules placing the same destination is allowed only when
the bytes (and mode) are identical after substitution, or root_merge applies;
otherwise it is an error naming both modules (a `monorepo-root` module should
own YAML/JSON root files).
"""
import argparse
import json
import os
import re
import stat
import subprocess
import sys

UNIT_DIR = {"single": "", "monorepo": "services/<SERVICE>"}


def die(code, msg):
    sys.stderr.write("assemble: " + msg + "\n")
    sys.exit(code)


def glob_re(g):
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif g.startswith("**", i):
            out += ".*"; i += 2
        elif g[i] == "*":
            out += "[^/]*"; i += 1
        elif g[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(g[i]); i += 1
    return re.compile(out + r"\Z")


def sub_bytes(data, slots, ph=None):
    for k, v in slots.items():
        data = data.replace((ph or {}).get(k, "<%s>" % k).encode(), v.encode())
    return data


def sub_str(s, slots, ph=None):
    for k, v in slots.items():
        s = s.replace((ph or {}).get(k, "<%s>" % k), v)
    return s


STRATEGIES = ("union-lines",)
TOKEN = re.compile(rb"<([A-Z][A-Z0-9_]*)>")


def union_lines(a, b):
    out, seen = [], set()
    for data in (a, b):
        parts = data.split(b"\n")
        if parts and parts[-1] == b"":
            parts.pop()
        for ln in parts:
            if ln not in seen:
                seen.add(ln)
                out.append(ln)
    return b"\n".join(out) + b"\n"


def candidates(src):
    """Relative paths of files (and symlinks) under src, sorted."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        r = subprocess.run(["git", "-C", src, "rev-parse", "--is-inside-work-tree"],
                           capture_output=True, env=env)
        inside = r.returncode == 0 and r.stdout.strip() == b"true"
    except OSError:
        inside = False
    if inside:
        r = subprocess.run(["git", "-C", src, "ls-files", "-z", "--cached", "--others",
                            "--exclude-standard", "--", "."], capture_output=True, env=env)
        if r.returncode != 0:
            die(1, "git ls-files failed in %s" % src)
        out = set()
        for b in r.stdout.split(b"\0"):
            if not b:
                continue
            rel = os.fsdecode(b)
            full = os.path.join(src, rel)
            if not os.path.lexists(full) or (os.path.isdir(full) and not os.path.islink(full)):
                continue  # tracked but deleted, or a submodule
            out.add(rel)
        return sorted(out)
    entries = []
    for dp, dns, fns in os.walk(src):
        dns.sort()
        for n in sorted(fns) + [d for d in dns if os.path.islink(os.path.join(dp, d))]:
            entries.append(os.path.relpath(os.path.join(dp, n), src))
    return sorted(entries)


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--layout", required=True)
    ap.add_argument("--module", action="append", default=[])
    ap.add_argument("--slot", action="append", default=[])
    ap.add_argument("--modules-dir", default=None)
    try:
        a = ap.parse_args()
    except SystemExit as e:
        sys.exit(2 if e.code else 0)

    if a.layout not in UNIT_DIR:
        die(2, "unknown layout %r (known: %s)" % (a.layout, ", ".join(sorted(UNIT_DIR))))
    if not a.module:
        die(2, "no --module given")
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    mdir = a.modules_dir or os.path.join(root, "prod-new", "modules")

    slots = {}
    for s in a.slot:
        k, sep, v = s.partition("=")
        if not sep or not k:
            die(2, "bad --slot %r (want NAME=VALUE)" % s)
        slots[k] = v

    manifests = []
    for mid in a.module:
        mp = os.path.join(mdir, mid, "module.json")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", mid) or not os.path.isfile(mp):
            die(2, "unknown module %r (no %s)" % (mid, mp))
        try:
            with open(mp, encoding="utf-8") as f:
                m = json.load(f)
        except ValueError as e:
            die(2, "unreadable manifest %s: %s" % (mp, e))
        mod_slots = m.get("slots", {})
        m["_ph"], m["_lit"] = {}, {}
        for k, v in mod_slots.items():
            if isinstance(v, dict) and "literal" in v:
                if not isinstance(v["literal"], str) or not v["literal"]:
                    die(2, "module %s: slot %s: literal must be a non-empty string" % (mid, k))
                m["_ph"][k] = v["literal"]
                m["_lit"][k] = v["literal"]
        rm = m.get("root_merge", {})
        if not isinstance(rm, dict):
            die(2, "module %s: root_merge must be an object" % mid)
        for g, strat in rm.items():
            if strat not in STRATEGIES:
                die(2, "module %s: root_merge %r -> %r (known: %s)" % (mid, g, strat, ", ".join(STRATEGIES)))
        for key in ("exclude", "slot_allow"):
            v = m.get(key, [])
            if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
                die(2, "module %s: %s must be a list of strings" % (mid, key))
        m["_id"] = mid
        manifests.append((os.path.join(mdir, mid), m))

    declared = set()
    for _, m in manifests:
        declared.update(m.get("slots", {}))
    for k in slots:
        if k not in declared:
            die(2, "unknown slot %r (declared: %s)" % (k, ", ".join(sorted(declared))))
    for k in sorted(declared):
        if k not in slots:
            die(2, "slot %r declared by a module but not given" % k)

    dest = a.dest
    if os.path.lexists(dest) and (not os.path.isdir(dest) or os.listdir(dest)):
        die(1, "dest %s exists and is not an empty directory" % dest)

    unit_dir = sub_str(UNIT_DIR[a.layout], slots)
    umask = os.umask(0)
    os.umask(umask)

    plan = {}  # out path -> {"kind": link|file, "data", "mode", "mods": [ids], "merge": bool}
    bad_paths, bad_content, unplaced, bad_lit = [], [], [], []
    for mod_path, m in manifests:
        mid, ph = m["_id"], m["_ph"]
        src = os.path.normpath(os.path.join(mod_path, m["source"]))
        if not os.path.isdir(src):
            die(2, "module %s: source %s is not a directory" % (mid, src))
        rules = [(glob_re(g), t, g) for g, t in m["placement"].items()]
        for _, t, g in rules:
            if t not in ("root", "unit"):
                die(2, "module %s: placement %r -> %r (want root|unit)" % (mid, g, t))
        excl = [glob_re(g) for g in m.get("exclude", [])]
        merge_rx = [glob_re(g) for g in m.get("root_merge", {})]
        allow = set(m.get("slot_allow", []))
        strict = m.get("strict_slots", False) is True
        self_dir = src == os.path.normpath(mod_path)
        seen_lit = set()
        for rel in candidates(src):
            if (self_dir and rel == "module.json") or any(rx.match(rel) for rx in excl):
                continue
            for k, lit in m["_lit"].items():
                if lit in rel:
                    seen_lit.add(k)
            target = next((t for rx, t, _ in rules if rx.match(rel)), None)
            if target is None:
                unplaced.append(rel)
                continue
            out = sub_str(rel, slots, ph)
            if "<" in out and re.search(r"<[^<>/]*>", out):
                bad_paths.append(out)
            if target == "unit" and unit_dir:
                out = unit_dir + "/" + out
            full = os.path.join(src, rel)
            if os.path.islink(full):
                ent = {"kind": "link", "data": os.readlink(full), "mode": 0}
            else:
                with open(full, "rb") as f:
                    data = f.read()
                for k, lit in m["_lit"].items():
                    if lit.encode() in data:
                        seen_lit.add(k)
                data = sub_bytes(data, slots, ph)
                for k in slots:
                    if ("<%s>" % k).encode() in data:
                        bad_content.append(out)
                        break
                else:
                    if strict:
                        stray = sorted({t.decode() for t in TOKEN.findall(data)} - allow)
                        if stray:
                            bad_content.append("%s (<%s>)" % (out, ">, <".join(stray)))
                mode = (stat.S_IMODE(os.stat(full).st_mode) & ~umask) | stat.S_IWUSR
                ent = {"kind": "file", "data": data, "mode": mode}
            ent["mods"] = [mid]
            ent["merge"] = any(rx.match(out) for rx in merge_rx)
            old = plan.get(out)
            if old is None:
                plan[out] = ent
            elif (old["kind"], old["data"], old["mode"]) == (ent["kind"], ent["data"], ent["mode"]):
                old["mods"].append(mid)
            elif ent["kind"] == "file" and old["kind"] == "file" and old["merge"] and ent["merge"]:
                old["data"] = union_lines(old["data"], ent["data"])
                old["mods"].append(mid)
            else:
                die(1, "modules %s and %s both place %s with different content; identical files "
                    "are written once, only root_merge union-lines merges text; for YAML/JSON a "
                    "monorepo-root module should own the file"
                    % (" + ".join(old["mods"]), mid, out))
        for k in sorted(m["_lit"]):
            if k not in seen_lit:
                bad_lit.append("module %s: literal %r of slot %s never occurs" % (mid, m["_lit"][k], k))

    if unplaced or bad_paths or bad_content or bad_lit:
        for p in bad_lit:
            sys.stderr.write("    literal: %s\n" % p)
        for p in unplaced:
            sys.stderr.write("    unplaced: %s\n" % p)
        for p in bad_paths:
            sys.stderr.write("    path: %s\n" % p)
        for p in bad_content:
            sys.stderr.write("    file: %s\n" % p)
        die(1, "refused -- %d unplaced file(s), %d path(s), %d file(s) with a leftover slot, "
            "%d unused literal slot(s)" % (len(unplaced), len(bad_paths), len(bad_content), len(bad_lit)))
    if not plan:
        die(1, "nothing to assemble")

    os.makedirs(dest, exist_ok=True)
    for out in sorted(plan):
        p = os.path.join(dest, out)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        e = plan[out]
        if e["kind"] == "link":
            os.symlink(e["data"], p)
        else:
            with open(p, "wb") as f:
                f.write(e["data"])
            os.chmod(p, e["mode"])
    print("assemble: ok -- %d file(s), layout %s, slots remaining: 0" % (len(plan), a.layout))


if __name__ == "__main__":
    main()
