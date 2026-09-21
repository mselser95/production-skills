#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

coverage_min="${COVERAGE_MIN:-85.0}"
coverage_out="${COVERAGE_OUT:-coverage.out}"
floors_file="${COVERAGE_FLOORS:-scripts/coverage-floors.txt}"

# -count=1 is load-bearing, not habit. Without it `go test` may serve a CACHED
# result, and the coverage profile written from a cached run reflects whatever
# was cached rather than this tree -- so the ratchet can pass or fail on
# identical source depending only on cache state. Measured: 64.71% vs 85.6% on
# one package, same tree, differing only in whether the cache was warm. A gate
# whose verdict depends on a cache is not a gate.
go test -count=1 -coverpkg=./... ./... -coverprofile="${coverage_out}"
total="$(go tool cover -func="${coverage_out}" | tail -n1 | grep -oE '[0-9]+\.[0-9]+%$' | tr -d '%')"
echo "TOTAL COVERAGE: ${total}% (threshold ${coverage_min}%)"

# The global verdict is RECORDED, not acted on yet. Exiting here is what this
# script did until 2026-09-21, and it meant the per-package ratchet below
# never ran on exactly the repos that needed it: a repo under its global floor
# skipped the ratchet entirely, reported "not probed", and nobody looked,
# because the repo's coverage waiver appeared to explain the red. A whole
# second gate sat dead behind a waiver that was about a different number.
#
# That inverts the ratchet's own purpose, stated in its header below: it exists
# BECAUSE a global average hides a per-package regression. Skipping it whenever
# the global number is unhealthy hides the regression in precisely the case the
# global number was already failing to describe.
#
# So both checks always run, both verdicts are always printed, and the exit
# status is the union. An operator needs both facts in one run -- being told
# about the global floor, fixing it, and only then discovering a package
# regression is two round trips over one measurement.
global_failed=0
# Declared here, not inside the ratchet block below: under `set -u` the union
# check at the end reads it unconditionally, including on the no-floors-file
# path where the ratchet never assigns it.
ratchet_failed=0
if awk -v got="${total}" -v min="${coverage_min}" 'BEGIN { exit !(got < min) }'; then
  echo "coverage ${total}% is below ${coverage_min}%" >&2
  global_failed=1
fi

# --- per-package ratchet --------------------------------------------------
# The global floor above hides a per-package regression as long as some
# other package's coverage rose to compensate. scripts/coverage-floors.txt
# pins one floor per package (current measured value minus 2 points at the
# time it was generated), so a package can never quietly slide underneath a
# healthy global average.
#
# Per-package percentages are derived from the SAME coverage.out profile
# above (no second test run): -coverpkg=./... means every test binary is
# instrumented for every package, so the raw profile contains one block
# entry per (package under test, package instrumented) pair. A block is
# "covered" if ANY of those entries has a non-zero count -- matching what
# `go tool cover -func` itself does when it merges the profile.
if [[ -f "${floors_file}" ]]; then
  module_path="$(go list -m)"
  perpkg_out="$(mktemp)"
  trap 'rm -f "${perpkg_out}"' EXIT

  awk -v module="${module_path}/" '
    /^mode:/ { next }
    NF < 3 { next }
    {
      loc = $1
      numstmt = $2 + 0
      count = $3 + 0
      if (!(loc in stmtOf)) {
        stmtOf[loc] = numstmt
        file = loc
        sub(/:.*/, "", file)
        sub(module, "", file)
        slash = match(file, /\/[^\/]+$/)
        pkgOf[loc] = (slash > 0) ? substr(file, 1, slash - 1) : file
      }
      if (count > 0) covered[loc] = 1
    }
    END {
      for (loc in stmtOf) {
        p = pkgOf[loc]
        pkgTotal[p] += stmtOf[loc]
        if (loc in covered) pkgCov[p] += stmtOf[loc]
      }
      for (p in pkgTotal) printf "%s %.2f\n", p, (100.0 * pkgCov[p] / pkgTotal[p])
    }
  ' "${coverage_out}" > "${perpkg_out}"

  while read -r pkg floor; do
    [[ -z "${pkg}" || "${pkg}" == \#* ]] && continue

    actual="$(awk -v want="${pkg}" '$1 == want { print $2; found=1 } END { if (!found) print "" }' "${perpkg_out}")"
    if [[ -z "${actual}" ]]; then
      echo "per-package coverage ratchet: package '${pkg}' has a floor (${floor}%) in ${floors_file} but no measured coverage in this run (renamed or removed package? update ${floors_file})" >&2
      ratchet_failed=1
      continue
    fi

    if awk -v got="${actual}" -v min="${floor}" 'BEGIN { exit !(got < min) }'; then
      echo "per-package coverage ratchet: ${pkg} is ${actual}%, below its floor of ${floor}% (see ${floors_file})" >&2
      ratchet_failed=1
    fi
  done < "${floors_file}"

  # The loop above walks the FLOORS file, so it catches a floor whose package
  # vanished. It cannot catch the opposite, which is the direction that
  # actually happens: a NEW package appears, nobody adds a line for it, and it
  # is silently ungated forever while the ratchet reports every package at or
  # above its floor. A green ratchet over an unmeasured package is worse than
  # no ratchet, because green reads as evidence.
  #
  # So: every package with measured statements must have a floor line.
  while read -r pkg _actual; do
    [[ -z "${pkg}" ]] && continue
    if ! awk -v want="${pkg}" '$1 == want { found=1 } END { exit !found }' "${floors_file}"; then
      echo "per-package coverage ratchet: package '${pkg}' has measured coverage but NO floor in ${floors_file} -- a new package is ungated until you add one (measure it, subtract 2.0, add the line)" >&2
      ratchet_failed=1
    fi
  done < "${perpkg_out}"

  if [[ "${ratchet_failed}" -eq 0 ]]; then
    echo "per-package coverage ratchet: all packages at/above their floor, and every measured package has one (${floors_file})"
  fi
else
  # No floors file means the ratchet had nothing to check. Say so rather than
  # leaving silence, which reads identically to "checked and all clear".
  echo "per-package coverage ratchet: SKIPPED -- no ${floors_file}" >&2
fi

# The union, reported as one verdict so neither failure can be read as the
# whole story.
if [[ "${global_failed}" -ne 0 || "${ratchet_failed}" -ne 0 ]]; then
  # Plain `if`s, not `[[ … ]] && var=…`: under `set -e` a false test makes that
  # form the failing last command of the list and kills the script before it
  # can report anything -- the gate would die exactly when it has a verdict.
  global_verdict="ok"
  if [[ "${global_failed}" -ne 0 ]]; then global_verdict="FAIL"; fi
  ratchet_verdict="ok"
  if [[ "${ratchet_failed}" -ne 0 ]]; then ratchet_verdict="FAIL"; fi
  echo "coverage: FAILED (global floor: ${global_verdict}, per-package ratchet: ${ratchet_verdict})" >&2
  exit 1
fi
