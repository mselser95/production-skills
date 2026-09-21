#!/usr/bin/env bash
# observability-provenance-selftest.sh -- the committed mutation matrix for two
# rows of verify-standard.sh that had NO selftest at all until 2026-09-21, and
# were both measured wrong in production on the same day.
#
# WHY THIS FILE EXISTS. Neither `observability:logs_correlate` nor
# `artifact-provenance` was covered by any selftest, and both were wrong:
#
#   logs_correlate     reported "19 of 32 log call sites drop the trace
#                      context" on falcon-xyz-udf-service, where NOT ONE of the
#                      19 was a log call. Its detector matched any `.Error(`
#                      with arguments, so it counted `status.Error(codes.X, …)`
#                      (the gRPC status constructor) and `http.Error(w, …)`,
#                      including one per RPC inside GENERATED
#                      Unimplemented<Service>Server stubs -- a row that gets
#                      wronger as a service's RPC surface grows.
#
#   artifact-provenance reported PASS on that same repo while its attest job was
#                      commented out in its entirety. The obvious diagnosis is
#                      wrong: the comment stripping works. The match came from
#                      live YAML -- a single `attestations: write` PERMISSIONS
#                      GRANT in a different job. The row accepted the capability
#                      as evidence of the act, which is the same defect its own
#                      comments record fixing once already for `cosign sign`.
#
# Both are the shape-without-the-property failure this framework exists to
# refuse, and both survived because nothing ever exercised the rows. A gate
# observed only green has not been observed.
#
# HOW IT TESTS. It LIFTS each row's program out of verify-standard.sh by anchor
# and runs it against fixtures, rather than restating the logic -- a selftest
# that reimplements the detector tests the reimplementation, not the thing that
# runs. That is this suite's house rule (see sbom-ordering-selftest.sh) and it
# is the reason the extraction below is anchored on distinctive lines and FAILS
# LOUDLY if an anchor stops matching, instead of silently testing nothing.
set -uo pipefail

CASES=0
FAILED=0

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || {
  echo "observability-provenance selftest: cannot reach the repo root" >&2; exit 2; }

