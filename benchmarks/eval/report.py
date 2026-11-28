#!/usr/bin/env python3
"""report.py <results.jsonl> [--markdown]

Group key = (skill, host, model, sandbox, split, language, kind, arm). Models, splits, sandbox
modes (seatbelt|codex|off|n/a), task LANGUAGES (task.json "language": go, rust, python) and task KINDS (task.json "kind": seeded, clean, ...)
are never pooled: every block below is printed per kind and there is NO verdict
across kinds (a skill that finds more real defects but raises more false positives
must not net to zero). Nothing is pooled across languages either: every block and both named
verdicts are per language. A row without "kind" or without "language" is an error (file:line),
never a default.

Per group: n rows, success rate with a Wilson 95% interval (labelled REP-LEVEL,
OPTIMISTIC: reps of one task are not independent), pass^k (share of tasks whose
k reps ALL passed; k is printed; only tasks with exactly k reps count), total
tokens and seconds SPENT (all rows, failed attempts included) per RESOLVED task
(passing rows); rows with no usage data are excluded from the token figure and
counted ("N no usage"; an arm with more than 20% such rows prints a WARNING line), never treated as 0, and the MEAN PER ROW of metrics.false_positives
and metrics.found (descriptive; rows that do not carry the metric are left out, n/a if none).

Per (skill, host, model, sandbox, split, language, kind) the VERDICT comes from a task-clustered paired
estimate: per task d_t = mean(pass | skill) - mean(pass | bare) over tasks that
have rows in BOTH arms; effect = mean(d_t); 95% interval = percentile bootstrap,
TWO-LEVEL: resample tasks with replacement, then inside each resampled task
resample its reps with replacement (independently per arm) before taking d_t
(10,000 resamples, fixed seed). The inner level matters: with only task-level
resampling, five tasks that all show 1/3 vs 0/3 would give a zero-width interval. Fewer than 5 paired tasks:
the estimate is printed but the verdict is "insufficient tasks (n=k)".
helps = interval entirely > 0, hurts = entirely < 0, else no evidence.

For the kinds named exactly `seeded` and `clean` two further lines are printed per
(skill, host, model, sandbox, split, language): `recall (seeded)` (the paired estimate on seeded
tasks) and `false-positive control (clean)` (the same estimate on clean tasks; a clean
task passes when no false defect is raised, so a positive number still means the skill
helps). Each carries its own interval and verdict, and `insufficient tasks (n=k)` when
fewer than 5 paired tasks OF THAT KIND AND LANGUAGE exist.

A line that is not a JSON object, or a row without "kind" or "language", is an error (file:line, exit 1):
never dropped.
Exit: 0 ok | 1 unparseable line | 2 no rows.
"""
import json
import math
import random
import sys
from collections import Counter, defaultdict

sys.dont_write_bytecode = True
Z = 1.959964
SEED = 20260601
RESAMPLES = 10000
MIN_TASKS = 5


def wilson(k, n):
    if n == 0:
        return (0.0, 0.0, 0.0)
    p = k / n
    d = 1 + Z * Z / n
    c = (p + Z * Z / (2 * n)) / d
    h = Z * math.sqrt(p * (1 - p) / n + Z * Z / (4 * n * n)) / d
    return (p, max(0.0, c - h), min(1.0, c + h))


def load(path):
    rows, bad = [], 0
    with open(path) as f:
        for i, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                r = json.loads(line)
                if not isinstance(r, dict):
                    raise ValueError("not an object")
            except ValueError as e:
                print("%s:%d: not a JSON row (%s)" % (path, i, e), file=sys.stderr)
                bad += 1
                continue
            if not isinstance(r.get("kind"), str) or not r["kind"].strip():
                print("%s:%d: row has no \"kind\" (a results file from before per-kind reporting? re-run the cells)" % (path, i),
                      file=sys.stderr)
                bad += 1
                continue
            if not isinstance(r.get("language"), str) or not r["language"].strip():
                print("%s:%d: row has no \"language\" (a results file from before per-language reporting? re-run the cells)" % (path, i),
                      file=sys.stderr)
                bad += 1
                continue
            rows.append(r)
    return rows, bad


def fmt(x, nd=0):
    return "n/a" if x is None else ("%.*f" % (nd, x))


