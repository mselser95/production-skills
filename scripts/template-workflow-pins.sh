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
# THE RULE IS ABOUT WHAT IS FETCHED AND WHERE IT GOES, NOT HOW IT IS RUN. Spelling
# lists ("| sh", "source <(...)", "sh i.sh" next line) are beaten by a new spelling, and
# a rule that concludes "safe" from what it failed to recognise is beaten by anything
# unusual. So each curl / wget is judged in four steps, and the DEFAULT of every step is
# "refuse": (1) is this a fetcher invocation? (2) what URLs does it fetch? (3) where does
# the body go? (4) look the (source class x sink class) cell up in the table below.
#
# (1) FETCHER. A token whose basename is curl or wget (`curl`, `/usr/bin/curl`, `\curl`,
#   `command curl`, `sudo -E curl`, `busybox wget`, `env X=1 curl`) in command position.
#   Command position is the default; only a command whose first word is one of
#   echo printf apt apt-get aptitude apk yum dnf zypper pacman brew snap which type whereis
#   hash dpkg pip pip3 npm pnpm yarn choco man, or `command -v`, makes the word a mere
#   mention. A token that starts with `-` as first word is text, not a command.
# (2) URLS. Options are parsed (curl and wget spellings, glued short flags such as
#   -sSLo/tmp/x, --opt=value, quotes). Any `scheme://` (any case, any scheme: ftp, HTTPS)
#   is a URL; a first positional that contains a dot or a slash is a scheme-less URL
#   (`curl get.docker.com`, `curl RAW.githubusercontent.com/o/r/main/i.sh`). Hosts and
#   keywords are compared lower-cased on a copy; the reported line is untouched. A URL or
#   positional with `$` (or `${{ }}`) is UNRESOLVED; a fetch with no URL at all is
#   UNRESOLVED. GitHub URLs are parsed positionally, the ref must be a 40-hex sha IN ITS
#   OWN POSITION (a 40-hex owner, repo, file name or unrelated query value proves nothing):
#     raw.githubusercontent.com/<o>/<r>/<ref>/...         github.com/<o>/<r>/raw|blob/<ref>/...
#     gist.githubusercontent.com/<o>/<id>/raw/<rev>/...   github.com/<o>/<r>/archive/<ref>.tar.gz|.zip
#     github.com/<o>/<r>/tarball|zipball/<ref>             codeload.github.com/<o>/<r>/tar.gz|zip/<ref>
#     api.github.com/repos/<o>/<r>/tarball|zipball|commits/<ref>, .../git/trees/<ref>,
#       .../contents/<path>?ref=<ref> (every ref= value must be a sha)
#     github.com/<o>/<r>/releases/latest/... = always refused; releases/download/<tag>/<f> = tag
#   `refs/heads/x`, a tag, a branch, a short sha are refused. Any other shape on a GitHub
#   host (*.github.com, *.githubusercontent.com): "unrecognised GitHub URL shape".
# (3) SINK, where the body goes:
#   discard   -o /dev/null, > /dev/null, -I / --head, --spider
#   printed   stdout to the log, or piped only into INERT commands:
#             jq grep egrep fgrep head tail wc cat sort uniq cut tr tac nl column
#             (no file redirect). Inside $( ) / backticks it is printed only when the
#             substitution is the right side of a plain assignment (V=$(curl .. | jq ..)).
#   file      -o FILE -oFILE -O -sSLo/x -fsSLO --output FILE --output=FILE --remote-name
#             --remote-name-all, wget with no -O- (a file is its default), > f, >> f, and
#             a pipe into tee, tar, unzip, gunzip, gzip, bunzip2, xz, unxz, 7z, cpio, dd,
#             sponge, install (unpacking code to disk is a file). -o - / -o- / -O- /
#             --output-document=- are stdout.
#   interp    anything else: sh bash zsh dash ksh python* perl ruby node php pwsh source . eval
#             xargs sh -c, wrappers of those (sudo env exec time nice), a $( ) / <( ) whose
#             value feeds another command, and every command not named above (default deny).
# (4) VERDICT. Cell = finding unless marked ok.
#   source class                |discard|printed          |file                 |interp
#   ----------------------------+-------+-----------------+---------------------+--------
#   sha-pinned GitHub (ref pos) |ok     |ok               |ok                   |ok
#   mutable GitHub ref / shape  |ok     |ok if api.github |finding              |finding
#                               |       |.com (JSON data) |                     |
#   releases/latest             |ok     |finding          |finding              |finding
#   release asset (tag)         |ok     |finding          |ok iff checksum, step|finding
#   non-GitHub host             |ok     |ok               |ok iff checksum, step|finding
#   unresolved / no URL         |ok     |ok               |ok iff checksum, step|finding
#   A POST/upload (-X POST|PUT|PATCH|DELETE, -d, --data*, -F, -T, --json, --post-data)
#   whose response is discarded or printed is SENDING, not fetching: ok. The same call
#   piped into an interpreter or saved is judged by the table. A checksum is "in the step"
#   when the SAME YAML list item runs `sha256sum -c|--check` (sha384/512) or
#   `shasum -a 256 -c`; its presence is checked, not that it covers that file. A stream
#   never touches disk, so no checksum ever covers an interp cell.
# RULE 2 -- floating tool versions. `go install` / `go run` of <module>@<ref> where ref
#   is not a semantic version (vX.Y.Z[-pre][+build]) or a 40-hex sha is a finding
#   (@latest @main @master @HEAD @upgrade @patch, a branch, a short sha, @$VAR).
# RULE 3 -- a step whose `shell:` is not bash/sh (python, pwsh, a matrix expression...)
#   cannot be read by this gate: "unsupported shell, cannot verify" (also for
#   `defaults: run: shell:`).
#
# SCOPE. Read: every `run:` scalar (inline, quoted, | or > block, continuations joined)
# of the workflow files AND of every action.yml/action.yaml under the sibling `actions/`
# directory (composite actions). A name:/if:/env: string that mentions curl is not
# execution. Comment lines and trailing ` # ...` are not read; tabs/CRLF normalised.
# OUT OF SCOPE, by name, each acceptable because this template has three workflows on
# ubuntu runners, no `shell:` override and no composite actions; revisit the day that
# stops being true, or the day a step legitimately needs one of them:
#   - fetchers other than curl/wget (gh, aria2c, xh/http, python urllib/requests, nc,
#     PowerShell iwr/irm): the template uses none; add the name here when it does.
#   - a fetcher via variable or alias (`C=curl; $C ..`): basename forms ARE handled
#     (curl, /usr/bin/curl, \curl, command curl, busybox wget); an alias is not.
#     A container image path such as `curlimages/curl` is not a curl invocation (it
#     runs in a container, not on the runner): out of scope, no workflow here uses one.
#   - `-K`/`--config` files and `@file` URL lists: the URLs are not in the workflow;
#     such a call with a body that is saved or executed is still refused as unresolved.
#   - `uses:` refs (tags/branches are indistinguishable statically; the template pins
#     actions by version tag), `with:`/`script:` payloads, flow-style steps
#     (`- {run: ...}`), package managers, container images by tag, `git clone` of a
#     branch, a fetch done by a script the step merely calls (`bash scripts/x.sh`), and
#     heredoc bodies are read as ordinary lines (prose "use curl to" is refused).
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
# composite actions next to the workflows (.github/actions/**/action.y*ml) are read too
adir="$dir/../actions"
if [[ -d "$adir" ]]; then
  while IFS= read -r f; do files+=("$f"); done < <(find "$adir" -type f \( -name action.yml -o -name action.yaml \) 2>/dev/null | sort)
