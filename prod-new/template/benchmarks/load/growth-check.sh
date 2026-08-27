#!/usr/bin/env bash
# growth-check.sh — decide whether a soak's resource samples show a LEAK.
#
# Reads a whitespace-separated table on stdin, one row per sample:
#
#   elapsed_s  goroutines  fds  rss_kb
#
# with `-` in any column the sampler could not read. Prints a verdict per
# metric and exits 1 if any of them grew beyond the tolerance, 2 if the input
# could not support a verdict at all.
#
# WHY THIS IS ITS OWN SCRIPT, rather than an awk block inside soak.sh. A leak
# detector is the classic gate that can only be verified by leaking, and a
# 30-minute soak is the worst possible place to find out that the detector
# never fires. Separated, it takes a synthetic series on stdin, so "does this
# actually go red on a leak" is a one-second question:
#
#   printf '%s\n' '0 10 20 100' '60 20 20 100' '120 30 20 100' ... | growth-check.sh
#
# THE VACUOUS FORMS, each of which produces a leak check that passes forever:
#
#   * FIRST SAMPLE VS LAST SAMPLE. Two points cannot distinguish growth from
#     noise, and the two they pick are the two most contaminated: the first is
#     taken before any pool, cache or arena has reached its working size. This
#     compares MEANS of two windows, after discarding a warm-up.
#
#   * TREATING WARM-UP AS A LEAK. The opposite error, and the reason people
#     widen the tolerance until nothing fails. Every long-lived process grows
#     for its first minutes and then stops; a check that flags that is a check
#     that gets switched off. The first third is discarded for this reason.
#
#   * A METRIC NOBODY COULD READ. A sampler that cannot see file descriptors
#     and reports 0 for all of them yields a perfectly flat series and a green
#     verdict. An unreadable column is reported UNAVAILABLE by name, and if NO
#     column was readable this exits 2 rather than passing.
#
#   * TOO FEW SAMPLES. Three points in a 30-minute window say nothing about a
#     slow leak. MIN_SAMPLES is a hard floor, and falling under it is exit 2 --
#     "could not decide", never "fine".
#
# Knobs (env): GROWTH_TOLERANCE_PCT (default 10), MIN_SAMPLES (default 9).
set -uo pipefail

tolerance="${GROWTH_TOLERANCE_PCT:-10}"
min_samples="${MIN_SAMPLES:-9}"

awk -v tolerance="$tolerance" -v min_samples="$min_samples" '
  # Column 1 is elapsed seconds; 2..4 are the sampled metrics.
  BEGIN {
    split("goroutines fds rss_kb", name, " ")
    n = 0
  }
  /^[[:space:]]*#/ { next }
  NF < 4 { next }
  {
    n++
    for (c = 2; c <= 4; c++) v[c, n] = $c
  }
  END {
    if (n < min_samples) {
      printf "UNDECIDED: %d sample(s), below the floor of %d. A soak this short cannot tell a slow leak from noise.\n", n, min_samples
      exit 2
    }

    # Discard the first third as warm-up, then split what remains in half and
    # compare the two means. Integer division, so the windows are whole
    # samples; with the floor above, each window holds at least three.
    warm = int(n / 3)
    rest = n - warm
    half = int(rest / 2)
    a_lo = warm + 1;      a_hi = warm + half
    b_lo = warm + half + 1; b_hi = n

    printf "samples=%d warmup_discarded=%d window_a=%d..%d window_b=%d..%d tolerance_pct=%s\n", \
      n, warm, a_lo, a_hi, b_lo, b_hi, tolerance

    readable = 0
    failed = 0
    for (c = 2; c <= 4; c++) {
      missing = 0
      for (i = 1; i <= n; i++) if (v[c, i] == "-" || v[c, i] == "") missing++
      if (missing == n) {
        printf "UNAVAILABLE %s: the sampler could not read this metric on this host; it was NOT measured, and nothing below claims it was.\n", name[c-1]
        continue
      }
      readable++

      sa = 0; ca = 0
      for (i = a_lo; i <= a_hi; i++) if (v[c, i] != "-") { sa += v[c, i]; ca++ }
      sb = 0; cb = 0
      for (i = b_lo; i <= b_hi; i++) if (v[c, i] != "-") { sb += v[c, i]; cb++ }
      if (ca == 0 || cb == 0) {
        printf "UNDECIDED %s: one of the two windows has no readable sample.\n", name[c-1]
        failed = 1
        continue
      }
      ma = sa / ca; mb = sb / cb
      if (ma == 0) {
        printf "UNDECIDED %s: the first window means zero, so growth has no denominator.\n", name[c-1]
        failed = 1
        continue
      }
      growth = 100 * (mb - ma) / ma

      # A series that never moves at all ACROSS THE MEASURED WINDOW is worth
      # saying out loud (the warm-up samples are excluded, so early growth
      # that levelled off does not suppress this note). It is often
      # correct (a goroutine count really can be constant) and it is also
      # exactly what a broken sampler produces, and the two are
      # indistinguishable from the verdict alone.
      spread = 0
      for (i = a_lo; i <= b_hi; i++) if (v[c, i] != "-" && v[c, i] != v[c, a_lo]) spread = 1
      flat = spread ? "" : "  NOTE: perfectly constant across the measured window (warm-up excluded) -- correct, or a sampler reading the same value each time."

      if (growth > tolerance) {
        printf "FAIL %s: %.1f -> %.1f, +%.2f%% (tolerance %s%%) -- growth that does not level off is what a leak looks like.%s\n", \
          name[c-1], ma, mb, growth, tolerance, flat
        failed = 1
      } else {
        printf "ok   %s: %.1f -> %.1f, %+.2f%% (tolerance %s%%)%s\n", name[c-1], ma, mb, growth, tolerance, flat
      }
    }

    if (readable == 0) {
      print "UNDECIDED: not one metric was readable on this host. This soak observed NOTHING; a pass here would mean nothing."
      exit 2
    }
    exit failed
  }
'
