#!/usr/bin/env bash
# inv-002 — THE INSTALLED TCB NEVER DIVERGES FROM SOURCE SILENTLY.
#
# Ratified 2026-08-31. The installed copy is what actually runs: a session loads
# skills from ${CLAUDE_CONFIG_DIR}/skills, not from this working tree. Every way
# that copy can stop matching the source must produce a non-zero exit AND NAME
# the file, because a count cannot be acted on -- "2 files" reads identically
# whether the pair is two READMEs or verify-standard.sh plus the tier policy.
#
# Three divergences, three distinct exit codes, and the codes are part of the
# invariant: they mean different work. 1 tamper (read the diff before trusting
# anything), 2 stale (you edited and did not reinstall), 3 writable (the
# read-only guard is missing, so the next accidental write will not fail loudly).
#
# Everything runs against a THROWAWAY config dir. It never touches a real one.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2

ok=0; failed=0
work="$(mktemp -d)" || exit 2
CFG="$work/cfg"
# The staleness case EDITS A TRACKED FILE and puts it back. Restoring it in the
# trap rather than only on the happy path matters: this test runs on every
# `make verify`, and a Ctrl-C between the append and the restore would leave a
# modified prod-ops/SKILL.md in the working tree -- which the next --verify
# would then report as a real staleness, sending someone to debug a test
# artefact.
restore_src() { [[ -f "$work/src.bak" ]] && cp "$work/src.bak" prod-ops/SKILL.md; }
trap 'restore_src; chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT INT TERM

expect() { # expect <name> <want-rc> <needle> -- runs --verify against $CFG
  local name="$1" want="$2" needle="$3" out rc why=""
  out=$( CLAUDE_CONFIG_DIR="$CFG" bash install.sh --verify 2>&1 ); rc=$?
  (( rc == want )) || why="rc=$rc want=$want"
  if [[ -z "$why" && -n "$needle" ]] && ! grep -qF "$needle" <<<"$out"; then
    why="did not NAME the file (expected '$needle')"
  fi
  if [[ -z "$why" ]]; then printf '  ok    %-52s\n' "$name"; ok=$((ok+1))
  else printf '  FAIL  %-52s %s\n' "$name" "$why"; printf '%s\n' "$out" | sed 's/^/          /'; failed=$((failed+1)); fi
}

echo "inv-002: the installed TCB never diverges from source silently"

CLAUDE_CONFIG_DIR="$CFG" bash install.sh >/dev/null 2>&1 || { echo "  cannot install into the throwaway dir" >&2; exit 2; }

# 1. GREEN BASELINE. Without it every case below could pass because --verify
#    fails on everything, which is a check that detects nothing and reports
#    everything.
expect "a fresh install verifies clean" 0 "TCB verified"

# 2. TAMPER -> exit 1, named. This is the case the manifest exists for.
victim="$CFG/skills/prod-ops/SKILL.md"
chmod u+w "$CFG/skills/prod-ops" "$victim" 2>/dev/null
head -c 200 "$victim" > "$victim.part" && mv "$victim.part" "$victim"
expect "a tampered installed file is DRIFT, named" 1 "prod-ops/SKILL.md"

CLAUDE_CONFIG_DIR="$CFG" bash install.sh >/dev/null 2>&1

# 3. WRITABLE -> exit 3, named. The window between the manifest write and the
#    chmod. Contents are correct here; what is missing is the guard that makes
#    the next accidental write fail loudly, and hashes cannot see it.
chmod u+w "$CFG/skills/prod-ops" "$CFG/skills/prod-ops/SKILL.md" 2>/dev/null
expect "a writable trusted set is caught, named" 3 "prod-ops/SKILL.md"

CLAUDE_CONFIG_DIR="$CFG" bash install.sh >/dev/null 2>&1

# 4. STALE -> exit 2, named. Integrity is not currency: the installed copy can be
#    untampered and still be an older trusted set, which is the case a hash
#    comparison alone reports as spotless.
src_victim="prod-ops/SKILL.md"
cp "$src_victim" "$work/src.bak"
printf '\n<!-- inv-002 staleness probe -->\n' >> "$src_victim"
expect "an unreinstalled source edit is STALE, named" 2 "stale: prod-ops/SKILL.md"
restore_src   # tambien en el trap; aca para que el caso 5 vea el arbol limpio

# 5. And back to clean, so a case that leaves the fixture broken cannot make the
#    next run look like a detection.
CLAUDE_CONFIG_DIR="$CFG" bash install.sh >/dev/null 2>&1
expect "reinstalling returns it to silent" 0 "TCB verified"

echo
echo "$ok ok, $failed failed"
(( failed == 0 )) || exit 1
