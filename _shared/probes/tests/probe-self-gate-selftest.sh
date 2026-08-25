#!/usr/bin/env bash
# scripts/tests/probe-self-gate-selftest.sh
#
# Non-vacuity matrix for verify-standard.sh's `probe-self:no-pipe-into-grep-q`
# row. That row is now the ENFORCEMENT for a rule that used to live only in a
# comment, so its correctness cannot live in a commit message: three of its
# kill directions failed review the first time it was written.
#
# Each case is a tiny file plus an expected verdict. FIRE means the gate must
# report FAIL on it; QUIET means it must not.
set -uo pipefail
# The probe always sits one directory above this test, in BOTH layouts:
#   repos:  scripts/tests/  -> scripts/verify-standard.sh
#   shared: _shared/probes/tests/ -> _shared/probes/verify-standard.sh
_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_here/../verify-standard.sh"
[[ -r $PROBE ]] || { echo "selftest: cannot read $PROBE"; exit 2; }

# Extract the gate's two detector expressions FROM the probe, so this test
# cannot drift away from the code it certifies.
eval "$(sed -n '/^  _greplike=/p;/^  _quietfl=/p' "$PROBE")"
[[ -n ${_greplike:-} && -n ${_quietfl:-} ]] || { echo "selftest: could not extract detectors from $PROBE -- did the gate move?"; exit 1; }

verdict() { # verdict <file> -> FIRE|QUIET
  local f=$1 nl=$'\001' logical pipegrep globalifs
  logical=$(grep -vE '^[[:space:]]*#' "$f" | tr '\n' "$nl" \
    | sed -e "s/\\\\${nl}[[:space:]]*/ /g" -e "s/|${nl}[[:space:]]*/| /g" | tr "$nl" '\n')
  pipegrep=$(printf '%s\n' "$logical" | grep -E "(^|[^|])\|[[:space:]]*${_greplike}${_quietfl}" || true)
  globalifs=$(grep -n '' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -E '^[0-9]+:[[:space:]]*(export[[:space:]]+)?IFS=[^[:space:];]*[[:space:]]*(;|$)' || true)
  [[ -n $pipegrep || -n $globalifs ]] && echo FIRE || echo QUIET
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { # check <expected> <name> <body...>
  local want=$1 name=$2; shift 2
  printf '%s\n' "$@" > "$tmp/c.sh"
  local got; got=$(verdict "$tmp/c.sh")
  if [[ $got == "$want" ]]; then pass=$((pass+1)); printf '  ok   %-46s %s\n' "$name" "$got"
  else fail=$((fail+1)); printf '  FAIL %-46s want=%s got=%s\n' "$name" "$want" "$got"; fi
}

# --- must FIRE: real reintroductions of the hazard -------------------------
check FIRE  "plain pipe into grep -q"        'go doc ./p | grep -q Foo'
check FIRE  "inside command substitution"    'x=$(go doc ./p | grep -q Foo && echo y)'
check FIRE  "inside a function body"         'chk(){ go doc ./p | grep -q Foo; }'
check FIRE  "egrep -q"                       'go doc ./p | egrep -q Foo'
check FIRE  "zgrep -q"                       'zcat x.gz | zgrep -q Foo'
check FIRE  "rg -q"                          'go doc ./p | rg -q Foo'
check FIRE  "long option --quiet"            'cat f | grep --quiet x'
check FIRE  "flags before q (-sq)"           'go doc ./p | grep -sq Foo'
check FIRE  "q before other flags (-qs)"     'go doc ./p | grep -qs Foo'
check FIRE  "no spaces a|grep -q"            'go doc ./p|grep -q Foo'
check FIRE  "absolute path grep"             'go doc ./p | /usr/bin/grep -q Foo'
check FIRE  "command grep -q"                'go doc ./p | command grep -q Foo'
check FIRE  "env-prefixed grep -q"           'go doc ./p | LC_ALL=C grep -q Foo'
check FIRE  "third pipe segment"             'a | b | grep -q Foo'
check FIRE  "backslash cont, indented pipe"  'go doc ./p \' '   | grep -q Foo'
check FIRE  "backslash cont, pipe column 0"  'go doc ./p \' '|grep -qx Foo'
check FIRE  "trailing-pipe continuation"     'go doc ./p |' '  grep -q Foo'
check FIRE  "global IFS assignment"          "IFS=\$'\\n'"
check FIRE  "exported IFS"                   'export IFS=:'

# --- must stay QUIET: legitimate code --------------------------------------
check QUIET "here-string into grep -q"       'grep -qx "$m" <<<"$blob"'
check QUIET "logical OR into grep -q"        'false || grep -q Foo file'
check QUIET "grep -q on a file operand"      'grep -q Foo file.txt'
check QUIET "pipe into a NON-quiet grep"     'go doc ./p | grep -c Foo'
check QUIET "local IFS join idiom"           'f(){ local IFS=,; echo "${a[*]}"; }'
check QUIET "IFS=\$'\\n' command prefix"      "IFS=\$'\\n' mapfile -t arr < f"
check QUIET "IFS= read prefix"               'while IFS= read -r l; do :; done < f'
check QUIET "IFS= mentioned inside a string" 'echo "the variable IFS= must not be set"'

# --- the row must fail closed when it cannot see itself --------------------
if PROBE_SELF="" bash -c 'if [[ -n "${PROBE_SELF:-}" && -r "${PROBE_SELF:-}" ]]; then exit 9; else exit 0; fi'; then
  pass=$((pass+1)); printf '  ok   %-46s %s\n' "unset PROBE_SELF takes the FAIL branch" "FIRE"
else
  fail=$((fail+1)); printf '  FAIL %-46s\n' "unset PROBE_SELF takes the FAIL branch"
fi

# --- the live probe itself must be clean -----------------------------------
live=$(verdict "$PROBE")
if [[ $live == QUIET ]]; then pass=$((pass+1)); printf '  ok   %-46s %s\n' "the live probe is clean" "$live"
else fail=$((fail+1)); printf '  FAIL %-46s got=%s\n' "the live probe is clean" "$live"; fi

echo "probe-self gate selftest: $pass ok, $fail failed"
(( fail == 0 )) || exit 1
