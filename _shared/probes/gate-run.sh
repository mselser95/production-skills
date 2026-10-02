#!/usr/bin/env bash
# gate-run.sh — run a gate command and let only the useful part reach an
# agent's context. The FULL output always goes to a log file; stdout carries a
# header, the lines that look like failures, and the tail.
#
# WHY: every agent turn re-reads the whole context, and raw gate logs were a
# large share of implementer context. Truncate verbatim, keep the full output
# recoverable (the log path is in the header), never paraphrase.
#
# Usage: gate-run.sh [--tail N] [--max-bytes B] [--label L] -- CMD [ARGS...]
#   --tail N       lines of tail to print (default 40)
#   --max-bytes B  output under B bytes is printed whole (default 2000)
#   --label L      names the log: mktemp ${TMPDIR:-/tmp}/gate-run.<L>.XXXXXX (default: pid)
# Stdout: `gate-run: <label> exit=<rc> log=<path> lines=<n>`, then either the
#   whole output, or `== failures` (matching lines, deduplicated, max 40) and
#   `== tail`.
# Exit: CMD's exit code; 2 on bad usage.
set -uo pipefail

usage() { echo "usage: gate-run.sh [--tail N] [--max-bytes B] [--label L] -- CMD [ARGS...]" >&2; exit 2; }

tail_n=40 max_bytes=2000 label=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tail) [ $# -ge 2 ] || usage; tail_n="$2"; shift 2 ;;
    --max-bytes) [ $# -ge 2 ] || usage; max_bytes="$2"; shift 2 ;;
    --label) [ $# -ge 2 ] || usage; label="$2"; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ $# -gt 0 ] || usage
case "$tail_n" in ''|*[!0-9]*) usage ;; esac
case "$max_bytes" in ''|*[!0-9]*) usage ;; esac
[ "$tail_n" -gt 0 ] || usage
[ -n "$label" ] || label="$$"
label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_')"

logdir="${TMPDIR:-/tmp}"
log="$(mktemp "$logdir/gate-run.$label.XXXXXX" 2>/dev/null)" || {
  echo "gate-run: ERROR cannot create log in $logdir"
  exit 2
}
"$@" > "$log" 2>&1
rc=$?

bytes="$(wc -c < "$log" | tr -d ' ')"
lines="$(awk 'END{print NR}' "$log")"
echo "gate-run: $label exit=$rc log=$log lines=$lines"

if [ "$bytes" -lt "$max_bytes" ]; then
  cat "$log"
  # a final line without a newline must not run into whatever prints next
  if [ "$bytes" -gt 0 ] && [ -n "$(tail -c 1 "$log")" ]; then echo; fi
else
  echo "== failures"
  grep -E 'FAIL|panic:|^--- FAIL|Error|error:|undefined:|cannot |not ok|✗' "$log" \
    | awk '!seen[$0]++' | head -n 40
  echo "== tail"
  tail -n "$tail_n" "$log"
  if [ -n "$(tail -c 1 "$log")" ]; then echo; fi
fi
exit "$rc"
