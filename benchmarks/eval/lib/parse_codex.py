#!/usr/bin/env python3
"""parse_codex.py <codex-jsonl> <out-text> <usage-json> [<last-message-file>]

`codex exec --json` emits JSONL. The agent's answer is the LAST item.completed
whose item.type is agent_message; usage is summed over turn.completed events
(input_tokens already includes the cached part; output_tokens is taken as
reported, reasoning tokens are not added on top). Codex reports no cost.
With an output schema the adapter also passes `-o <file>` (codex writes the final agent message
there): when that file exists and is not blank it IS the answer, the JSONL item is the fallback.
Exit 0 ok | 3 no events at all.
"""
import json
import sys

src, out, usage = sys.argv[1:4]
last = sys.argv[4] if len(sys.argv) > 4 else ""
text, tin, tout, events = "", 0, 0, 0
with open(src, errors="replace") as f:
    for line in f:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not isinstance(e, dict):
            continue
        events += 1
        if e.get("type") == "item.completed":
            it = e.get("item") or {}
            if it.get("type") == "agent_message" and isinstance(it.get("text"), str):
                text = it["text"]
        elif e.get("type") == "turn.completed":
            u = e.get("usage") or {}
            tin += int(u.get("input_tokens") or 0)
            tout += int(u.get("output_tokens") or 0)
if events == 0:
    print("parse_codex: no JSON events", file=sys.stderr)
    sys.exit(3)
if last:
    try:
        with open(last, errors="replace") as f:
            body = f.read()
        if body.strip():
            text = body
    except OSError:
        pass
with open(out, "w") as f:
    f.write(text)
with open(usage, "w") as f:
    json.dump({"tokens_in": tin, "tokens_out": tout, "cost_usd": None}, f)
