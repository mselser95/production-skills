#!/usr/bin/env bash
#
# Retry a command that READS over the network.
#
# # Why this exists
#
# Every `go install <tool>@<version>` in CI is a network read of a module
# proxy, and until now none of them were retried while every other read in
# this repository is. On 2026-09-14 two consecutive pushes to develop were
# red for the same reason, and it was not the code:
#
#   ##[error]golang.org/x/tools@v0.44.0: read
#   "https://proxy.golang.org/golang.org/x/tools/@v/v0.44.0.zip":
#   stream error: stream ID 933; INTERNAL_ERROR; received from peer
#
# An HTTP/2 stream error part-way through a large zip. `GOPROXY=...,direct`
# does not rescue it: the `direct` fallback is for a module the proxy does not
# HAVE, not for a transfer that breaks mid-flight, so Go treats it as fatal.
# The result is a red required check that says nothing about the commit.
#
# # Why this does not hide a real failure
#
# A retry masks a defect only when the thing retried is not idempotent or when
# failure is the answer. Installing a PINNED tool version is neither: it is a
# pure read of an immutable artifact, so either it eventually arrives or every
# attempt fails and this script exits with the last status and the job stays
# red. What it removes is the class of red that means "the internet hiccuped",
# which is worth removing precisely because a required check that is red for
# unrelated reasons teaches people that its red means nothing.
#
# Deliberately NOT retried anywhere: writes, and the gates themselves. A
# flaky test is a finding, not something to run three times until it passes.
# This wrapper belongs on `go install` and nothing else.
#
# # Usage
#
#   bash scripts/retry.sh go install example.com/tool@v1.2.3
#
# Knobs: RETRY_ATTEMPTS (default 3), RETRY_DELAY (default 5s, doubling).
set -uo pipefail

ATTEMPTS="${RETRY_ATTEMPTS:-3}"
DELAY="${RETRY_DELAY:-5}"

# A wrapper invoked with no command would run nothing and exit 0 -- success
# over an empty input, which is the exact shape the gates in this repository
# exist to refuse. Refuse it here too.
if (( $# == 0 )); then
  echo "retry.sh: no command given -- refusing to report success having run nothing" >&2
  exit 2
fi

status=0
for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
  # `status=$?` must be captured in the ELSE branch, not after `fi`. After
  # `fi`, `$?` is the status of the IF COMPOUND -- which bash defines as 0 when
  # the condition was false and there is no else branch. The first draft of
  # this script did exactly that, and the selftest beside it caught the result:
  # a command that failed all three attempts exited 0. That is a fail-open in
  # the one place it can do the most damage, since `go install`, gosec,
  # govulncheck, gitleaks and actionlint are all invoked through here.
  if "$@"; then
    if (( attempt > 1 )); then
      echo "retry.sh: succeeded on attempt ${attempt}/${ATTEMPTS}: $*" >&2
    fi
    exit 0
  else
    status=$?
  fi

  if (( attempt == ATTEMPTS )); then
    echo "retry.sh: FAILED after ${ATTEMPTS} attempt(s), exit ${status}: $*" >&2
    exit "$status"
  fi

  echo "retry.sh: attempt ${attempt}/${ATTEMPTS} failed (exit ${status}); retrying in ${DELAY}s: $*" >&2
  sleep "$DELAY"
  DELAY=$(( DELAY * 2 ))
done

# Unreachable: the loop either exits 0 on success or exits non-zero on the
# final attempt. Kept so a future edit to the loop cannot fall through to an
# implicit exit 0.
exit "${status:-1}"
