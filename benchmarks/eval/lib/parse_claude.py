#!/usr/bin/env python3
"""parse_claude.py <claude-json> <out-text> <usage-json>

`claude -p --output-format json` prints one object: result, is_error, subtype, usage{input_tokens,
cache_creation_input_tokens, cache_read_input_tokens, output_tokens}, total_cost_usd (the row field is cost_usd).
tokens_in counts all three input kinds. When the run was given --json-schema, `claude --help` documents only the
flag, NOT the result field that holds the document. This code accepts `structured_output` (the name the headless
JSON result is expected to use; to be confirmed by a paid probe): if that field is a JSON object it is written, as
JSON text, to the output file (the grader's input); otherwise the `result` text is.

CONTRACT (one place). Usage and cost are `null` (JSON null in the usage file and the row) unless read from ONE valid
result document; never 0 as a stand-in. The CLI's output must be exactly ONE JSON document that is an OBJECT: an
array, two concatenated documents, or trailing non-whitespace is stream-invalid (the old "array of events, take the
last result" tolerance is gone). A leading UTF-8 BOM is stripped. No duplicate key in any object. NaN/Infinity parse as floats and fail the usage / cost checks.
`is_error` must be a boolean when present. Usage fields: input_tokens and output_tokens are REQUIRED;
cache_creation_input_tokens and cache_read_input_tokens are OPTIONAL (absent = not used; checked when present). Each
must be a JSON integer, 0 <= n <= 2**53 (no bool, float, string, null, negative). total_cost_usd must be a finite
number >= 0 (int or float, not bool) or absent / null (-> cost null).

ERROR CLASSES (stdout: the class name; usage file: nulls + "error": "<class>[: text]"; out file: empty):
  exit 0  ok            the answer and the usage are delivered
  exit 0  usage-invalid the document is valid but usage or total_cost_usd is missing/invalid: the ANSWER IS STILL
                        DELIVERED and gradable; ALL of tokens_in/tokens_out/cost_usd are null; the usage file and the row
                        carry "usage_error" (excluded from cost statistics). Exit 0 on purpose: a non-zero exit would
                        make the adapter treat the run as failed and not graded.
  exit 4  stream-incomplete   the output is empty (the CLI printed nothing)
  exit 5  stream-invalid      not UTF-8 / not JSON / not exactly one object / duplicate key / bad is_error
  exit 6  host-error          is_error is true, or subtype starts with "error"; the message (result, truncated) is in the
                              error text and passes through run.sh's redaction filter like every row string
(exit 3, stream-trailing-data, is codex-only. Exit 1, the old "run reported is_error", is now 6.)
Precedence: stream-invalid > host-error > usage-invalid.
"""
import json
import sys

LIMIT = 2 ** 53
EXIT = {"stream-incomplete": 4, "stream-invalid": 5, "host-error": 6}


def _pairs(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError("duplicate key")
        d[k] = v
    return d


def _uint(v):
    return type(v) is int and 0 <= v <= LIMIT   # type() not isinstance: bool is an int subclass


def parse(src):
    """-> (class | None, text, usage dict | None, usage_error | None, detail)"""
    with open(src, "rb") as f:
        raw = f.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    if not raw.strip():
        return "stream-incomplete", "", None, None, "empty output"
    try:
        d = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs, parse_constant=float)
    except (ValueError, RecursionError):
        return "stream-invalid", "", None, None, "not exactly one valid JSON document"
    if not isinstance(d, dict):
        return "stream-invalid", "", None, None, "the document is not an object"
    ie = d.get("is_error", False)
    if not isinstance(ie, bool):
        return "stream-invalid", "", None, None, "is_error is not a boolean"
    res = d.get("result")
    text = res if isinstance(res, str) else ""
    sub = d.get("subtype")
    if ie or (isinstance(sub, str) and sub.startswith("error")):
        m = " ".join(text.split())[:200]
        return "host-error", "", None, None, "is_error" + (" (%s)" % sub if isinstance(sub, str) and sub else "") + (": " + m if m else "")
    structured = d.get("structured_output")   # name NOT confirmed by --help; see the docstring
    if isinstance(structured, dict):
        text = json.dumps(structured)
    u = d.get("usage")
    if not isinstance(u, dict):
        return None, text, None, "usage missing", ""
    for k in ("input_tokens", "output_tokens"):
        if k not in u:
            return None, text, None, "%s missing" % k, ""
    for k in ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"):
        if k in u and not _uint(u[k]):
            return None, text, None, "%s is not an integer in [0, 2**53]" % k, ""
    cost = d.get("total_cost_usd")
    if cost is not None:
        if type(cost) not in (int, float) or not (0 <= cost < float("inf")):   # NaN fails the comparison too
            return None, text, None, "total_cost_usd is not a finite number >= 0", ""
    tin = u["input_tokens"] + u.get("cache_creation_input_tokens", 0) + u.get("cache_read_input_tokens", 0)
    return None, text, {"tokens_in": tin, "tokens_out": u["output_tokens"], "cost_usd": cost}, None, ""


def main():
    src, out, usage = sys.argv[1:4]
    try:
        cls, text, u, uerr, detail = parse(src)
    except OSError as ex:
        cls, text, u, uerr, detail = "stream-incomplete", "", None, None, "output unreadable (%s)" % type(ex).__name__
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
        print("parse_claude: %s (%s)" % (cls, detail), file=sys.stderr)
        print(cls)
        return EXIT[cls]
    return 0


if __name__ == "__main__":
    sys.exit(main())
