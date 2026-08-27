#!/usr/bin/env bash
# error-handling-fitness.sh — refuse the three error-handling shapes a machine
# can find, in the one place they are cheapest to remove: presubmit.
#
# WHY THIS EXISTS, and why it is a gate rather than a line on a review
# checklist. Yuan, Luo, Zhuang, Rodrigues, Zhao, Zhang, Jain and Stumm
# reproduced 198 randomly sampled user-reported failures of Cassandra, HBase,
# HDFS, MapReduce and Redis ("Simple Testing Can Prevent Most Critical
# Failures", OSDI 2014). Two numbers from that paper are the whole argument
# for this file:
#
#   * 92% of the CATASTROPHIC failures followed from incorrect handling of
#     errors the system had ALREADY CAUGHT AND SIGNALLED. Detection was almost
#     never the defect. The handler was.
#   * 35% of the catastrophic failures came from three handler patterns
#     trivial enough for a machine to find: a handler that is empty, a handler
#     whose body is a TODO/FIXME, and a handler whose entire body is a log
#     statement past a condition the surrounding code treats as fatal.
#
# So this is not a style preference to be negotiated down at review time. It
# is the strongest empirical result the field has about where catastrophes
# begin, and the three shapes it names are exactly the ones a text pass can
# catch -- which is why they belong in a gate rather than in a reviewer's
# attention budget.
#
# WHAT IT CHECKS — three rules covering TWO of the paper's three patterns
# (the paper's "empty or only a log statement" pattern is split into two rules
# here because the two shapes need different detectors; its third pattern has
# no Go analogue and is declared unchecked below, so the 35% figure belongs to
# the paper's enumeration, not to this gate's):
#
#   TODO-IN-ERROR-BRANCH   TODO or FIXME anywhere inside an error branch. The
#                          author already knew the handler was unfinished; the
#                          only thing ever missing was something that reads
#                          the note back to them.
#   EMPTY-ERROR-BRANCH     an `if err != nil {` block whose body is empty or
#                          contains nothing but comments.
#   LOG-AND-CONTINUE       an error branch whose ONLY statement is a log call,
#                          with no return / panic / os.Exit anywhere in the
#                          body, inside a function that itself RETURNS ERROR.
#
# HONEST SCOPE, because a check that overclaims is worse than one that scopes
# itself. This is a TEXT pass (awk over the source), not a type-checked AST
# pass, and LOG-AND-CONTINUE in particular is an APPROXIMATION of the paper's
# "past a condition the surrounding code treats as fatal". That condition is
# semantic; the proxy used here is structural -- "the enclosing function
# declares an error return, so it HAD a way to propagate and logged instead".
# The proxy is deliberately conservative: it prefers to miss rather than to
# accuse. These are its known FALSE NEGATIVES, and nothing this script prints
# claims to have covered them:
#
#   * an error branch whose variable is not named `err`-something. The opener
#     match anchors on an identifier CONTAINING `err` (case-insensitive)
#     compared `!= nil`, so `if e != nil {` is invisible to every rule here.
#   * a log-and-continue in a function that returns no error. A swallowing
#     handler deep inside a goroutine is the paper's shape too, and this rule
#     cannot distinguish it from a legitimately ignorable warning.
#   * a two-statement handler -- `log.Warn(...)` then `metrics.Inc()`, then
#     falling through. "Only statement" is the bright line that keeps this
#     rule out of arguments about intent, and it costs exactly this.
#   * a function whose signature spans several lines: the enclosing-function
#     lookup reads one line.
#   * anything inside a raw string literal or a `/* */` block comment, which
#     this pass does not tokenize.
#   * the paper's third pattern, `catch (Exception e) { abort() }`, has no Go
#     analogue worth grepping and is not checked at all.
#
# The brace walk that delimits each branch is untokenized for the same reason,
# and it fails SAFE in one direction on purpose: a `{` inside a string literal
# makes a block look LONGER than it is, and a longer block never matches
# "empty" or "only one statement". A miscount cannot manufacture a finding.
#
# It has no known FALSE POSITIVES over the scaffold, which is the other half
# of the bargain. A gate that fires on correct code trains people to widen it
# until it is gone, and a widened gate is indistinguishable from a deleted one.
#
#   error-handling-fitness.sh                 scan the repo's Go sources
#   error-handling-fitness.sh internal cmd    scan only those paths
#
# Exit: 0 clean; 1 findings, or NO Go sources found. The second one is this
# repo's zero-inputs rule, the same one check-registries.sh enforces over an
# emptied registry directory: a scan of nothing must never report success,
# because "0 findings" over 0 files and over 400 files is the same line and
# the opposite fact.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

