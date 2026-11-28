#!/usr/bin/env python3
"""parse_codex.py <codex-jsonl> <out-text> <usage-json>

`codex exec --json` emits JSONL, captured by the adapter on the CLI's stdout (nothing inside the cell is read).
The agent's answer is the LAST item.completed whose item.type is agent_message; usage is the turn.completed
event's usage (input_tokens already includes the cached part; output_tokens is taken as reported, reasoning
tokens are not added on top). Codex reports no cost (cost_usd is always null).

CONTRACT (one place). Usage is `null` (tokens_in / tokens_out / cost_usd all JSON null in the usage file and the
row) unless it was read from a VALID terminal event of a COMPLETE stream. Never 0 as a stand-in.
A valid stream: UTF-8 JSONL, one JSON object per non-blank line, no duplicate key in any object, exactly ONE
terminal event `turn.completed` and nothing after it, no `error` / `turn.failed` event, and at most one final
answer after the last non-reasoning tool item. A UTF-8 BOM at the very start of the stream is stripped (a BOM is
not an attack); a BOM anywhere else makes that line invalid JSON.
Usage fields: input_tokens and output_tokens are REQUIRED; cached_input_tokens and reasoning_output_tokens are
OPTIONAL (checked only when present). Each must be a JSON integer, 0 <= n <= 2**53: `true`/`false`, floats (even
`5.0`), numeric strings, null, negatives, NaN/Infinity (parsed as floats), and larger numbers are all invalid.

ERROR CLASSES (stdout: the class name; usage file: nulls + "error": "<class>[: text]"; out file: empty):
  exit 0  ok                  the answer and the usage are delivered
  exit 0  usage-invalid       the stream is valid but a usage field is missing/invalid: the ANSWER IS STILL DELIVERED and
                              gradable; usage is null; the usage file carries "usage_error" and the row carries it too
                              (the row is excluded from cost statistics). Exit 0 on purpose: a non-zero exit would make
                              the adapter treat the run as failed and not graded.
  exit 3  stream-trailing-data  content after the terminal event (a second turn.completed included), or more than one
                              agent_message after the last tool activity
  exit 4  stream-incomplete   no terminal event (the CLI crashed or stopped early), or no event at all
  exit 5  stream-invalid      a line that is not valid UTF-8 / not JSON / not an object, a duplicate key,
                              a BOM that is not at the start of the stream
  exit 6  host-error          a `turn.failed` or `error` event; the event's message (truncated, one line) is in the error
                              text and passes through run.sh's redaction filter like every row string
Precedence when several apply: stream-invalid > host-error > stream-trailing-data > stream-incomplete.
RESIDUAL (stated, not closed): a tool the agent runs shares the CLI's stdout descriptor tree, so it can write
well-formed events BEFORE the terminal event, and the harness cannot tell those from the CLI's own. That is why
usage numbers are "as reported by the CLI process tree", never an independent measurement.
"""
import json
import sys

LIMIT = 2 ** 53
EXIT = {"stream-trailing-data": 3, "stream-incomplete": 4, "stream-invalid": 5, "host-error": 6}


def _pairs(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError("duplicate key")
        d[k] = v
    return d


def _uint(v):
    return type(v) is int and 0 <= v <= LIMIT   # type() not isinstance: bool is an int subclass


def _msg(e):
    m = e.get("message")
    if not isinstance(m, str):
        er = e.get("error")
        m = er.get("message") if isinstance(er, dict) else er
    return " ".join(m.split())[:200] if isinstance(m, str) else ""


def parse(src):
    """-> (class | None, text, usage dict | None, usage_error | None, detail)"""
    text, terminal, trailing, final_candidates = "", None, False, 0
    events, invalid, host_err = 0, False, None
    with open(src, "rb") as f:
        for n, raw in enumerate(f):
            if n == 0 and raw.startswith(b"\xef\xbb\xbf"):
                raw = raw[3:]
            if not raw.strip():
                continue
            if terminal is not None:
                trailing = True
                continue
            try:
                e = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs, parse_constant=float)
            except (ValueError, RecursionError):   # UnicodeDecodeError is a ValueError
                invalid = True
                break
            if not isinstance(e, dict):
                invalid = True
                break
            events += 1
            t = e.get("type")
            if t in ("error", "turn.failed"):
                if host_err is None:
                    host_err = t + ((": " + _msg(e)) if _msg(e) else "")
            elif t == "item.completed":
                it = e.get("item")
                if not isinstance(it, dict):
                    invalid = True
                    break
                ty = it.get("type")
                if ty == "agent_message" and isinstance(it.get("text"), str):
                    text = it["text"]
                    final_candidates += 1
                elif ty != "reasoning":
                    final_candidates = 0   # tool activity: earlier candidates were not the final answer
            elif t == "turn.completed":
                terminal = e
    if invalid:
        return "stream-invalid", "", None, None, "a line is not a valid JSON object"
    if host_err is not None:
        return "host-error", "", None, None, host_err
    if trailing or final_candidates > 1:
        return "stream-trailing-data", "", None, None, "content after the terminal event, or several final answer candidates"
    if terminal is None:
        return "stream-incomplete", "", None, None, "no terminal turn.completed event" if events else "no events"
    u = terminal.get("usage")
    if not isinstance(u, dict):
        return None, text, None, "usage missing", ""
    for k in ("input_tokens", "output_tokens"):
        if k not in u:
            return None, text, None, "%s missing" % k, ""
    for k in ("input_tokens", "output_tokens", "cached_input_tokens", "reasoning_output_tokens"):
        if k in u and not _uint(u[k]):
            return None, text, None, "%s is not an integer in [0, 2**53]" % k, ""
    return None, text, {"tokens_in": u["input_tokens"], "tokens_out": u["output_tokens"], "cost_usd": None}, None, ""


def main():
    src, out, usage = sys.argv[1:4]
    try:
        cls, text, u, uerr, detail = parse(src)
    except OSError as ex:
        cls, text, u, uerr, detail = "stream-incomplete", "", None, None, "stream unreadable (%s)" % type(ex).__name__
    doc = {"tokens_in": None, "tokens_out": None, "cost_usd": None}
    if cls:
        text = ""
        doc["error"] = cls + (": " + detail if cls == "host-error" else "")
    elif u is not None:
        doc.update(u)
    else:
        doc["usage_error"] = uerr
    with open(out, "w") as f:
        f.write(text)
    with open(usage, "w") as f:
        json.dump(doc, f)
    if cls:
        print("parse_codex: %s (%s)" % (cls, detail), file=sys.stderr)
        print(cls)
        return EXIT[cls]
    return 0


if __name__ == "__main__":
    sys.exit(main())
