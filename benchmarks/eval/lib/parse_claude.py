#!/usr/bin/env python3
"""parse_claude.py <claude-json> <out-text> <usage-json>

`claude -p --output-format json` prints one object: result, is_error, usage{
input_tokens, cache_creation_input_tokens, cache_read_input_tokens,
output_tokens}, total_cost_usd. tokens_in counts all three input kinds.
When the run was given --json-schema, `claude --help` documents only the flag ("JSON Schema
for structured output validation (only works with --print)"), NOT the result field that holds
the document. This code accepts `structured_output` (the name the headless JSON result is
expected to use; to be confirmed by a paid probe): if that field is a JSON object it is
written, as JSON text, to the output file (the grader's input); otherwise the `result` text is.
Exit 0 ok | 1 the run reported is_error | 3 unparseable.
"""
import json
import sys

src, out, usage = sys.argv[1:4]
try:
    with open(src) as f:
        d = json.load(f)
    if isinstance(d, list):  # tolerate a stream-json style array: take the result event
        d = [e for e in d if isinstance(e, dict) and e.get("type") == "result"][-1]
    u = d.get("usage") or {}
    tin = sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    tout = int(u.get("output_tokens") or 0)
    cost = d.get("total_cost_usd")
    text = d.get("result")
    text = text if isinstance(text, str) else ""
    structured = d.get("structured_output")   # name NOT confirmed by --help; see the docstring
    if isinstance(structured, dict):
        text = json.dumps(structured)
except Exception as e:  # noqa: BLE001
    print("parse_claude: unparseable output (%s)" % type(e).__name__, file=sys.stderr)
    sys.exit(3)
with open(out, "w") as f:
    f.write(text)
with open(usage, "w") as f:
    json.dump({"tokens_in": tin, "tokens_out": tout, "cost_usd": cost}, f)
sys.exit(1 if d.get("is_error") else 0)
