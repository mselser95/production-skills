#!/usr/bin/env bash
# agent-dispatch-guard-selftest.sh — every decision of the Agent-tool hook shown
# on an input where it must fire, and on one where it must not.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/../hooks/agent-dispatch-guard.sh"
[[ -f "$hook" ]] || { echo "agent-dispatch-guard selftest: hook not found at $hook"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-selftest.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/governed/.prod/context" "$tmp/governed-ctx/.prod/context" "$tmp/plain"
touch "$tmp/governed/production.yaml" "$tmp/governed-ctx/production.yaml" "$tmp/governed-ctx/.prod/context/resolved-context-x.yaml"
pass=0 bad=0

run() { # name kind prompt cwd want(allow|deny) needle
  local name="$1" kind="$2" prompt="$3" cwd="$4" want="$5" needle="${6:-}"
  local out dec
  out=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Agent","cwd":sys.argv[3],"tool_input":{"subagent_type":sys.argv[1],"prompt":sys.argv[2]}}))' "$kind" "$prompt" "$cwd" | bash "$hook" 2>/dev/null)
  dec=$(python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; print(d["permissionDecision"], "injected" if "updatedInput" in d else "plain", d.get("permissionDecisionReason",""))' <<<"$out" 2>/dev/null)
  if [[ "$dec" == "$want"* && "$dec" == *"$needle"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$name"
  else bad=$((bad+1)); printf '  FAIL  %s -> %s\n' "$name" "${dec:-<no json: $out>}"; fi
}

run "fork + implement -> deny"                 fork            "Implement the T3 task and commit"           "$tmp/plain"        deny  "never runs in a fork"
run "fork + research only -> allow+budget"      fork            "Research only, no files written: map envs"  "$tmp/plain"        allow injected
run "gp + implement, governed, no ctx -> deny"  general-purpose "Implement the endpoint and add a test"      "$tmp/governed"     deny  "prod-spec"
run "gp + implement, governed, ctx -> deny"     general-purpose "Implement the endpoint and add a test"      "$tmp/governed-ctx" deny  "prod-implementer"
run "gp + implement, ungoverned -> allow+budget" general-purpose "Implement the endpoint and add a test"     "$tmp/plain"        allow injected
run "gp + read-only validator -> allow+budget"  general-purpose "READ-ONLY validator: review commit; never edit permanently" "$tmp/governed" allow injected
run "Explore -> allow+budget"                   Explore         "Find where tokens are counted"              "$tmp/governed"     allow injected
run "prod-implementer -> allow, untouched"      prod-implementer "Implement task T1 and commit"             "$tmp/governed"     allow plain
run "prod-scout -> allow, untouched"            prod-scout      "Inventory the repo"                         "$tmp/governed"     allow plain
run "already injected -> not doubled"           Explore         "Find X [context budget — injected]"         "$tmp/plain"        allow plain
run "spanish implement verb, governed -> deny"  general-purpose "implementá el endpoint y agregá el test"    "$tmp/governed"     deny  "prod-spec"

# non-Agent tool passes through untouched
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$hook")
[[ "$out" == *'"allow"'* ]] && { pass=$((pass+1)); echo "  ok    non-Agent tool -> allow"; } || { bad=$((bad+1)); echo "  FAIL  non-Agent tool: $out"; }
# garbage input fails OPEN with a stderr line, exit 0
out=$(echo 'not json' | bash "$hook" 2>"$tmp/err"); rc=$?
[[ $rc -eq 0 && "$out" == *'"allow"'* && -s "$tmp/err" ]] && { pass=$((pass+1)); echo "  ok    garbage input -> fail open, logged"; } || { bad=$((bad+1)); echo "  FAIL  garbage input rc=$rc out=$out"; }
# bypass env
out=$(echo '{"tool_name":"Agent","cwd":"'"$tmp/governed"'","tool_input":{"subagent_type":"fork","prompt":"implement it"}}' | AGENT_GUARD_DISABLE=1 bash "$hook")
[[ "$out" == *'"allow"'* && "$out" == *bypassed* ]] && { pass=$((pass+1)); echo "  ok    AGENT_GUARD_DISABLE=1 -> allow, says so"; } || { bad=$((bad+1)); echo "  FAIL  bypass: $out"; }

if (( pass == 0 )); then echo "agent-dispatch-guard selftest: ZERO cases ran"; exit 1; fi
if (( bad )); then echo "agent-dispatch-guard selftest: $bad of $((pass+bad)) case(s) failed"; exit 1; fi
echo "agent-dispatch-guard selftest: ok -- $pass case(s)"
