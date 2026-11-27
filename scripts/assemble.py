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
Exit: 0 ok - 1 refused (leftover slot, unplaced file, dest not empty) - 2 usage.
"""
import argparse
import json
import os
import re
import stat
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


def sub_bytes(data, slots):
    for k, v in slots.items():
        data = data.replace(("<%s>" % k).encode(), v.encode())
    return data


def sub_str(s, slots):
    for k, v in slots.items():
        s = s.replace("<%s>" % k, v)
    return s


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

    plan = {}  # relative output path -> ("link", target) | ("file", bytes, mode)
    bad_paths, bad_content, unplaced = [], [], []
    for mod_path, m in manifests:
        src = os.path.normpath(os.path.join(mod_path, m["source"]))
        if not os.path.isdir(src):
            die(2, "module %s: source %s is not a directory" % (m.get("id"), src))
        rules = [(glob_re(g), t, g) for g, t in m["placement"].items()]
        for _, t, g in rules:
            if t not in ("root", "unit"):
                die(2, "module %s: placement %r -> %r (want root|unit)" % (m.get("id"), g, t))
        entries = []
        for dp, dns, fns in os.walk(src):
            dns.sort()
            for n in sorted(fns) + [d for d in dns if os.path.islink(os.path.join(dp, d))]:
                entries.append(os.path.relpath(os.path.join(dp, n), src))
        for rel in sorted(entries):
            target = next((t for rx, t, _ in rules if rx.match(rel)), None)
            if target is None:
                unplaced.append(rel)
                continue
            out = sub_str(rel, slots)
            if "<" in out and re.search(r"<[^<>/]*>", out):
                bad_paths.append(out)
            if target == "unit" and unit_dir:
                out = unit_dir + "/" + out
            full = os.path.join(src, rel)
            if out in plan:
                die(1, "two files land on %s" % out)
            if os.path.islink(full):
                plan[out] = ("link", os.readlink(full))
                continue
            with open(full, "rb") as f:
                data = f.read()
            data = sub_bytes(data, slots)
            for k in slots:
                if ("<%s>" % k).encode() in data:
                    bad_content.append(out)
                    break
            mode = (stat.S_IMODE(os.stat(full).st_mode) & ~umask) | stat.S_IWUSR
            plan[out] = ("file", data, mode)

    if unplaced or bad_paths or bad_content:
        for p in unplaced:
            sys.stderr.write("    unplaced: %s\n" % p)
        for p in bad_paths:
            sys.stderr.write("    path: %s\n" % p)
        for p in bad_content:
            sys.stderr.write("    file: %s\n" % p)
        die(1, "refused -- %d unplaced file(s), %d path(s) and %d file(s) with a leftover slot"
            % (len(unplaced), len(bad_paths), len(bad_content)))
    if not plan:
        die(1, "nothing to assemble")

    os.makedirs(dest, exist_ok=True)
    for out in sorted(plan):
        p = os.path.join(dest, out)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        e = plan[out]
        if e[0] == "link":
            os.symlink(e[1], p)
        else:
            with open(p, "wb") as f:
                f.write(e[1])
            os.chmod(p, e[2])
    print("assemble: ok -- %d file(s), layout %s, slots remaining: 0" % (len(plan), a.layout))


if __name__ == "__main__":
    main()
