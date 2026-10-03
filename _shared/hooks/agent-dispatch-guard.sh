#!/usr/bin/env bash
# agent-dispatch-guard.sh — PreToolUse hook on the Agent tool. The harness runs
# it; the model cannot skip it.
#
# WHY A HOOK AND NOT A RULE. dispatch.md has said "one fresh agent per task,
# never a fork" since it was written, and 22 of 69 implementer dispatches in
# this user's transcripts still handed one agent the whole plan; forks that
# inherit ~170k tokens of parent context were used to implement. A rule in a
# markdown file is read and then overridden by whoever is in a hurry. A hook
# is not.
#
# Decisions (stdin: the hook JSON; stdout: the hook decision JSON):
#   prod-* agents                                  -> allow, untouched (they carry their rules)
#   fork + implementation prompt                   -> DENY (use prod-implementer)
#   general-purpose/claude + implementation prompt
#       in a governed repo (production.yaml found) -> DENY (prod-spec -> prod-implementer)
#       elsewhere                                  -> allow + budget rules injected
#   anything else (Explore, Plan, research forks)  -> allow + budget rules injected
#
# "Implementation prompt" = contains an implementation verb AND does not declare
# itself read-only. The verb list is deliberately coarse; a false deny costs one
# re-dispatch with the right agent, a false allow costs a 40M-token run.
#
# Exit 0 always with a JSON decision; exit 1 only when stdin is not JSON (the
# harness then fails open and logs it, which is the honest outcome for a guard
# that cannot read its input). Set AGENT_GUARD_DISABLE=1 to bypass (logged).
set -uo pipefail

input="$(cat)"
[[ -n "$input" ]] || { echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'; exit 0; }

AGENT_GUARD_DISABLE="${AGENT_GUARD_DISABLE:-0}" python3 - "$input" <<'PY'
import json, os, re, sys

raw = sys.argv[1]
try:
    d = json.loads(raw)
except Exception:
    sys.exit(1)

def out(obj):
    print(json.dumps(obj)); sys.exit(0)
def allow(extra=None):
    o = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}
    if extra: o["hookSpecificOutput"].update(extra)
    out(o)
def deny(reason):
    out({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                "permissionDecisionReason": reason}})

if d.get("tool_name") != "Agent":
    allow()
if os.environ.get("AGENT_GUARD_DISABLE") == "1":
    allow({"additionalContext": "agent-dispatch-guard bypassed via AGENT_GUARD_DISABLE=1"})

ti = d.get("tool_input") or {}
kind = (ti.get("subagent_type") or "general-purpose").strip()
prompt = ti.get("prompt") or ""
cwd = d.get("cwd") or os.getcwd()

if kind.startswith("prod-"):
    allow()

IMPL = re.compile(
    r"\b(implement\w*|implementa\w*|refactor\w*|fix(?:es|ed|ing)?\b|arregl\w*|"
    r"commit\w*|push(?:ea|ear|es)?\b|edit(?:a|ar|s|ing)?\b|modif\w*|rewrite|reescrib\w*|"
    r"write (?:the )?(?:code|tests?|a (?:script|probe|hook))|add (?:a |the )?(?:test|endpoint|field|target|rule)|"
    r"agrega\w*|crea(?:r|me)? (?:un|el|la) (?:archivo|script|test|target)|scaffold\w*|migrat\w*|"
    r"delete\w* (?:the )?file|borr\w*|rename\w*)",
    re.IGNORECASE)
READONLY = re.compile(r"read[- ]only|solo lectura|no files? written|do not (?:edit|write|commit)|"
                      r"never (?:edit|write|commit)|review only|research only|no edits", re.IGNORECASE)

is_impl = bool(IMPL.search(prompt)) and not READONLY.search(prompt)

def governed(path):
    p = os.path.abspath(path)
    for _ in range(12):
        if os.path.isfile(os.path.join(p, "production.yaml")):
            return p
        n = os.path.dirname(p)
        if n == p: break
        p = n
    return None

if is_impl and kind == "fork":
    deny("Implementation never runs in a fork: it inherits the parent's whole context "
         "(median 170k tokens, measured) and re-reads it every turn. Dispatch "
         "`prod-implementer` with the task contract (resolved context ids, ONE task, "
         "gate commands, output format). For read-only research, say so in the prompt "
         "('research only, no files written').")

if is_impl and kind in ("general-purpose", "claude", ""):
    root = governed(cwd)
    if root:
        has_ctx = False
        ctx_dir = os.path.join(root, ".prod", "context")
        if os.path.isdir(ctx_dir):
            has_ctx = any("resolved-context" in f for f in os.listdir(ctx_dir))
        if not has_ctx:
            deny(f"{os.path.basename(root)} is governed by a production spec and has no resolved "
                 "context under .prod/context/. Run `prod-spec` first (it writes the resolved "
                 "context, the change plan and the acceptance spec), then dispatch "
                 "`prod-implementer` per task. A general-purpose agent is not the implementer here.")
        deny(f"{os.path.basename(root)} is governed: implementation tasks go to `prod-implementer` "
             "(one fresh agent per change-plan task, tools restricted, budget rules), never to a "
             "general-purpose agent. Read-only work: say 'read-only' in the prompt.")

BUDGET = (
    "\n\n[context budget — injected by agent-dispatch-guard]\n"
    "- BOUNDED-OUTPUT: a tool result over 500 chars never enters your context whole; pipe gates "
    "and long commands through `2>&1 | tail -n 40` (full log to a file), read logs only by the "
    "slice a failure names.\n"
    "- FOCUSED-READ: locate with `grep -n`, read with `sed -n A,Bp` (≤120 lines); whole-file reads "
    "only under 200 lines.\n"
    "- NO-REREAD: never read a file or log already in your context.\n"
    "- NO-POLLING: no sleep/until/pgrep loops; foreground or `run_in_background`.\n"
    "- Final report ≤250 words: findings with file:line, what you ran and its last line, what you "
    "could not verify."
)
if "[context budget" in prompt:
    allow()
new = dict(ti); new["prompt"] = prompt + BUDGET
allow({"updatedInput": new})
PY
rc=$?
if (( rc != 0 )); then
  echo "agent-dispatch-guard: could not parse hook input as JSON; failing open" >&2
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
fi
exit 0
