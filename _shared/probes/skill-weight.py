"""skill-weight core: see skill-weight.sh for the why, the rules and the exit codes.
Run through the wrapper, which checks python3 + PyYAML first."""
import datetime
import hashlib
import os
import re
import sys

import yaml

SKILLS = ["prod-spec", "prod-review", "prod-incident", "prod-implement",
          "prod-test-synth", "prod-ops", "prod-curate", "prod-bootstrap", "prod-new"]
MAX_LINES, RATCHET_PCT = 500, 5
CEILINGS = {"eager": 64000, "reachable": 128000}
SETS = ("eager", "reachable")
ANCHOR = "Read `references/preamble.md` first"
FORMAT_ERR = "baseline format is older than this probe: re-record with `make skill-weight-baseline`"
RERECORD = "re-record with `make skill-weight-baseline` if intended"
# One regex, whole body, any form (backticked, bare, ./, link target, <skill>/ prefix).
# `*` not `+`: a bare `references/` (the whole directory) must match, not vanish.
REF_RE = re.compile(r"(?<![A-Za-z0-9_])references/[A-Za-z0-9_./-]*")
GLOB = "*?[{"  # a glob mention orders every file it matches read, exactly as a directory does
GLOB_TAIL_RE = re.compile(r"[^\s`'\")<>]*")
PROBES = "references/probes/"  # where a skill's RUN scripts are linked; the path alone does not make a probe
# `references` as a whole backticked token or a link target, with or without a leading <dir>/ and a trailing /
DIR_TOKEN_RE = re.compile(r"`((?:[^`\s]*/)?references/?)`|\]\(((?:[^)\s]*/)?references/?)\)")
WRAP_RE = re.compile(r"(references/[A-Za-z0-9_./-]*-)[ \t]*\n[ \t]*")  # path wrapped after a hyphen
TICK_RE = re.compile(r"`(references/[^`\s]+)`")
HEADER = ["skill", "SKILL.md lines", "SKILL.md bytes", "eager bytes", "reachable bytes",
          "eager probe bytes", "reachable probe bytes", "eager tokens", "reachable tokens",
          "eager files", "reachable files"]

tokens = lambda b: (b + 2) // 4


