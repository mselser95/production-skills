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


# ---------------------------------------------------------------------------
# Cases for the one-pass `sed` read (the speed change) and what it must not break.
# Each names the mutation it exists to catch. provenance: candidate -- from the
# independent review of that change; ttl: 2027-06-01; pinning: true for the exact
# line numbers and process counts, which are measured and not ratified properties.
# ---------------------------------------------------------------------------
echo "gate-hygiene-fitness selftest (one-pass strip: alignment, fallback, cleanup, speed)"

pass() { printf '  ok    %-62s\n' "$1"; ok=$((ok+1)); }
fail() { printf '  FAIL  %-62s %s\n' "$1" "$2"; failed=$((failed+1)); }

# fx NAME -- make a fresh fixture dir "$work/NAME" with scripts/; echoes the dir.
fx() { local d="$work/$1"; rm -rf "$d"; mkdir -p "$d/scripts"; printf '%s' "$d"; }

# real tool paths, resolved before any wrapper dir exists.
REAL_SED="$(command -v sed)"; REAL_GREP="$(command -v grep)"; REAL_AWK="$(command -v awk || true)"

# LOCALES -- captured first: `locale -a | grep -q` is the very pipefail race this gate refuses.
LOCALES="$(locale -a 2>/dev/null || true)"
# loc_name WANT -- the installed spelling of a locale (Linux says C.utf8, macOS C.UTF-8), or fail.
loc_name() {
  local want l; want=$(printf '%s' "$1" | tr -d '-' | tr 'A-Z' 'a-z')
  while IFS= read -r l; do
    [[ "$(printf '%s' "$l" | tr -d '-' | tr 'A-Z' 'a-z')" == "$want" ]] && { printf '%s' "$l"; return 0; }
  done <<<"$LOCALES"
  return 1
}

# wrappers NAME -- a dir of counting sed/grep/awk; each appends its name to $HYG_COUNT then execs the real tool.
wrappers() {
  local wd="$work/$1"; mkdir -p "$wd"
  local t real
  for t in sed grep awk; do
    case $t in sed) real=$REAL_SED;; grep) real=$REAL_GREP;; awk) real=$REAL_AWK;; esac
    [[ -n "$real" ]] || continue
    printf '#!/bin/sh\necho %s >> "$HYG_COUNT"\nexec %s "$@"\n' "$t" "$real" > "$wd/$t"; chmod +x "$wd/$t"
  done
  printf '%s' "$wd"
}
count_of() { "$REAL_GREP" -cx "$2" "$1" 2>/dev/null || true; }   # file, tool

# --- lockstep: comment and blank lines must not shift the stripped text. -------
# Catches: the fd-3 read moved after the comment `continue` (an off-by-one that
# every other case here passes by accident, because line 1 is a shebang).
d=$(fx lockstep_before)
printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' '# c1' '' '# c2' '   ' 'produce | grep -q x' 'echo ok' '# note' 'produce | grep -qF y' 'echo end' > "$d/scripts/fixture.sh"
out=$( cd "$d" && bash "$SUBJECT" scripts 2>&1 ); rc=$?
if (( rc == 1 )) && grep -qF 'fixture.sh:7 ' <<<"$out" && grep -qF 'fixture.sh:10 ' <<<"$out" && (( $(grep -c GREPQ <<<"$out") == 2 )); then
  pass lockstep_comments_and_blanks_before_trigger; else fail lockstep_comments_and_blanks_before_trigger "rc=$rc: $(grep GREPQ <<<"$out" | tr '\n' '|')"; fi
d=$(fx lockstep_between)
printf '%s\n' 'set -o pipefail' 'produce | grep -q a' '# one' '# two' '# three' '' 'echo mid' 'produce | grep -q b' > "$d/scripts/fixture.sh"
out=$( cd "$d" && bash "$SUBJECT" scripts 2>&1 ); rc=$?
if (( rc == 1 )) && grep -qF 'fixture.sh:2 ' <<<"$out" && grep -qF 'fixture.sh:8 ' <<<"$out" && (( $(grep -c GREPQ <<<"$out") == 2 )); then
  pass lockstep_comments_between_two_triggers; else fail lockstep_comments_between_two_triggers "rc=$rc: $(grep GREPQ <<<"$out" | tr '\n' '|')"; fi

