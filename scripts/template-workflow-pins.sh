#!/usr/bin/env bash
# template-workflow-pins.sh — no template workflow may execute a remote script fetched
# from a mutable ref.
#
# WHY THIS EXISTS. prod-new/template/.github/workflows/ci.yaml shipped
# `curl .../anchore/syft/main/install.sh | sh` in its sbom job: a script from a mutable
# branch runs whatever that branch holds on the day. Nothing in THIS repo executes or
# reads the template's workflows, so it went unnoticed. This gate reads them.
#
# DESIGN: AN ALLOWLIST WITH WHOLESALE REFUSAL OF OBFUSCATION. Earlier rounds judged
# curl/wget with a shell parser and each round found a new spelling that beat it (quote
# fragments, ANSI-C quoting, escapes in YAML double-quoted scalars, captured bodies, a
# repeated -o ...). Detecting every evasion of a hand-rolled parser does not converge, so
# the gate now ACCEPTS only a short list of exact shapes and REFUSES the means of
# obfuscating a command, whether or not the result would have been harmful. Over-refusal
# is acceptable; the template has three workflows and the real ones must pass.
#
# R0 SCALAR. A run: scalar written as a YAML double-quoted string that contains a
#    backslash is refused (escapes like \x2f are not decoded here). Single-quoted and
#    block scalars are read literally; backslash-newline is joined as the shell does and
#    a join that splits a word is refused.
#    COMMENTS (PS-A9): shell comments in a block scalar are not stripped at all (see PS-A9 CHANGES below); only a PLAIN
#    scalar loses a whitespace-preceded # outside quotes.
# R1 TRIGGER. A run: step is SUBJECT if, after joining continuations, any line (lower-cased,
#    quotes and backslashes removed, so c''url and c\url are seen) holds curl, wget, iwr,
#    Invoke-WebRequest/RestMethod, urlopen, http(s)://, codeload., raw.githubusercontent,
#    install.sh, get.<host>, or go install/run/get with an @.
# R2 REFUSED WHOLESALE in a SUBJECT step, one finding text each: $'..',
#    $( )/backticks WHEN SCOPED (the line or the body holds a fetch trigger, the body is unclosed, or
#    the captured variable is later fed to eval/sh/bash/source/./exec in the step), eval, exec,
#    source/. <( ), other <( ), sh/bash/pwsh -c, python -c, perl/ruby/node -e, a command
#    word containing a quote, a variable adjacent to other characters, a wrapper (env command
#    exec xargs nohup timeout sudo nice) before a fetch tool, --next, -K/--config, wget
#    -i, more than one URL in a fetch, an output option given twice, -o - /dev/stdout
#    /dev/fd/*, a URL with a dot segment, %2e, @ or a scheme other than https, a fetched
#    file executed from ANOTHER step of the same workflow, iwr/iex/Invoke-*.
# R2a EVERY SCALAR (PS-A8). A trigger in ANY non-run scalar of a file (env at any level, with:, defaults, list items;
#    name/description/uses/if excluded) makes every run step of that FILE subject, and the scalar is itself judged as a
#    fetch line (R2 + R3), so env: {F: curl ... | sh} is refused.
# R2b NO TRIGGER NEEDED, every run step (PS-A8): a ${{ }} expression or bare variable in COMMAND position (first word
#    or after ; && || | ( then do else), sh/bash -c with a variable, eval, exec, a shell variable glued to letters
#    (${C}rl, pre$V), a line mixing a variable with // (an assembled URL). [ ] / [[ ]] tests are not command position.
# R3 ALLOWLIST. Every line of a SUBJECT step holding a fetch tool or URL must match exactly
#    one shape (anything else: "fetch does not match an accepted shape"):
#    a  curl -sSfL <pinned raw.githubusercontent.com/o/r/<40hex>/path> | sh|bash [-s -- args]
#    b  curl -o NAME <pinned raw URL>, then echo "<64hex>  NAME" | sha256sum -c - (or echo
#       .. > F; sha256sum -c F) before NAME is mentioned again
#    c  curl -o NAME https://github.com/o/r/releases/download/<tag>/<asset>, same checksum
#    d  curl -o /dev/null [-w FMT] URL | curl -I URL | wget -q --spider URL (no pipe); PS-A10: a loopback http URL (host exactly
#       127.0.0.1, localhost or [::1]) is also accepted, with --retry N and a trailing | grep -q WORD (no -w there)
#    e  curl -X POST|PUT [-H h] [-d body|--data-binary @file] URL (no pipe, -o /dev/null only)
#    f  curl [-H h] https://api.github.com/... | jq ... | python3 -m json.tool
#    g  [bash scripts/retry.sh] go install|run|get module@vX.Y.Z or @<40hex>
#    Shapes b/c also need the check to be able to FAIL the step (PS-A8): refused when the step holds set +e, set +o
#    errexit, a function definition, alias, trap, || true / || :, any compound (if/then/fi, while, case, for, ( ), { }),
#    a shell: other than unset/bash/sh (bash {0} does not run -e) or a defaults shell likewise; the sum must be a
#    literal 64-hex (echo "$(sha256sum f)" is "computed at runtime").
#    Shape d: -w/--write-out takes only %{http_code} %{url_effective} %{time_total} %{response_code} %{size_download}
#    and literal text (no %output, %header, @file, %{json}, other %).
#    Shape g is refused when the file sets GOSUMDB=off or GOFLAGS with -insecure (GOPROXY=direct is NOT refused: known gap).
#    h  `uses:` lines are OUT OF SCOPE (only run: scalars are read; another gate may cover them).
#    A mention is accepted only when the whole line is echo/printf/# with no pipe, redirect,
#    ; & or backtick.
# R4 FAIL CLOSED. No workflow files: exit 2. Unreadable file or awk/grep missing: exit 3.
#    run/steps keys the line parser did not read (flow or JSON style): refused. A workflow whose steps are all
#    `uses:` is accepted (uses steps count as read steps).
#
#
# THREAT MODEL (PS-A9). This gate guards the template's OWN workflows, authored and reviewed in this repository, against an
# UNINTENDED fetch of a remote script from a mutable ref (a branch-named raw URL, an unpinned installer, a Go tool at
# @latest/@main). It refuses by default and accepts only the shapes listed.
# It is NOT a sandbox against an adversarial workflow author: an author who deliberately obfuscates a fetch (string-built
# command names, data smuggled through expressions, a fetcher this allowlist does not know) can evade it, and the review
# of the workflow diff is the control for that. A refusal is always safe; an acceptance means 'matches a reviewed shape',
# not 'proven harmless'.
# KNOWN RESIDUALS, out of scope after PS-A9: GOPROXY=direct with shape g (the module is still checksum-verified by GOSUMDB
# unless that is switched off, which is refused, but the proxy is not pinned); an unknown fetcher binary that is not in the
# trigger list (the pipe-into-interpreter and untracked-file rules in every step are the only net); data smuggled via a
# non-scanned source (an expression that expands to a command, a file the checkout provides, a service the step calls);
# package managers at mutable versions (npx x@latest, npm i -g x@latest, pipx run, uvx, pip install x, docker run image:latest,
# brew install, go get -u) are not judged.
#
# PS-A9 CHANGES. (1) Shell comments in a block scalar are NOT stripped any more (the strip desynced from bash on backticks,
# ${V:- #} and a backslash-space); a comment that spells a fetch is refused, reword it. Plain scalars still strip a
# whitespace-preceded # outside quotes (quote-aware, so it never strips MORE than YAML does). (2) A checked step (shapes b/c)
# refuses shopt, any set line holding +, any set -o/+o; if it holds a set at all the checksum line must end with || exit 1;
# shell: bash -e {0} / sh -e {0} is accepted. (3) name: scalars are scanned and refused when they hold a fetch trigger,
# $( ), a backtick or |. (4) Triggers added: gh api/release/run/..., git clone/archive, aria2c, http(s) words, /dev/tcp,
# fetch(, child_process, python/perl/ruby/node -c/-e; in EVERY run step a pipe into sh/bash/python/perl/ruby/node/source/
# eval/xargs and running a file (sh/bash/./source/chmod) that the repository does not track are refused; with: script:
# bodies are scanned like run text; shape f accepts gh api ... | jq and the gh release shape (sh_h) gh release download ... -O NAME + checksum.
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

