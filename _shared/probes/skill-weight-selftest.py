"""skill-weight selftest driver: every rule of skill-weight.py shown firing on a temp
fixture where its property is false. In-process (imports the core's run()), so a case
costs milliseconds. Run by skill-weight-selftest.sh, which adds the end-to-end cases that
can only be proven through the shell wrapper.

usage: skill-weight-selftest.py <tmpdir>   (leaves <tmpdir>/_tpl, a healthy root, for the wrapper)
last line: DRIVER <pass> <bad>"""
import datetime
import importlib.util
import os
import shutil
import sys

sys.dont_write_bytecode = True  # a selftest must leave no __pycache__ in the tree
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("skill_weight", os.path.join(here, "skill-weight.py"))
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)

tmp = sys.argv[1]
SKILLS = sw.SKILLS
SUB = ["prod-review", "prod-ops", "prod-curate"]  # in-process cases need only these
res = {"pass": 0, "bad": 0}
P0 = ("Read `references/preamble.md` first, then `references/b.md`.\n"
      "Output formats: `references/a.md`. If a plan exists, also read\n`references/c.md`.")


def ok(name):
    print("  ok   %s" % name)
    res["pass"] += 1


def bad(name, why):
    print("  BAD  %s\n       %s" % (name, why.replace("\n", "|")[:400]))
    res["bad"] += 1


def put(path, text):
    """Write by replacement: fixtures are hardlink copies of the template, never edit in place."""
    if os.path.lexists(path):
        os.unlink(path)
    with open(path, "w") as f:
        f.write(text)


def fill(path, n, ch="p"):
    put(path, ch * n)


def skill_md(root, skill, para, body="body"):
    os.makedirs(os.path.join(root, skill, "references"), exist_ok=True)
    put(os.path.join(root, skill, "SKILL.md"),
        "---\nname: %s\ndescription: x\n---\n# %s\n\n%s\n\n%s\n" % (skill, skill, para, body))


def ev(root, today=None):
    rc, out, err = sw.run("check", root, today=today, skills=SUB)
    return rc, "\n".join(out + err)


def rec(root, skills=SUB):
    return sw.run("write", root, skills=skills)


def okline(root, skill):
    _, text = ev(root)
    for ln in text.split("\n"):
        if ln.startswith("  ok    %s " % skill):
            import re
            return re.sub(r"[0-9]+ bytes", "N bytes", re.sub(r" [0-9]+ lines,", "", re.sub(r"~[0-9]+ tok", "~N tok", ln)))
    return ""


def case(name, root, rc, has=(), hasnt=(), today=None):
    got, text = ev(root, today)
    if isinstance(has, str):
        has = (has,)
    if got == rc and all(h in text for h in has) and not any(h in text for h in hasnt):
        ok(name)
    else:
        bad(name, "want rc=%d containing %r not %r; got rc=%d: %s" % (rc, has, hasnt, got, text))


def same_line(name, root, skill, before):
    after = okline(root, skill)
    if after and after == before:
        ok(name)
    else:
        bad(name, "want unchanged ok line [%s]; got [%s]" % (before, after))


def baseline_text(root):
    with open(os.path.join(root, "benchmarks", "skill-weight-baseline.md")) as f:
        return f.read()


def baseline_row(root, skill):
    for ln in baseline_text(root).split("\n"):
        if ln.startswith("| %s |" % skill):
            return [c.strip() for c in ln.strip("|").split("|")]
    return []


def edit_baseline(root, fn, checksum=True):
    path = os.path.join(root, "benchmarks", "skill-weight-baseline.md")
    lines = baseline_text(root).split("\n")
    lines = fn(lines)
    if checksum:
        tl = [l.strip() for l in lines if l.strip().startswith("|")]
        lines = ["checksum: " + sw.checksum(tl) if l.startswith("checksum:") else l for l in lines]
    put(path, "\n".join(lines))


def waivers(root, *entries, today_ok=True):
    """entries: (id, skill, set|None, ceiling, expires)"""
    txt = "entries:\n"
    for i, sk, st, cb, ex in entries:
        txt += "  - id: %s\n    obligation: skill-weight\n    skill: %s\n" % (i, sk)
        if st:
            txt += "    set: %s\n" % st
        txt += "    ceiling_bytes: %s\n    owner: t\n    created: 2026-01-01\n    expires: %s\n    reason: x\n" % (cb, ex)
    put(os.path.join(root, "registries", "waivers.yaml"), txt)


# ---- fixture templates, built once: _tpl = all nine (left for the wrapper), _mini = SUB ----
def build(path, skills):
    for s in skills:
        skill_md(path, s, P0)
        r = os.path.join(path, s, "references")
        fill(os.path.join(r, "preamble.md"), 1000, "p")
        fill(os.path.join(r, "a.md"), 500, "a")
        fill(os.path.join(r, "b.md"), 500, "b")
        fill(os.path.join(r, "c.md"), 500, "c")
    os.makedirs(os.path.join(path, "benchmarks"))
    os.makedirs(os.path.join(path, "registries"))
    rec(path, skills)


build(os.path.join(tmp, "_tpl"), SKILLS)
tpl = os.path.join(tmp, "_mini")
build(tpl, SUB)
counter = [0]


