#!/usr/bin/env python3
"""parse_codex.py <codex-jsonl> <out-text> <usage-json>

`codex exec --json` emits JSONL, captured by the adapter on the CLI's stdout (nothing inside the cell is read).
The agent's answer is the LAST item.completed whose item.type is agent_message; usage is the turn.completed
event's usage (input_tokens already includes the cached part; output_tokens is taken as reported, reasoning
tokens are not added on top). Codex reports no cost.

STREAM INTEGRITY. The parser accepts exactly ONE terminal event, `turn.completed`, and nothing after it.
Rejected, exit 3, nothing taken from the stream, `stream-trailing-data` printed on stdout (the adapter maps it to
the row error "stream-trailing-data"):
  - any non-blank line after the terminal event (a second turn.completed included);
  - more than one agent_message after the last tool activity (any completed item that is neither an agent_message
    nor reasoning): one final answer candidate only.
The out/usage files are still written (empty answer, zero usage) so a row can be built.
RESIDUAL (stated, not closed): a tool the agent runs shares the CLI's stdout descriptor tree, so it can write
well-formed events BEFORE the terminal event, and the harness cannot tell those from the CLI's own. That is why
usage numbers are "as reported by the CLI process tree", never an independent measurement.
A stream with no terminal event (the CLI crashed) is accepted as before: usage 0, the host's exit code speaks.
Exit 0 ok | 3 no events at all, or a rejected stream.
"""
import json
import sys

src, out, usage = sys.argv[1:4]
text, tin, tout, events = "", 0, 0, 0
terminal = False
trailing = False
final_candidates = 0
with open(src, errors="replace") as f:
    for line in f:
        if not line.strip():
            continue
        if terminal:
            trailing = True
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not isinstance(e, dict):
            continue
        events += 1
        t = e.get("type")
        if t == "item.completed":
            it = e.get("item") or {}
            ty = it.get("type")
            if ty == "agent_message" and isinstance(it.get("text"), str):
                text = it["text"]
                final_candidates += 1
            elif ty != "reasoning":
                final_candidates = 0   # tool activity: earlier candidates were not the final answer
        elif t == "turn.completed":
            terminal = True
            u = e.get("usage") or {}
            tin = int(u.get("input_tokens") or 0)
            tout = int(u.get("output_tokens") or 0)
if events == 0:
    print("parse_codex: no JSON events", file=sys.stderr)
    sys.exit(3)
if trailing or final_candidates > 1:
    print("parse_codex: stream-trailing-data (content after the terminal event, or several final answer candidates)", file=sys.stderr)
    with open(out, "w") as f:
        f.write("")
    with open(usage, "w") as f:
        json.dump({"tokens_in": 0, "tokens_out": 0, "cost_usd": None}, f)
    print("stream-trailing-data")
    sys.exit(3)
with open(out, "w") as f:
    f.write(text)
with open(usage, "w") as f:
    json.dump({"tokens_in": tin, "tokens_out": tout, "cost_usd": None}, f)