def mean_metric(rows, name):
    """mean of metrics.<name> over the rows that carry a number; None if none do"""
    vs = []
    for r in rows:
        v = (r.get("metrics") or {}).get(name)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            vs.append(v)
    return sum(vs) / len(vs) if vs else None


MISSING_USAGE_WARN = 0.2   # an arm with more than this share of rows without usage gets a warning line


def cell(rows):
    n = len(rows)
    k = sum(1 for r in rows if r.get("pass") is True)
    by_task = defaultdict(list)
    for r in rows:
        by_task[r.get("task")].append(r.get("pass") is True)
    counts = Counter(len(v) for v in by_task.values())
    kk = max(counts, key=lambda c: (counts[c], c))   # modal reps per task (ties: larger)
    full = [v for v in by_task.values() if len(v) == kk]
    passk = sum(1 for v in full if all(v)) / len(full)
    has = [r for r in rows if r.get("tokens_in") is not None and r.get("tokens_out") is not None]   # a half-null row is missing usage, never 0
    toks = sum((r.get("tokens_in") or 0) + (r.get("tokens_out") or 0) for r in has)
    k_has = sum(1 for r in has if r.get("pass") is True)
    secs = sum(r["duration_s"] for r in rows if isinstance(r.get("duration_s"), (int, float)))
    fp, found = mean_metric(rows, "false_positives"), mean_metric(rows, "found")
    return {"n": n, "k": k, "reps": kk, "uneven": len(counts) > 1, "passk": passk, "ntask": len(full),
            "tok": toks / k_has if k_has else None, "nousage": len(rows) - len(has), "n_usage_missing": len(rows) - len(has), "sec": secs / k if k else None, "fp": fp, "found": found,
            "reps_by_task": by_task,
            "per_task": {t: sum(v) / len(v) for t, v in by_task.items()}}


def paired(a, b):
    """-> (effect, lo, hi, tasks_paired, only_skill, only_bare) ; bootstrap over tasks"""
    ta, tb = a["per_task"], b["per_task"]
    both = sorted(t for t in ta if t in tb)
    d = [ta[t] - tb[t] for t in both]
    only_a = sorted(t for t in ta if t not in tb)
    only_b = sorted(t for t in tb if t not in ta)
    if not d:
        return None, None, None, 0, only_a, only_b
    rng = random.Random(SEED)
    m = len(d)
    ra, rb = a["reps_by_task"], b["reps_by_task"]
    pairs = [(ra[t], rb[t]) for t in both]
    means = []
    for _ in range(RESAMPLES):
        tot = 0.0
        for (xa, xb) in (pairs[rng.randrange(m)] for _ in range(m)):
            tot += sum(rng.choices(xa, k=len(xa))) / len(xa) - sum(rng.choices(xb, k=len(xb))) / len(xb)
        means.append(tot / m)
    means.sort()
    lo = means[int(0.025 * RESAMPLES)]
    hi = means[int(math.ceil(0.975 * RESAMPLES)) - 1]
    return sum(d) / m, lo, hi, m, only_a, only_b


def verdict(lo, hi, m):
    if m < MIN_TASKS:
        return "insufficient tasks (n=%d)" % m
    if lo > 0:
        return "helps"
    if hi < 0:
        return "hurts"
    return "no evidence"


def diff_for(cells, key7, warns, notes, label):
    """paired skill-vs-bare estimate for one (skill, host, model, sandbox, split, language, kind) -> (cols, verdict)"""
    a, b = cells.get(key7 + ("skill",)), cells.get(key7 + ("bare",))
    if not a or not b:
        return ["n/a", "n/a", "0"], "insufficient tasks (n=0): one arm missing"
    if a["reps"] != b["reps"]:
        warns.append("WARNING: %s: arms are not comparable on pass^k (k=%d skill vs k=%d bare)" % (label, a["reps"], b["reps"]))
    for arm, c in (("skill", a), ("bare", b)):
        if c["n_usage_missing"] > MISSING_USAGE_WARN * c["n"]:
            warns.append("WARNING: %s: %d of %d %s rows have no usage (> %d%%): the token comparison between the arms is not reliable"
                         % (label, c["n_usage_missing"], c["n"], arm, round(100 * MISSING_USAGE_WARN)))
    e, lo, hi, m, oa, ob = paired(a, b)
    if oa or ob:
        notes.append("unpaired tasks in %s: skill-only=%s bare-only=%s" % (label, ",".join(oa) or "-", ",".join(ob) or "-"))
    if e is None:
        return ["n/a", "n/a", "0"], verdict(0, 0, 0)
    return ["%+.1f pp" % (100 * e), "[%+.1f, %+.1f]" % (100 * lo, 100 * hi), str(m)], verdict(lo, hi, m)


