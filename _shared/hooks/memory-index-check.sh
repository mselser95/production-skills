#!/usr/bin/env bash
# memory-index-check.sh — SessionStart hook (and standalone probe) for the
# auto-memory index.
#
# WHY. Claude Code loads only the first 200 lines OR the first 25 KB of
# MEMORY.md, whichever comes first (docs: code.claude.com/docs/en/memory).
# On 2026-10-03 this user's index was 315 lines / 74 KB with 237-char lines:
# the 25 KB bound landed at line 105, so 210 memories were invisible to every
# session and 29 files had no index line at all. Nothing said so. The harness
# prints "MEMORY.md is N lines, only part was loaded" into the system prompt,
# which no one reads. This hook prints ONE line into the session context on
# every start, so the bound is enforced by a gate that cannot be forgotten.
#
# Checks (all against the directory autoMemoryDirectory names):
#   1. MEMORY.md <= MAX_LINES lines and <= MAX_BYTES bytes
#   2. no index line longer than MAX_LINE chars (long hooks are how 25 KB
#      arrives before line 200)
#   3. every `[..](file.md)` target in MEMORY.md exists
#   4. every *.md in the directory is reachable: linked from MEMORY.md, or
#      linked from a hub file that MEMORY.md links (orphans are memories
#      no session can ever find)
#
# Output: one `memory-index: ok (...)` line, or `memory-index: FAIL` followed
# by one line per violation with the fix. Exit 0 always as a hook (a broken
# index must not block a session); `--strict` exits 1 on FAIL for Makefiles
# and selftests.
#
# Usage: memory-index-check.sh [--strict] [DIR]
#   DIR defaults to $MEMORY_INDEX_DIR, then to autoMemoryDirectory in
#   ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json. An unset setting is itself
#   reported: without it every project writes to its own invisible directory.
set -uo pipefail
MAX_LINES="${MEMORY_INDEX_MAX_LINES:-200}"
MAX_BYTES="${MEMORY_INDEX_MAX_BYTES:-25000}"
MAX_LINE="${MEMORY_INDEX_MAX_LINE:-160}"

strict=0; dir=""
for a in "$@"; do
  case "$a" in
    --strict) strict=1 ;;
    *) dir="$a" ;;
  esac
done
[[ -n "$dir" ]] || dir="${MEMORY_INDEX_DIR:-}"
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [[ -z "$dir" ]]; then
  dir="$(python3 - "$cfg/settings.json" <<'PY' 2>/dev/null
import json, os, sys
try:
    d = json.load(open(sys.argv[1])).get("autoMemoryDirectory") or ""
except Exception:
    d = ""
print(os.path.expanduser(d) if d else "")
PY
)"
  if [[ -z "$dir" ]]; then
    echo "memory-index: FAIL -- autoMemoryDirectory no está seteado en $cfg/settings.json; cada proyecto escribe a su propio directorio invisible. Fix: \"autoMemoryDirectory\": \"~/.claude-memory\""
    [[ $strict -eq 1 ]] && exit 1; exit 0
  fi
fi
idx="$dir/MEMORY.md"
if [[ ! -f "$idx" ]]; then
  echo "memory-index: FAIL -- $idx no existe"
  [[ $strict -eq 1 ]] && exit 1; exit 0
fi

fails=()
lines=$(wc -l < "$idx" | tr -d ' ')
bytes=$(wc -c < "$idx" | tr -d ' ')
(( lines <= MAX_LINES )) || fails+=("$lines líneas > $MAX_LINES: el harness corta en 200 — mover entradas a un hub-*.md")
(( bytes <= MAX_BYTES )) || fails+=("$bytes bytes > $MAX_BYTES: el harness corta en 25 KB — acortar ganchos o mover entradas a un hub")
longest=$(awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' "$idx")
if (( longest > MAX_LINE )); then
  n=$(awk -v m="$MAX_LINE" 'length($0) > m { c++ } END { print c+0 }' "$idx")
  fails+=("$n línea(s) de más de $MAX_LINE chars (máx $longest): acortar el gancho, el detalle va en el archivo")
fi

# links from the index, and from the hubs the index links
links_of() { grep -o '](\([^)]*\.md\))' "$1" 2>/dev/null | sed 's/^](//; s/)$//' | sort -u; }
index_links="$(links_of "$idx")"
missing=0
reach="$(mktemp "${TMPDIR:-/tmp}/memidx.XXXXXX")"; trap 'rm -f "$reach"' EXIT
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if [[ -f "$dir/$f" ]]; then
    echo "$f" >> "$reach"
    links_of "$dir/$f" >> "$reach"
  else
    missing=$((missing+1)); fails+=("link roto en MEMORY.md: $f no existe")
  fi
done <<< "$index_links"
orphans=()
for p in "$dir"/*.md; do
  f="$(basename "$p")"
  [[ "$f" == "MEMORY.md" ]] && continue
  grep -qxF "$f" "$reach" || orphans+=("$f")
done
if (( ${#orphans[@]} > 0 )); then
  fails+=("${#orphans[@]} memoria(s) sin línea en MEMORY.md ni en un hub (nadie las puede encontrar): ${orphans[*]:0:6}$( (( ${#orphans[@]} > 6 )) && echo ' …')")
fi

total=$(find "$dir" -maxdepth 1 -name '*.md' ! -name MEMORY.md | wc -l | tr -d ' ')
if (( ${#fails[@]} == 0 )); then
  echo "memory-index: ok ($lines líneas, $bytes bytes, $total memorias alcanzables, $dir)"
  exit 0
fi
echo "memory-index: FAIL ($lines líneas, $bytes bytes, $dir)"
for f in "${fails[@]}"; do echo "  - $f"; done
[[ $strict -eq 1 ]] && exit 1
exit 0
