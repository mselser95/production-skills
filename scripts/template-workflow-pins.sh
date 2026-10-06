#!/usr/bin/env bash
# template-workflow-pins.sh — the template's workflows must not fetch code (or a
# tool) from a mutable location.
#
# WHY THIS EXISTS. prod-new/template/.github/workflows/ci.yaml shipped
# `curl .../anchore/syft/main/install.sh | sh` in its sbom job: a script from a
# mutable branch runs whatever that branch holds on the day. It reached every repo
# scaffolded from this template unnoticed, because nothing in THIS repo executes or
# reads the template's workflows. This gate reads them.
#
# THE RULE IS ABOUT WHAT IS FETCHED, NOT HOW IT IS RUN. Recognising the execution
# ("| sh", "| sudo -E bash", "source <(...)", "eval $(...)", "sh i.sh" on the next
# line...) is a list of spellings that a new spelling beats. So the gate judges the
# FETCH: every `curl` / `wget` found anywhere in a `run:` scalar (inline, quoted,
# `|` or `>` block, backslash continuations joined; any flags, any position) is
# judged by where it fetches from, whatever happens to the bytes afterwards.
#
# RULE 1 -- GitHub-hosted content must be immutable. A URL on raw.githubusercontent.com,
#   gist.githubusercontent.com, github.com, www.github.com, codeload.github.com,
#   api.github.com or any other *.github.com / *.githubusercontent.com host is a
#   finding unless its ref is a 40-hex commit sha. Shapes (ref = the part judged):
#     raw.githubusercontent.com/<o>/<r>/<ref>/...        ref; `refs/heads/x` is refused
#     github.com/<o>/<r>/raw/<ref>/...  and  /blob/<ref>/...   ref
#     gist.githubusercontent.com/<o>/<id>/raw/<rev>/...  rev
#     github.com/<o>/<r>/archive/<ref>.tar.gz|.zip       ref; archive/refs/... refused
#     codeload.github.com/<o>/<r>/tar.gz|zip/<ref>        ref
#     github.com/<o>/<r>/releases/latest/download/...     ALWAYS refused (moves by definition)
#     github.com/<o>/<r>/releases/download/<tag>/<file>   a tag is mutable: refused unless
#        the same step writes the download to a FILE and verifies a checksum (rule 3)
#     api.github.com/... and any github.com shape not listed: refused unless the URL
#        carries a 40-hex sha as a path segment or ref= value (tarball/<sha>, ?ref=<sha>)
#   A scheme-less URL (`curl raw.githubusercontent.com/...`) is judged the same way.
#   A sha-pinned GitHub URL passes however it is consumed (the sha fixes the bytes).
# RULE 2 -- floating tool versions. `go install` / `go run` of <module>@<ref> where ref
#   is not a semantic version (vX.Y.Z[-pre][+build]) or a 40-hex sha is a finding
#   (@latest @main @master @HEAD @upgrade @patch, a branch, a short sha, @$VAR).
# RULE 3 -- every other host, and release assets.
#   - fetched bytes consumed in-stream (piped to ANY command, or inside <( ), $( ) or
#     backticks) from a non-GitHub host or a release asset: a finding, with or without a
#     checksum, because a stream never touches disk so no checksum covers it.
#   - written to a FILE (-o, -O, > file; wget without -O-) from a non-GitHub host or a
#     release asset: accepted only when the SAME step (YAML list item) also runs
#     `sha256sum -c|--check` (sha384/512 too) or `shasum -a 256 -c|--check`. The gate
#     checks the PRESENCE of a verification in the step, NOT that it covers that file;
#     that is the limit of a static check.
#   - a plain file download from a non-GitHub host with no checksum is a finding: bytes
#     that end up on disk, unverified, are the thing the pipeline exists to refuse.
#   - a curl that prints to stdout only (no -o/-O/redirect/pipe/substitution) from a
#     non-GitHub host is not a download (health check, API probe): accepted.
# RULE 4 -- a curl/wget whose URL cannot be resolved statically (held in a variable, built
#   by concatenation, `$VAR` in the host or ref) is a finding "cannot verify what is
#   fetched", unless the step verifies a checksum (and the fetch is not in-stream).
#
# SCOPE. Only `run:` scalars are read. A `name:` / `if:` / `env:` string that mentions
# curl is not execution and is not a finding. OUT OF SCOPE, by name: `uses:` of an action
# at a branch or tag (a tag and a branch cannot be told apart statically and the template
# pins actions by version tag), `with:`/`script:` payloads (github-script and similar),
# flow-style steps (`- {run: ...}`), package managers (`npm i -g`, `pip install` without
# versions, `apt`), container images by tag, `git clone` of a branch, and a fetch done by
# a script the step merely calls (`bash scripts/x.sh`). A `curl`/`wget` with neither a
# URL nor a `$` (`apt-get install curl`) is not a fetch.
# Comment lines (first non-space character '#') and trailing ` # ...` are not read.
# Tabs and Windows line endings are normalised before reading.
#
# Usage: template-workflow-pins.sh [workflows-dir]   (default: the template's)
# Exit: 0 clean · 1 findings · 2 no workflow files found · 3 internal error (no summary)
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