# Resolve the probe in either layout: `_shared/probes/…` in this framework repo
# (where it is EDITED) and `scripts/…` in an instantiated repo (where it RUNS).
PROBE="_shared/probes/verify-standard.sh"
[ -f "$PROBE" ] || PROBE="scripts/verify-standard.sh"
[ -f "$PROBE" ] || { echo "observability-provenance selftest: no verify-standard.sh found" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

# --- extract the two programs ------------------------------------------------
# Anchors are distinctive lines, and a zero-length extraction is a hard error:
# non-vacuity-selftest.sh records six cases that silently went empty when a
# redirect was appended to the line they anchored on.
sed -n '/^  slog_plain=0$/,/^  done < <(grep -rlE/p' "$PROBE" > "$TMP/logs.sh"
[ -s "$TMP/logs.sh" ] || { echo "FAIL: logs_correlate anchor matched nothing -- the probe changed shape" >&2; exit 2; }
grep -q 'done < <(grep -rlE' "$TMP/logs.sh" || { echo "FAIL: logs_correlate extraction truncated" >&2; exit 2; }

sed -n '/^  if grep -qE "cosign\[\[:space:\]\]+attest/,/^  else row "artifact-provenance"/p' "$PROBE" > "$TMP/prov.sh"
[ -s "$TMP/prov.sh" ] || { echo "FAIL: artifact-provenance anchor matched nothing -- the probe changed shape" >&2; exit 2; }
grep -q 'else row "artifact-provenance"' "$TMP/prov.sh" || { echo "FAIL: artifact-provenance extraction truncated" >&2; exit 2; }

# --- harnesses ---------------------------------------------------------------
run_logs() {            # $1 = fixture dir -> prints "plain=<n> ctx=<n>"
  ( cd "$1" || exit 2
    # SC1090: the path is built at runtime. SC2154: both counters are assigned
    # by the fragment sourced on the line above -- lifted out of the probe
    # rather than restated here, which is the whole point of this suite.
    # shellcheck disable=SC1090
    . "$TMP/logs.sh"
    # shellcheck disable=SC2154
    printf 'plain=%s ctx=%s\n' "$slog_plain" "$slog_ctx" )
}

run_prov() {            # $1 = workflow dir, $2 = "waived"|"" -> prints the verdict
  ( wf="$1"
    _waived="${2:-}"
    row() { printf '%s\n' "$2"; }
    waived() { [ -n "$_waived" ]; }
    # SC2034: wf_exec is not unused -- it is the INPUT the sourced fragment
    # reads, exactly as the probe builds it one line before the extracted
    # block. shellcheck cannot see across the `.` on the next line.
    # shellcheck disable=SC2034
    wf_exec="$(grep -rhE "^[^#]*" "$wf"/*.yaml 2>/dev/null | sed 's/#.*//' || true)"
    # shellcheck disable=SC1090
    . "$TMP/prov.sh" )
}

check() {               # $1 = label, $2 = expected, $3 = actual
  CASES=$((CASES+1))
  if [ "$2" = "$3" ]; then
    printf '  ok   %-58s %s\n' "$1" "$3"
  else
    printf '  FAIL %-58s expected=%s actual=%s\n' "$1" "$2" "$3"
    FAILED=$((FAILED+1))
  fi
}

# --- logs_correlate fixtures -------------------------------------------------
# HEALTHY: every real log call carries context; the only `.Error(` hits are the
# gRPC status constructor, an http.Error, and generated stubs.
mkdir -p "$TMP/logs-healthy"
cat > "$TMP/logs-healthy/server.go" <<'GO'
package server

import "log/slog"

func (s *S) A(ctx context.Context) error {
	s.logger.InfoContext(ctx, "handled")
	return status.Error(codes.InvalidArgument, "bad resolution")
}
func (s *S) B(ctx context.Context) error {
	s.logger.ErrorContext(ctx, "upstream failed")
	return status.Error(codes.Internal, "boom")
}
func (s *S) C(w http.ResponseWriter) { http.Error(w, "nope", 400) }
GO
cat > "$TMP/logs-healthy/svc_grpc.pb.go" <<'GO'
// Code generated by protoc-gen-go-grpc. DO NOT EDIT.

package v1

func (UnimplementedSvcServer) A() error { return status.Error(codes.Unimplemented, "method A not implemented") }
func (UnimplementedSvcServer) B() error { return status.Error(codes.Unimplemented, "method B not implemented") }
func (UnimplementedSvcServer) C() error { return status.Error(codes.Unimplemented, "method C not implemented") }
func (UnimplementedSvcServer) D() error { return status.Error(codes.Unimplemented, "method D not implemented") }
func (UnimplementedSvcServer) E() error { return status.Error(codes.Unimplemented, "method E not implemented") }
func (UnimplementedSvcServer) F() error { return status.Error(codes.Unimplemented, "method F not implemented") }
GO

# BROKEN: genuine plain log calls, which must still be caught.
mkdir -p "$TMP/logs-broken"
cat > "$TMP/logs-broken/server.go" <<'GO'
package server

import "log/slog"

func (s *S) A(ctx context.Context) {
	s.logger.Info("handled")
	s.logger.Warn("careful")
	s.logger.Error("bad thing", "err", err)
	s.logger.InfoContext(ctx, "ok")
}
GO

# GENERATED-ONLY: a repo whose only matches are generated must not invent a
# denominator. "0 of 0 is wrong" is the vacuous pass this framework refuses.
mkdir -p "$TMP/logs-genonly"
cp "$TMP/logs-healthy/svc_grpc.pb.go" "$TMP/logs-genonly/"

# GENERATED-LOGGER: isolates the generated-file exclusion from the receiver
# filter. In the healthy fixture above every generated hit is `status.Error`,
# so the receiver filter alone already strips them and the exclusion is
# redundant THERE -- a case that cannot fail proves nothing. Some generators do
# emit real logging, so this fixture puts a genuine `logger.Info(` inside a
# generated file: only the `DO NOT EDIT.` exclusion can keep it out of the
# count, which makes this the case that holds that half of the fix in place.
mkdir -p "$TMP/logs-genlogger"
cat > "$TMP/logs-genlogger/zz_generated_client.go" <<'GO'
// Code generated by some-codegen. DO NOT EDIT.

package client

func (c *C) Do() {
	c.logger.Info("generated client call")
	c.logger.Warn("generated retry")
}
GO
cat > "$TMP/logs-genlogger/handwritten.go" <<'GO'
package client

func (s *S) A(ctx context.Context) { s.logger.InfoContext(ctx, "ok") }
GO

check "logs: status.Error+http.Error+generated are NOT log calls" \
      "plain=0 ctx=2" "$(run_logs "$TMP/logs-healthy")"
check "logs: a real plain log call is still counted" \
      "plain=3 ctx=1" "$(run_logs "$TMP/logs-broken")"
check "logs: generated-only tree yields an empty denominator" \
      "plain=0 ctx=0" "$(run_logs "$TMP/logs-genonly")"
check "logs: a real log call inside a GENERATED file is excluded" \
      "plain=0 ctx=1" "$(run_logs "$TMP/logs-genlogger")"

# PORTABILITY, checked statically because it CANNOT be checked with a fixture
# here. `grep -oc` is not portable: BSD grep (macOS) prints the number of
# MATCHES, GNU/busybox grep (ubuntu-latest, where CI runs) prints the number of
# matching LINES. Measured on two calls in one line: macOS 2, alpine 1. A
# fixture would therefore PASS on the machine this suite is usually run on and
# only fail in CI -- so the guard is a text check on the extracted program,
# which fails identically everywhere.
#
# COMMENTS ARE STRIPPED FIRST. Without that, this check fires on the comment
# in the probe that EXPLAINS the rule ("NEVER `grep -oc`") -- a guard that
# punishes documenting its own lesson, which makes the cheapest way to pass it
# deleting the explanation. Measured: it did exactly that on its first run.
oc_misuse=$(grep -vE '^[[:space:]]*#' "$TMP/logs.sh" | grep -cE "grep[[:space:]]+(-[A-Za-z]*[[:space:]]+)*-[A-Za-z]*(oc|co)[A-Za-z]*[[:space:]]" || true)
check "logs: no non-portable 'grep -oc' in the counting program" "0" "$oc_misuse"

# --- artifact-provenance fixtures --------------------------------------------
mkdir -p "$TMP/prov-grant" "$TMP/prov-real" "$TMP/prov-sign" "$TMP/prov-none"

# GRANT-ONLY: the exact residue a commented-out attest job leaves behind.
cat > "$TMP/prov-grant/ci.yaml" <<'YML'
jobs:
  docker-build:
    permissions:
      id-token: write
      attestations: write
    steps:
      - run: docker build .
  # attest-build:
  #   steps:
  #     - uses: actions/attest-build-provenance@v1
YML
cat > "$TMP/prov-real/ci.yaml" <<'YML'
jobs:
  attest-build:
    permissions:
      attestations: write
    steps:
      - uses: actions/attest-build-provenance@v1
YML
printf 'jobs:\n  s:\n    steps:\n      - run: cosign sign img\n' > "$TMP/prov-sign/ci.yaml"
printf 'jobs:\n  b:\n    steps:\n      - run: go build ./...\n' > "$TMP/prov-none/ci.yaml"

grant_verdict=$(run_prov "$TMP/prov-grant")
real_verdict=$(run_prov "$TMP/prov-real")
sign_verdict=$(run_prov "$TMP/prov-sign")
none_verdict=$(run_prov "$TMP/prov-none")
waived_verdict=$(run_prov "$TMP/prov-grant" waived)

check "prov: a permissions GRANT alone does not prove provenance" \
      "FAIL" "$(case "$grant_verdict" in FAIL*) echo FAIL;; PASS*) echo PASS;; *) echo NA;; esac)"
check "prov: a real attest-build-provenance step passes" \
      "PASS" "$(case "$real_verdict" in PASS*) echo PASS;; FAIL*) echo FAIL;; *) echo NA;; esac)"
check "prov: signing alone still fails" \
      "FAIL" "$(case "$sign_verdict" in FAIL*) echo FAIL;; PASS*) echo PASS;; *) echo NA;; esac)"
check "prov: nothing at all still fails" \
      "FAIL" "$(case "$none_verdict" in FAIL*) echo FAIL;; PASS*) echo PASS;; *) echo NA;; esac)"
# The waiver must OUTRANK every diagnostic FAIL. It used to sit below them,
# which made `artifact-provenance-signing` unreachable in the one case it is
# named for -- a waiver that is dead code in its own use case.
check "prov: a granted waiver outranks the diagnostic FAILs" \
      "NA" "$waived_verdict"

# --- verdict -----------------------------------------------------------------
if [ "$CASES" -eq 0 ]; then
  echo "observability-provenance selftest: ZERO cases ran -- refusing to report a pass over an empty set" >&2
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "observability-provenance selftest: $FAILED of $CASES case(s) FAILED" >&2
  exit 1
fi
echo "observability-provenance selftest: $CASES cases passed"
