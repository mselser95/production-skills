#!/usr/bin/env bash
# inv-003 — NO TIER-POLICY KEY GOES UNSCORED.
#
# Ratified 2026-08-31. A key declared in _shared/tier-policy.yaml is an
# obligation this framework states about every repo it governs. A key nothing
# scores is an obligation nobody checks -- the framework's own name for a lie.
#
# The invariant has two directions and both are asserted here, because the pair
# is what makes it hold over time:
#
#   FORWARD  a declared key must be scored by a named probe row, or sit on the
#            work list with the demo that proves its property.
#   REVERSE  an entry in either EXCUSE LIST (the alias map, the work list) must
#            still name a key the policy declares. A stale entry excuses nothing
#            today and silently excuses the next key that reuses the name.
#
# The forward direction alone was the state until 2026-08-29, and it is the
# weaker half: it cannot notice its own exemptions rotting.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2

ok=0; failed=0
work="$(mktemp -d)" || exit 2
trap 'rm -rf "$work"' EXIT

SUBJECT="_shared/probes/policy-coverage.sh"
[[ -r "$SUBJECT" ]] || { echo "inv-003: cannot read $SUBJECT" >&2; exit 2; }

# Fixtures copy the subject in: it resolves its inputs from its own location, so
# a run in place would measure production instead of the fixture. The fixture
# policy is DERIVED from the subject's own alias list, because the reverse check
# treats an alias whose key is absent as a finding -- a hand-written policy would
# make all of them fire and the green baseline would be unreachable.
alias_keys=$(sed -n '/^ALIASES="/,/^"/p' "$SUBJECT" | grep -oE '^[a-z_]+:' | tr -d ':' | sort -u)
alias_rows=$(sed -n '/^ALIASES="/,/^"/p' "$SUBJECT" | grep -E '^[a-z_]+:' | sed 's/^[a-z_]*://' | tr ',' '\n')

fixture() { # fixture <name> [extra-key ...]
  local d="$work/$1"; shift
  rm -rf "$d"; mkdir -p "$d/_shared/probes"
  cp "$SUBJECT" "$d/_shared/probes/policy-coverage.sh"
  { echo "defaults: &defaults"
    while IFS= read -r k; do [[ -n "$k" ]] && echo "  $k: required"; done <<<"$alias_keys"
    for k in "$@"; do echo "  $k: required"; done
    echo "tiers:"; } > "$d/_shared/tier-policy.yaml"
  { echo '#!/usr/bin/env bash'
    while IFS= read -r k; do [[ -n "$k" ]] && echo "row \"${k//_/-}\" PASS \"x\""; done <<<"$alias_keys"
    while IFS= read -r r; do [[ -n "$r" ]] && echo "row \"$r\" PASS \"x\""; done <<<"$alias_rows"; } \
    > "$d/_shared/probes/verify-standard.sh"
  echo "$d"
}

check() { # check <name> <want-rc> <dir> [needle]
  local name="$1" want="$2" dir="$3" needle="${4:-}" out rc why=""
  out=$( cd "$dir" && bash _shared/probes/policy-coverage.sh 2>&1 ); rc=$?
  (( rc == want )) || why="rc=$rc want=$want"
  if [[ -z "$why" && -n "$needle" ]] && ! grep -qF "$needle" <<<"$out"; then why="did not say '$needle'"; fi
  if [[ -z "$why" ]]; then printf '  ok    %-54s\n' "$name"; ok=$((ok+1))
  else printf '  FAIL  %-54s %s\n' "$name" "$why"; printf '%s\n' "$out" | sed 's/^/          /'; failed=$((failed+1)); fi
}

echo "inv-003: no tier-policy key goes unscored"

# 1. THE REAL REPOSITORY, not a fixture. The invariant is about THIS policy, and
#    a test that only ever examines synthetic trees would hold while the actual
#    one drifted.
out=$(bash "$SUBJECT" 2>&1); rc=$?
if (( rc == 0 )) && grep -qE '[0-9]+ keys -- [0-9]+ scored, 0 known-unscored' <<<"$out"; then
  printf '  ok    %-54s %s\n' "this repo: every declared key is scored" "$(grep -oE '[0-9]+ keys[^,]*' <<<"$out" | head -1)"; ok=$((ok+1))
else
  printf '  FAIL  %-54s rc=%s\n' "this repo: every declared key is scored" "$rc"
  printf '%s\n' "$out" | sed 's/^/          /'; failed=$((failed+1))
fi

# 2. GREEN BASELINE on a fixture, so the red cases below cannot pass because the
#    subject fails on everything it is shown.
d=$(fixture green alfa); printf 'row "alfa" PASS "x"\n' >> "$d/_shared/probes/verify-standard.sh"
check "fixture: every key scored" 0 "$d"

# 3. FORWARD: a key nothing scores.
d=$(fixture unscored beta)
check "a declared key that no row scores" 1 "$d" "NEW UNSCORED KEYS"

# 4. Snake_case key, kebab-case row: the same obligation, and conflating them was
#    never the finding.
d=$(fixture hyphen gamma_delta); printf 'row "gamma-delta" PASS "x"\n' >> "$d/_shared/probes/verify-standard.sh"
check "a snake_case key scored by a kebab-case row" 0 "$d"

# 5. REVERSE: an alias naming a key the policy no longer declares.
d=$(fixture deadalias)
python3 - "$d/_shared/probes/policy-coverage.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
open(p,"w").write(s.replace('ALIASES="\n','ALIASES="\nclave_borrada:alguna-fila\n',1))
PY
check "an alias naming a key the policy dropped" 1 "$d" "STALE EXCUSES"

# 6. REVERSE: a work-list entry for a key that no longer exists. The list is
#    empty in this repo today, which is exactly why the case matters -- an empty
#    list cannot demonstrate its own guard.
d=$(fixture deadknown)
python3 - "$d/_shared/probes/policy-coverage.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
open(p,"w").write(s.replace('KNOWN_UNSCORED="\n','KNOWN_UNSCORED="\nclave_fantasma  la razon\n',1))
PY
check "a work-list entry for a key the policy dropped" 1 "$d" "clave_fantasma"

echo
echo "$ok ok, $failed failed"
(( failed == 0 )) || exit 1