def slurp(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def refs_in(text):
    """Every references/<path> mention, as (start, end, path); trailing dots dropped. A bare
    `references/` and a glob (`references/*.md`, `{a,b}`, `?`, `[x]`) are returned like any
    other path: they resolve to no file, so measure() fails them."""
    out = []
    for m in REF_RE.finditer(text):
        end = m.end()
        if text[end:end + 1] and text[end] in GLOB:
            end = GLOB_TAIL_RE.match(text, end).end()
            path = text[m.start():end]
        else:
            raw = m.group(0)
            last = raw.rsplit("/", 1)[-1]
            # a last segment made only of dots is `.` or `..`, not sentence punctuation: keep it
            path = raw if last and not last.strip(".") else raw.rstrip(".")
            end = m.start() + len(path)
        out.append((m.start(), end, path))
    return out


def dotted(ref):
    """True when a mention has a `.` or `..` segment: it names its file indirectly."""
    return any(seg in (".", "..") for seg in ref.split("/"))


def is_probe(root, skill, ref, real):
    """A PROBE is a script the skill RUNS, so its source is not read context. All must hold:
    the mention is under references/probes/ with no `.`/`..` segment; its REAL path (links
    resolved) is inside the repo's _shared/probes/ or the skill's own references/probes/; and it
    is an executable regular file named *.sh. Anything else under references/probes/ is an
    ordinary reference and is counted."""
    if not ref.startswith(PROBES) or dotted(ref):
        return False
    if not (os.path.isfile(real) and os.access(real, os.X_OK) and real.endswith(".sh")):
        return False
    homes = [os.path.realpath(os.path.join(root, "_shared", "probes")),
             os.path.realpath(os.path.join(root, skill, "references", "probes"))]
    return any(real.startswith(h + os.sep) for h in homes)


def eager_paragraph(text):
    for para in re.split(r"\n[ \t]*\n", text):
        flat = " ".join(para.split())
        if ANCHOR in flat:
            return flat
    return None


def eager_refs(flat):
    """Backticked references/ paths in the anchor paragraph, conditional units dropped.
    A UNIT ends at . ! ? (then whitespace) or at ';'. Dashes do not end it. A unit is
    conditional when it begins with "If ", contains "also read" or contains "only where";
    then EVERY reference in it is dropped, on either side of a dash."""
    flat = flat.replace("e.g.", "e_g_").replace("i.e.", "i_e_")
    out = []
    for unit in re.split(r"(?<=[.!?])\s+|;", flat):
        c = unit.strip()
        if c.startswith("If ") or "also read" in c or "only where" in c:
            continue
        for ref in TICK_RE.findall(c):
            if ref not in out:
                out.append(ref)
    return out


def unticked(flat):
    """Mentions in the anchor paragraph that are not exactly a backticked `references/<path>`."""
    bad = []
    for s, e, path in refs_in(flat):
        if not (s > 0 and flat[s - 1] == "`" and flat[e:e + 1] == "`"):
            bad.append(path)
    return bad


def resolve(root, skill, ref):
    p = os.path.join(root, skill, ref)
    if os.path.isfile(p) and os.access(p, os.R_OK):  # isfile follows links
        return os.path.realpath(p), os.path.getsize(p)  # the TARGET's size
    return None, 0


def measure(root, skills=SKILLS):
    rows, problems, found = {}, {}, 0
    for s in skills:
        problems[s] = []
        md = os.path.join(root, s, "SKILL.md")
        if not os.path.isfile(md):
            problems[s].append("no readable %s/SKILL.md -- a skill without its entrypoint weighs nothing and loads as nothing" % s)
            continue
        found += 1
        text = slurp(md)
        lines = len(text.splitlines())
        text = WRAP_RE.sub(r"\1", text)
        size = os.path.getsize(md)
        if lines > MAX_LINES:
            problems[s].append("SKILL.md is %d lines, over the %d-line ceiling (agentskills.io/specification)" % (lines, MAX_LINES))
        mentioned = []
        for _, _, p in refs_in(text):
            if p not in mentioned:
                mentioned.append(p)
        seen, reach, unresolved = {os.path.realpath(md)}, ["SKILL.md"], []
        reach_bytes, rprobes, notes, noted = size, 0, [], set()
        for m in DIR_TOKEN_RE.finditer(text):
            tok = m.group(1) or m.group(2)
            problems[s].append("mentioned %s names the whole references directory, which orders every file in it read and cannot be measured: name the files explicitly" % tok)
        for ref in sorted(mentioned):
            if dotted(ref):
                problems[s].append("mentioned %s has a `.` or `..` segment: name the file by its direct path" % ref)
                continue
            real, n = resolve(root, s, ref)
            if real is None:
                unresolved.append(ref)
            elif real not in seen:
                seen.add(real)
                reach.append(ref)
                if is_probe(root, s, ref, real):
                    rprobes += n
                else:
                    reach_bytes += n
                    if ref.startswith(PROBES) and ref not in noted:
                        noted.add(ref)
                        notes.append("note: %s %s is not an executable .sh under _shared/probes: counted as read context" % (s, ref))
        for ref in unresolved:
            hint = ""
            if ref.endswith("/") or any(c in ref for c in GLOB):
                hint = "; a directory or glob mention orders every file in it read and cannot be measured: name the files explicitly"
            problems[s].append("mentioned %s does not resolve to a readable file (dangling link, directory or typo)%s" % (ref, hint))
        # Defence in depth: the anchor paragraph itself mentions references/preamble.md, so a
        # skill with no mention at all already fails "no paragraph contains" below.
        if len(reach) == 1 and not unresolved and not any(dotted(r) for r in mentioned):
            problems[s].append("no references/ mention found -- every skill mentions at least references/preamble.md, so the rule went blind")
        para = eager_paragraph(text)
        eager, eager_bytes, eprobes = ["SKILL.md"], size, 0
        if para is None:
            problems[s].append("no paragraph contains %r -- the opening read-first order is gone or reworded" % ANCHOR)
        else:
            for p in unticked(para):
                problems[s].append("the read-first paragraph mentions %s outside backticks; write it as `references/<path>` or the eager rule cannot see it" % p)
            erefs = eager_refs(para)
            if not erefs:
                problems[s].append("the eager rule matched no reference -- every skill orders at least references/preamble.md, so the rule went blind (or the opening paragraph lost its read-first order)")
            eseen = {os.path.realpath(md)}
            for ref in erefs:
                if dotted(ref):
                    continue  # already failed above; never resolved, so it cannot displace a file
                real, n = resolve(root, s, ref)
                if real is not None and real not in eseen:
                    eseen.add(real)
                    eager.append(ref)
                    if is_probe(root, s, ref, real):
                        eprobes += n
                        problems[s].append("the read-first paragraph orders %s, a probe: \"read first\" is not \"run\"; move the mention to the step that runs it" % ref)
                    else:
                        eager_bytes += n
        rows[s] = dict(lines=lines, size=size, eager=eager, eager_bytes=eager_bytes,
                       eager_probes=eprobes, notes=notes, reachable=reach, reachable_bytes=reach_bytes,
                       reachable_probes=rprobes)
    return rows, problems, found


def table_lines(rows, skills=SKILLS):
    out = ["| " + " | ".join(HEADER) + " |", "|" + "---|" * len(HEADER)]
    for s in skills:
        r = rows[s]
        out.append("| %s | %d | %d | %d | %d | %d | %d | %d | %d | %s | %s |" % (
            s, r["lines"], r["size"], r["eager_bytes"], r["reachable_bytes"], r["eager_probes"],
            r["reachable_probes"], tokens(r["eager_bytes"]), tokens(r["reachable_bytes"]),
            ", ".join(sorted(r["eager"])), ", ".join(sorted(r["reachable"]))))
    return out


def checksum(lines):
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def write_baseline(root, rows, path, skills=SKILLS):
    tl = table_lines(rows, skills)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write("# Skill weight baseline\n\n"
                "Generated by `_shared/probes/skill-weight.sh --write` (`make skill-weight-baseline`). Do not hand-edit:\n"
                "the last line is a checksum of the table, and `skill-weight.sh` fails when they disagree.\n"
                "EAGER = SKILL.md + the references its opening paragraph orders read first. REACHABLE = SKILL.md + every\n"
                "references/ file it names explicitly. A PROBE (an executable .sh whose real path is in _shared/probes/) is a\n"
                "script the skill RUNS, not reads: it stays in the file lists but its bytes are the `probe bytes` columns,\n"
                "outside `eager bytes` / `reachable bytes`, which are the gated numbers. approx tokens = gated bytes/4. The probe fails when a\n"
                "skill's file list changes in either direction, or when a set's gated bytes exceed its row by more than\n"
                "%d %%. Read the diff of this file as the review of what a skill loads.\n\n" % RATCHET_PCT)
        f.write("\n".join(tl) + "\n\n")
        f.write("checksum: %s\n" % checksum(tl))
    os.replace(tmp_path, path)  # atomic; never rewrites a file in place


def load_baseline(path, skills=SKILLS):
    """-> (rows, errors); rows is None when the file cannot be read."""
    try:
        raw = slurp(path).splitlines()
    except OSError:
        return None, []
    errs, rows, tl, ck = [], {}, [], None
    for ln in raw:
        st = ln.strip()
        if st.startswith("|"):
            tl.append(st)
        m = re.fullmatch(r"checksum:\s*([0-9a-f]{64})", st)
        if m:
            ck = m.group(1)
    if ck is None:
        errs.append("baseline has no `checksum:` line -- re-record with --write")
    elif ck != checksum(tl):
        errs.append("hand-edited baseline: its table does not match its checksum; re-record with --write")
    for st in tl:
        cells = [c.strip() for c in st.strip("|").split("|")]
        if cells[0] == "skill" and cells != HEADER:
            return {}, [FORMAT_ERR]
    for st in tl:
        cells = [c.strip() for c in st.strip("|").split("|")]
        if cells[0] == "skill" or all(re.fullmatch(r":?-+:?", c) for c in cells):
            continue
        if cells[0] not in skills:
            errs.append("baseline has a row for %r, which is not one of the nine skills" % cells[0])
        elif cells[0] in rows:
            errs.append("baseline has two rows for %s" % cells[0])
        elif len(cells) != len(HEADER) or not all(c.isdigit() for c in cells[1:9]):
            errs.append("baseline row for %s is malformed" % cells[0])
        else:
            rows[cells[0]] = dict(eager_bytes=int(cells[3]), reachable_bytes=int(cells[4]),
                                  eager=[x.strip() for x in cells[9].split(",") if x.strip()],
                                  reachable=[x.strip() for x in cells[10].split(",") if x.strip()])
    return rows, errs


def load_liabilities(path):
    liab, errs, reg_err = {}, [], None
    if not os.path.exists(path):
        return liab, errs, reg_err
    try:
        data = yaml.safe_load(slurp(path)) or {}
        ents = data.get("entries") or []
        if not isinstance(ents, list):
            raise ValueError("`entries:` is not a list")
        for e in ents:
            if not isinstance(e, dict) or e.get("obligation") != "skill-weight":
                continue
            sk, cb, ex = e.get("skill"), e.get("ceiling_bytes"), e.get("expires")
            st = e.get("set", "eager")
            if isinstance(ex, datetime.datetime):
                ex = ex.date()
            if not (isinstance(sk, str) and isinstance(cb, int) and not isinstance(cb, bool)
                    and isinstance(ex, datetime.date) and e.get("owner") and st in SETS):
                raise ValueError("entry %r needs skill, set (eager|reachable), integer ceiling_bytes, owner and a YYYY-MM-DD expires" % (e.get("id"),))
            if (sk, st) in liab:
                errs.append("two liabilities for (%s, %s): %s and %s -- one entry per (skill, set)" % (sk, st, liab[(sk, st)]["id"], e.get("id")))
                continue
            liab[(sk, st)] = dict(ceiling=cb, expires=ex, id=e.get("id"))
    except Exception as exc:  # unparseable registry must not excuse anyone
        reg_err = "%s: %s" % (os.path.basename(path), exc)
    return liab, errs, reg_err


def run(mode, root, baseline_path=None, registry=None, today=None, skills=SKILLS):
    """Pure core: returns (exit_code, stdout_lines, stderr_lines). `today` and `skills` are
    injectable (the selftest uses a small skill set; the CLI always uses the nine)."""
    baseline_path = baseline_path or os.path.join(root, "benchmarks", "skill-weight-baseline.md")
    registry = registry or os.path.join(root, "registries", "waivers.yaml")
    fails = 0
    out, err = [], []

    def fail(name, msg):
        nonlocal fails
        out.append("  FAIL  %-16s %s" % (name, msg))
        fails += 1

    rows, problems, found = measure(root, skills)
    if found == 0:
        err.append("skill-weight: FAIL -- no SKILL.md found under %s; nothing checked is not a pass" % root)
        return 2, out, err

    if mode == "write":
        bad = [s for s in skills if problems[s] and not (len(problems[s]) == 1 and "SKILL.md is" in problems[s][0])]
        if bad or len(rows) != len(skills):
            for s in skills:
                for m in problems[s]:
                    fail(s, m)
            err.append("skill-weight: refusing to record a baseline from a measurement that failed")
            return 1, out, err
        write_baseline(root, rows, baseline_path, skills)
        out.append("skill-weight: baseline recorded -- %s (%d skills)" % (os.path.relpath(baseline_path, root), len(skills)))
        return 0, out, err

    base, base_errs = load_baseline(baseline_path, skills)
    liab, liab_errs, reg_err = load_liabilities(registry)
    today = today or datetime.datetime.now(datetime.timezone.utc).date()
    fmt_bad = FORMAT_ERR in base_errs
    notes, over_live, totals = [], 0, {"eager": 0, "reachable": 0}
    ptotals = {"eager": 0, "reachable": 0}
    for s in skills:
        if s not in rows:
            continue
        r = rows[s]
        for st in SETS:
            b, lst = r[st + "_bytes"], r[st]
            totals[st] += b
            ptotals[st] += r[st + "_probes"]
            if fmt_bad:
                pass  # one line says it all; per-skill "absent"/"malformed" lines would bury it
            elif base is None:
                if st == "eager":
                    problems[s].append("no readable benchmarks/skill-weight-baseline.md -- run `make skill-weight-baseline`")
            elif s not in base:
                if st == "eager":
                    problems[s].append("absent from benchmarks/skill-weight-baseline.md -- run `make skill-weight-baseline`")
            else:
                was = base[s][st]
                added, gone = sorted(set(lst) - set(was)), sorted(set(was) - set(lst))
                if added or gone:
                    problems[s].append("%s file list changed (%s%s%s): %s"
                                       % (st.upper(), "ADDED " + ", ".join(added) if added else "",
                                          "; " if added and gone else "", "REMOVED " + ", ".join(gone) if gone else "", RERECORD))
                bb = base[s][st + "_bytes"]
                if b * 100 > bb * (100 + RATCHET_PCT):
                    problems[s].append("%s set grew to %d bytes from baseline %d (+%.1f %%, limit +%d %%): the weight this skill loads went up"
                                       % (st.upper(), b, bb, 100.0 * (b - bb) / bb, RATCHET_PCT))
                elif b < bb and not (added or gone):
                    notes.append("note: %s %s set is %d bytes below its baseline; `make skill-weight-baseline` can re-record it lower" % (s, st, bb - b))
            ceil, l = CEILINGS[st], liab.get((s, st))
            if b > ceil:
                if reg_err:
                    problems[s].append("%s set over the %d-byte ceiling and the liability registry is unreadable (%s)" % (st.upper(), ceil, reg_err))
                elif l is None:
                    problems[s].append("%s set %d bytes is over the %d-byte ceiling with no live `set: %s` liability in registries/waivers.yaml" % (st.upper(), b, ceil, st))
                elif l["expires"] < today:
                    problems[s].append("%s set %d bytes is over the ceiling and its liability %s EXPIRED %s -- it excuses nothing now" % (st.upper(), b, l["id"], l["expires"]))
                elif b > l["ceiling"]:
                    problems[s].append("%s set %d bytes exceeds its liability's ceiling_bytes %d: the liability excuses the ceiling, not growth" % (st.upper(), b, l["ceiling"]))
                else:
                    over_live += 1
            elif l is not None:
                problems[s].append("stale liability %s: %s set %d bytes is under the %d-byte ceiling -- remove the liability" % (l["id"], st.upper(), b, ceil))
    for (sk, st), l in liab.items():
        if sk not in skills:
            fail(sk, "liability %s names a skill that is not one of the nine -- remove the liability" % l["id"])
    for m in liab_errs:
        fail("registry", m)
    if reg_err:
        fail("registry", "registries/waivers.yaml does not parse as skill-weight liabilities (%s)" % reg_err)
    for m in base_errs:
        fail("baseline", m)
    for s in skills:
        if problems[s]:
            for m in problems[s]:
                fail(s, m)
        else:
            r = rows[s]
            out.append("  ok    %-16s %3d lines, eager %d file(s) %d bytes (~%d tok) (+ probes %d not gated), reachable %d file(s) %d bytes (~%d tok) (+ probes %d not gated)"
                  % (s, r["lines"], len(r["eager"]), r["eager_bytes"], tokens(r["eager_bytes"]), r["eager_probes"],
                     len(r["reachable"]), r["reachable_bytes"], tokens(r["reachable_bytes"]), r["reachable_probes"]))
    for s in skills:
        if s in rows:
            notes.extend(rows[s]["notes"])
    for n in notes:
        out.append("  " + n)
    if fails:
        err.append("skill-weight: %d failure(s) across %d skill(s)" % (fails, found))
        return 1, out, err
    out.append("skill-weight: ok -- %d skill(s), eager total %d bytes (~%d tokens) (+ probes %d not gated), reachable total %d bytes (~%d tokens) (+ probes %d not gated), %d set(s) over ceiling under live liability"
          % (found, totals["eager"], tokens(totals["eager"]), ptotals["eager"], totals["reachable"],
             tokens(totals["reachable"]), ptotals["reachable"], over_live))
    return 0, out, err


def main():
    rc, out, err = run(sys.argv[1], sys.argv[2])
    for ln in out:
        print(ln)
    for ln in err:
        print(ln, file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
