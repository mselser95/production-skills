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
#   general-purpose / fork in a GOVERNED repo
#     (production.yaml in cwd or a parent)         -> DENY, naming the pinned agent for the ask:
#                                                     implement -> prod-implementer (prod-spec first
#                                                     if no resolved context), review -> prod-validator,
#                                                     recon -> prod-scout / Explore
#   fork + implementation prompt, anywhere         -> DENY (use prod-implementer)
#   anything else (Explore, Plan, ungoverned gp)   -> allow + budget rules injected
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

REVIEW = re.compile(r"validat\w*|review\w*|verdict|BLOCKER|audit\w*|revis\w*", re.IGNORECASE)
RECON = re.compile(r"inventor\w*|recon\w*|list (?:every|all)|map (?:the|every)|find where|which files|where is", re.IGNORECASE)

if kind in ("general-purpose", "claude", "", "fork"):
    root = governed(cwd)
    if root:
        # In a governed repo EVERY dispatch goes to a pinned agent: the pinned
        # ones start at ~20k tokens of context with their rules in place; a
        # general-purpose or fork agent starts at 50-170k with none. The reason
        # names the right agent for what the prompt asks.
        name = os.path.basename(root)
        if is_impl:
            has_ctx = os.path.isdir(os.path.join(root, ".prod", "context")) and any(
                "resolved-context" in f for f in os.listdir(os.path.join(root, ".prod", "context")))
            if not has_ctx:
                deny(f"{name} is governed by a production spec and has no resolved context under "
                     ".prod/context/. Run `prod-spec` first (resolved context, change plan, acceptance "
                     "spec), then dispatch `prod-implementer` per task.")
            deny(f"{name} is governed: implementation goes to `prod-implementer` (one fresh agent per "
                 "change-plan task), never to a general-purpose or fork agent.")
        if REVIEW.search(prompt):
            deny(f"{name} is governed: reviews and validations go to `prod-validator` (read-only, "
                 "opus, restricted tools), never to a general-purpose or fork agent.")
        if RECON.search(prompt):
            deny(f"{name} is governed: inventories and recon sweeps go to `prod-scout` (haiku, "
                 "read-only) or the built-in `Explore`; a general-purpose agent is not the scout.")
        deny(f"{name} is governed: dispatch a pinned agent -- `prod-implementer` (implement), "
             "`prod-validator` (review), `prod-acceptance-author` (acceptance tests), `prod-scout` "
             "(recon), `prod-mechanic` (ops) -- or the built-in `Explore`/`Plan` for pure search. "
             "general-purpose and fork are not used in governed repos.")

if is_impl and kind == "fork":
    deny("Implementation never runs in a fork: it inherits the parent's whole context "
         "(median 170k tokens, measured) and re-reads it every turn. Dispatch "
         "`prod-implementer` with the task contract. For read-only research, say so.")

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
