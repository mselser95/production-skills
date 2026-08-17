#!/usr/bin/env bash
# profile.sh — capture a CPU + memory profile pair for a package.
#
# Usage: benchmarks/profile.sh [package] [bench-pattern]
#   benchmarks/profile.sh                          # ./internal/domain, all benchmarks
#   benchmarks/profile.sh ./internal/domain BenchmarkApply_Deposit
#
# Writes benchmarks/profiles/<package>-cpu.prof and -mem.prof (gitignored;
# a profile is a point-in-time artifact, not a regression fixture -- see
# benchmarks/profiles/README.md). View with:
#   go tool pprof benchmarks/profiles/<package>-cpu.prof
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

pkg="${1:-./internal/domain}"
pattern="${2:-.}"

mkdir -p benchmarks/profiles
slug="$(echo "$pkg" | tr '/.' '__')"
cpu_out="benchmarks/profiles/${slug}-cpu.prof"
mem_out="benchmarks/profiles/${slug}-mem.prof"

go test -run=^$ -bench="$pattern" -benchtime=2s \
  -cpuprofile="$cpu_out" -memprofile="$mem_out" "$pkg"

echo "captured: $cpu_out"
echo "captured: $mem_out"
echo "view with: go tool pprof $cpu_out"