# --- R3: the last line of a file with no trailing newline is scanned. ----------
# Catches: `while read` without `|| [[ -n $line ]]` (the pre-existing blind spot), on the source read AND on fd 3.
d=$(fx nonl_source_rule); printf 'set -o pipefail\necho hi\npkill -x name' > "$d/scripts/fixture.sh"
out=$( cd "$d" && bash "$SUBJECT" scripts 2>&1 ); rc=$?
if (( rc == 1 )) && grep -qF 'fixture.sh:3 ' <<<"$out"; then pass final_line_without_newline_source_rule; else fail final_line_without_newline_source_rule "rc=$rc"; fi
d=$(fx nonl_stripped_rule); printf 'set -o pipefail\necho hi\nproduce | grep -q x' > "$d/scripts/fixture.sh"
out=$( cd "$d" && bash "$SUBJECT" scripts 2>&1 ); rc=$?
if (( rc == 1 )) && grep -qF 'fixture.sh:3 ' <<<"$out"; then pass final_line_without_newline_stripped_rule; else fail final_line_without_newline_stripped_rule "rc=$rc"; fi

# --- invalid bytes in the MIDDLE of a file, under a UTF-8 locale. --------------
# Catches: the fallback removed. sed aborts at the bad line in a UTF-8 locale; the
# later GREPQ line must still be judged on ITS OWN stripped text.
d=$(fx badbytes); printf 'set -o pipefail\necho ok\nprintf \xff\xfe x\necho ok\nproduce | grep -q x\n' > "$d/scripts/fixture.sh"
base=$( cd "$d" && LC_ALL=C bash "$SUBJECT" scripts 2>/dev/null ); baserc=$?
skipped=0; tried=0
for loc in en_US.UTF-8 C.UTF-8; do
  if ! real_loc=$(loc_name "$loc"); then printf '  skip  %-62s locale %s not installed\n' "invalid_bytes_middle_$loc" "$loc"; skipped=$((skipped+1)); continue; fi
  tried=$((tried+1))
  got=$( cd "$d" && LC_ALL=$real_loc bash "$SUBJECT" scripts 2>/dev/null ); grc=$?
  if (( grc == 1 )) && (( baserc == 1 )) && [[ "$got" == "$base" ]] && grep -qF 'fixture.sh:5 ' <<<"$got"; then pass "invalid_bytes_middle_$loc"; else fail "invalid_bytes_middle_$loc" "rc=$grc base=$baserc got=[$got] base=[$base]"; fi
done
(( tried > 0 )) || { printf '  skip  %-62s no UTF-8 locale installed: the fallback is not exercised here\n' invalid_bytes_middle_all_locales; skipped=$((skipped+1)); }

# --- speed guard: external processes do not scale with lines. -------------------
# Catches: a per-line fork coming back; the fallback decided once per RUN instead of per file.
# N, plain case: one valid 3,000-line file costs 1 sed (the pass) + 2 grep (set -e / pipefail probes) = 3; allow 4 in all.
wd=$(wrappers wrap_plain); cf="$work/count_plain"; : > "$cf"
d=$(fx speed_plain); { echo 'set -uo pipefail'; i=0; while (( i < 3000 )); do echo "echo \"line $i\" 'x'"; i=$((i+1)); done; } > "$d/scripts/fixture.sh"
out=$( cd "$d" && PATH="$wd:$PATH" HYG_COUNT="$cf" bash "$SUBJECT" scripts 2>&1 ); rc=$?
tot=$("$REAL_GREP" -c . "$cf" || true)
if (( rc == 0 )) && (( tot <= 4 )) && (( $(count_of "$cf" sed) <= 1 )); then pass "speed_3000_lines_total_${tot}_external_procs_le_4"; else fail speed_3000_lines_external_procs "rc=$rc total=$tot sed=$(count_of "$cf" sed)"; fi
# Two files: invalid bytes (5 non-comment lines) then valid 3,000 lines. Bound for sed:
# valid file 1 + invalid file (1 failed pass + 1 per NON-COMMENT line = 5) = 7. A per-run
# fallback would pay ~3,000 for the second file.
if two_loc=$(loc_name en_US.UTF-8 || loc_name C.UTF-8); then
  wd=$(wrappers wrap_two); cf="$work/count_two"; : > "$cf"
  d=$(fx speed_two); printf '# bad\nset -uo pipefail\necho a\nprintf \xff x\necho b\necho c\n' > "$d/scripts/a_bad.sh"
  cp "$work/speed_plain/scripts/fixture.sh" "$d/scripts/b_valid.sh"
  out=$( cd "$d" && LC_ALL=$two_loc PATH="$wd:$PATH" HYG_COUNT="$cf" bash "$SUBJECT" scripts 2>&1 ); rc=$?
  nsed=$(count_of "$cf" sed)
  if (( rc == 0 )) && (( nsed <= 7 )); then pass "fallback_is_per_file_sed_${nsed}_le_7"; else fail fallback_is_per_file "rc=$rc sed=$nsed (bound 7)"; fi