fi

out="$(awk -v q="'" '
BEGIN {
  fetchre = "(^|[^A-Za-z0-9_-])(curl|wget)([ \"" q "`;&|)<>]|$)"
  gore = "(^|[^A-Za-z0-9_./-])go +(install|run)( |$)"
  semre = "^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$"
  chk = "(^| )(-[A-Za-z]*c[A-Za-z]*|--check)( |$)"
  assignre = "=\"?(\\$\\(|`)$"
  longv = " output header data data-raw data-binary data-ascii data-urlencode request user user-agent referer max-time connect-timeout retry retry-delay retry-max-time write-out cookie cookie-jar upload-file form form-string proxy config range cacert cert key proto proto-redir limit-rate json url output-document directory-prefix tries timeout post-data post-file body-data body-file method password http-user http-password "
  split("sudo env exec time nice nohup command builtin busybox then do else if while until ! { elif", a, " "); for (k in a) wrap[a[k]] = 1
  split("echo printf apt apt-get aptitude apk yum dnf zypper pacman brew snap which type whereis hash dpkg pip pip3 npm pnpm yarn choco man", a, " "); for (k in a) notcmd[a[k]] = 1
  split("jq grep egrep fgrep head tail wc cat sort uniq cut tr tac nl column", a, " "); for (k in a) inert[a[k]] = 1
  split("tee tar unzip gunzip gzip bunzip2 xz unxz 7z cpio dd sponge install", a, " "); for (k in a) filecmd[a[k]] = 1
}
function isha(s) { return length(s) == 40 && s ~ /^[0-9a-f]+$/ }
function isgh(h) { return (h ~ /(^|\.)github\.com$/ || h ~ /(^|\.)githubusercontent\.com$/) }
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
# ---- shell-word tokenizer: tk[1..ntk], tkq[i]=1 when the token began with a quote
function tokenize(s,   i, n, c, qs, cur, st, qd) {
  split("", tk); split("", tkq); ntk = 0; cur = ""; st = 0; qs = ""; qd = 0; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (qs != "") { if (c == qs) qs = ""; else cur = cur c; continue }
    if (c == "\"" || c == q) { qs = c; if (!st) { st = 1; qd = 1 }; continue }
    if (c == " ") { if (st) { ntk++; tk[ntk] = cur; tkq[ntk] = qd; cur = ""; st = 0; qd = 0 }; continue }
    st = 1; cur = cur c
  }
  if (st) { ntk++; tk[ntk] = cur; tkq[ntk] = qd }
}
# (1) command position: 0 when the curl/wget word is only mentioned
function cmdpos(pre,   i, c, k, t, n, w, j, b) {
  k = 0
  for (i = length(pre); i >= 1; i--) { c = substr(pre, i, 1); if (c == ";" || c == "&" || c == "|" || c == "(" || c == "`") { k = i; break } }
  t = substr(pre, k + 1); gsub(/"/, " ", t); gsub(q, " ", t); gsub(/\\/, " ", t)
  n = split(t, w, " ")
  if (n >= 1 && w[1] ~ /^-/) return 0
  if (t ~ /(^| )command +-[vV]( |$)/) return 0
  for (j = 1; j <= n; j++) {
    b = w[j]
    if (b ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || b ~ /^-/ || (b in wrap)) continue
    sub(/^.*\//, "", b)
    return (b in notcmd) ? 0 : 1
  }
  return 1
}
# class of one pipeline stage: 1 inert, 2 file, 3 interpreter (default)
function stagecls(stg,   i, t, cmd, cls, rd, tg) {
  tokenize(stg); cmd = ""; cls = 0
  for (i = 1; i <= ntk; i++) {
    t = tk[i]
    if (!tkq[i] && t ~ /^[0-9&]*>/) {
      if (t ~ /^[0-9]*>&/ || t ~ /^2>/) continue
      rd = t; sub(/^[0-9&]*>>?/, "", rd)
      if (rd == "") { rd = tk[i + 1]; i++ }
      if (rd != "/dev/null") cls = 2
      continue
    }
    if (cmd != "") continue
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || t ~ /^-/ || (t in wrap)) continue
    cmd = t; sub(/^\\+/, "", cmd); sub(/^.*\//, "", cmd)
  }
  if (cmd == "") return 3
  if (cmd in inert) return (cls > 1) ? cls : 1
  if (cmd in filecmd) return 2
  return 3
}
function chain(t,   i, n, e, c, nx, cls, sc) {
  cls = 1
  while (1) {
    n = length(t); e = n + 1
    for (i = 1; i <= n; i++) {
      c = substr(t, i, 1); nx = substr(t, i + 1, 1)
      if (c == ";" || c == ")" || c == "`" || c == "|") { e = i; break }
      if (c == "&" && (nx == "&" || nx == " " || nx == "") && substr(t, i - 1, 1) != ">") { e = i; break }
    }
    sc = stagecls(substr(t, 1, e - 1)); if (sc > cls) cls = sc
    if (e > n || substr(t, e, 1) != "|" || substr(t, e + 1, 1) == "|") break
    t = substr(t, e + 1)
  }
  return cls
}
# (2) parse the options of one invocation
function addurl(v,   i, j) {
  i = index(v, "://")
  if (i) { j = i; while (j > 1 && substr(v, j - 1, 1) ~ /[A-Za-z0-9+.-]/) j--; v = substr(v, j) } else v = "https://" v
  nurl++; urlv[nurl] = v
}
function setout(v) { if (v == "-") outstd = 1; else if (v == "/dev/null") outnull = 1; else outfile = 1 }
function rdtarget(t) { if (t == "/dev/null") redirnull = 1; else redirfile = 1 }
function optval(tool, nm, v) {
  if (nm == "url") { addurl(v); return }
  if (tool == "curl" && (nm == "o" || nm == "output")) { setout(v); return }
  if (tool == "wget" && (nm == "O" || nm == "output-document")) { setout(v); return }
  if (tool == "curl" && (nm == "d" || nm == "F" || nm == "T" || nm ~ /^(data|data-raw|data-binary|data-ascii|data-urlencode|form|form-string|upload-file|json)$/)) { sendf = 1; return }
  if (tool == "wget" && (nm == "post-data" || nm == "post-file" || nm == "body-data" || nm == "body-file")) { sendf = 1; return }
  if ((nm == "X" || nm == "request" || nm == "method") && toupper(v) ~ /^(POST|PUT|PATCH|DELETE)$/) sendf = 1
}
function parse(tool, s,   i, t, k, nm, v, eq, vs, rd, pend, pendrd) {
  tokenize(s); outfile = outstd = outnull = sendf = headf = redirfile = redirnull = unres = nurl = 0; split("", urlv)
  pend = ""; pendrd = 0
  vs = (tool == "curl") ? "oHdXuAemwbcTFxKrCEDYyztQPU" : "OoPtTwUeiaBlQ"
  for (i = 1; i <= ntk; i++) {
    t = tk[i]
    if (pendrd) { if (pendrd == 1) rdtarget(t); pendrd = 0; continue }
    if (pend != "") { optval(tool, pend, t); pend = ""; continue }
    if (!tkq[i] && t ~ /^[0-9&]*>/) {
      if (t ~ /^[0-9]*>&/) continue
      rd = t; sub(/^[0-9&]*>>?/, "", rd)
      if (substr(t, 1, 1) == "2") { if (rd == "") pendrd = 2; continue }
      if (rd == "") pendrd = 1; else rdtarget(rd)
      continue
    }
    if (t ~ /^--/) {
      nm = substr(t, 3); v = ""; eq = index(nm, "=")
      if (eq) { v = substr(nm, eq + 1); nm = substr(nm, 1, eq - 1) }
      if (nm == "remote-name" || nm == "remote-name-all") { outfile = 1; continue }
      if (nm == "head" || nm == "spider") { headf = 1; continue }
      if (index(longv, " " nm " ")) { if (eq) optval(tool, nm, v); else pend = nm }
      continue
    }
    if (t ~ /^-./) {
      for (k = 2; k <= length(t); k++) {
        nm = substr(t, k, 1)
        if (index(vs, nm)) { v = substr(t, k + 1); if (v == "") pend = nm; else optval(tool, nm, v); break }
        if (tool == "curl") { if (nm == "O") outfile = 1; else if (nm == "I") headf = 1 }
      }
      continue
    }
    if (t == "" || t == "-" || t ~ /^@/) continue
    if (t ~ /\$/) unres = 1
    else if (t ~ /[.\/]/) addurl(t)
  }
}
# source class of one URL: unres | other | pinned | gh_ref | gh_unk | gh_latest | gh_rel ; sets isapi
function srcclass(u,   us, qs, p, np, host, ref, i, kv, nkv, found, allsha, kind) {
  isapi = 0
  if (u ~ /\$/) return "unres"
  us = tolower(u); qs = ""
  i = index(us, "#"); if (i) us = substr(us, 1, i - 1)
  i = index(us, "?"); if (i) { qs = substr(us, i + 1); us = substr(us, 1, i - 1) }
  np = split(us, p, "/")
  host = p[3]; sub(/^[^@]*@/, "", host); sub(/:[0-9]*$/, "", host)
  if (!isgh(host)) return "other"
  if (host == "raw.githubusercontent.com") { ref = p[6]; if (ref == "") return "gh_unk"; return isha(ref) ? "pinned" : "gh_ref" }
  if (host == "gist.githubusercontent.com") { if (p[6] != "raw" || p[7] == "") return "gh_unk"; return isha(p[7]) ? "pinned" : "gh_ref" }
  if (host == "codeload.github.com") { if (p[6] !~ /^(tar\.gz|zip|legacy\.tar\.gz|legacy\.zip)$/ || p[7] == "") return "gh_unk"; return isha(p[7]) ? "pinned" : "gh_ref" }
  if (host == "github.com" || host == "www.github.com") {
    kind = p[6]
    if (kind == "raw" || kind == "blob" || kind == "tarball" || kind == "zipball") { ref = p[7] }
    else if (kind == "archive") { ref = p[7]; sub(/\.(tar\.gz|tgz|zip)$/, "", ref) }
    else if (kind == "releases") { if (p[7] == "latest") return "gh_latest"; if (p[7] == "download") return "gh_rel"; return "gh_unk" }
    else return "gh_unk"
    if (ref == "") return "gh_unk"
    return isha(ref) ? "pinned" : "gh_ref"
  }
  if (host == "api.github.com") {
    isapi = 1
    if (p[4] != "repos") return "gh_unk"
    kind = p[7]
    if (kind == "tarball" || kind == "zipball" || kind == "commits") ref = p[8]
    else if (kind == "git" && p[8] == "trees") ref = p[9]
    else if (kind == "contents") {
      nkv = split(qs, kv, "&"); found = 0; allsha = 1
      for (i = 1; i <= nkv; i++) if (kv[i] ~ /^ref=/) { found++; if (!isha(substr(kv[i], 5))) allsha = 0 }
      return (found > 0 && allsha) ? "pinned" : "gh_ref"
    }
    else return "gh_unk"
    if (kind == "tarball" || kind == "zipball") { if (ref == "") return "gh_ref" }
    else if (ref == "") return "gh_unk"
    return isha(ref) ? "pinned" : "gh_ref"
  }
  return "gh_unk"
}
function judgeunres(sk, sum) {
  if (sk == "discard" || sk == "printed") return ""
  if (sk == "file" && sum) return ""
  return "cannot verify what is fetched (URL not literal / not found) and no checksum verification in the step"
}
# (4) the verdict table: "" = ok, else the finding
function judge(u, sk, sum,   c) {
  c = srcclass(u)
  if (c == "pinned") return ""
  if (c == "unres") return judgeunres(sk, sum)
  if (sk == "discard") return ""
  if (c == "other") {
    if (sk == "printed") return ""
    if (sk == "file") return sum ? "" : "non-GitHub download to a file with no checksum verification in the step"
    return "non-GitHub fetch consumed in-stream (a checksum cannot cover a stream)"
  }
  if (c == "gh_latest") return "releases/latest always moves"
  if (c == "gh_rel") {
    if (sk == "interp") return "GitHub release asset consumed in-stream (a tag is mutable; a checksum cannot cover a stream)"
    if (sk != "file" || !sum) return "GitHub release asset (a tag is mutable) with no checksum verification of the downloaded file in the step"
    return ""
  }
  if (isapi && sk == "printed") return ""
  return (c == "gh_unk") ? "unrecognised GitHub URL shape: cannot tell what ref is fetched" : "mutable GitHub ref (not a 40-hex commit sha)"
}
function analyse(f, ln, text, sum,   rest, base, m, p, abs, pre, tail, n, i, c, endc, seg, tool, w, k, tp, dest, sk, cl, why, j, u, tpre, rec, toks, tok, at, ref, nres) {
  w = text
  while ((i = index(w, "${{")) > 0) { j = index(substr(w, i), "}}"); if (j == 0) break; w = substr(w, 1, i - 1) "$EXPR" substr(w, i + j + 1) }
  rest = w; base = 0
  while (match(rest, fetchre)) {
    m = substr(rest, RSTART, RLENGTH); tool = "curl"; p = index(m, "curl"); if (!p) { tool = "wget"; p = index(m, "wget") }
    abs = base + RSTART + p - 1
    base = abs + 3; rest = substr(w, base + 1)
    pre = substr(w, 1, abs - 1)
    k = abs - 1; while (k >= 1 && substr(w, k, 1) !~ /[ ;&|(`"<>]/ && substr(w, k, 1) != q) k--
    tp = substr(w, k + 1, abs - 1 - k)
    if (tp != "" && tp !~ /^(\\|\/|\.\/|\.\.\/|~\/)/) continue
    if (!cmdpos(substr(w, 1, k))) continue
    tail = substr(w, abs); n = length(tail); endc = ""; i = 5
    for (; i <= n; i++) {
      c = substr(tail, i, 1)
      if (c == ";" || c == ")" || c == "`") { endc = c; break }
      if (c == "&" && substr(tail, i + 1, 1) == "&") { endc = "&&"; break }
      if (c == "|") { endc = (substr(tail, i + 1, 1) == "|") ? "||" : "|"; break }
    }
    seg = substr(tail, 1, i - 1)
    parse(tool, substr(seg, 5))
    if (outfile || redirfile) dest = "file"
    else if (outnull || redirnull || headf) dest = "discard"
    else if (tool == "wget" && !outstd) dest = "file"
    else dest = "stdout"
    sk = dest
    if (dest == "stdout") {
      sk = "printed"
      if (endc == "|") { cl = chain(substr(tail, i + 1)); sk = (cl == 1) ? "printed" : ((cl == 2) ? "file" : "interp") }
      if (sk == "printed" && insubst(pre) && pre !~ assignre) sk = "interp"
    }
    checked++
    why = ""
    if (!(sendf && (sk == "discard" || sk == "printed"))) {
      for (j = 1; j <= nurl && why == ""; j++) why = judge(urlv[j], sk, sum)
      if (why == "" && (unres || nurl == 0)) why = judgeunres(sk, sum)
    }
    if (why != "") report(f, ln, why, text)
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
function okshell(v) { sub(/ +#.*$/, "", v); gsub(/"/, "", v); gsub(q, "", v); return (v ~ /^(bash|sh)( |$)/) }
function flush(   k, sum) {
  if (stepshell != "" && nrec > 0 && !okshell(stepshell)) { checked++; report(rfile[1], rline[1], "unsupported shell, cannot verify", "shell: " stepshell) }
  stepshell = ""
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
    if (mode == "inl" && runempty && line ~ /^ *shell: *[^ #]/) { v2 = line; sub(/^ *shell: */, "", v2); if (!okshell(v2)) { checked++; report(FILENAME, FNR, "unsupported shell, cannot verify", "defaults shell: " v2) } }
    ind = match(line, /[^ ]/) - 1
    if (ind > runind) { content(FNR, line); next }
    finish_run()
  }
  if (line ~ /^ *-( |$)/) flush()
  if (match(line, /^ *(- +)?shell: */)) { stepshell = substr(line, RLENGTH + 1); if (stepshell == "") stepshell = "?" }
  if (match(line, /^ *(- +)?run:( |$)/)) {
    pfx = line; sub(/run:.*$/, "", pfx); runind = length(pfx)
    val = substr(line, runind + 5); sub(/^ +/, "", val); sub(/ +$/, "", val)
    inrun = 1; runln = FNR; acc = ""; accn = 0; cur = ""; runempty = (val == "")
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