# kind -> the named summary line it feeds (same estimate, one name per question)
SUMMARY = (("seeded", "recall (seeded)"), ("clean", "false-positive control (clean)"))


def main(argv):
    md = "--markdown" in argv
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1:
        print("usage: report.py <results.jsonl> [--markdown]", file=sys.stderr)
        return 2
    rows, bad = load(args[0])
    if bad:
        print("report: %d bad line(s); refusing to report a partial file" % bad, file=sys.stderr)
        return 1
    if not rows:
        print("report: no rows in %s" % args[0], file=sys.stderr)
        return 2
    groups = defaultdict(list)
    for r in rows:
        groups[(r.get("skill"), r.get("host"), r.get("model") or "-", r.get("sandbox") or "n/a", r.get("split"), r["language"], r["kind"], r.get("arm"))].append(r)

    head = ["skill", "host", "model", "sandbox", "split", "language", "kind", "arm", "n", "success", "95% CI rep-level (optimistic)",
            "pass^k", "tok spent/resolved", "s spent/resolved", "false_pos/row", "found/row"]
    table, cells, warns = [], {}, []
    for key in sorted(groups, key=lambda k: tuple(str(x) for x in k)):
        c = cells[key] = cell(groups[key])
        p, lo, hi = wilson(c["k"], c["n"])
        if c["uneven"]:
            warns.append("WARNING: %s: tasks have unequal rep counts; pass^k uses only the %d task(s) with k=%d"
                         % ("/".join(map(str, key)), c["ntask"], c["reps"]))
        table.append([str(x) for x in key] + [str(c["n"]), "%.1f%% (%d/%d)" % (100 * p, c["k"], c["n"]),
                     "[%.1f, %.1f]" % (100 * lo, 100 * hi), "%.2f (k=%d)" % (c["passk"], c["reps"]),
                     (fmt(c["tok"]) + (" (%d no usage)" % c["nousage"] if c["nousage"] else "")), fmt(c["sec"], 1),
                     fmt(c["fp"], 2), fmt(c["found"], 2)])

    dhead = ["skill", "host", "model", "sandbox", "split", "language", "kind", "skill-bare (paired, per-task)", "95% CI (task bootstrap)", "tasks", "verdict"]
    diffs, notes = [], []
    seen = sorted({k[:7] for k in cells}, key=lambda k: tuple(str(x) for x in k))
    for k7 in seen:
        cols, v = diff_for(cells, k7, warns, notes, "/".join(map(str, k7)))
        diffs.append([str(x) for x in k7] + cols + [v])

    summary = []   # the two named lines; only for kinds named exactly seeded / clean
    for k6 in sorted({k[:6] for k in cells}, key=lambda k: tuple(str(x) for x in k)):
        for kind, name in SUMMARY:
            if k6 + (kind,) + ("skill",) not in cells and k6 + (kind,) + ("bare",) not in cells:
                continue
            cols, v = diff_for(cells, k6 + (kind,), [], [], "")
            summary.append("%s: %s  %s  %s  tasks=%s  %s" % (name, "/".join(map(str, k6)), cols[0], cols[1], cols[2], v))

    def emit(h, t):
        if md:
            print("| " + " | ".join(h) + " |")
            print("|" + "|".join("---" for _ in h) + "|")
            for r in t:
                print("| " + " | ".join(r) + " |")
        else:
            w = [max(len(x) for x in col) for col in zip(h, *t)]
            for r in [h] + t:
                print("  ".join(c.ljust(w[i]) for i, c in enumerate(r)).rstrip())
        print()

    emit(head, table)
    emit(dhead, diffs)
    for line in summary:
        print(("- " if md else "") + line)
    if summary:
        print()
    for line in warns + notes:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
