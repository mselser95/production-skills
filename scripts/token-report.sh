#!/usr/bin/env bash
# token-report.sh — measure what agent work COSTS in tokens, as a TREND.
#
# Reads Claude Code subagent transcripts (<root>/projects/**/subagents/*.meta.json
# plus the sibling .jsonl) and aggregates per (agentType, model): turns, context
# size, loop and BAIL rates, and tokens per COMPLETED task (total input-side
# tokens / count of IMPLEMENTED|AUTHORED outcomes). Tokens per task is the number
# that matters: a cheap agent that bails half the time is not cheap.
#
# This is a TREND, not a gate on correctness, and it is deliberately NOT part of
# `make gates` / `check-fast`: it reads the user's home directory, not the repo.
# The only alarm is one-directional: tokens-per-completed-task rising by more
# than 25% against benchmarks/token-baseline.md. Falling is free.
#
# Outcome rule: every SubagentHandback tool_use message is one task attempt (a
# resumed transcript can hold several); with none, the last assistant text is the
# one attempt. A line STARTING with BAIL wins, then IMPLEMENTED|AUTHORED, else
# "neither" (so "NOT IMPLEMENTED yet" is not a completion).
# Loop rule: an identical Bash command run >=3 times in one transcript counts
# once per distinct command; a transcript with any such command is a "loop".
#
# Usage:
#   token-report.sh [--write] [ROOT...]   default roots: ~/.claude ~/.claude-bloxroute ~/.claude-clc
#     --write   record benchmarks/token-baseline.md and exit 0
#   BASELINE=path overrides the baseline file (used by the selftest).
# Exit: 0 ok · 1 tokens/completed rose >25% · 2 no transcripts / unusable input
set -uo pipefail