else
  printf '  skip  %-62s no UTF-8 locale installed\n' fallback_is_per_file; skipped=$((skipped+1))
fi

# --- R2: a sed that loses a line must not shift every later line. ---------------
# Catches: the desync guard removed (the later line would be judged on the NEXT line's text).
wd="$work/wrap_dropper"; mkdir -p "$wd"
printf '#!/bin/sh\n%s "$@" | %s 2d\n' "$REAL_SED" "$REAL_SED" > "$wd/sed"; chmod +x "$wd/sed"
d=$(fx desync); printf '%s\n' 'set -o pipefail' 'echo hi' 'produce | grep -q x' 'echo done' > "$d/scripts/fixture.sh"
out=$( cd "$d" && PATH="$wd:$PATH" bash "$SUBJECT" scripts 2>&1 ); rc=$?
if (( rc == 1 )) && grep -qF 'fixture.sh:3 ' <<<"$out" && (( $(grep -c GREPQ <<<"$out") == 1 )); then pass desync_guard_rescans_per_line; else fail desync_guard_rescans_per_line "rc=$rc: $out"; fi

# --- R1 / M9: no temp file -> still scan, say so once, never report clean. -----
# Catches: mktemp failure turned into "skip the file" (clean, rc 0), or into a bare exit.
d=$(fx notmp); printf '%s\n' 'set -o pipefail' 'produce | grep -q x' > "$d/scripts/fixture.sh"
out=$( cd "$d" && TMPDIR="/nonexistent-$$-$RANDOM" bash "$SUBJECT" scripts 2>&1 ); rc=$?
if (( rc == 1 )) && grep -qF 'fixture.sh:2 ' <<<"$out" && ! grep -qF 'clean' <<<"$out" && (( $(grep -c 'cannot create a temp file' <<<"$out") == 1 )); then
  pass no_temp_dir_still_scans_never_clean; else fail no_temp_dir_still_scans_never_clean "rc=$rc: $out"; fi
ro="$work/readonly"; rm -rf "$ro"; mkdir -p "$ro"; chmod 0555 "$ro"
if ( : > "$ro/probe" ) 2>/dev/null; then
  printf '  skip  %-62s directory is writable despite 0555 (running as root)\n' no_temp_readonly_dir; skipped=$((skipped+1)); rm -f "$ro/probe"
else
  out=$( cd "$d" && TMPDIR="$ro" bash "$SUBJECT" scripts 2>&1 ); rc=$?
  if (( rc == 1 )) && grep -qF 'fixture.sh:2 ' <<<"$out" && ! grep -qF 'clean' <<<"$out"; then pass no_temp_readonly_dir_still_scans; else fail no_temp_readonly_dir_still_scans "rc=$rc: $out"; fi
fi
chmod 0755 "$ro"

