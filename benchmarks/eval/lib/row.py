#!/usr/bin/env python3
"""row.py -- assemble one results row and append it to the JSONL file.

A cell that went wrong still yields a row (pass:false + error): a silently
missing row would inflate every success rate computed from the file.

pass = grader exit 0 AND host exit 0 AND not timed out. A host that crashed is
not credited with whatever state it left behind.
"""
import argparse
import json
import sys


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:  # noqa: BLE001
        return default


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--task-json", required=True)
    a.add_argument("--task-id", required=True)
    a.add_argument("--skill", required=True)
    for k in ("arm", "host", "model", "skill_sha", "harness_sha", "ts", "error", "sandbox", "order_seed"):
        a.add_argument("--" + k.replace("_", "-"), default="", dest=k)
    a.add_argument("--rep", type=int, default=0)
    a.add_argument("--exit", type=int, default=-1, dest="host_exit")
    a.add_argument("--grade-exit", type=int, default=-1)
    a.add_argument("--timed-out", default="0")
    a.add_argument("--duration", type=float, default=0.0)
    a.add_argument("--usage-file", default="")
    a.add_argument("--grade-file", default="")
    a.add_argument("--output-file", default="")
    a.add_argument("--schema", default="0")   # "1" when an output schema applied to this cell
    a.add_argument("--out", required=True)
    a = a.parse_args()

    task = read_json(a.task_json, {})
    usage = read_json(a.usage_file, {}) if a.usage_file else {}
    metrics = {}
    err = a.error
    if a.grade_file:
        try:
            with open(a.grade_file) as f:
                lines = [l for l in f.read().splitlines() if l.strip()]
            m = json.loads(lines[-1]) if lines else None
            if isinstance(m, dict):
                metrics = m
            elif a.grade_exit in (0, 1):
                err = err or "grader printed no JSON object"
        except Exception:  # noqa: BLE001
            if a.grade_exit in (0, 1):
                err = err or "grader printed no JSON object"
    timed_out = a.timed_out == "1"
    if a.grade_exit not in (0, 1):
        err = err or "grader error (exit %d)" % a.grade_exit
    ok = a.grade_exit == 0 and a.host_exit == 0 and not timed_out and not err
    if timed_out:
        err = err or "timeout"
    elif a.host_exit != 0 and not err:
        err = "host exit %d" % a.host_exit

    def num(k):
        v = usage.get(k)
        return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None

    # output_valid: null when no schema applied, else true iff the agent's output file parses as a JSON OBJECT
    valid = None
    if a.schema == "1":
        valid = False
        try:
            with open(a.output_file) as f:
                valid = isinstance(json.loads(f.read()), dict)
        except Exception:  # noqa: BLE001
            valid = False

    row = {
        "task": a.task_id, "skill": a.skill, "split": task.get("split"), "kind": task.get("kind"), "output_valid": valid,
        "arm": a.arm, "host": a.host, "model": a.model or None, "rep": a.rep,
        "pass": bool(ok), "metrics": metrics,
        "tokens_in": num("tokens_in"), "tokens_out": num("tokens_out"),
        "cost_usd": num("cost_usd"), "duration_s": round(a.duration, 2),
        "exit": a.host_exit, "timed_out": timed_out,
        "sandbox": a.sandbox or "n/a", "order_seed": a.order_seed or None, "skill_sha": a.skill_sha, "harness_sha": a.harness_sha, "ts": a.ts,
    }
    if err:
        row["error"] = err
    with open(a.out, "a") as f:
        f.write(json.dumps(row, sort_keys=True) + "\n")


if __name__ == "__main__":
    sys.exit(main())
