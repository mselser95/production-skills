#!/usr/bin/env bash
# gate-hygiene-fitness-selftest.sh — the verifier of gate-hygiene-fitness.sh,
# scoped to the GREPQ-UNDER-PIPEFAIL rule.
#
# provenance: derived -- from the 2026-11-27 incident recorded in the subject's
# header (a blocking gate, probe-wiring.sh, false-FAILed twice because
# `printf ... | grep -qxF` lost a SIGPIPE race under pipefail). The rule was
# advisory before that; this file is what keeps it failing.
#
# The subject lives in the template (it is vended to scaffolded repos); this
# verifier lives here so `make selftests` runs it, the same arrangement as
# no-unfilled-slots-selftest.sh. Fixtures are built OUTSIDE the repository: the
# subject resolves its root with `git rev-parse --show-toplevel`, and outside a
# repo it falls back to cwd, so every case measures the fixture.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBJECT="${HYGIENE_SUBJECT:-$root/prod-new/template/scripts/gate-hygiene-fitness.sh}"
[[ -r "$SUBJECT" ]] || { echo "selftest: cannot read $SUBJECT" >&2; exit 2; }

ok=0; failed=0
work="$(mktemp -d)" || exit 2
trap 'rm -rf "$work"' EXIT

# run NAME WANT_RC BODY [NEEDLE] -- BODY is the whole fixture script.
run() {
  local name="$1" want="$2" body="$3" needle="${4:-}"
  local d="$work/$name"; rm -rf "$d"; mkdir -p "$d/scripts"
  printf '%s\n' "$body" > "$d/scripts/fixture.sh"
  local out rc why=""
  out=$( cd "$d" && bash "$SUBJECT" scripts 2>&1 ); rc=$?
  (( rc == want )) || why="rc=$rc want=$want"
  if [[ -z "$why" && -n "$needle" ]] && ! grep -qF -- "$needle" <<<"$out"; then
    why="output did not mention '$needle'"
  fi
  if [[ -z "$why" ]]; then printf '  ok    %-62s\n' "$name"; ok=$((ok+1))
  else printf '  FAIL  %-62s %s\n' "$name" "$why"; printf '%s\n' "$out" | sed 's/^/          /' | head -6; failed=$((failed+1)); fi
}

echo "gate-hygiene-fitness selftest (GREPQ-UNDER-PIPEFAIL)"

# 0. GREEN BASELINE: without it every FAIL case below could be the gate failing
#    on everything.
run baseline_clean_script 0 $'#!/usr/bin/env bash\nset -uo pipefail\necho hi' "clean"

# (a) the rule FIRES. rc 1 AND named, so a gate that fails for another reason does not pass here.
run a_pipe_into_grepq 1 $'#!/usr/bin/env bash\nset -o pipefail\nproduce | grep -q x && echo found' "GREPQ-UNDER-PIPEFAIL"
run a_incident_shape 1 $'#!/usr/bin/env bash\nset -uo pipefail\nif ! printf \'%s\\n\' "${PROBES[@]}" | grep -qxF -- "$e"; then exit 2; fi' "GREPQ-UNDER-PIPEFAIL"
run a_combined_flags_set_euo 1 $'#!/usr/bin/env bash\nset -euo pipefail\nproduce | grep -qE "x+"' "GREPQ-UNDER-PIPEFAIL"

# (b) capture, then match the variable: the prescribed form passes.
run b_capture_then_match 0 $'#!/usr/bin/env bash\nset -uo pipefail\nout=$(produce)\nif grep -q x <<<"$out"; then echo found; fi\n[[ $out == *x* ]] && echo found'

# (c) no pipe at all.
run c_grepq_on_file 0 $'#!/usr/bin/env bash\nset -uo pipefail\ngrep -q x some.file && echo found'

# (c2) `||` is not a pipe: two here-string greps joined by || have no writer to kill.
#      The pre-2026-11-27 regex read `|| grep -q` as a pipe (2 of the 4 advisories).
run c2_or_is_not_a_pipe 0 $'#!/usr/bin/env bash\nset -uo pipefail\nif grep -qF a <<<"$o" || grep -qF b <<<"$o"; then echo hit; fi'

# (d) without pipefail the pipeline's status is grep's, so there is no inversion.
run d_no_pipefail 0 $'#!/usr/bin/env bash\nset -u\nproduce | grep -q x && echo found'

# (e) the construct inside a quoted fixture string is data, not code.
run e_quoted_fixture_text 0 $'#!/usr/bin/env bash\nset -uo pipefail\ncheck FIRE "plain pipe" \'go doc ./p | grep -q Foo\''

echo "$ok ok, $failed failed"
(( failed == 0 )) || exit 1
