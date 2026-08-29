#!/usr/bin/env bash
# skills-static-selftest.sh — prove skills-static.sh actually goes RED.
#
# The probe it tests was written because the DOCUMENTED structural gate
# (`skill-optimizer doctor --static`) is a third-party install that is absent on
# this machine, so it never ran and never failed, and because the built-in
# nearest thing (`claude plugin validate <skills-dir>`) passes a nested skill
# whose SKILL.md has been DELETED. A replacement written to fix "the gate never
# goes red" that is itself never proven to go red would be the same bug wearing
# a new name -- so every rule below has a fixture where its property is FALSE.
#
# Each case builds a throwaway skills root holding one deliberately broken
# prod-ops, runs the probe, and asserts on the exit code AND on the message, so
# a rule cannot pass a case by failing for some unrelated reason.
set -uo pipefail

probe="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills-static.sh"
[[ -r "$probe" ]] || { echo "selftest: cannot read $probe" >&2; exit 2; }

tmp=$(mktemp -d) || exit 2
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

pass=0 fail=0
# want_rc: expected exit code. want_msg: substring the output must contain.
run_case() {
  local desc="$1" want_rc="$2" want_msg="$3" root="$4"
  local out rc
  out=$("$probe" "$root" 2>&1); rc=$?
  if [[ "$rc" == "$want_rc" ]] && [[ "$out" == *"$want_msg"* ]]; then
    printf '  ok   %s\n' "$desc"; pass=$((pass + 1))
  else
    printf '  BAD  %s\n       wanted rc=%s and message containing %q\n       got rc=%s: %s\n' \
      "$desc" "$want_rc" "$want_msg" "$rc" "$(printf '%s' "$out" | tr '\n' '|')"
    fail=$((fail + 1))
  fi
}

# A structurally VALID prod-ops, used as the healthy baseline and as the base
# every mutation is applied to.
mk_root() { # mk_root <name> ; echoes the root path
  local r="$tmp/$1/skills"; mkdir -p "$r/prod-ops"
  cat >"$r/prod-ops/SKILL.md" <<'EOF'
---
name: prod-ops
description: A valid description, non-empty, so the baseline is green.
---
body
EOF
  printf '%s' "$r"
}

echo "skills-static selftest"

# --- 0. the baseline must be GREEN --------------------------------------------
# Without this, every case below could be "passing" because the probe fails on
# everything, which proves nothing about the rules.
r=$(mk_root base)
run_case "a structurally valid skill passes" 0 "structurally valid" "$r"

# --- 1. SKILL.md missing entirely ---------------------------------------------
# The case `claude plugin validate` passes silently. This is the whole reason
# the probe exists, so it is the first mutation.
r=$(mk_root nomd); rm "$r/prod-ops/SKILL.md"
run_case "a skill directory with no SKILL.md fails" 1 "no readable SKILL.md" "$r"

# --- 2. no frontmatter delimiter on line 1 ------------------------------------
r=$(mk_root nofm); printf 'just prose, no frontmatter\n' >"$r/prod-ops/SKILL.md"
run_case "SKILL.md not opening with --- fails" 1 "does not open with a --- frontmatter delimiter" "$r"

# --- 3. frontmatter opened and never closed -----------------------------------
r=$(mk_root unclosed); printf -- '---\nname: prod-ops\ndescription: x\n' >"$r/prod-ops/SKILL.md"
run_case "an unclosed frontmatter block fails" 1 "never closed" "$r"

# --- 4. frontmatter that is not valid YAML ------------------------------------
# The case a grep-based check waves through: `grep name:` matches happily while
# the block will not load. `[unclosed` is a YAML flow sequence with no bracket.
r=$(mk_root badyaml); printf -- '---\nname: [unclosed\ndescription: x\n---\nbody\n' >"$r/prod-ops/SKILL.md"
run_case "frontmatter that does not parse as YAML fails" 1 "does not parse as YAML" "$r"

# --- 5. description present but empty -----------------------------------------
# Structurally intact, loads fine, and the skill is unreachable in practice
# because the description is the only text the model sees when choosing a skill.
r=$(mk_root emptydesc); printf -- '---\nname: prod-ops\ndescription:\n---\nbody\n' >"$r/prod-ops/SKILL.md"
run_case "an empty description fails" 1 "no non-empty description" "$r"

# --- 6. name missing ----------------------------------------------------------
r=$(mk_root noname); printf -- '---\ndescription: x\n---\nbody\n' >"$r/prod-ops/SKILL.md"
run_case "a missing name fails" 1 "no non-empty name" "$r"

# --- 7. name disagreeing with the directory -----------------------------------
r=$(mk_root badname); printf -- '---\nname: prod-something-else\ndescription: x\n---\nbody\n' >"$r/prod-ops/SKILL.md"
run_case "a name that contradicts its directory fails" 1 "does not match its directory" "$r"

# --- 8. dangling reference symlink --------------------------------------------
# Fails at USE time rather than check time if nobody looks: the skill loads,
# and only a run that needs the reference discovers it resolves to nothing.
r=$(mk_root dangling); mkdir -p "$r/prod-ops/references"
ln -s "$tmp/definitely-not-here.md" "$r/prod-ops/references/ghost.md"
run_case "a dangling reference symlink fails" 1 "dangling symlink" "$r"

# --- 9. ZERO INPUTS -----------------------------------------------------------
# A sweep whose subject list came back empty must not report clean. Exit 2, so
# "found nothing to check" is distinguishable from "checked and all good" (0)
# and from "checked and something is broken" (1).
mkdir -p "$tmp/empty/skills"
run_case "a root with no skills at all is not a pass" 2 "a check with no subjects is not a pass" "$tmp/empty/skills"

# --- 10. length is NOT checked ------------------------------------------------
# The inverse assertion, and the reason it is here: the first draft failed any
# description over 1024 chars and fired on six of the nine real skills. The
# bound was invented, and Claude Code's own skill listing had already delivered
# a 1075-char description whole. This case pins the removal so a future edit
# cannot quietly reintroduce an unmeasured limit.
r=$(mk_root longdesc)
{ printf -- '---\nname: prod-ops\ndescription: '; head -c 4000 </dev/zero | tr '\0' 'x'; printf -- '\n---\nbody\n'; } >"$r/prod-ops/SKILL.md"
run_case "a 4000-char description does NOT fail (no invented bound)" 0 "structurally valid" "$r"

echo
if (( fail > 0 )); then
  echo "skills-static selftest: ${fail} case(s) BAD, ${pass} ok" >&2
  exit 1
fi
echo "skills-static selftest: ok -- ${pass} case(s), every rule demonstrated firing on a fixture where its property is false"