# Absolutize a CALLER-supplied BASELINE before cd to repo root; the default is
# set after the cd so it is always relative to the repo, never the caller's cwd.
if [[ -n "${BASELINE:-}" && "$BASELINE" != /* ]]; then
  bdir="$(cd "$(dirname "$BASELINE")" 2>/dev/null && pwd)" || {
    echo "token-report: BASELINE directory does not exist: $(dirname "$BASELINE")" >&2; exit 2; }
  BASELINE="$bdir/$(basename "$BASELINE")"
fi

# Absolutize ROOT arguments before cd to repo root
write=0
[[ "${1:-}" == "--write" ]] && { write=1; shift; }
if (( $# == 0 )); then
  set -- "$HOME/.claude" "$HOME/.claude-bloxroute" "$HOME/.claude-clc"
else
  roots=()
  for arg in "$@"; do
    if [[ "$arg" != /* ]]; then
      abs="$(cd "$arg" 2>/dev/null && pwd)" && arg="$abs"
    fi
    roots+=("$arg")
  done
  set -- "${roots[@]}"
fi

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || exit 2
BASELINE="${BASELINE:-benchmarks/token-baseline.md}"

WRITE="$write" BASELINE="$BASELINE" python3 - "$@" <<'PY'
import glob, json, os, re, sys, datetime, collections

roots = sys.argv[1:]
write = os.environ["WRITE"] == "1"
baseline = os.environ["BASELINE"]
LOOP_THRESHOLD = 3
RISE = 1.25

def blen(c):
    if isinstance(c, str):
        return len(c.encode())
    if isinstance(c, list):
        return sum(blen(x.get("text", "") if isinstance(x, dict) else x) for x in c)
    return 0

def classify(text):
    if re.search(r"^\s*BAIL\b", text, re.M):
        return "BAIL"
    if re.search(r"^\s*(IMPLEMENTED|AUTHORED)\b", text, re.M):
        return "IMPLEMENTED"
    return "neither"

def analyse(meta_path):
    jl = meta_path[:-len(".meta.json")] + ".jsonl"
    if not os.path.isfile(jl):
        return None
    try:
        agent = json.load(open(meta_path)).get("agentType") or "unknown"
    except Exception:
        return None
    models = collections.Counter()
    turns, maxctx, cread, out, inp = 0, 0, 0, 0, 0
    result_bytes = read_bytes = 0
    names = {}
    cmds = collections.Counter()
    last_text = ""
    handbacks = []
    for line in open(jl, errors="replace"):
        try:
            e = json.loads(line)
        except Exception:
            continue
        if not isinstance(e, dict):
            continue
        msg = e.get("message")
        if not isinstance(msg, dict):
            msg = {}
        if e.get("type") == "assistant":
            u = msg.get("usage")
            if isinstance(u, dict):
                turns += 1
                i = u.get("input_tokens", 0) or 0
                r = u.get("cache_read_input_tokens", 0) or 0
                c = u.get("cache_creation_input_tokens", 0) or 0
                inp += i + r + c
                cread += r
                out += u.get("output_tokens", 0) or 0
                maxctx = max(maxctx, i + r + c)
                if msg.get("model") and msg["model"] != "<synthetic>":
                    models[msg["model"]] += 1
            texts = []
            content = msg.get("content")
            for it in content if isinstance(content, list) else []:
                if not isinstance(it, dict):
                    continue
                if it.get("type") == "text":
                    texts.append(it.get("text", ""))
                elif it.get("type") == "tool_use":
                    inpt = it.get("input")
                    if not isinstance(inpt, dict):
                        inpt = {}
                    kind = it.get("name")
                    if kind == "Bash":
                        cmd = " ".join(str(inpt.get("command", "")).split())
                        cmds[cmd] += 1
                        if re.match(r"(cat|sed)\b", cmd):
                            kind = "ReadLike"
                    elif kind == "Read":
                        kind = "ReadLike"
                    elif kind == "SubagentHandback":
                        handbacks.append(str(inpt.get("message", "")))
                    names[it.get("id")] = kind
            if texts:
                last_text = "\n".join(texts)
        elif e.get("type") == "user":
            content = msg.get("content")
            if isinstance(content, list):
                for it in content:
                    if isinstance(it, dict) and it.get("type") == "tool_result":
                        b = blen(it.get("content"))
                        result_bytes += b
                        if names.get(it.get("tool_use_id")) == "ReadLike":
                            read_bytes += b
    if turns == 0:
        return None
    # each handback is one task attempt; no handback -> the last text is the one attempt
    outcomes = [classify(h) for h in handbacks] or [classify(last_text)]
    return dict(agent=agent, model=models.most_common(1)[0][0] if models else "unknown",
                turns=turns, maxctx=maxctx, cread=cread,
                out=out, inp=inp, result_bytes=result_bytes, read_bytes=read_bytes,
                repeats=sum(1 for n in cmds.values() if n >= LOOP_THRESHOLD),
                outcomes=outcomes)

rows = []
for root in roots:
    for m in glob.glob(os.path.join(root, "projects", "**", "subagents", "*.meta.json"), recursive=True):
        r = analyse(m)
        if r:
            rows.append(r)
if not rows:
    print("token-report: found ZERO transcripts under: " + " ".join(roots) + " -- nothing measured is not a pass", file=sys.stderr)
    sys.exit(2)

groups = collections.defaultdict(list)
for r in rows:
    groups[(r["agent"], r["model"])].append(r)

HDR = "| agentType | model | n | mean turns | total tokens | mean max ctx | mean result bytes | mean read bytes | BAIL rate | loop rate | tokens/completed |"
NOTE = "Attempts whose handback has no IMPLEMENTED/AUTHORED block count as non-completions."
SEP = "|---|---|---|---|---|---|---|---|---|---|---|"
table = []
cur = {}
for (agent, model) in sorted(groups):
    g = groups[(agent, model)]
    n = len(g)
    tot = sum(x["inp"] + x["out"] for x in g)
    inp = sum(x["inp"] for x in g)
    att = [o for x in g for o in x["outcomes"]]
    done = att.count("IMPLEMENTED")
    tpc = "n/a" if done == 0 else str(round(inp / done))
    cur[(agent, model)] = None if done == 0 else inp / done
    table.append("| %s | %s | %d | %.1f | %d | %d | %d | %d | %.0f%% | %.0f%% | %s |" % (
        agent, model, n, sum(x["turns"] for x in g) / n, tot,
        sum(x["maxctx"] for x in g) / n,
        sum(x["result_bytes"] for x in g) / n,
        sum(x["read_bytes"] for x in g) / n,
        100 * att.count("BAIL") / len(att),
        100 * sum(1 for x in g if x["repeats"] > 0) / n, tpc))
body = [HDR, SEP] + table
print("\n".join(body))
print("\n" + NOTE)
print("transcripts: %d" % len(rows))

def shown(r):
    # never embed an absolute path or the username in a committed file
    r = os.path.abspath(r)
    home = os.path.expanduser("~")
    if r == home or r.startswith(home + os.sep):
        return "~" + r[len(home):]
    return os.path.basename(r)

if write:
    os.makedirs(os.path.dirname(baseline) or ".", exist_ok=True)
    with open(baseline, "w") as f:
        f.write("# Token baseline\n\n")
        f.write("Generated by `scripts/token-report.sh --write`. Do not hand-edit.\n\n")
        f.write("This is a TREND, not a gate on correctness. The only alarm is one-directional:\n")
        f.write("tokens/completed rising more than 25%% against this table exits 1.\n".replace("%%", "%"))
        f.write("tokens/completed = total input-side tokens / count of IMPLEMENTED|AUTHORED outcomes.\n\n")
        f.write("Date: %s\n\nRoots: %s\n\n" % (datetime.date.today().isoformat(), " ".join(shown(r) for r in roots)))
        f.write("\n".join(body) + "\n")
    print("token-report: wrote " + baseline)
    sys.exit(0)

if os.path.isfile(baseline):
    print("token-report: baseline %s" % baseline)
    was = {}
    for line in open(baseline):
        c = [x.strip() for x in line.strip().strip("|").split("|")]
        if len(c) == 11 and re.fullmatch(r"\d+", c[10]):
            was[(c[0], c[1])] = float(c[10])
    rose = 0
    for k, v in sorted(was.items()):
        if k not in cur:
            print("  GONE  %s / %s  had %d tokens/completed in the baseline, no transcripts now" % (k[0], k[1], v), file=sys.stderr)
            rose += 1
        elif cur[k] is None:
            print("  NA    %s / %s  had %d tokens/completed in the baseline, now n/a (nothing completed)" % (k[0], k[1], v), file=sys.stderr)
            rose += 1
        elif cur[k] > v * RISE:
            print("  ROSE  %s / %s  %d -> %d tokens/completed (+%.0f%%)" % (k[0], k[1], v, cur[k], 100 * (cur[k] / v - 1)), file=sys.stderr)
            rose += 1
    if rose:
        print("token-report: %d group(s) rose, vanished or went n/a" % rose, file=sys.stderr)
        sys.exit(1)
    print("token-report: no tokens/completed rose >25%% vs %s (%d compared)" % (baseline, len(was)))
else:
    print("token-report: no baseline at %s -- run with --write to record one" % baseline)
PY
