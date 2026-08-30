#!/usr/bin/env bash
# no-unfilled-slots.sh — refuse a scaffold that still carries template slots.
#
# WHY THIS EXISTS
#
# prod-new copies template/ and instantiates every `<SLOT>`. Two of those slots
# survive a naive instantiation, and the two fail in opposite ways:
#
#   IN A PATH. The template ships a directory literally named `cmd/<SERVICE>`,
#   and `sed` rewrites file CONTENTS, never file names. Measured 2026-08-29 by
#   instantiating the template by hand: a content grep reported zero remaining
#   slots while the directory sat there untouched, and `go build ./...` failed
#   with `malformed import path ".../cmd/<SERVICE>": invalid char '<'` -- an
#   error that names the import and sends the reader into go.mod.
#
#   IN PROSE. A `<OWNER>` left in README.md or a runbook BUILDS FINE. Nothing
#   in the gate chain has an opinion about markdown, so that one ships. It is
#   the more dangerous of the two precisely because it is not loud: the repo is
#   green, and its documentation tells an operator to clone
#   github.com/<OWNER>/<SERVICE> during an incident.
#
# So the check has to look at contents AND paths, and it has to run in the
# scaffold rather than in the template -- in the template every slot is
# CORRECT, which is why this file is not self-testing here.
#
# Exit: 0 no slots remain · 1 slots remain (named) · 2 refused to answer
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

# The slot vocabulary, ASSEMBLED AT RUNTIME rather than written literally, and
# that is not a style choice -- it is the fix for this script destroying itself.
#
# The first version said SLOTS='...' with the two slot names spelled out. It
# shipped inside the template, so instantiation rewrote THIS FILE along with
# every other: the line became SLOTS='svc|mselser95' and the check turned into a
# detector of the words "svc" and "mselser95", which appear in every file of a
# correctly instantiated repo. Measured 2026-08-29: a clean scaffold reported 18
# files "still carrying template slots", including AGENTS.md, which contains no
# slot at all.
#
# A gate written in the syntax it hunts for is a gate the process it audits will
# edit. Splitting the bracket off means sed cannot match the pattern, so the
# check survives the substitution it exists to verify.
_lt='<'
SLOTS="${_lt}SERVICE>|${_lt}OWNER>"

# EXCLUDE this file and the skill docs that DOCUMENT the slots. A check that
# fires on the sentence explaining the check is the "rule that punishes
# documenting its own lesson" shape, and it gets widened until it is gone.
excl='^\./(\.git|\.wt|vendor|node_modules)/|scripts/no-unfilled-slots\.sh$'

paths=$(find . \( -name '.git' -o -name '.wt' -o -name 'vendor' -o -name 'node_modules' \) -prune -o -print 2>/dev/null \
  | grep -E '<[A-Z_]+>' || true)

files=$(grep -rlE "$SLOTS" . \
  --exclude-dir=.git --exclude-dir=.wt --exclude-dir=vendor --exclude-dir=node_modules \
  2>/dev/null | grep -vE "$excl" || true)

# ZERO SUBJECTS IS A REFUSAL, not a pass. If find and grep both return nothing
# because the tree is empty or unreadable, "no slots remain" is true and
# meaningless -- the same shape every probe in this repo refuses.
total_files=$(find . \( -name '.git' -o -name '.wt' \) -prune -o -type f -print 2>/dev/null | grep -c . || true)
if [[ "${total_files:-0}" -eq 0 ]]; then
  echo "no-unfilled-slots: found ZERO files to check -- a clean result over nothing is not a clean result" >&2
  exit 2
fi

np=$(printf '%s' "$paths" | grep -c . || true)
nf=$(printf '%s' "$files" | grep -c . || true)

if (( np + nf > 0 )); then
  echo "no-unfilled-slots: this repo still carries template slots -- it is a partial scaffold, not a repo." >&2
  if (( np > 0 )); then
    echo "  in PATHS (sed does not rewrite file names; rename them):" >&2
    printf '%s\n' "$paths" | sed 's/^/    /' >&2
  fi
  if (( nf > 0 )); then
    echo "  in CONTENTS:" >&2
    printf '%s\n' "$files" | sed 's/^/    /' >&2
  fi
  exit 1
fi

echo "no-unfilled-slots: ok -- ${total_files} file(s) checked, no ${SLOTS} remaining in contents or paths"