# `"${@:-.}"` rather than a length test: bash 3.2 (the macOS system shell, and
# therefore part of the portability floor every script here holds) treats
# `${#arr[@]}` on an empty array as an unbound variable under `set -u`.
roots=("${@:-.}")

# The file set. Each exclusion is here for its own reason: `vendor/` is not
# this repo's code to fix, `.git/` is not code, and generated `*.pb.go`
# carries the generator's error handling, which cannot be edited here anyway.
#
# TEST FILES ARE DELIBERATELY IN SCOPE. An empty error branch in a test is a
# test that proves nothing -- the same defect one level up, and the one this
# standard keeps finding. LOG-AND-CONTINUE cannot fire inside a
# `func TestX(t *testing.T)` regardless, because that function returns no
# error, so the rule that could have been noisy in tests is structurally
# silent there rather than suppressed by an exclusion nobody would revisit.
files=()
while IFS= read -r f; do
  files[${#files[@]}]="$f"
done < <(
  find "${roots[@]}" \
    \( -name vendor -o -name .git -o -name node_modules \) -prune -o \
    -type f -name '*.go' ! -name '*.pb.go' -print 2>/dev/null | LC_ALL=C sort
)

# ZERO INPUTS FAIL. Without this, a `roots` argument naming a path with no Go
# under it -- a typo, a directory that moved, a Makefile edit made in a hurry
# -- prints "clean" and exits 0, and the gate reports the strongest empirical
# result in the field as satisfied having read nothing at all.
if ((${#files[@]} == 0)); then
  printf 'error-handling-fitness: NO Go sources found under %s -- a scan of nothing is not a clean scan.\n' "${roots[*]}" >&2
  exit 1
fi

report_file="$(mktemp)"
trap 'rm -f "${report_file}"' EXIT

awk '
# ---------------------------------------------------------------------------
# Each file is buffered and then walked, rather than classified line by line
# as it streams. NESTING is the reason: an `if err != nil` can sit inside
# another one, and a streaming pass has to carry a stack of half-open
# candidate blocks to get that right. Buffering makes every candidate an
# independent forward walk from its own opening brace, so the nested case
# needs no special handling and cannot be got subtly wrong. Go files are
# small; this costs nothing measurable.
# ---------------------------------------------------------------------------
FNR == 1 { if (NR > 1) flush(); n = 0; fname = FILENAME }
{ buf[++n] = $0 }
END { flush() }

function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

# is_error_opener -- does this line open an `if <...>err<...> != nil {` block?
# The assign-and-test form (`if err := f(); err != nil {`) is accepted because
# it is the dominant Go idiom; excluding it would blind every rule below to
# most of the handlers in a typical file.
function is_error_opener(s) {
  if (s !~ /\{/) return 0
  return (s ~ /(^|[^A-Za-z0-9_])if[ \t].*[A-Za-z0-9_]*[eE][rR][rR][A-Za-z0-9_]*[ \t]*!=[ \t]*nil[ \t]*\{/)
}

# is_func_line -- a function DEFINITION line, top-level or a literal. The
# literal forms (`f := func() error {`, `go func() {`) are included because a
# handler inside a closure swallows an error exactly as effectively, and it is
# the CLOSURE, not the enclosing method, that decides whether a `return` was
# available to it.
function is_func_line(s) {
  return (s ~ /(^|[^A-Za-z0-9_])func[ \t]*[(A-Za-z_]/ && s ~ /\{[ \t]*$/)
}

# returns_error -- does this function-definition line declare an error return?
# Read from the END of the signature, because the naive "the line contains
# `error`" test is wrong in the other direction: a PARAMETER of type error
# would satisfy it. Two shapes cover Go:
#   `... ) error {`        -> the trimmed signature ends in `error`
#   `... ) (T, error) {`   -> the trailing parenthesised group contains it
# Named results (`) (n int, err error) {`) fall out of the second shape.
function returns_error(s,   t, i, c, depth, grp) {
  t = s
  sub(/[ \t]*\{[ \t]*$/, "", t)
  t = trim(t)
  if (t ~ /(^|[^A-Za-z0-9_])error$/) return 1
  if (t !~ /\)$/) return 0
  depth = 0
  for (i = length(t); i >= 1; i--) {
    c = substr(t, i, 1)
    if (c == ")") depth++
    else if (c == "(") { depth--; if (depth == 0) break }
  }
  if (i < 1) return 0
  grp = substr(t, i, length(t) - i + 1)
  return (grp ~ /(^|[^A-Za-z0-9_])error([^A-Za-z0-9_]|$)/)
}

# is_log_call -- the log-statement shapes Go actually produces, enumerated
# rather than approximated by "a call with no assignment", which would swallow
# every real handler that calls a cleanup function and turn this rule into
# noise. The two exclusions matter as much as the matches: an assignment is
# not a log statement, and `fmt.Errorf` matches the `.Errorf(` shape while
# being the exact opposite of swallowing.
function is_log_call(s) {
  if (s ~ /(^|[^A-Za-z0-9_])(fmt|errors)\./) return 0
  if (s ~ /(:=|[^=!<>]=[^=])/) return 0
  return (s ~ /(^|[^A-Za-z0-9_])(log|logger|slog)\./ ||
          s ~ /\.(Printf|Println|Print|Logf|Log)\(/ ||
          s ~ /\.(Error|Errorf|Warn|Warnf|Info|Infof|Debug|Debugf)(Context)?\(/)
}

# terminates -- does this body line hand control back, so the error is not in
# fact being continued past? `continue`/`break`/`goto` count: they leave the
# branch for different control flow, which is a decision, not the paper is
# fall-through shape.
function terminates(s) {
  return (s ~ /(^|[^A-Za-z0-9_])(return|panic|continue|break|goto)([^A-Za-z0-9_]|$)/ ||
          s ~ /os\.Exit\(/ ||
          s ~ /\.Fatal(f|ln)?\(/ ||
          s ~ /\.Skip(f|Now)?\(/ ||
          s ~ /runtime\.Goexit\(/)
}

function report(ln, rule, msg) { printf "%s:%d: %s: %s\n", fname, ln, rule, msg }

function flush(   i) {
  for (i = 1; i <= n; i++) if (is_error_opener(buf[i])) classify(i)
}

# brace_delta -- net brace balance of a fragment, with the two cheapest
# skew sources removed: a line comment, and a braced rune literal.
function brace_delta(s,   i, c, d) {
  sub(/\/\/.*$/, "", s)
  gsub(/'"'"'[{}]'"'"'/, "", s)
  d = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "{") d++
    else if (c == "}") d--
  }
  return d
}

# close_index -- position, within a fragment, of the `}` at which the running
# balance first reaches -1. That is the brace that pops OUR frame, as opposed
# to one closing a block the body itself opened.
function close_index(s,   i, c, d) {
  d = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "{") d++
    else if (c == "}") { d--; if (d < 0) return i }
  }
  return 0
}

# classify -- walk one error branch from its opening brace to the brace that
# matches it, then apply the three rules to the body between them.
function classify(start,   i, j, depth, delta, closed, nbody, body, rest, line,
                           hasTodo, hasTerm, nonComment, lastStmt, fline, fi) {
  depth = 1
  closed = 0
  nbody = 0
  for (i = start; i <= n; i++) {
    if (i == start) {
      j = index(buf[i], "{")
      rest = substr(buf[i], j + 1)
    } else {
      rest = buf[i]
    }
    delta = brace_delta(rest)
    if (depth + delta <= 0) {
      j = close_index(rest)
      if (j > 1) body[++nbody] = substr(rest, 1, j - 1)
      closed = 1
      break
    }
    depth += delta
    body[++nbody] = rest
  }
  # An unterminated block means the file is not valid Go (or the untokenized
  # brace walk lost the thread). Either way, say nothing: an accusation made
  # from a miscount is exactly the kind of finding that gets a gate widened.
  if (!closed) return

  nonComment = 0; hasTodo = 0; hasTerm = 0; lastStmt = ""
  for (i = 1; i <= nbody; i++) {
    line = trim(body[i])
    if (line ~ /TODO|FIXME/) hasTodo = 1
    if (line == "" || line ~ /^\/\//) continue
    nonComment++
    lastStmt = line
    if (terminates(line)) hasTerm = 1
  }

  # ---- (b) TODO-IN-ERROR-BRANCH -------------------------------------------
  # Checked FIRST, and before the empty rule, because `if err != nil {
  # // TODO: handle this }` is both shapes at once and the TODO is the more
  # actionable of the two verdicts: it names what the author already knew.
  if (hasTodo) {
    report(start, "TODO-IN-ERROR-BRANCH",
           "TODO/FIXME inside an error branch -- the handler is documented as unfinished and nothing reads the note. Finish it, or file it in registries/contract-debt.yaml, where an expiry date makes it come back on its own")
    return
  }

  # ---- (a) EMPTY-ERROR-BRANCH ---------------------------------------------
  if (nonComment == 0) {
    report(start, "EMPTY-ERROR-BRANCH",
           "an error branch with no statements -- the error was detected, signalled, and then discarded. Yuan et al. (OSDI 2014): 92% of catastrophic failures begin in the handler, not in the detection")
    return
  }

  # ---- (c) LOG-AND-CONTINUE -----------------------------------------------
  # The enclosing function is the nearest preceding definition line; a closure
  # counts, because the closure is what owns the return.
  fline = ""
  for (fi = start; fi >= 1; fi--) if (is_func_line(buf[fi])) { fline = buf[fi]; break }
  if (fline == "") return
  if (!returns_error(fline)) return
  if (nonComment != 1) return
  if (hasTerm) return
  if (!is_log_call(lastStmt)) return
  report(start, "LOG-AND-CONTINUE",
         "the only statement in this error branch is a log call, and the enclosing function RETURNS ERROR -- it had a way to propagate and logged instead. Return the error (wrapped), or, if continuing really is correct, say why in the branch and let the second statement prove it was a decision")
}
' "${files[@]}" >"${report_file}"

findings=$(LC_ALL=C grep -c -E ': (EMPTY-ERROR-BRANCH|TODO-IN-ERROR-BRANCH|LOG-AND-CONTINUE): ' "${report_file}")

if ((findings > 0)); then
  cat "${report_file}" >&2
  printf '\nerror-handling-fitness: %d finding(s) across %d Go file(s).\n' "$findings" "${#files[@]}" >&2
  printf 'Each is one of the three shapes Yuan et al. (OSDI 2014) measured behind 35%% of catastrophic distributed-systems failures.\n' >&2
  exit 1
fi

printf 'error-handling-fitness: clean -- %d Go file(s), 0 empty / TODO / log-and-continue error branches.\n' "${#files[@]}"