out="$(awk -v q="'" '
BEGIN {
  urlre = "(https?://)?(raw\\.githubusercontent\\.com|gist\\.githubusercontent\\.com|api\\.github\\.com|codeload\\.github\\.com|www\\.github\\.com|github\\.com)/[^ \"" q "`)|;<>]*|https?://[^ \"" q "`)|;<>]+"
  fetchre = "(^|[^A-Za-z0-9_-])(curl|wget)([^A-Za-z0-9_-]|$)"
  gore = "(^|[^A-Za-z0-9_./-])go +(install|run)( |$)"
  semre = "^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$"
  chk = "(^| )(-[A-Za-z]*c[A-Za-z]*|--check)( |$)"
}
function isha(s) { return length(s) == 40 && s ~ /^[0-9a-f]+$/ }
function has40(u,   a, n, i) { n = split(u, a, /[\/=?&]/); for (i = 1; i <= n; i++) if (isha(a[i])) return 1; return 0 }
function hassum(t,   s) {
  s = t
  while (match(s, /sha(256|384|512)sum[^;&|]*/)) { if (substr(s, RSTART, RLENGTH) ~ chk) return 1; s = substr(s, RSTART + RLENGTH) }
  s = t
  while (match(s, /shasum[^;&|]*/)) { if (substr(s, RSTART, RLENGTH) ~ chk && substr(s, RSTART, RLENGTH) ~ /-a *(256|384|512)/) return 1; s = substr(s, RSTART + RLENGTH) }
  return 0
}
function lastidx(s, pat,   i, r) { r = 0; for (i = 1; i <= length(s) - length(pat) + 1; i++) if (substr(s, i, length(pat)) == pat) r = i; return r }
function insubst(pre,   a, b, lo, tmp) {
  a = lastidx(pre, "$("); b = lastidx(pre, "<("); lo = (a > b) ? a : b
  if (lo > 0 && substr(pre, lo + 2) !~ /\)/) return 1
  tmp = pre; if (gsub(/`/, "`", tmp) % 2 == 1) return 1
  return 0
}
function report(f, ln, why, text) { printf "%s:%d: %s: %s\n", f, ln, why, text; findings++ }
function analyse(f, ln, text, sum,   rest, base, m, p, us, abs, pre, tail, n, i, c, endc, seg, t, u, parts, host, ref, kind, stream, file, stdo, unres, nurl, why, rel, isgh, rtail, k, toks, tok, at) {
  # ---- rules 1, 3, 4: every curl / wget ----
  rest = text; base = 0
  while (match(rest, fetchre)) {
    m = substr(rest, RSTART, RLENGTH); p = index(m, "curl"); if (!p) p = index(m, "wget")
    abs = base + RSTART + p - 1
    pre = substr(text, 1, abs - 1); tail = substr(text, abs)
    n = length(tail); endc = ""; i = 5
    for (; i <= n; i++) {
      c = substr(tail, i, 1)
      if (c == ";" || c == ")" || c == "`") { endc = c; break }
      if (c == "&" && substr(tail, i + 1, 1) == "&") { endc = "&&"; break }
      if (c == "|") { endc = (substr(tail, i + 1, 1) == "|") ? "||" : "|"; break }
    }
    seg = substr(tail, 1, i - 1)
    base = abs + 3; rest = substr(text, base + 1)
    stream = (endc == "|" || insubst(pre)) ? 1 : 0
    t = seg; gsub(/[0-9]*> *&[0-9-]+/, "", t); gsub(/[0-9]*> *\/dev\/null/, "", t)
    stdo = (t ~ /(^| )-[A-Za-z]*[oO] *=? *-( |$)/ || t ~ /--output(-document)?[ =]-( |$)/) ? 1 : 0
    file = 0
    if (!stdo && !stream) {
      if (t ~ />/ || t ~ /(^| )-[A-Za-z]*[oO]([ =]|$)/ || t ~ /--(output|remote-name|output-document)/ || seg ~ /^wget/) file = 1
    }
    kind = stream ? "stream" : (file ? "file" : "stdout")
    unres = 0; nurl = 0; why = ""; t = seg
    while (why == "" && match(t, urlre)) {
      u = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
      if (u !~ /^https?:\/\//) u = "https://" u
      nurl++
      if (u ~ /\$/) { unres = 1; continue }
      us = u; sub(/[?#].*$/, "", us)
      split(us, parts, "/"); host = tolower(parts[3]); sub(/:[0-9]*$/, "", host)
      isgh = (host ~ /(^|\.)github\.com$/ || host ~ /(^|\.)githubusercontent\.com$/)
      if (!isgh) {
        if (kind == "stream") why = "non-GitHub fetch consumed in-stream (a checksum cannot cover a stream)"
        else if (kind == "file" && !sum) why = "non-GitHub download to a file with no checksum verification in the step"
        continue
      }
      ref = ""
      if (host == "raw.githubusercontent.com") ref = parts[6]
      else if (host == "gist.githubusercontent.com") ref = (parts[6] == "raw") ? parts[7] : ""
      else if (host == "codeload.github.com") ref = parts[7]
      else if (host == "github.com" || host == "www.github.com") {
        if (parts[6] == "raw" || parts[6] == "blob") ref = parts[7]
        else if (parts[6] == "archive") { ref = parts[7]; sub(/\.(tar\.gz|tgz|zip)$/, "", ref) }
      }
      if (isha(ref)) continue
      rel = (parts[6] == "releases" && (host == "github.com" || host == "www.github.com"))
      if (rel && parts[7] == "latest") why = "releases/latest always moves"
      else if (rel && parts[7] == "download") {
        if (kind == "stream") why = "GitHub release asset consumed in-stream (a tag is mutable; a checksum cannot cover a stream)"
        else if (kind != "file" || !sum) why = "GitHub release asset (a tag is mutable) with no checksum verification of the downloaded file in the step"
      }
      else if (ref == "" && has40(u)) continue
      else why = "mutable GitHub ref (not a 40-hex commit sha)"
    }
    if (why == "" && nurl == 0 && seg ~ /\$/) unres = 1
    if (why == "" && unres) {
      if (kind == "stream" || !sum) why = "cannot verify what is fetched (URL not literal) and no checksum verification in the step"
    }
    if (nurl > 0 || unres) { checked++; if (why != "") report(f, ln, why, text) }
  }
  # ---- rule 2: go install / go run at a floating version ----
  rest = text
  while (match(rest, gore)) {
    tail = substr(rest, RSTART + RLENGTH); rest = tail
    for (i = 1; i <= length(tail); i++) { c = substr(tail, i, 1); if (c == ";" || c == ")" || c == "`" || c == "|" || c == "&") break }
    seg = substr(tail, 1, i - 1); gsub("[\"" q "]", " ", seg)
    n = split(seg, toks, " ")
    for (k = 1; k <= n; k++) {
      tok = toks[k]; if (tok ~ /^-/) continue
      at = index(tok, "@"); if (!at) continue
      ref = substr(tok, at + 1); gocount++
      if (ref ~ /\$/ || ref == "") report(f, ln, "cannot verify go tool version (ref not literal)", text)
      else if (!isha(ref) && ref !~ semre) report(f, ln, "floating tool version (not vX.Y.Z or a 40-hex sha)", text)
    }
  }
}
function push(ln, txt) { nrec++; rline[nrec] = ln; rtext[nrec] = txt; rfile[nrec] = lastfile }
function addlit(ln, s) {
  sub(/ #.*$/, "", s)
  if (cur == "") curln = ln
  if (s ~ / *\\$/) { sub(/ *\\$/, "", s); cur = cur s " "; return }
  push(curln, cur s); cur = ""
}
function content(ln, s) {
  if (mode == "lit") addlit(ln, s)
  else { sub(/^ +/, "", s); sub(/ *\\$/, "", s); acc = (acc == "" ? "" : acc " ") s; accn++ }
}
function finish_run() {
  if (cur != "") { push(curln, cur); cur = "" }
  if (mode != "lit" && acc != "") {
    if (accn == 1) sub(/ #.*$/, "", acc)
    push(runln, acc)
  }
  inrun = 0; acc = ""; accn = 0; runs++
}
function flush(   k, sum) {
  sum = 0
  for (k = 1; k <= nrec; k++) if (hassum(rtext[k])) sum = 1
  for (k = 1; k <= nrec; k++) analyse(rfile[k], rline[k], rtext[k], sum)
  nrec = 0
}
FNR == 1 { if (inrun) finish_run(); flush(); files_seen++ }
{
  lastfile = FILENAME
  line = $0; sub(/\r$/, "", line); gsub(/\t/, " ", line)
  if (inrun) {
    if (line ~ /^ *$/) next
    ind = match(line, /[^ ]/) - 1
    if (ind > runind) { content(FNR, line); next }
    finish_run()
  }
  if (line ~ /^ *-( |$)/) flush()
  if (match(line, /^ *(- +)?run:( |$)/)) {
    pfx = line; sub(/run:.*$/, "", pfx); runind = length(pfx)
    val = substr(line, runind + 5); sub(/^ +/, "", val); sub(/ +$/, "", val)
    inrun = 1; runln = FNR; acc = ""; accn = 0; cur = ""
    if (val ~ /^[|>][-+0-9]*( +#.*)?$/) mode = (substr(val, 1, 1) == "|") ? "lit" : "fold"
    else { mode = "inl"; if (val != "") content(FNR, val) }
  }
}
END {
  if (inrun) finish_run()
  flush()
  printf "SUMMARY files=%d run_scalars=%d remote_steps=%d go_refs=%d findings=%d\n", files_seen, runs + 0, checked + 0, gocount + 0, findings + 0
  exit (findings > 0) ? 1 : 0
}
' "${files[@]}" 2>&1)"
rc=$?
sum="$(grep '^SUMMARY ' <<<"$out" | head -n 1)"
grep -v '^SUMMARY ' <<<"$out" >&2
if [[ -z "$sum" ]]; then
  echo "template-workflow-pins: INTERNAL ERROR -- no summary produced (rc=$rc); refusing to report clean" >&2
  exit 3
fi
if (( rc != 0 )); then
  echo "template-workflow-pins: FAIL -- ${sum#SUMMARY }" >&2
  exit 1
fi
echo "template-workflow-pins: ok -- ${sum#SUMMARY }"
