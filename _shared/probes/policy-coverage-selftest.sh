#!/usr/bin/env bash
# policy-coverage-selftest.sh — the verifier of policy-coverage.sh.
#
# policy-coverage runs in the pre-commit hook AND in CI and had no selftest until
# 2026-08-29, which meant its rules were proven exactly once each, by hand, on
# the day someone thought to try. Two of them had already been wrong in ways only
# execution found: an `awk -F:` alias parser that reported 25 findings which were
# all itself, and a row-extraction regex too narrow to see its own row names.
#
# HOW THE FIXTURE WORKS, and it is not optional. policy-coverage resolves its
# inputs by cd-ing to `$(dirname $BASH_SOURCE)/../..` -- its own repo root -- so
# pointing it at a fixture directory does nothing at all: it reads the real
# tier-policy.yaml regardless. Measured: a fixture with one key still reported
# "52 keys". So each case COPIES the script into the fixture tree and runs the
# copy, which makes BASH_SOURCE resolve inside the fixture.
#
# The fixture policy is DERIVED from the script's own ALIASES list rather than
# written out, because the stale-excuse check added the same day treats an alias
# whose key is absent as a finding -- a hand-written fixture policy would make
# all 35 of them fire and the green baseline would be unreachable.
set -uo pipefail

SUBJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/policy-coverage.sh"
[[ -r "$SUBJECT" ]] || { echo "selftest: cannot read $SUBJECT" >&2; exit 2; }

ok=0; failed=0
work="$(mktemp -d)" || exit 2
trap 'rm -rf "$work"' EXIT

# Every key the script's embedded lists mention, so the baseline is clean.
alias_keys=$(sed -n '/^ALIASES="/,/^"/p' "$SUBJECT" | grep -oE '^[a-z_]+:' | tr -d ':' | sort -u)
known_keys=$(sed -n '/^KNOWN_UNSCORED="/,/^"/p' "$SUBJECT" | awk 'NF && $1 !~ /^KNOWN_UNSCORED|^"$/ {print $1}' | sort -u)

fixture() { # name [extra-policy-key ...] -> prints dir
  local d="$work/$1"; shift
  mkdir -p "$d/_shared/probes"
  cp "$SUBJECT" "$d/_shared/probes/policy-coverage.sh"
  {
    echo "defaults: &defaults"
    while IFS= read -r k; do [[ -n "$k" ]] && echo "  $k: required"; done <<<"$alias_keys"
    while IFS= read -r k; do [[ -n "$k" ]] && echo "  $k: required"; done <<<"$known_keys"
    for k in "$@"; do echo "  $k: required"; done
    echo "tiers:"
  } > "$d/_shared/tier-policy.yaml"
  # A probe emitting a row for every alias key AND every row name the aliases
  # point at, so the baseline scores everything.
  {
    echo '#!/usr/bin/env bash'
    while IFS= read -r k; do [[ -n "$k" ]] && echo "row \"${k//_/-}\" PASS \"x\""; done <<<"$alias_keys"
    sed -n '/^ALIASES="/,/^"/p' "$SUBJECT" | grep -E '^[a-z_]+:' | sed 's/^[a-z_]*://' \
      | tr ',' '\n' | while IFS= read -r r; do [[ -n "$r" ]] && echo "row \"$r\" PASS \"x\""; done
  } > "$d/_shared/probes/verify-standard.sh"
  echo "$d"
}

check() { # name want-rc dir [needle]
  local name="$1" want="$2" dir="$3" needle="${4:-}" out rc why=""
  out=$( cd "$dir" && bash _shared/probes/policy-coverage.sh 2>&1 ); rc=$?
  (( rc == want )) || why="rc=$rc want=$want"
  if [[ -z "$why" && -n "$needle" ]] && ! grep -qF "$needle" <<<"$out"; then
    why="output did not mention '$needle'"
  fi
  if [[ -z "$why" ]]; then printf '  ok    %-58s\n' "$name"; ok=$((ok+1))
  else printf '  FAIL  %-58s %s\n' "$name" "$why"; printf '%s\n' "$out" | sed 's/^/          /'; failed=$((failed+1)); fi
}

echo "policy-coverage selftest"

# 1. GREEN BASELINE. Without it every case below could pass because the script
#    fails on everything it is shown.
d=$(fixture green alfa); printf 'row "alfa" PASS "x"\n' >> "$d/_shared/probes/verify-standard.sh"
check "every key scored -> 0" 0 "$d"

# 2. A key nothing scores is the original purpose of this probe.
d=$(fixture unscored beta)
check "key declared in policy, scored by nothing -> 1" 1 "$d" "NEW UNSCORED KEYS"

# 3. Underscore/hyphen equivalence: policy keys are snake_case, row names are
#    kebab-case, and conflating them was never the finding.
d=$(fixture hyphen gamma_delta); printf 'row "gamma-delta" PASS "x"\n' >> "$d/_shared/probes/verify-standard.sh"
check "snake_case key matched by a kebab-case row -> 0" 0 "$d"

# 4. THE REVERSE DIRECTION, added 2026-08-29: an ALIAS naming a key the policy no
#    longer declares. It excuses nothing, and waits to excuse the next key that
#    reuses the name.
d=$(fixture deadalias)
python3 - "$d/_shared/probes/policy-coverage.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
open(p,"w").write(s.replace('ALIASES="\n','ALIASES="\nclave_borrada:alguna-fila\n',1))
PY
check "alias naming a key the policy dropped -> 1" 1 "$d" "STALE EXCUSES"

# 5. Same for the work list. KNOWN_UNSCORED is empty today, which is exactly why
#    this case matters: an empty list cannot demonstrate its own guard.
d=$(fixture deadknown)
python3 - "$d/_shared/probes/policy-coverage.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
open(p,"w").write(s.replace('KNOWN_UNSCORED="\n','KNOWN_UNSCORED="\nclave_fantasma  la razon original\n',1))
PY
check "work-list entry naming a key the policy dropped -> 1" 1 "$d" "KNOWN_UNSCORED: clave_fantasma"

# 6. ZERO ROWS is a refusal, not a clean comparison.
d=$(fixture norows alfa); printf '#!/usr/bin/env bash\n' > "$d/_shared/probes/verify-standard.sh"
check "zero rows extracted -> 2, not 0" 2 "$d" "ZERO rows"

# 7. ZERO KEYS likewise.
d=$(fixture nokeys); printf 'tiers:\n' > "$d/_shared/tier-policy.yaml"
check "zero keys extracted -> 2, not 0" 2 "$d" "ZERO keys"

echo
echo "$ok ok, $failed failed"
(( failed == 0 )) || exit 1
