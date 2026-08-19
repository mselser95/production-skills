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

if awk -v got="${total}" -v min="${coverage_min}" 'BEGIN { exit !(got < min) }'; then
  echo "coverage ${total}% is below ${coverage_min}%" >&2
  exit 1
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

  ratchet_failed=0
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

  if [[ "${ratchet_failed}" -ne 0 ]]; then
    exit 1
  fi
  echo "per-package coverage ratchet: all packages at/above their floor (${floors_file})"
fi
