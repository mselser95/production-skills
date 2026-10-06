#!/usr/bin/env bash
# template-workflow-pins.sh — the template's workflows must not fetch code from a
# moving target and run it.
#
# WHY THIS EXISTS. prod-new/template/.github/workflows/ci.yaml shipped
# `curl .../anchore/syft/main/install.sh | sh` in its sbom job: a script from a
# mutable branch, piped to a shell, runs whatever that branch holds on the day.
# It went to every repo scaffolded from this template unnoticed, because nothing
# in THIS repo executes or reads the template's workflows (actionlint covers this
# repo's own .github/workflows, and the scaffold job's check-fast never opens a
# workflow). This gate reads them.
#
# WHAT IT REFUSES (per non-comment line; backslash continuations are joined):
#   a. a remote script piped to a shell: curl/wget output piped into sh/bash,
#      `bash <(curl ...)`, or `sh -c "$(curl ...)"`, unless
#        - every raw.githubusercontent.com / github.com URL in it carries a ref
#          segment (after /raw/ or /blob/, or directly after owner/repo for raw.)
#          that is a 40-hex commit sha -- a branch name (main, master, HEAD,
#          develop, trunk) or a short/tag ref is refused, or
#        - for any OTHER host, the same step (the YAML list item) also runs a
#          checksum verification: `sha256sum -c` or `shasum -a 256 -c`.
#   b. a tool installed at a floating version: `go install ...@latest|@main|@master`.
# OUT OF SCOPE, said rather than half-implemented: `npm i -g` and `pip install`
# without a version (the template has none today).
#
# Comment lines (first non-space character '#') are not findings.
# Usage: template-workflow-pins.sh [workflows-dir]   (default: the template's)
# Exit: 0 clean · 1 findings · 2 no workflow files found (refuses an empty set)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir="${1:-$here/../prod-new/template/.github/workflows}"

files=()
if [[ -d "$dir" ]]; then
  for f in "$dir"/*.yaml "$dir"/*.yml; do [[ -f "$f" ]] && files+=("$f"); done
fi
if (( ${#files[@]} == 0 )); then
  echo "template-workflow-pins: no workflow files under $dir -- refusing to report clean over nothing" >&2
  exit 2
fi

out="$(awk '
function flush(   i, k, bad) {
  for (k = 1; k <= nrec; k++) {
    checked++
    if (rtype[k] == "remote") {
      bad = rbad[k]
      if (rneedsum[k] && !stepsum) bad = 1
      if (bad) { printf "%s:%d: unpinned remote script: %s\n", rfile[k], rline[k], rtext[k]; findings++ }
    }
  }
  nrec = 0; stepsum = 0
}
function analyse(ln, text,   t, urls, u, ref, n, parts, host, bad, needsum, hasurl) {
  if (text ~ /go[ \t]+install[ \t].*@(latest|main|master)([ \t"\x27]|$)/) {
    printf "%s:%d: floating tool version: %s\n", FILENAME, ln, text; findings++
  }
  if (text ~ /sha256sum[ \t]+(-[a-z]*c|--check)/ || text ~ /shasum[ \t]+-a[ \t]+256[ \t]+-c/) stepsum = 1
  if (text !~ /(curl|wget)/) return
  if (!(text ~ /\|[ \t]*(sudo[ \t]+)?(ba)?sh([ \t]|$)/ || text ~ /(^|[ \t;&(])(ba)?sh[ \t]+<\([ \t]*(curl|wget)/ || text ~ /(ba)?sh[ \t]+-c[ \t]+"?\$\([ \t]*(curl|wget)/)) return
  bad = 0; needsum = 0; hasurl = 0
  t = text
  while (match(t, /https?:\/\/[^ \t"\x27)|]+/)) {
    u = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH); hasurl = 1
    n = split(u, parts, "/"); host = parts[3]
    if (host == "raw.githubusercontent.com") ref = parts[6]
    else if (host == "github.com" || host == "www.github.com") ref = (parts[6] == "raw" || parts[6] == "blob") ? parts[7] : ""
    else { needsum = 1; continue }
    if (ref !~ /^[0-9a-f]{40}$/) bad = 1
  }
  if (!hasurl) bad = 1
  nrec++; rtype[nrec] = "remote"; rline[nrec] = ln; rtext[nrec] = text; rbad[nrec] = bad; rneedsum[nrec] = needsum; rfile[nrec] = FILENAME
}
FNR == 1 { flush(); files_seen++; cur = "" }
{
  line = $0
  if (line ~ /^[ \t]*#/) next
  if (line ~ /^[ \t]*- /) { flush() }
  if (cur == "") start = FNR
  if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", line); cur = cur line " "; next }
  cur = cur line
  analyse(start, cur); cur = ""
}
END {
  flush()
  printf "SUMMARY files=%d remote_steps=%d findings=%d\n", files_seen, checked, findings + 0
  exit (findings > 0) ? 1 : 0
}
' "${files[@]}" 2>&1)"
rc=$?
grep -v '^SUMMARY ' <<<"$out" >&2
sum="$(grep '^SUMMARY ' <<<"$out" | head -n 1)"
if (( rc != 0 )); then
  echo "template-workflow-pins: FAIL -- ${sum#SUMMARY }" >&2
  exit 1
fi
echo "template-workflow-pins: ok -- ${sum#SUMMARY }"