def mk(name, baseline=True):
    counter[0] += 1
    r = os.path.join(tmp, "%s-%d" % (name, counter[0]))
    shutil.copytree(tpl, r, symlinks=True, copy_function=os.link)
    if not baseline:
        os.remove(os.path.join(r, "benchmarks", "skill-weight-baseline.md"))
    return r


def sk(root, skill, *parts):
    return os.path.join(root, skill, *parts)


# ---- healthy fixture and skill-level rules ------------------------------------------
r = mk("healthy")
case("healthy fixture passes", r, 0, "skill-weight: ok")
case("healthy fixture reports both sets", r, 0, "reachable 5 file(s)")
case("conditional clause stays out of EAGER (c.md is reachable only)", r, 0, "eager 4 file(s)")
r = mk("nobase", False)
case("no baseline file fails", r, 1, "no readable benchmarks/skill-weight-baseline.md")
r = mk("absent")
edit_baseline(r, lambda L: [l for l in L if not l.startswith("| prod-ops ")])
case("skill absent from the baseline fails", r, 1, "absent from benchmarks/skill-weight-baseline.md")
r = mk("long")
put(sk(r, "prod-ops", "SKILL.md"), "---\nname: x\n---\n\n%s\n\n%s" % (P0, "line\n" * 520))
case("SKILL.md over 500 lines fails", r, 1, "over the 500-line ceiling")
r = mk("nomd")
os.remove(sk(r, "prod-curate", "SKILL.md"))
case("missing SKILL.md fails", r, 1, "no readable prod-curate/SKILL.md")
os.makedirs(os.path.join(tmp, "empty"))
case("zero skills found is not a pass", os.path.join(tmp, "empty"), 2, "nothing checked is not a pass")
r = mk("blind")
skill_md(r, "prod-ops", "Read nothing here.")
case("an opening paragraph that matches nothing fails", r, 1, "no paragraph contains")
r = mk("blind2")
skill_md(r, "prod-ops", "Read `references/preamble.md` first.", "then `references/a.md`")
os.remove(sk(r, "prod-ops", "references", "preamble.md"))
case("a dangling mention fails (preamble removed)", r, 1, "references/preamble.md does not resolve")
r = mk("dangle")
skill_md(r, "prod-ops", P0, "see `references/ghost.md`")
case("dangling mention in a late step fails", r, 1, "references/ghost.md does not resolve")
r = mk("dirm")
os.mkdir(sk(r, "prod-ops", "references", "probes"))
skill_md(r, "prod-ops", P0, "see `references/probes/`")
case("a directory mention fails", r, 1, "references/probes/ does not resolve")
for label, txt in (("bare `references/`", "everything in `references/`"), ("bare references/ without ticks", "everything in references/ here"),
                   ("bare references/ then a comma", "see references/, then"), ("glob `references/*.md`", "and `references/*.md`"),
                   ("brace glob", "and `references/{a,b}.md`"), ("question-mark glob", "and `references/?.md`"),
                   ("bracket glob", "and `references/[ab].md`"), ("glob mid-name", "and `references/a*.md`")):
    for where in ("opening", "later"):
        r = mk("glob")
        if where == "opening":
            skill_md(r, "prod-ops", P0.replace("Output formats:", "Output formats: %s;" % txt, 1), "body")
        else:
            skill_md(r, "prod-ops", P0, "step 7: %s." % txt)
        case("%s in the %s text fails, naming the files explicitly" % (label, where), r, 1,
             ("does not resolve to a readable file", "name the files explicitly"))
r = mk("subdir2")
skill_md(r, "prod-ops", P0, "see `references/probes/`")
os.makedirs(sk(r, "prod-ops", "references", "probes"))
case("a subdirectory mention still fails, naming the files explicitly", r, 1, ("references/probes/ does not resolve", "name the files explicitly"))
r = mk("prose")
skill_md(r, "prod-ops", P0, "the references directory holds files under `references/probes/p.sh`, (see `references/a.md`), `references/b.md`: and `references/c.md`.")
os.makedirs(sk(r, "prod-ops", "references", "probes"))
fill(sk(r, "prod-ops", "references", "probes", "p.sh"), 10, "s")
rec(r)
case("prose that merely says 'the references directory' and file mentions with trailing ) , : . resolve", r, 0, "skill-weight: ok")
r = mk("noref")
skill_md(r, "prod-ops", "Nothing at all to read.", "no mention either")
case("a skill with no references/ mention at all: both the anchor and the blind guard fire", r, 1,
     ("no paragraph contains", "no references/ mention found"))
r = mk("sym")
skill_md(r, "prod-ops", P0, "see `references/link.md`")
os.symlink(os.path.join(tmp, "nowhere"), sk(r, "prod-ops", "references", "link.md"))
case("a dangling symlink fails", r, 1, "references/link.md does not resolve")
r = mk("symok")
os.makedirs(os.path.join(r, "_shared"))
fill(os.path.join(r, "_shared", "pre.md"), 1000, "q")
os.remove(sk(r, "prod-ops", "references", "preamble.md"))
os.symlink("../../_shared/pre.md", sk(r, "prod-ops", "references", "preamble.md"))
case("a symlinked reference resolves and weighs its target", r, 0, "skill-weight: ok")

