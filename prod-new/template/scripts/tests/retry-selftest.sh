#!/usr/bin/env bash
#
# Selftest for scripts/retry.sh.
#
# A retry wrapper is exactly the kind of helper that turns a red gate green by
# accident: get it wrong and every command it wraps reports success. So it is
# driven against fixtures with KNOWN outcomes and both directions are asserted
# -- that it passes what should pass AND that it still fails what should fail.
#
# The case that matters most is #2. If a retried command fails on every
# attempt, this wrapper must propagate that failure. A wrapper that swallowed
# it would silently disarm `go install`, `gosec`, `govulncheck`, `gitleaks` and
# `actionlint` in one move, since all of them are invoked through it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

RETRY="scripts/retry.sh"
pass=0
fail=0

ok()  { printf '  ok    %-52s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %-52s %s\n' "$1" "$2"; fail=$((fail + 1)); }

check() { # <name> <expected-exit> <actual-exit>
  if [[ "$2" == "$3" ]]; then ok "$1" "exit $3"; else bad "$1" "expected exit $2, got $3"; fi
}

echo "retry selftest"

# 1. No command at all. Must REFUSE rather than exit 0 having run nothing --
#    success over an empty input is the shape this repository's gates exist to
#    refuse, and a wrapper is no exception.
RETRY_DELAY=0 bash "$RETRY" >/dev/null 2>&1
check "no command given is refused, not passed" 2 "$?"

# 2. A command that fails every time must still fail, with ITS status (not 1,
#    not 0), after exactly RETRY_ATTEMPTS attempts.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/always-fails.sh" <<'EOF'
#!/usr/bin/env bash
echo "x" >> "$COUNTER"
exit 7
EOF
chmod +x "$tmp/always-fails.sh"

COUNTER="$tmp/n1" RETRY_DELAY=0 RETRY_ATTEMPTS=3 bash "$RETRY" "$tmp/always-fails.sh" >/dev/null 2>&1
check "a command that always fails still fails" 7 "$?"

attempts=$(wc -l < "$tmp/n1" | tr -d ' ')
if [[ "$attempts" == "3" ]]; then
  ok "it tried exactly RETRY_ATTEMPTS times" "3 attempts"
else
  bad "it tried exactly RETRY_ATTEMPTS times" "expected 3, got $attempts"
fi

# 3. A command that succeeds first time must not be run again -- a retry
#    wrapper that re-runs a successful command would double every install.
cat > "$tmp/always-works.sh" <<'EOF'
#!/usr/bin/env bash
echo "x" >> "$COUNTER"
exit 0
EOF
chmod +x "$tmp/always-works.sh"

COUNTER="$tmp/n2" RETRY_DELAY=0 bash "$RETRY" "$tmp/always-works.sh" >/dev/null 2>&1
check "a command that succeeds passes" 0 "$?"

attempts=$(wc -l < "$tmp/n2" | tr -d ' ')
if [[ "$attempts" == "1" ]]; then
  ok "a success is not re-run" "1 attempt"
else
  bad "a success is not re-run" "expected 1, got $attempts"
fi

# 4. THE WHOLE POINT: a command that fails transiently and then succeeds must
#    pass. Without this case the wrapper could be `exec "$@"` and cases 1-3
#    would all still be green.
cat > "$tmp/flaky.sh" <<'EOF'
#!/usr/bin/env bash
echo "x" >> "$COUNTER"
n=$(wc -l < "$COUNTER" | tr -d ' ')
[[ "$n" -ge 3 ]]
EOF
chmod +x "$tmp/flaky.sh"

COUNTER="$tmp/n3" RETRY_DELAY=0 RETRY_ATTEMPTS=3 bash "$RETRY" "$tmp/flaky.sh" >/dev/null 2>&1
check "a transient failure is retried and passes" 0 "$?"

attempts=$(wc -l < "$tmp/n3" | tr -d ' ')
if [[ "$attempts" == "3" ]]; then
  ok "it kept trying until it worked" "3 attempts"
else
  bad "it kept trying until it worked" "expected 3, got $attempts"
fi

# 5. The attempt budget is finite: a flaky command that needs MORE attempts
#    than allowed must fail. This is what keeps the wrapper from looping on a
#    genuinely broken dependency.
COUNTER="$tmp/n4" RETRY_DELAY=0 RETRY_ATTEMPTS=2 bash "$RETRY" "$tmp/flaky.sh" >/dev/null 2>&1
check "the attempt budget is respected, not unbounded" 1 "$?"

echo
echo "$pass ok, $fail failed"
[[ "$fail" -eq 0 ]]