root="$(cd "$dir/../.." 2>/dev/null && pwd)"
out="$(PINS_ROOT="$root" awk -v q="'" '
BEGIN {
  trig = "curl|wget|iwr|invoke-webrequest|invoke-restmethod|urlopen|http://|https://|codeload\\.|raw\\.githubusercontent|install\\.sh|get\\.[a-z0-9-]+\\.[a-z]|(^|[^a-z0-9_.-])gh +(api|release|run|extension|gist|repo|codespace|attestation)([^a-z0-9_-]|$)|git +(clone|archive)|aria2c|(^|[^a-z0-9_.-])https? |/dev/tcp|fetch\\(|child_process|(python[0-9.]*|perl|ruby|node) +(-[a-z]+ +)*-[ce] "
  gotrig = "(^|[^a-z0-9_./-])go +(install|run|get)( |$)"
  new_sq = "^" q ".*" q "$"
  semre = "^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$"
  rawre = "(^|[^A-Za-z0-9_.-])\"?run\"? *:"
  stepsre = "(^|[^A-Za-z0-9_.-])\"?steps\"? *:"
  OP = sprintf("%c", 2)
}
function isha(s) { return length(s) == 40 && s ~ /^[0-9a-f]+$/ }
function ishex(s, n) { return length(s) == n && s ~ /^[0-9a-f]+$/ }
function report(f, ln, why, text) { printf "%s:%d: %s: %s\n", f, ln, why, text; findings++ }
function rep(f, ln, why, text) { report(f, ln, why, text); return 1 }
function lowq(t,   s) { s = tolower(t); gsub("[\"" q "]", "", s); gsub(/\\/, "", s); return s }
function subject(t,   lo) { lo = lowq(t); return (lo ~ trig || (lo ~ gotrig && index(lo, "@") > 0)) }
function hasfetchtool(lo) { return lo ~ /(^|[^a-z0-9_.-])(curl|wget)([^a-z0-9_-]|$)/ }
# quote-aware tokenizer: quotes dropped, unquoted | ; & < > ( ) become their own tokens prefixed with \002
function tokenize(s, T,   i, n, c, qs, cur, has) {
  split("", T); n = 0; cur = ""; qs = ""; has = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (qs != "") { if (c == qs) qs = ""; else cur = cur c; continue }
    if (c == "\"" || c == q) { qs = c; has = 1; continue }
    if (c == " ") { if (cur != "" || has) T[++n] = cur; cur = ""; has = 0; continue }
    if (index("|;&<>()", c)) { if (cur != "" || has) T[++n] = cur; cur = ""; has = 0; T[++n] = OP c; continue }
    cur = cur c
  }
  if (qs != "") return -1
  if (cur != "" || has) T[++n] = cur
  return n
}
function isop(t) { return substr(t, 1, 1) == OP }
function isfl(t) { return t ~ /^-[sSfL]+$/ }
function okseg(s) { return s ~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/ }
function pathok(p) { return p ~ /^[A-Za-z0-9_.+\/-]+$/ && p !~ /(^|\/)\.\.?(\/|$)/ && p !~ /\/\// && p !~ /\/$/ }
function pinraw(u,   a, n, p) {
  n = split(u, a, "/")
  if (n < 7 || a[1] != "https:" || a[2] != "" || a[3] != "raw.githubusercontent.com") return 0
  if (!okseg(a[4]) || !okseg(a[5]) || !isha(a[6])) return 0
  p = substr(u, length(a[1]) + length(a[2]) + length(a[3]) + length(a[4]) + length(a[5]) + length(a[6]) + 7)
  return pathok(p)
}
function relasset(u,   a, n) {
  n = split(u, a, "/")
  if (n != 9 || a[1] != "https:" || a[2] != "" || a[3] != "github.com" || a[6] != "releases" || a[7] != "download") return 0
  if (!okseg(a[4]) || !okseg(a[5]) || tolower(a[8]) == "latest") return 0
  return (a[8] ~ /^[A-Za-z0-9_][A-Za-z0-9_.+-]*$/ && a[9] ~ /^[A-Za-z0-9_][A-Za-z0-9_.+-]*$/)
}
function apiok(u) { return (index(u, "https://api.github.com/") == 1 && substr(u, 24) ~ /^[A-Za-z0-9_.\/?=&%,+:-]+$/ && u !~ /\.\.|\/\.\// && tolower(u) !~ /%2e/) }
function okname(s) { return s ~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/ && s != ".." }
function esc(s) { gsub(/\./, "\\.", s); return s }
function usesname(t, name) { return (" " t " ") ~ ("[^A-Za-z0-9_.-]" esc(name) "[^A-Za-z0-9_.-]") }
# checksum proof for NAME after line k: returns the line index where it is verified, or 0/-1
function stepbad(   j, s, lo) {
  hasset = 0
  if (curshell != "" && curshell !~ /^(bash|sh)$/ && curshell !~ /^(bash|sh) +-[a-z]*e[a-z]* +\{0\}$/) return "the step shell: is not the default/bash/sh (bash {0} does not run -e, so a failed check cannot fail the step)"
  if (filebadshell) return "a defaults shell: other than bash/sh is set (a failed check may not fail the step)"
  for (j = 1; j <= nrec; j++) {
    s = rtext[j]; lo = " " lowq(s)
    if (lo ~ /[ ;&|(]set +[-+][a-z]*\+e/ || lo ~ /[ ;&|(]set +\+o +errexit/ || lo ~ /[ ;&|(]set +\+[a-z]*e/) return "set +e in a checked step: a failed checksum could not fail the step"
    if (lo ~ /(^|[ ;&|(])shopt( |$)/) return "shopt in a checked step could disable errexit"
    if (lo ~ /[ ;&|(]set +[^;&|]*\+/) return "a set line with + (set +e, set -u +e, +o errexit) in a checked step could disable errexit"
    if (lo ~ /[ ;&|(]set +([^;&|]* )?[-+][a-z]*o( |;|$)/) return "set -o / set +o in a checked step is refused (errexit could be switched off)"
    if (lo ~ /[ ;&|(]set +-/) hasset = 1
    if (lo ~ /[A-Za-z0-9_.:-]+ *\(\) *(\{|$)/ || lo ~ /[ ;&|(]function +[a-z_]/) return "a shell function definition in a checked step could shadow the checksum tool"
    if (lo ~ /[ ;&|(](alias|trap)( |$)/) return "alias/trap in a checked step could neutralise the checksum"
    if (lo ~ /\|\| *(true|:|exit 0)( |;|$)/) return "|| true / || : in a checked step swallows a failed checksum"
    if (lo ~ /(^|[ ;&|(])(if|then|elif|else|fi|while|until|do|done|case|esac|for|select)([ ;]|$)/ || lo ~ /(^ *|[;&|] *)[({]( |$)/ || lo ~ /(^| )[)}]( |;|$)/) return "a compound command (if/then/fi, while, case, ( ), { }) in a checked step could skip the checksum"
  }
  return ""
}
function needck(k, name,   j, w, nw, s, f, m, sw, ex1, t2) {
  ckwhy = sw = stepbad()
  if (sw != "") return 0
  for (j = k + 1; j <= nrec; j++) {
    s = rtext[j]
    if (s ~ /sha256sum/ && (index(s, "$(") || index(s, "`"))) { ckwhy = "the checksum is computed at runtime (a literal 64-hex is required)"; return 0 }
    gsub("[\"" q "]", "", s); sub(/^ +/, "", s); sub(/ +$/, "", s)
    ex1 = 0; if (s ~ / *\|\| *exit +1$/) { sub(/ *\|\| *exit +1$/, "", s); ex1 = 1 }
    nw = split(s, w, / +/)
    if (hasset && !ex1 && nw == 7 && w[1] == "echo" && w[4] == "|") { ckwhy = "the step uses set/shopt, so the checksum line itself must end with || exit 1"; return 0 }
    if (nw == 7 && w[1] == "echo" && ishex(w[2], 64) && w[3] == name && w[4] == "|" && w[5] == "sha256sum" && w[6] == "-c" && w[7] == "-") return j
    if (nw == 5 && w[1] == "echo" && ishex(w[2], 64) && w[3] == name && w[4] == ">" && w[5] ~ /^[A-Za-z0-9_.-]+$/) {
      f = w[5]
      for (m = j + 1; m <= nrec; m++) { s = rtext[m]; sub(/^ +/, "", s); sub(/ +$/, "", s); t2 = s; if (t2 ~ / *\|\| *exit +1$/) { sub(/ *\|\| *exit +1$/, "", t2); ex1 = 1 } else ex1 = 0
        if (t2 == "sha256sum -c " f) { if (hasset && !ex1) { ckwhy = "the step uses set/shopt, so the checksum line itself must end with || exit 1"; return 0 } return m }
        if (0) ; if (usesname(s, name)) return -1 }
      return 0
    }
    if (usesname(s, name)) return -1
  }
  return 0
}
# the value of a scalar that is NOT a run: scalar (env, with:, defaults, list items), "" for keys that cannot execute
function nrval(l,   v) {
  if (l ~ /^ *(#|$)/ || l ~ /^ *(- +)?(name|description|uses|run|if):/) return ""
  v = l
  if (!sub(/^ *(- +)?[A-Za-z_][A-Za-z0-9_.-]*: */, "", v)) sub(/^ *- +/, "", v)
  if (v !~ /^["]/ && v !~ ("^" q)) { bqs = ""; v = stripcmt(v) }
  if ((v ~ /^".*"$/ || v ~ new_sq) && length(v) > 1) v = substr(v, 2, length(v) - 2)
  return v
}
# whole-file pre-read: a trigger in any non-run scalar makes every run step SUBJECT; GOSUMDB=off / GOFLAGS -insecure disables shape g
function prescan(fn,   l, pin, pind, pf, v, lo) {
  filetrig = gounsafe = filebadshell = 0; pin = 0
  while ((getline l < fn) > 0) {
    sub(/\r$/, "", l); gsub(/\t/, " ", l); lo = tolower(l)
    if (l !~ /^ *#/ && (lo ~ ("gosumdb *[=:] *[\"" q "]?off") || (lo ~ /goflags/ && lo ~ /-insecure/))) gounsafe = 1
    if (pin) { if (l ~ /^ *$/ || (match(l, /[^ ]/) - 1) > pind) continue; pin = 0 }
    if (match(l, /^ *(- +)?run:( |$)/)) { pf = l; sub(/run:.*$/, "", pf); pind = length(pf); pin = 1; continue }
    v = nrval(l)
    if (v != "" && subject(v)) filetrig = 1
  }
  close(fn)
}
# a pseudo run line for a trigger found in a non-run scalar: judged exactly like a fetch line (R2 + R3)
function judgeline(f, ln, txt,   save, k, nf, w) {
  save = nrec; k = nrec + 1; nrec = k; rtext[k] = txt; rline[k] = ln; rfile[k] = f
  nf = r2(f, ln, txt, 0, k)
  if (nf == 0) { w = shape(k); if (w != "") report(f, ln, w, txt) }
  nrec = save
}
# a line that only PRINTS (echo/printf, balanced quotes, no pipe/redirect other than >> $GITHUB_STEP_SUMMARY, no substitution)
# is a mention even when it holds a URL or ${{ }}: it neither fetches nor executes
function summecho(raw,   t, c) {
  t = raw; sub(/^ +/, "", t); sub(/ +$/, "", t)
  if (t !~ /^(echo|printf) /) return 0
  if (!sub(/ >> *("\$GITHUB_STEP_SUMMARY"|\$GITHUB_STEP_SUMMARY|"\$\{GITHUB_STEP_SUMMARY\}")$/, "", t)) return 0
  if (t ~ /[|><;&`]/ || index(t, "$(") || index(t, "\\")) return 0
  c = t; if (gsub(/"/, "", c) % 2) return 0
  c = t; if (gsub(q, "", c) % 2) return 0
  return 1
}
function trk(p,   rc) {
  if (p !~ /^[A-Za-z0-9_.+\/-]+$/ || p ~ /(^|\/)\.\.(\/|$)/) return 0
  rc = system("env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE git -C \"$PINS_ROOT\" ls-files --error-unmatch -- \"" p "\" >/dev/null 2>&1")
  return (rc == 0)
}
# a file a step runs must be one the repository tracks (after stripping a repo-relative prefix), or one fetched and checksum-verified in THIS step
function exok(p) {
  if (p in okn) return 1
  sub(/^\$GITHUB_WORKSPACE\//, "", p); sub(/^\$\{GITHUB_WORKSPACE\}\//, "", p); sub(/^\$\{\{ github\.workspace \}\}\//, "", p); sub(/^\.\//, "", p)
  if (p ~ /^[\/~$]/ || index(p, "$") || index(p, "{")) return 0
  return trk(p)
}
# R2c, EVERY run step not judged as an accepted fetch shape: a pipe into an interpreter/eval/xargs, and running a file the repository does not track
function r2c(f, ln, raw,   lo, T, n, i, j, p, c, nf, isc) {
  nf = 0
  if (raw ~ /^ *#/) return 0
  lo = lowq(raw)
  if (lo ~ /(^|[^|])\|[ ]*(sudo +)?(sh|bash|zsh|dash|ksh|python[0-9.]*|perl|ruby|node|source|eval|xargs)([^a-z0-9_-]|$)/)
    nf += rep(f, ln, "a pipe into an interpreter, eval or xargs is refused (its input cannot be judged)", raw)
  n = tokenize(raw, T)
  for (i = 1; i <= n; i++) {
    if (isop(T[i]) || (i > 1 && !isop(T[i - 1]))) continue
    c = T[i]; j = i + 1; isc = 0
    if (c == "sh" || c == "bash" || c == "zsh" || c == "dash" || c == "source" || c == ".") {
      while (j <= n && T[j] ~ /^-/) { if (T[j] ~ /^-[a-z]*c[a-z]*$/) isc = 1; j++ }
    } else if (c == "chmod") {
      while (j <= n && (T[j] ~ /^-/ || T[j] ~ /^[ugoa]*[+=][rwxXst]+$/ || T[j] ~ /^[0-7]+$/)) j++
    } else continue
    if (isc || j > n || isop(T[j])) continue
    p = T[j]
    if (!exok(p)) nf += rep(f, ln, "executes a file the repository does not track (" p ")", raw)
  }
  return nf
}
# name: scalars are reinjected by expressions (${{ github.workflow }}), so they are scanned too
function namecheck(f, ln, line,   v, lo) {
  if (!match(line, /^ *(- +)?name: */)) return
  v = substr(line, RLENGTH + 1)
  if (v ~ /^[|>][-+0-9]*$/) return
  if (v !~ /^["]/ && v !~ ("^" q)) { bqs = ""; v = stripcmt(v) }
  lo = lowq(v)
  if (subject(v) || index(v, "$(") || index(v, "`") || index(v, "|"))
    report(f, ln, "a name scalar is reinjected by expressions (a name must not hold a fetch trigger, $( ), backtick or |; reword it)", v)
}
# R2b: refusals that need no trigger, applied to EVERY run step: a command whose word is a variable or ${{ }} expression,
# a program fed inline from a variable, eval/exec, a shell variable glued to letters, a URL assembled with a variable
function r2b(f, ln, raw,   lo, t, nf, v, a, b, pre, post, T, n, i) {
  nf = 0
  if (raw ~ /^ *#/) return 0
  lo = lowq(raw)
  t = raw
  gsub(/\$GITHUB_WORKSPACE\//, "WS/", t); gsub(/\$\{GITHUB_WORKSPACE\}\//, "WS/", t); gsub(/\$HOME\//, "WS/", t); gsub(/\$\{HOME\}\//, "WS/", t); gsub(/\$\{\{ github\.workspace \}\}\//, "WS/", t)
  while (match(t, /\[\[ [^\]]* \]\]/) || match(t, /\[ [^\]]* \]/)) t = substr(t, 1, RSTART - 1) " TEST " substr(t, RSTART + RLENGTH)
  if (match(t, "(^ *|[;&|(] *|(then|do|else|elif|[{]) +)[\"" q "]*\\$(\\{\\{|\\{|[A-Za-z_])"))
    nf += rep(f, ln, "a variable or expression in command position cannot be judged", raw)
  if (index(raw, "$") && (lo ~ /(^|[^a-z0-9_.-])(sh|bash|zsh|dash|ksh) +(-[a-z]+ +)*-[a-z]*c([^a-z0-9_-]|$)/))
    nf += rep(f, ln, "sh -c / bash -c with a variable cannot be judged", raw)
  if (lo ~ /(^|[^a-z0-9_.-])eval([^a-z0-9_-]|$)/) nf += rep(f, ln, "eval is refused", raw)
  if (lo ~ /(^|[^a-z0-9_.-])exec([^a-z0-9_-]|$)/) nf += rep(f, ln, "exec is refused", raw)
  n = tokenize(raw, T)
  for (i = 1; i <= n; i++) {
    if (isop(T[i]) || (i > 1 && !isop(T[i - 1]))) continue
    t = T[i]; gsub(/\$GITHUB_WORKSPACE\//, "WS/", t); gsub(/\$HOME\//, "WS/", t)
    if (match(t, /\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)/)) {
      pre = (RSTART > 1) ? substr(t, RSTART - 1, 1) : " "; post = substr(t, RSTART + RLENGTH, 1)
      if (pre ~ /[A-Za-z0-9_]/ || post ~ /[A-Za-z0-9_]/) { nf += rep(f, ln, "a shell variable glued to letters could form a command word", raw); break }
    }
  }
  if (index(raw, "$") && index(raw, "//") && !((raw ~ /^ *(echo|printf)( |$)/) && raw !~ /[|><;&`]/))
    nf += rep(f, ln, "a line that mixes a variable with // cannot be verified as a URL", raw)
  return nf
}
function regname(name, ln) { nmN++; nmname[nmN] = name; nmstep[nmN] = stepn; nmln[nmN] = ln }
# a word spelled with quote fragments: letters then an opening quote (c''url, b"a"sh), or a quoted
# piece directly followed by another quote or by letters ("c""url", "c"url)
function qword(s,   i, c, qs, cur, prevclose) {
  qs = ""; cur = ""; prevclose = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (qs != "") { if (c == qs) { qs = ""; prevclose = 1 }; continue }
    if (c == "\"" || c == q) {
      if (prevclose || (cur != "" && cur !~ /^-/ && cur !~ /=/)) return 1
      qs = c; continue
    }
    if (index(" ;|&()<>", c)) { cur = ""; prevclose = 0; continue }
    if (prevclose && c ~ /[A-Za-z]/) return 1
    prevclose = 0; cur = cur c
  }
  return 0
}
# does this text hold a fetch trigger (fetch tool word, URL, go install/run/get with @)?
function fetchtrig(lo) { return (lo ~ trig || (lo ~ gotrig && index(lo, "@") > 0)) }
# R2 scope for command substitution: refused only when (i) the line holds a fetch trigger, (ii) a $( ) / backtick body
# (to its matching close, nesting tracked) holds one or is unterminated on the line, or (iii) the substitution is
# assigned to a variable that a LATER line of the step feeds to eval/sh/bash/source/./exec. Returns the finding or "".
function subwhy(k, raw, lo,   i, c, d, body, nb, st, var, j, ll) {
  if (fetchtrig(lo)) return "command substitution on a line that holds a fetch trigger is refused"
  nb = length(raw)
  for (i = 1; i <= nb; i++) {
    c = substr(raw, i, 1)
    if (c == "$" && substr(raw, i + 1, 1) == "(") {
      d = 1; st = i + 2
      for (j = st; j <= nb && d > 0; j++) { c = substr(raw, j, 1); if (c == "(") d++; else if (c == ")") d-- }
      if (d > 0) return "command substitution $( ) is not closed on its line (cannot read the body)"
      body = substr(raw, st, j - st - 1)
      if (fetchtrig(lowq(body))) return "command substitution body holds a fetch trigger"
    } else if (c == "`") {
      st = i + 1; j = index(substr(raw, st), "`")
      if (j == 0) return "backtick is not closed on its line (cannot read the body)"
      body = substr(raw, st, j - 1); i = st + j - 1
      if (fetchtrig(lowq(body))) return "backtick body holds a fetch trigger"
    }
  }
  if (match(raw, /(^|[ ;&|(])[A-Za-z_][A-Za-z0-9_]*=[^ ]*(\$\(|`)/)) {
    ll = substr(raw, RSTART + RLENGTH); var = substr(raw, RSTART, RLENGTH); sub(/^[ ;&|(]/, "", var); sub(/=.*$/, "", var)
    for (j = k; j <= nrec; j++) {
      if (j > k) ll = rtext[j]
      body = ll; ll = lowq(ll)
      if ((index(body, "$" var) || index(body, "${" var "}")) && ll ~ /(^|[ ;&|(])(eval|sh|bash|source|\.|exec)( |$)/) return "command substitution assigned to " var " is later executed (eval/sh/bash/source/./exec)"
    }
  }
  return ""
}
# R2: obfuscation primitives, each refused wholesale in a SUBJECT step. Returns the number of findings.
function r2(f, ln, raw, glue, k,   s, lo, nf, t, nu, u, i, n, tk, nout, v, val, hf, T, w) {
  nf = 0
  s = raw; gsub("[\"" q "]", "", s)
  lo = lowq(raw); hf = hasfetchtool(lo)
  if (glue) nf += rep(f, ln, "a backslash-newline splits a word (cannot read what runs)", raw)
  if (index(raw, "$" q)) nf += rep(f, ln, "ANSI-C quoting $" q "..." q " is refused", raw)
  if (index(raw, "`") || index(raw, "$(")) { w = subwhy(k, raw, lo); if (w != "") nf += rep(f, ln, w, raw) }
  if (lo ~ /(^|[^a-z0-9_.-])eval([^a-z0-9_-]|$)/) nf += rep(f, ln, "eval is refused", raw)
  if (lo ~ /(^|[^a-z0-9_.-])exec([^a-z0-9_-]|$)/) nf += rep(f, ln, "exec is refused", raw)
  if (lo ~ /(^|[^a-z0-9_.-])(source|\.) +<\(/) nf += rep(f, ln, "source/. of a process substitution is refused", raw)
  else if (index(raw, "<(")) nf += rep(f, ln, "process substitution <( ) is refused", raw)
  if (lo ~ /(^|[^a-z0-9_.-])(sh|bash|zsh|dash|ksh|pwsh|powershell)( +-[a-z]+)* +-[a-z]*c([^a-z0-9_-]|$)/ || lo ~ /(^|[^a-z0-9_.-])python[0-9.]*( +-[a-z]+)* +-[a-z]*c([^a-z0-9_-]|$)/ || lo ~ /(^|[^a-z0-9_.-])(perl|ruby|node)( +-[a-z]+)* +-[a-z]*e([^a-z0-9_-]|$)/)
    nf += rep(f, ln, "an interpreter given its program inline (sh -c, python -c, perl -e ...) is refused", raw)
  if (qword(raw)) nf += rep(f, ln, "a command word that contains a quote is refused", raw)
  t = s
  while (match(t, /\$(\{\{[^}]*\}\}|\{[^}]*\}|[A-Za-z_][A-Za-z0-9_]*)/)) {
    i = (RSTART > 1) ? substr(t, RSTART - 1, 1) : " "; v = substr(t, RSTART + RLENGTH, 1); if (v == "") v = " "
    if (i != " " || v != " ") { nf += rep(f, ln, "a variable adjacent to other characters could form a command word", raw); break }
    t = substr(t, RSTART + RLENGTH)
  }
  if (lo ~ /(^|[^a-z0-9_.-])(env|command|exec|xargs|nohup|timeout|sudo|nice|busybox)( +[^|;&]*)? +(curl|wget)([^a-z0-9_-]|$)/) nf += rep(f, ln, "a wrapper around the fetch tool (env, command, xargs, nohup, timeout, sudo, nice) is refused", raw)
  if (hf) {
    if (s ~ /(^| )--next( |$)/) nf += rep(f, ln, "curl --next is refused", raw)
    if (s ~ /(^| )(-[A-Za-z]*K[A-Za-z]*|--config)([ =]|$)/) nf += rep(f, ln, "-K / --config is refused", raw)
    if (lo ~ /(^|[^a-z0-9_.-])wget([^a-z0-9_-]|$)/ && s ~ /(^| )(-[A-Za-z]*i[A-Za-z]*|--input-file)([ =]|$)/) nf += rep(f, ln, "wget -i / --input-file is refused", raw)
  }
  if (lo ~ /(^|[^a-z0-9_-])(iwr|iex|invoke-[a-z]+)([^a-z0-9_-]|$)/) nf += rep(f, ln, "iwr / iex / Invoke-* has no accepted shape", raw)
  t = s; nu = 0
  while (match(t, /[A-Za-z][A-Za-z0-9+.-]*:\/\/[^ ]*/)) {
    u = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH); nu++
    if (u !~ /^https:\/\// && !loopback(u)) nf += rep(f, ln, "URL scheme is not https", raw)
    if (u ~ /\.\./ || u ~ /\/\.\// || u ~ /\/\.$/) nf += rep(f, ln, "URL contains a dot segment", raw)
    if (tolower(u) ~ /%2e/) nf += rep(f, ln, "URL contains an encoded dot (%2e)", raw)
    if (u ~ /@/) nf += rep(f, ln, "URL contains @ (userinfo)", raw)
  }
  if (hf && nu > 1) nf += rep(f, ln, "more than one URL in a fetch command", raw)
  if (hf) {
    n = tokenize(raw, T); nout = 0
    for (i = 1; i <= n; i++) {
      tk = T[i]; val = "\001"
      if (tk == "--output" || tk == "--output-document") { nout++; val = T[i + 1] }
      else if (tk ~ /^--(output|output-document)=/) { nout++; val = tk; sub(/^[^=]*=/, "", val) }
      else if (tk == "--remote-name" || tk == "--remote-name-all") nout++
      else if (tk ~ /^-[A-Za-z]+$/ && tk ~ /[oO]/) { nout++; if (tk ~ /[oO]$/) val = T[i + 1] }
      else if (tk ~ /^-[A-Za-z]*[oO][^A-Za-z]/) { nout++; match(tk, /[oO]/); val = substr(tk, RSTART + 1) }
      if (val != "\001") {
        if (val == "-" || val == "/dev/stdout" || val ~ /^\/dev\/fd\//) nf += rep(f, ln, "output to stdout/fd (-o -, /dev/stdout, /dev/fd/*) is refused", raw)
        else if (val != "" && val !~ /^\/dev\// && !isop(val)) regname(val, ln)
      }
    }
    if (nout > 1) nf += rep(f, ln, "an output option (-o -O --output --remote-name) given more than once", raw)
  }
  return nf
}
function sh_a(T, n,   i, j, a) {
  if (T[1] != "curl") return 0
  for (i = 2; i <= n && isfl(T[i]); i++) ;
  if (i + 2 > n || !pinraw(T[i]) || T[i + 1] != OP "|" || (T[i + 2] != "sh" && T[i + 2] != "bash")) return 0
  if (n == i + 2) return 1
  if (T[i + 3] != "-s" || T[i + 4] != "--") return 0
  for (j = i + 5; j <= n; j++) if (isop(T[j]) || T[j] ~ /[$`;&|<>(){}]/) return 0
  return 1
}
function sh_bc(T, n, k, kind,   i, name, ck, j) {
  if (T[1] != "curl") return 0
  for (i = 2; i <= n && isfl(T[i]); i++) ;
  if (T[i] != "-o" || n != i + 2 || !okname(T[i + 1])) return 0
  if (kind == "b" ? !pinraw(T[i + 2]) : !relasset(T[i + 2])) return 0
  name = T[i + 1]
  ck = needck(k, name)
  if (ck > 0) { okn[name] = 1; return 1 }
  shwhy = (ck < 0) ? "the fetched file is used before its sha256 check" : "the fetched file has no sha256 check in the step"
  if (ckwhy != "") shwhy = ckwhy
  return 0
}
# curl -w: only a fixed set of variables plus literal text; %output, %header, @file, %{json}, any other % is refused
function wok(v,   r, nm) {
  if (index(v, "@")) return 0
  r = v
  while (index(r, "%")) {
    if (!match(r, /%\{[a-z_]+\}/) || RSTART != index(r, "%")) return 0
    nm = substr(r, RSTART + 2, RLENGTH - 3)
    if (nm != "http_code" && nm != "url_effective" && nm != "time_total" && nm != "response_code" && nm != "size_download") return 0
    r = substr(r, RSTART + RLENGTH)
  }
  return 1
}
# PS-A10: http:// accepted ONLY for a host that is exactly 127.0.0.1, localhost or [::1] (optional :port), never userinfo or a suffix
function loopback(u) { return u ~ /^http:\/\/(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?([\/?#][^$`{}]*)?$/ }
function sh_d(T, n,   i, t, head, dn, nurl, lb, sink, m) {
  if (T[1] == "wget") {
    for (i = 2; i <= n; i++) { t = T[i]; if (t == "-q") ; else if (t == "--spider") head = 1; else if (t ~ /^https:\/\/[^$`{}]+$/) nurl++; else return 0 }
    return (head && nurl == 1)
  }
  if (T[1] != "curl") return 0
  lb = 0; sink = 0; m = n
  for (i = 2; i <= n; i++) if (loopback(T[i])) lb = 1
  if (lb) {   # PS-A10: a loopback health check may end in | grep -q WORD (the only pipe accepted); nothing else after the URL
    for (i = 2; i <= n; i++) if (T[i] == OP "|") {
      if (T[i + 1] == "grep" && T[i + 2] ~ /^-q[iF]*$/ && T[i + 3] ~ /^[A-Za-z0-9_.-]+$/ && i + 3 == n) { sink = 1; m = i - 1 }
      break
    }
  }
  for (i = 2; i <= m; i++) {
    t = T[i]
    if (isfl(t)) continue
    if (lb && (t == "--retry" || t == "--retry-delay" || t == "--max-time" || t == "-m" || t == "--connect-timeout") && T[i + 1] ~ /^[0-9]+$/) { i++; continue }
    if (t == "-I" || t == "--head") head = 1
    else if (t == "-o" && T[i + 1] == "/dev/null") { dn = 1; i++ }
    else if ((t == "-w" || t == "--write-out") && !lb && i < m && !isop(T[i + 1]) && T[i + 1] !~ /[$`]/) { if (!wok(T[i + 1])) { shwhy = "write-out format is not in the allowed set"; return 0 } i++ }
    else if (t ~ /^https:\/\/[^$`{}]+$/ || loopback(t)) nurl++
    else return 0
  }
  return (nurl == 1 && (head || dn || sink || lb))
}
function sh_e(T, n,   i, t, meth, nurl) {
  if (T[1] != "curl") return 0
  for (i = 2; i <= n; i++) {
    t = T[i]
    if (isfl(t)) continue
    if (t == "-X" && (T[i + 1] == "POST" || T[i + 1] == "PUT")) { meth = 1; i++ }
    else if ((t == "-H" || t == "-d" || t == "--data" || t == "--data-raw") && i < n && !isop(T[i + 1]) && T[i + 1] !~ /`/) i++
    else if (t == "--data-binary" && T[i + 1] ~ /^@[A-Za-z0-9_.\/-]+$/) i++
    else if (t == "-o" && T[i + 1] == "/dev/null") i++
    else if (t ~ /^https:\/\/[^$`{}]+$/ || t ~ /^\$[A-Za-z_][A-Za-z0-9_]*$/ || t ~ /^\$\{[A-Za-z_][A-Za-z0-9_]*\}$/) nurl++
    else return 0
  }
  return (meth && nurl == 1)
}
function sh_f(T, n,   i, t, j) {
  if (T[1] == "gh" && T[2] == "api") {
    i = 3
    while (i <= n && T[i] == "-H" && i < n && !isop(T[i + 1]) && T[i + 1] !~ /`/) i += 2
    if (i + 2 > n || T[i] !~ /^[A-Za-z0-9_.\/?=&%,+:-]+$/ || T[i] ~ /\.\./ || T[i + 1] != OP "|" || T[i + 2] != "jq") return 0
    for (j = i + 3; j <= n; j++) if (isop(T[j]) || T[j] ~ /`/) return 0
    return 1
  }
  if (T[1] != "curl") return 0
  for (i = 2; i <= n; i++) {
    t = T[i]
    if (isfl(t)) continue
    if (t == "-H" && i < n && !isop(T[i + 1]) && T[i + 1] !~ /`/) { i++; continue }
    break
  }
  if (i + 2 > n || !apiok(T[i]) || T[i + 1] != OP "|") return 0
  if (T[i + 2] == "python3") return (i + 4 == n && T[i + 3] == "-m" && T[n] == "json.tool")
  if (T[i + 2] != "jq") return 0
  for (j = i + 3; j <= n; j++) if (isop(T[j]) || T[j] ~ /`/) return 0
  return 1
}
# shape h: gh release download <tag> [-R o/r] [-p pattern] -O NAME, then the same in-step echo-sum check as shapes b/c
function sh_h(T, n, k,   i, name, ck, tag) {
  if (T[1] != "gh" || T[2] != "release" || T[3] != "download") return 0
  tag = T[4]
  if (tag !~ /^[A-Za-z0-9_][A-Za-z0-9_.+-]*$/ || tolower(tag) == "latest") return 0
  for (i = 5; i <= n; i++) {
    if ((T[i] == "-R" || T[i] == "--repo") && T[i + 1] ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/) i++
    else if ((T[i] == "-p" || T[i] == "--pattern") && T[i + 1] ~ /^[A-Za-z0-9_.+-]+$/) i++
    else if ((T[i] == "-O" || T[i] == "--output") && okname(T[i + 1]) && !name) { name = T[i + 1]; i++ }
    else return 0
  }
  if (!name) return 0
  ck = needck(k, name)
  if (ck > 0) { okn[name] = 1; return 1 }
  shwhy = (ck < 0) ? "the fetched file is used before its sha256 check" : "the fetched file has no sha256 check in the step"
  if (ckwhy != "") shwhy = ckwhy
  return 0
}
function sh_g(T, n,   i, j, t, nat, at, ref) {
  i = 1; if (T[1] == "bash" && T[2] == "scripts/retry.sh") i = 3
  if (T[i] != "go" || (T[i + 1] != "install" && T[i + 1] != "run" && T[i + 1] != "get")) return 0
  if (gounsafe) { shwhy = "go module checksum verification is disabled in this file (GOSUMDB=off or GOFLAGS -insecure)"; return 0 }
  for (j = i + 2; j <= n; j++) {
    t = T[j]
    if (isop(t)) return 0
    at = index(t, "@")
    if (at) {
      ref = substr(t, at + 1)
      if (substr(t, 1, at - 1) !~ /^[A-Za-z0-9_.\/~-]+$/ || !(isha(ref) || ref ~ semre)) return 0
      nat++
    } else if (t !~ /^[A-Za-z0-9_.\/=:,-]+$/) return 0
  }
  if (nat < 1) return 0
  gocount += nat
  return 1
}
# R3: every line of a SUBJECT step that holds a fetch tool or a URL must match exactly one accepted shape
function shape(k,   raw, t, n, T, m, j, lo, wd) {
  raw = rtext[k]; lo = lowq(raw)
  if (!(lo ~ trig || (lo ~ gotrig && index(lo, "@") > 0))) return ""
  t = raw; sub(/^ +/, "", t); sub(/ +$/, "", t)
  if ((t ~ /^(echo|printf)( |$)/ || t ~ /^#/) && t !~ /[|><;&`]/ && !index(t, "$(")) return ""
  n = tokenize(t, T)
  if (n < 1) return "fetch does not match an accepted shape"
  if (!hasfetchtool(lo) && index(raw, "://") == 0) {
    for (j = 1; j <= n; j++) if ((T[j] in okn) && n <= 4 && (T[1] ~ /^(sh|bash|chmod|source|\.\/.*|\.)$/ || T[1] == "./" T[j])) return ""
  }
  shwhy = ""; m = 0
  m += sh_a(T, n); m += sh_bc(T, n, k, "b"); m += sh_bc(T, n, k, "c"); m += sh_d(T, n); m += sh_e(T, n); m += sh_f(T, n); m += sh_g(T, n); m += sh_h(T, n, k)
  if (m == 1) return ""
  if (shwhy != "") return "fetch does not match an accepted shape (" shwhy ")"
  return "fetch does not match an accepted shape"
}
function push(ln, txt,   a) {
  nrec++; rline[nrec] = ln; rfile[nrec] = lastfile; rglue[nrec] = 0
  if (index(txt, "\001")) {
    a = txt; gsub(/\001/, "", a)
    rglue[nrec] = 1; txt = a
  }
  rtext[nrec] = txt
}
function addlit(ln, s) {
  if (cur == "") curln = ln
  if (cur ~ /\001$/) sub(/^ +/, "", s)
  if (s ~ /[^ ]\\$/) { sub(/\\$/, "", s); cur = cur s "\001"; return }
  if (s ~ / *\\$/) { sub(/ *\\$/, "", s); cur = cur s " "; return }
  push(curln, cur s); cur = ""
}
# COMMENTS (PS-A9). Used for PLAIN scalars only (run: inline, non-run scalars, name:). A block scalar is never stripped: a
# shell comment there is scanned like any other text. The strip is quote-aware and treats a backslash as escaping the next
# character, so it removes LESS than YAML does (YAML ends a plain scalar at any whitespace-preceded #): safe, it over-scans.
function stripcmt(s,   i, c, out, n) {
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (bqs == q) { if (c == q) bqs = ""; continue }
    if (c == "\\") { i++; continue }
    if (bqs == "\"") { if (c == "\"") bqs = ""; continue }
    if (c == "\"" || c == q) { bqs = c; continue }
    if (c == "#" && (i == 1 || substr(s, i - 1, 1) == " ")) return (i == 1) ? "" : substr(s, 1, i - 2)
  }
  return s
}
function content(ln, s) {
  if (dq && index(s, "\\")) dqesc = 1
  if (mode == "lit") addlit(ln, s)
  else { sub(/^ +/, "", s); sub(/ *\\$/, "", s); acc = (acc == "" ? "" : acc " ") s; accn++ }
}
function finish_run() {
  if (cur != "") { push(curln, cur); cur = "" }
  if (mode != "lit" && acc != "") {
    if (accn == 1 && mode == "inl" && !qwhole) { bqs = ""; acc = stripcmt(acc) }
    push(runln, acc)
  }
  if (dqesc) report(lastfile, runln, "cannot judge a double-quoted run scalar with escapes", "run: (double-quoted scalar containing a backslash)")
  dq = dqesc = 0
  inrun = 0; acc = ""; accn = 0; runs++
}
function okshell(v) { sub(/ +#.*$/, "", v); gsub(/"/, "", v); gsub(q, "", v); return (v ~ /^(bash|sh)( |$)/) }
function flush(   k, subj, nf, w, st) {
  curshell = stepshell; sub(/ +#.*$/, "", curshell); gsub(/["]/, "", curshell); gsub(q, "", curshell); sub(/ +$/, "", curshell)
  if (stepshell != "" && nrec > 0 && !okshell(stepshell)) { checked++; report(rfile[1], rline[1], "unsupported shell, cannot verify", "shell: " stepshell) }
  stepshell = ""
  stepn++; split("", okn)
  subj = filetrig
  for (k = 1; k <= nrec; k++) { skipl[k] = summecho(rtext[k]); shaped[k] = 0 }
  for (k = 1; k <= nrec; k++) if (!skipl[k] && subject(rtext[k])) subj = 1
  for (k = 1; k <= nrec; k++) if (!skipl[k]) r2b(rfile[k], rline[k], rtext[k])
  if (subj) {
    checked++
    for (k = 1; k <= nrec; k++) {
      if (skipl[k]) continue
      nf = r2(rfile[k], rline[k], rtext[k], rglue[k], k)
      if (nf == 0) { w = shape(k); if (w != "") report(rfile[k], rline[k], w, rtext[k]) }
      if (fetchtrig(lowq(rtext[k]))) shaped[k] = 1   # a fetch line is judged by r2 + shape alone (no duplicate findings from r2c)
    }
  }
  for (k = 1; k <= nrec; k++) if (!skipl[k] && !shaped[k]) r2c(rfile[k], rline[k], rtext[k])
  for (k = 1; k <= nrec; k++) { fmax++; ftext[fmax] = rtext[k]; fstep[fmax] = stepn }
  nrec = 0
}
# R2: a fetched file named by -o <name> must not be executed from ANOTHER step of the same workflow file
function xstep(   a, b, t, nm) {
  for (a = 1; a <= nmN; a++) {
    nm = esc(nmname[a])
    for (b = 1; b <= fmax; b++) {
      if (fstep[b] == nmstep[a]) continue
      t = " " ftext[b]; gsub("[\"" q "]", "", t)
      if (t ~ ("[ ;&|(](sh|bash|zsh|dash|source|\\.|python[0-9.]*|perl|ruby|node|chmod[^;&|]*) +(\\./)?" nm "([ ;&|)]|$)") || t ~ ("[ ;&|(]\\./" nm "([ ;&|)]|$)")) {
        report(lastfile, nmln[a], "a fetched file is executed from another step of the workflow", ftext[b]); break
      }
    }
  }
  nmN = 0; fmax = 0
}
# fail closed: a file whose run steps the line parser could not read is not "clean"
function filecheck() {
  if (lastfile == "") return
  xstep()
  if (un > 0 || (pr + pu == 0 && hassteps)) report(lastfile, unln ? unln : 1, "could not read " (un > 0 ? un : 1) " run step(s) in " lastfile ": unparsed workflow shapes are not accepted", "(flow/JSON style or a run key the line parser did not read)")
  un = pr = pu = hassteps = unln = 0
}
FNR == 1 { if (inrun) finish_run(); flush(); filecheck(); files_seen++; prescan(FILENAME) }
{
  lastfile = FILENAME
  line = $0; sub(/\r$/, "", line); gsub(/\t/, " ", line)
  if (inrun) {
    if (line ~ /^ *$/) next
    if (mode == "inl" && runempty && line ~ /^ *shell: *[^ #]/) { v2 = line; sub(/^ *shell: */, "", v2); if (v2 !~ /^[\"]?(bash|sh)[\"]? *(#.*)?$/) filebadshell = 1; if (!okshell(v2)) { checked++; report(FILENAME, FNR, "unsupported shell, cannot verify", "defaults shell: " v2) } }
    ind = match(line, /[^ ]/) - 1
    if (ind > runind) { content(FNR, line); next }
    finish_run()
  }
  if (line ~ /^ *-( |$)/) flush()
  namecheck(FILENAME, FNR, line)
  nv = nrval(line)
  if (nv != "" && subject(nv)) judgeline(FILENAME, FNR, nv)
  if (line ~ /^ *(- +)?uses:/) pu++
  if (line !~ /^ *#/) {
    if (line !~ /^ *(- +)?run:( |$)/ && line ~ rawre) { un++; if (!unln) unln = FNR }
    if (line ~ stepsre) hassteps = 1
  }
  if (match(line, /^ *(- +)?shell: */)) { stepshell = substr(line, RLENGTH + 1); if (stepshell == "") stepshell = "?" }
  if (match(line, /^ *(- +)?run:( |$)/)) {
    pfx = line; sub(/run:.*$/, "", pfx); runind = length(pfx)
    val = substr(line, runind + 5); sub(/^ +/, "", val); sub(/ +$/, "", val)
    runrec0 = nrec; pr++; inrun = 1; runln = FNR; acc = ""; accn = 0; cur = ""; runempty = (val == ""); dq = dqesc = 0
    if (val ~ /^[|>][-+0-9]*( +#.*)?$/) mode = (substr(val, 1, 1) == "|") ? "lit" : "fold"
    else {
      mode = "inl"; dq = (substr(val, 1, 1) == "\""); qwhole = 0
      if (val ~ /^".*"$/ && length(val) > 1) { qwhole = 1; if (index(val, "\\")) dqesc = 1; val = substr(val, 2, length(val) - 2) }
      else if (val ~ new_sq && length(val) > 1) { qwhole = 1; val = substr(val, 2, length(val) - 2); gsub(q q, q, val) }
      if (val != "") content(FNR, val)
    }
  }
}
END {
  if (inrun) finish_run()
  flush()
  filecheck()
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