# ---- EAGER rule: conditional scope (a unit ends at . ! ? ; -- never at a dash) -------
def shape(name, para, rc, has=(), hasnt=(), body="body"):
    r = mk("shape")
    skill_md(r, "prod-review", para, body)
    case(name, r, rc, has, hasnt)


def shape_same(name, para):
    r = mk("shape")
    before = okline(r, "prod-review")
    skill_md(r, "prod-review", para)
    same_line(name, r, "prod-review", before)


HEAD = "Read `references/preamble.md` first, then `references/b.md`.\n"
shape_same("semicolon-joined conditional: only the conditional clause drops, a.md still counted",
           HEAD + "Output formats: `references/a.md`; if a plan exists, also read `references/c.md`.")
shape_same("(e.g. If ...) does not drop its sentence: measured as before",
           HEAD + "Output formats: `references/a.md` (e.g. If a plan exists). If a plan exists, also read `references/c.md`.")
shape_same("(e.g. If ...) BEFORE the reference: the sentence stays whole, a.md counted",
           HEAD + "Output formats (e.g. If a plan exists) see `references/a.md`. If a plan exists, also read `references/c.md`.")
shape_same("(i.e. If ...) BEFORE the reference: the sentence stays whole, a.md counted",
           HEAD + "Output formats (i.e. If a plan exists) see `references/a.md`. If a plan exists, also read `references/c.md`.")
shape_same("conditional marker BEFORE a dash, reference AFTER it: conditional (c.md stays out)",
           HEAD + "Output formats: `references/a.md`. If a plan exists — also `references/c.md`.")
shape_same("marker AFTER a dash, reference BEFORE it: conditional (c.md stays out)",
           HEAD + "Output formats: `references/a.md`. See `references/c.md` — only where a plan exists.")
shape_same("en dash does not bound a conditional either",
           HEAD + "Output formats: `references/a.md`. See `references/c.md` – only where a plan exists.")
shape_same("`unconditional a; only where X, see b`: a counted, b not",
           HEAD + "Output formats: `references/a.md`; only where X, see `references/c.md`.")
shape_same("`If X, read c. Read a.`: c not, a counted",
           HEAD + "If X, read `references/c.md`. Output formats: `references/a.md`.")
r = mk("shape")
skill_md(r, "prod-review", "Read `references/preamble.md` first.\n\nThen read `references/b.md`. Output formats: `references/a.md`. If a plan exists, also read `references/c.md`.")
case("anchor and orders split over two paragraphs: EAGER REMOVED a.md, b.md, named", r, 1,
     "EAGER file list changed (REMOVED references/a.md, references/b.md)")
r = mk("shape")
skill_md(r, "prod-review", HEAD + "\nOutput formats: `references/a.md`. If a plan exists, also read `references/c.md`.")
case("'Output formats' moved to the next paragraph: EAGER REMOVED a.md, REACHABLE unchanged", r, 1,
     "EAGER file list changed (REMOVED references/a.md)", ("REACHABLE file list changed",))
for label, txt in (("unbackticked reference", "references/a.md."), ("./references/", "./references/a.md."),
                   ("backticked ./references/", "`./references/a.md`."), ("markdown link", "[a](references/a.md)."),
                   ("<skill>/ prefix", "`prod-review/references/a.md`.")):
    shape("%s in the anchor paragraph fails" % label,
          HEAD + "Output formats: %s If a plan exists, also read `references/c.md`." % txt, 1,
          "mentions references/a.md outside backticks")
r = mk("big")
fill(sk(r, "prod-review", "references", "big.md"), 120000, "B")
fill(sk(r, "prod-review", "references", "big2.md"), 56000, "C")
rec(r)
skill_md(r, "prod-review", P0, "Also [dimensions](references/big.md) and [tier policy](references/big2.md).")
case("176 KB added as links: REACHABLE ADDED big.md, big2.md, named", r, 1,
     ("REACHABLE file list changed (ADDED references/big.md, references/big2.md)", "REACHABLE set grew to"))
for form in ("references/d.md", "./references/d.md", "[d](references/d.md)", "prod-review/references/d.md",
             "`references/d.md`", "<references/d.md>"):
    r = mk("form")
    fill(sk(r, "prod-review", "references", "d.md"), 300, "d")
    skill_md(r, "prod-review", P0, "later step: %s." % form)
    case("late mention as %s is REACHABLE (ADDED d.md)" % form, r, 1, "REACHABLE file list changed (ADDED references/d.md)")
r = mk("wrap")
fill(sk(r, "prod-review", "references", "dom-ain.md"), 300, "d")
skill_md(r, "prod-review", P0, "later: see `references/dom-\nain.md` here.")
rec(r)
if "references/dom-ain.md" in " ".join(baseline_row(r, "prod-review")):
    ok("a path wrapped after a hyphen resolves (dom-ain.md recorded)")
else:
    bad("hyphen wrap", "dom-ain.md not recorded")
r = mk("dot")
skill_md(r, "prod-review", P0, "later: see references/a.md. And references/b.md.")
case("trailing sentence dots are not part of a path", r, 0, "skill-weight: ok")

# ---- REACHABLE accounting ------------------------------------------------------------
r = mk("late")
fill(sk(r, "prod-ops", "references", "late.md"), 700, "l")
skill_md(r, "prod-ops", P0, "Step 9: read `references/late.md`.")
rec(r)
row = baseline_row(r, "prod-ops")
if row[10].endswith("references/late.md, references/preamble.md") and "late.md" not in row[9]:
    ok("REACHABLE counts a reference named only in a late step, EAGER does not")