# --- temp-file cleanup on every way out. ----------------------------------------
# Catches: the per-file rm dropped (leak after normal end); the EXIT trap removed
# (leak when killed mid-scan or on the early exit).
tdir="$work/tmpd"; rm -rf "$tdir"; mkdir -p "$tdir"
# two files: a leak per file shows up even though the EXIT trap removes the last one.
d=$(fx cleanup_ok); printf '%s\n' 'set -uo pipefail' 'echo hi' > "$d/scripts/fixture.sh"; cp "$d/scripts/fixture.sh" "$d/scripts/second.sh"
( cd "$d" && TMPDIR="$tdir" bash "$SUBJECT" scripts >/dev/null 2>&1 )
if [[ -z "$(ls -A "$tdir")" ]]; then pass tmp_removed_after_normal_run; else fail tmp_removed_after_normal_run "left: $(ls "$tdir")"; fi
rm -rf "$tdir"; mkdir -p "$tdir"
d=$(fx cleanup_empty); rm -rf "$d/scripts"; mkdir -p "$d/scripts"
( cd "$d" && TMPDIR="$tdir" bash "$SUBJECT" scripts >/dev/null 2>&1 ); rc=$?
if (( rc == 2 )) && [[ -z "$(ls -A "$tdir")" ]]; then pass tmp_absent_after_early_exit_no_sources; else fail tmp_absent_after_early_exit_no_sources "rc=$rc left: $(ls "$tdir")"; fi

# signals: start a scan of a large file, wait (bounded) until its temp file exists,
# signal it, assert the dir is empty. If the scan finished first the case is
# INCONCLUSIVE and FAILS. SIGINT is ignored by a background job of a
# non-interactive shell, so it is started through perl which restores the default.
d=$(fx cleanup_big); { echo 'set -uo pipefail'; i=0; while (( i < 40000 )); do echo "echo \"l $i\" 'x'"; i=$((i+1)); done; } > "$d/scripts/fixture.sh"
sigcase() { # name signal bash
  local name="$1" sig="$2" sh="$3" pid i rc left
  rm -rf "$tdir"; mkdir -p "$tdir"
  if [[ "$sig" == INT ]]; then
    command -v perl >/dev/null 2>&1 && command -v pgrep >/dev/null 2>&1 || { printf '  skip  %-62s needs perl (restores SIGINT) and pgrep\n' "$name"; skipped=$((skipped+1)); return; }
    ( cd "$d" && TMPDIR="$tdir" exec perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' "$sh" "$SUBJECT" scripts >/dev/null 2>&1 ) & pid=$!
  else
    ( cd "$d" && TMPDIR="$tdir" exec "$sh" "$SUBJECT" scripts >/dev/null 2>&1 ) & pid=$!
  fi
  # Wait for the temp file AND for the one-pass sed child to be gone: bash swallows a
  # SIGINT that arrives while a foreground child (the sed) runs and that child was not
  # itself signalled, so a signal in that window would test nothing.
  i=0; while { [[ -z "$(ls -A "$tdir")" ]] || pgrep -P "$pid" >/dev/null 2>&1; } && kill -0 "$pid" 2>/dev/null && (( i < 400 )); do sleep 0.05; i=$((i+1)); done
  if ! kill -0 "$pid" 2>/dev/null || [[ -z "$(ls -A "$tdir")" ]]; then fail "$name" "inconclusive: scan ended or no temp file before the signal"; wait "$pid" 2>/dev/null; return; fi
  kill -"$sig" "$pid"; wait "$pid" 2>/dev/null; rc=$?
  left="$(ls -A "$tdir")"
  if (( rc > 128 )) && [[ -z "$left" ]]; then pass "$name"; else fail "$name" "rc=$rc (want >128: killed mid-scan) left: $left"; fi
}
shells=("$(command -v bash)"); [[ -x /bin/bash && "$(/bin/bash -c 'echo $BASH_VERSION')" != "$("${shells[0]}" -c 'echo $BASH_VERSION')" ]] && shells+=(/bin/bash)
for sh in "${shells[@]}"; do
  v=$("$sh" -c 'echo ${BASH_VERSINFO[0]}')
  sigcase "tmp_removed_on_TERM_mid_scan_bash$v" TERM "$sh"
  sigcase "tmp_removed_on_INT_mid_scan_bash$v" INT "$sh"
done
(( skipped == 0 )) || echo "  note: $skipped case(s) skipped explicitly above"

echo "$ok ok, $failed failed"
(( failed == 0 )) || exit 1