else:
    bad("late step", str(row))
r = mk("once")
os.symlink("a.md", sk(r, "prod-ops", "references", "alias.md"))
skill_md(r, "prod-ops", P0, "Again `references/a.md`, [a](references/a.md), ./references/a.md, prod-ops/references/a.md and the alias `references/alias.md`.")
rec(r)
want = os.path.getsize(sk(r, "prod-ops", "SKILL.md")) + 1000 + 500 + 500 + 500
got = baseline_row(r, "prod-ops")[4]
if got == str(want):
    ok("REACHABLE counts each file once (mentions and a symlink alias): %s" % got)
else:
    bad("each file once", "want %d got %s" % (want, got))
# ---- probes: a PROBE is an executable .sh whose real path is under _shared/probes -----
def genuine(r, name, size, skill="prod-ops", link=True):
    """An executable script in <root>/_shared/probes, linked from the skill's references/probes."""
    d = os.path.join(r, "_shared", "probes")
    os.makedirs(d, exist_ok=True)
    real = os.path.join(d, name)
    fill(real, size, "s")
    os.chmod(real, 0o755)
    if link:
        os.makedirs(sk(r, skill, "references", "probes"), exist_ok=True)
        put_link(sk(r, skill, "references", "probes", name), "../../../_shared/probes/" + name)
    return real


def put_link(path, target):
    if os.path.lexists(path):
        os.unlink(path)
    os.symlink(target, path)


def probe_fixture(name, eager_probe=False, size=900, body="run `references/probes/p.sh`"):
    r = mk(name)
    genuine(r, "p.sh", size)
    para = P0 + (" Then run `references/probes/p.sh`." if eager_probe else "")
    skill_md(r, "prod-ops", para, body)
    return r


r = probe_fixture("probes")
rec(r)
row = baseline_row(r, "prod-ops")
want = os.path.getsize(sk(r, "prod-ops", "SKILL.md")) + 1000 + 500 + 500 + 500
if row[6] == "900" and row[5] == "0" and row[4] == str(want) and "references/probes/p.sh" in row[10]:
    ok("a genuine probe mention is in the file list and the sub-total, not in the gated bytes")
else:
    bad("probes accounting", "want gated %d, probes 900: %s" % (want, row))
case("a recorded probe passes the check", r, 0, ("skill-weight: ok", "reachable 6 file(s)", "(+ probes 900 not gated)"))
genuine(r, "p.sh", 1350, link=False)
case("growing a mentioned probe by 50 % does NOT fail", r, 0, "skill-weight: ok")
genuine(r, "p.sh", 900000, link=False)
case("a probe growing 1000x does not fail either (not gated, no ceiling)", r, 0, "skill-weight: ok")
# BEFORE: an EAGER probe was blessed (listed, sub-totalled, not gated). AFTER: it FAILS.
r = probe_fixture("probes-eager", eager_probe=True)
case("a genuine probe in the read-first paragraph FAILS: read first is not run", r, 1,
     "orders references/probes/p.sh, a probe")
r = probe_fixture("probes-new")
rec(r)
genuine(r, "q.sh", 100)
skill_md(r, "prod-ops", P0, "run `references/probes/p.sh` and `references/probes/q.sh`")
case("adding a NEW probe mention fails the file-list ratchet, naming it", r, 1,
     "REACHABLE file list changed (ADDED references/probes/q.sh)")
r = probe_fixture("probes-gone")
rec(r)
skill_md(r, "prod-ops", P0, "nothing to run")
case("removing a probe mention fails the file-list ratchet, naming it", r, 1,
     "REACHABLE file list changed (REMOVED references/probes/p.sh)")
r = probe_fixture("probes-six")
rec(r)
B = int(baseline_row(r, "prod-ops")[4])
fill(sk(r, "prod-ops", "references", "a.md"), 500 + B * 55 // 1000, "a")  # +5.5 % of the gated reachable bytes
case("with a probe in the set, a non-probe reference growing 5.5 % still fails", r, 1, "REACHABLE set grew to")
# BEFORE: a 130000-byte plain file under references/probes/ was "a probe" and passed. AFTER: a genuine probe does.
r = probe_fixture("probes-ceil", size=130000)
rec(r)
case("a set over the ceiling only when a genuine probe is counted passes with no liability", r, 0,
     ("skill-weight: ok", "(+ probes 130000 not gated)"), ("over the 128000-byte ceiling",))
waivers(r, ("w1", "prod-ops", "reachable", 140000, "2099-01-01"))
case("...and a reachable liability for it is stale", r, 1, "stale liability w1")
r = mk("stale-drop")
fill(sk(r, "prod-ops", "references", "d.md"), 130000, "d")
skill_md(r, "prod-ops", P0, "step 5: `references/d.md`")
rec(r)
waivers(r, ("w1", "prod-ops", "reachable", 140000, "2099-01-01"))
case("a set over its ceiling under a live liability passes", r, 0, "skill-weight: ok")
fill(sk(r, "prod-ops", "references", "d.md"), 1000, "d")
rec(r)
case("the set drops under its ceiling and is re-recorded: the liability is stale", r, 1, "stale liability w1")

# the not-gated numbers come from the right set: a probe in a later step is REACHABLE only
r = probe_fixture("probes-sets", size=777)
rec(r)
case("(+ probes N not gated): eager 0 and reachable 777, separately", r, 0,
     ("eager 4 file(s)", "(+ probes 0 not gated), reachable 6 file(s)", "(+ probes 777 not gated)"))
rc, out, err = sw.run("check", r, skills=SUB)
if any("skill-weight: ok" in l and "eager total" in l and "(+ probes 0 not gated), reachable total" in l
       and l.rstrip().count("(+ probes 777 not gated)") == 1 for l in out):
    ok("the summary line shows eager probes 0 and reachable probes 777")
else:
    bad("summary probes", "\n".join(out)[-300:])

# anything under references/probes/ that is not a genuine probe is read context, counted, with a note
NOTE = "is not an executable .sh under _shared/probes: counted as read context"
r = mk("fake-copy")
os.makedirs(sk(r, "prod-review", "references", "probes"))
fill(sk(r, "prod-review", "references", "probes", "big.md"), 70000, "B")
skill_md(r, "prod-review", P0, "step 4: read `references/probes/big.md`")
rec(r)
case("a 70 KB markdown copied under references/probes is counted (REACHABLE over the ceiling is not hidden), with a note", r, 0,
     ("reachable 6 file(s)", "(+ probes 0 not gated)", "references/probes/big.md " + NOTE))
r = mk("fake-eager")
os.makedirs(sk(r, "prod-review", "references", "probes"))
fill(sk(r, "prod-review", "references", "probes", "big.md"), 70000, "B")
skill_md(r, "prod-review", P0 + " Also `references/probes/big.md`.".replace("Also", "Then read"), "body")
rec(r)
case("...and in the read-first paragraph it is counted in EAGER, over 64000 FAILS with no liability", r, 1,
     ("EAGER set 72", "over the 64000-byte ceiling"))
r = mk("fake-link")
os.makedirs(sk(r, "prod-review", "references", "probes"))
fill(os.path.join(r, "_shared-doc.md"), 3000, "L")
os.symlink("../../../_shared-doc.md", sk(r, "prod-review", "references", "probes", "doc.md"))
skill_md(r, "prod-review", P0, "see `references/probes/doc.md`")
rec(r)
case("a symlink under references/probes to a markdown file is counted", r, 0, ("references/probes/doc.md " + NOTE,))
if baseline_row(r, "prod-review")[6] == "0":
    ok("...and its bytes are in the gated total, probes sub-total 0")
else:
    bad("symlink md", str(baseline_row(r, "prod-review")))
r = mk("fake-noexec")
genuine(r, "n.sh", 800, "prod-review")
os.chmod(os.path.join(r, "_shared", "probes", "n.sh"), 0o644)
skill_md(r, "prod-review", P0, "run `references/probes/n.sh`")
rec(r)
case("a non-executable .sh is counted as read context", r, 0, "references/probes/n.sh " + NOTE)
case("...and the note says to chmod +x it", r, 0, "it is not executable: `chmod +x` it if the skill runs it")
r = mk("fake-outside")
os.makedirs(os.path.join(r, "elsewhere"))
fill(os.path.join(r, "elsewhere", "o.sh"), 800, "o")
os.chmod(os.path.join(r, "elsewhere", "o.sh"), 0o755)
os.makedirs(sk(r, "prod-review", "references", "probes"))
os.symlink("../../../elsewhere/o.sh", sk(r, "prod-review", "references", "probes", "o.sh"))
skill_md(r, "prod-review", P0, "run `references/probes/o.sh`")
rec(r)
case("an executable .sh whose real path is outside _shared/probes and the skill's own probes is counted", r, 0,
     "references/probes/o.sh " + NOTE)
r = mk("own-real")
os.makedirs(sk(r, "prod-review", "references", "probes"))
fill(sk(r, "prod-review", "references", "probes", "own.sh"), 800, "o")
os.chmod(sk(r, "prod-review", "references", "probes", "own.sh"), 0o755)
skill_md(r, "prod-review", P0, "run `references/probes/own.sh`")
rec(r)
case("installed-copy layout (no _shared/probes): an executable .sh really in the skill's own references/probes is a probe", r, 0,
     "(+ probes 800 not gated)", (NOTE,))
# the exploit: in the SOURCE repo (_shared/probes exists) a REAL executable .sh under the skill's references/probes
# is an ordinary reference: counted, and over the ceiling it FAILS without a liability
r = mk("own-real-src")
genuine(r, "g.sh", 100, "prod-ops")
os.makedirs(sk(r, "prod-review", "references", "probes"))
fill(sk(r, "prod-review", "references", "probes", "big.sh"), 130000, "#")
os.chmod(sk(r, "prod-review", "references", "probes", "big.sh"), 0o755)
skill_md(r, "prod-review", P0, "step 4: read `references/probes/big.sh`")
rec(r)
case("source repo: a REAL executable .sh under the skill's own references/probes is counted, with a note, and over the ceiling it FAILS without a liability", r, 1,
     ("over the 128000-byte ceiling", "references/probes/big.sh " + NOTE))
# an executable NON-.sh really in _shared/probes is counted (suffix check)
r = mk("probe-py")
genuine(r, "p.py", 900, "prod-ops")
skill_md(r, "prod-ops", P0, "run `references/probes/p.py`")
rec(r)
case("an executable non-.sh file in _shared/probes is counted, not a probe", r, 0, "references/probes/p.py " + NOTE)
# an executable .sh whose real path is in ANOTHER directory named probes is counted
r = mk("other-probes")
os.makedirs(os.path.join(r, "elsewhere", "probes"))
fill(os.path.join(r, "elsewhere", "probes", "o.sh"), 800, "o")
os.chmod(os.path.join(r, "elsewhere", "probes", "o.sh"), 0o755)
os.makedirs(sk(r, "prod-review", "references", "probes"))
os.symlink("../../../elsewhere/probes/o.sh", sk(r, "prod-review", "references", "probes", "o.sh"))
skill_md(r, "prod-review", P0, "run `references/probes/o.sh`")
rec(r)
case("an executable .sh whose real path is in another directory named probes is counted", r, 0,
     "references/probes/o.sh " + NOTE)
r = mk("dotdot")
genuine(r, "p.sh", 900, "prod-ops")
skill_md(r, "prod-ops", P0, "run `references/probes/../a.md`")
case("references/probes/../a.md FAILS: name the file by its direct path", r, 1, "name the file by its direct path")
r = mk("dotdot2")
skill_md(r, "prod-ops", P0, "run `references/probes/../c.md` and also `references/c.md`")
case("a `..` mention fails and does not displace references/c.md in the de-dup: c.md stays REACHABLE", r, 1,
     "name the file by its direct path", ("REACHABLE file list changed",))
for label, txt in (("`references/.`", "`references/.`"), ("`references/..`", "`references/..`"),
                   ("`references/./a.md`", "`references/./a.md`")):
    r = mk("dots")
    skill_md(r, "prod-ops", P0, "see %s here" % txt)
    case("%s FAILS as a direct-path violation, not 'outside backticks'" % label, r, 1,
         "name the file by its direct path", ("outside backticks",))

# a bare `references` (no trailing slash) as a token or link target orders the directory read
for label, txt in (("`references`", "every file in the `references` folder"), ("`prod-review/references`", "see `prod-review/references`"),
                   ("`./references`", "see `./references`"), ("link target (references)", "see [all](references)"),
                   ("link target (prod-ops/references/)", "see [all](prod-ops/references/)")):
    for where in ("opening", "later"):
        r = mk("bareref")
        if where == "opening":
            skill_md(r, "prod-ops", P0.replace("Output formats:", "Output formats: %s;" % txt, 1), "body")
        else:
            skill_md(r, "prod-ops", P0, "step 7: %s." % txt)
        case("%s in the %s text fails, naming the files explicitly" % (label, where), r, 1, "name the files explicitly")
# the same directory by another spelling: angle-bracket target, titled link, capitalised token
for label, txt in (("link target <references>", "see [all](<references>)"), ("link target with a title", 'see [all](references "t")'),
                   ("link target <prod-ops/references/> with a title", 'see [all](<prod-ops/references/> "t")'),
                   ("capitalised `References`", "every file in `References`")):
    r = mk("bareref2")
    skill_md(r, "prod-ops", P0, "step 7: %s." % txt)
    case("%s fails, naming the files explicitly" % label, r, 1, "name the files explicitly")
# ...and these are NOT the bare directory: a widened rule would fail them
for label, txt in (("`references.md`", "see `references.md` here"), ("`references-old`", "see `references-old` here"),
                   ("`my_references`", "see `my_references` here"), ("heading ## References", "## References\n\nbody text")):
    r = mk("notbare")
    skill_md(r, "prod-ops", P0, "step 7: %s." % txt if not txt.startswith("##") else txt)
    case("%s is not the bare directory and passes" % label, r, 0, "skill-weight: ok")
r = mk("prose2")
skill_md(r, "prod-ops", P0, "the references directory and the references folder hold files; see `references/verification-probes.md` and `references/preferences.md`.")
fill(sk(r, "prod-ops", "references", "verification-probes.md"), 400, "v")
fill(sk(r, "prod-ops", "references", "preferences.md"), 400, "v")
rec(r)
case("prose 'the references directory' and names merely containing 'probes' / 'references' pass", r, 0, "skill-weight: ok")
# a non-probe NAMED with 'probes' is counted in the gated bytes (probe detection is not a substring test)
if baseline_row(r, "prod-ops")[6] == "0" and int(baseline_row(r, "prod-ops")[4]) > 3600:
    ok("references/verification-probes.md is counted in the gated bytes, not in the probes sub-total")
else:
    bad("probes substring", str(baseline_row(r, "prod-ops")))
# ...and an executable .sh really in _shared/probes, reached through a path that merely CONTAINS probes/
# (references/lib/probes/q.sh), is not under references/probes/: counted, not excused
r = mk("probes-nested")
genuine(r, "q.sh", 900, link=False)
os.makedirs(sk(r, "prod-ops", "references", "lib", "probes"), exist_ok=True)
put_link(sk(r, "prod-ops", "references", "lib", "probes", "q.sh"), "../../../../_shared/probes/q.sh")
skill_md(r, "prod-ops", P0, "run `references/lib/probes/q.sh`.")
rec(r)
if baseline_row(r, "prod-ops")[6] == "0" and int(baseline_row(r, "prod-ops")[4]) > 900:
    ok("probe detection is the references/probes/ prefix, not any path containing probes/")
else:
    bad("probes nested", str(baseline_row(r, "prod-ops")))

# glob characters, each on its own: a mention with `{` or `[` fails
for label, txt in (("`{,.orig}` brace", "`references/a.md{,.orig}`"), ("`[a-z]*` class", "`references/[a-z]*.md`")):
    r = mk("glob2")
    skill_md(r, "prod-ops", P0, "step 7: %s." % txt)
    case("%s FAILS" % label, r, 1, "name the files explicitly")
# footnote marker: a backticked path followed by [^1] is a clean mention; a bare path with [^1] is a glob and fails (deliberate)
r = mk("foot")
skill_md(r, "prod-ops", P0, "step 7: `references/a.md`[^1].\n\n[^1]: why")
case("`references/a.md`[^1] (footnote after the closing backtick) passes", r, 0, "skill-weight: ok")
r = mk("foot2")
skill_md(r, "prod-ops", P0, "step 7: references/a.md[^1].\n\n[^1]: why")
case("references/a.md[^1] (unbackticked, footnote glued on) FAILS as a glob: the safe side, on purpose", r, 1, "name the files explicitly")

# a baseline in the old column layout is ONE line
r = mk("oldfmt")
edit_baseline(r, lambda L: [l.replace("| reachable probe bytes |", "| of which probes |") for l in L])
case("a baseline in an older column format fails with one line, no per-skill noise", r, 1,
     ("baseline format is older than this probe: re-record with `make skill-weight-baseline`",), ("malformed", "absent from"))

# ---- file-list ratchet ---------------------------------------------------------------
r = mk("adde")
fill(sk(r, "prod-ops", "references", "d.md"), 300, "d")
skill_md(r, "prod-ops", "Read `references/preamble.md` first, then `references/b.md`, `references/d.md`.\nOutput formats: `references/a.md`. If a plan exists, also read `references/c.md`.")
case("file ADDED to EAGER fails, naming it, with the re-record hint", r, 1,
     ("EAGER file list changed (ADDED references/d.md)", "make skill-weight-baseline` if intended"))
r = mk("rme")
skill_md(r, "prod-ops", "Read `references/preamble.md` first, then `references/b.md`. If a plan exists, also read `references/c.md`.")
case("file REMOVED from EAGER fails, naming it", r, 1, "EAGER file list changed (REMOVED references/a.md)")
r = mk("addr")
fill(sk(r, "prod-ops", "references", "d.md"), 300, "d")
skill_md(r, "prod-ops", P0, "step 5: `references/d.md`")
case("file ADDED to REACHABLE only fails, naming it", r, 1, "REACHABLE file list changed (ADDED references/d.md)", ("EAGER file list changed",))
rec(r)
case("re-recorded baseline is accepted", r, 0, "skill-weight: ok")
r = mk("rmr")
skill_md(r, "prod-ops", "Read `references/preamble.md` first, then `references/b.md`.\nOutput formats: `references/a.md`.")
case("file REMOVED from REACHABLE only fails, naming it", r, 1, "REACHABLE file list changed (REMOVED references/c.md)", ("EAGER file list changed",))
rec(r)
case("re-recorded after a removal is accepted", r, 0, "skill-weight: ok")
r = mk("shrink")
fill(sk(r, "prod-ops", "references", "a.md"), 100, "a")
case("a shrink with equal lists is a note, not a failure", r, 0, "can re-record it lower")

# ---- byte ratchet boundary -----------------------------------------------------------
r = mk("edge")
B = int(baseline_row(r, "prod-ops")[3])
pad = (20 - B % 20) % 20
fill(sk(r, "prod-ops", "references", "a.md"), 500 + pad, "a")
rec(r)
B = int(baseline_row(r, "prod-ops")[3])
fill(sk(r, "prod-ops", "references", "a.md"), 500 + pad + B // 20, "a")
case("ratchet: exactly +5 % passes", r, 0, "skill-weight: ok")
fill(sk(r, "prod-ops", "references", "a.md"), 500 + pad + B // 20 + 1, "a")
case("ratchet: +5 % plus one byte fails", r, 1, "EAGER set grew to %d bytes from baseline %d" % (B + B // 20 + 1, B))
r = mk("grow")
fill(sk(r, "prod-ops", "references", "a.md"), 5000, "a")
case("byte growth with equal lists fails (REACHABLE too)", r, 1, "REACHABLE set grew to")

# ---- ceilings and liabilities --------------------------------------------------------
LIVE = "2099-01-01"
r = mk("eceil")
fill(sk(r, "prod-ops", "references", "b.md"), 70000, "b")
rec(r)
case("EAGER over 64000 with no liability fails", r, 1, "bytes is over the 64000-byte ceiling with no live `set: eager`")
waivers(r, ("w1", "prod-ops", None, 75000, LIVE))
case("EAGER liability (set omitted = eager) excuses the ceiling", r, 0, "1 set(s) over ceiling under live liability")
waivers(r, ("w1", "prod-ops", "eager", 75000, LIVE))
case("EAGER liability with explicit set: eager passes", r, 0, "skill-weight: ok")
waivers(r, ("w1", "prod-ops", "eager", 75000, "2000-01-01"))
case("expired liability excuses nothing", r, 1, "EXPIRED 2000-01-01")
waivers(r, ("w1", "prod-ops", "eager", 75000, "2030-06-01"))
case("injected clock: the expiry day itself is still live", r, 0, "skill-weight: ok", today=datetime.date(2030, 6, 1))
case("injected clock: the day after expiry excuses nothing", r, 1, "EXPIRED 2030-06-01", today=datetime.date(2030, 6, 2))
waivers(r, ("w1", "prod-ops", "eager", 71000, LIVE))
fill(sk(r, "prod-ops", "references", "b.md"), 72000, "b")
case("growth past the liability's ceiling_bytes fails", r, 1, "exceeds its liability's ceiling_bytes 71000")
r = mk("stale")
waivers(r, ("w1", "prod-ops", "eager", 75000, LIVE))
case("a liability for a set under its ceiling is stale", r, 1, "stale liability w1")
waivers(r, ("w1", "prod-zzz", "eager", 75000, LIVE))
case("a liability for an unknown skill fails", r, 1, "names a skill that is not one of the nine")
put(os.path.join(r, "registries", "waivers.yaml"), "entries: [oops\n")
case("an unparseable registry fails", r, 1, "does not parse as skill-weight liabilities")
waivers(r, ("w1", "prod-ops", "sideways", 75000, LIVE))
case("an unknown set value fails", r, 1, "needs skill, set (eager|reachable)")
waivers(r, ("w1", "prod-ops", "eager", 75000, LIVE), ("w2", "prod-ops", "eager", 76000, LIVE))
case("duplicate liability for the same (skill, set) fails", r, 1, "two liabilities for (prod-ops, eager)")
r = mk("rceil")
fill(sk(r, "prod-ops", "references", "d.md"), 130000, "d")
skill_md(r, "prod-ops", P0, "step 5: `references/d.md`")
rec(r)
NOLIVE = "bytes is over the 128000-byte ceiling with no live `set: reachable`"
case("REACHABLE over 128000 with no liability fails", r, 1, NOLIVE)
waivers(r, ("w1", "prod-ops", "reachable", 140000, LIVE))
case("a live set: reachable liability excuses it", r, 0, "skill-weight: ok")
waivers(r, ("w1", "prod-ops", "eager", 140000, LIVE))
case("an eager liability does not excuse a reachable overage", r, 1, NOLIVE)
waivers(r, ("w1", "prod-ops", "reachable", 140000, LIVE), ("w2", "prod-ops", "reachable", 150000, LIVE))
case("duplicate reachable liability fails", r, 1, "two liabilities for (prod-ops, reachable)")
waivers(r, ("w1", "prod-ops", "reachable", 130500, LIVE))
case("reachable growth past ceiling_bytes fails", r, 1, "exceeds its liability's ceiling_bytes 130500")
waivers(r, ("w1", "prod-ops", "reachable", 140000, LIVE), ("w2", "prod-ops", "eager", 140000, LIVE))
case("one entry per (skill, set): a stale eager entry beside a live reachable one fails", r, 1, "stale liability w2")

# ---- the baseline as data ------------------------------------------------------------
r = mk("dup")
edit_baseline(r, lambda L: [l for l in L if l] + [l for l in L if l.startswith("| prod-ops ")])
case("duplicate baseline row fails", r, 1, "baseline has two rows for prod-ops")
r = mk("unk")
edit_baseline(r, lambda L: L + [l.replace("prod-ops", "prod-zzz") for l in L if l.startswith("| prod-ops ")])
case("baseline row for an unknown skill fails", r, 1, "not one of the nine skills")
r = mk("ck")
edit_baseline(r, lambda L: [l.replace("| prod-ops |", "| prod-ops |", 1) if not l.startswith("| prod-ops ") else
                            "| " + " | ".join(l.strip("|").split("|")[0:1] + ["99999"] + l.strip("|").split("|")[2:]) + " |"
                            for l in L], checksum=False)
case("hand-edited baseline (checksum mismatch) fails", r, 1, "hand-edited baseline")
r = mk("nock")
edit_baseline(r, lambda L: [l for l in L if not l.startswith("checksum:")], checksum=False)
case("baseline without a checksum line fails", r, 1, "no `checksum:` line")
r = mk("malformed")
edit_baseline(r, lambda L: [l.replace("| prod-ops | ", "| prod-ops | x", 1) if l.startswith("| prod-ops ") else l for l in L])
case("malformed baseline row fails", r, 1, "baseline row for prod-ops is malformed")
r = mk("w-ok", False)
rc, out, err = rec(r)
case("--write regenerates a baseline the check then accepts", r, 0, "skill-weight: ok")
r = mk("w-bad", False)
os.remove(sk(r, "prod-ops", "references", "a.md"))
rc, out, err = rec(r)
if rc == 1 and any("refusing to record" in e for e in err) and not os.path.exists(os.path.join(r, "benchmarks", "skill-weight-baseline.md")):
    ok("--write refuses to record a failed measurement (and writes nothing)")
else:
    bad("write refuses", "rc=%s %s" % (rc, err))

print("DRIVER %d %d" % (res["pass"], res["bad"]))
sys.exit(1 if res["bad"] else 0)
