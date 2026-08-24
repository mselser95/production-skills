#!/usr/bin/env bash
# check-registries.sh — the liability registries' teeth.
#
# Four registries record live exceptions: waived obligations, feature flags,
# quarantined tests, contract-migration debt. Recording them is worthless
# without expiry enforcement: a waiver nobody revisits is a permanent silent
# exemption, which is how a "temporary" gate suppression becomes policy.
#
# This script fails when ANY entry's `expires:` date is in the past, naming the
# entry and its owner. Wire it into presubmit: at expiry the obligation returns
# to force and the build reddens on its own, with no human remembering to check.
#
#   check-registries.sh            fail on expired entries
#   check-registries.sh --warn     report but exit 0 (grace period)
#   check-registries.sh --soon N   also warn on entries expiring within N days
#
# `expires: never` is legal ONLY for permanent operational levers (a kill
# switch is not debt); every other value must be a YYYY-MM-DD date.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

# Overridable so scripts/tests/check-registries-selftest.sh can point this at
# a scratch directory of crafted fixture entries and run the REAL parser
# end-to-end, instead of re-implementing its logic (a selftest that
# reimplements the parser tests the copy, not the thing that runs). Absolute
# paths work regardless of the `cd` above; the default is unchanged.
registries_dir="${REGISTRIES_DIR:-registries}"

mode="fail"; soon_days=14
while (($#)); do
  case "$1" in
    --warn) mode="warn" ;;
    --soon) shift; soon_days="${1:-14}" ;;
  esac
  shift
done

today=$(date -u +%Y-%m-%d)
# epoch_utc_midnight <YYYY-MM-DD> -- print the UTC-midnight epoch for that date,
# or fail if the date is not real.
#
# Two implementations of date(1), one answer required. Beyond the time-of-day
# divergence explained at today_s, BSD date NORMALISES an impossible date --
# 2026-02-30 becomes 2026-03-02 -- so `2027-02-30` sailed through on macOS and
# failed on Linux. Rendering the parsed timestamp back to YYYY-MM-DD and
# requiring it to equal the input catches that on BOTH platforms, without
# needing to know which one is running.
epoch_utc_midnight() {
  local want="$1" secs back
  if secs=$(TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "${want} 00:00:00" +%s 2>/dev/null); then
    back=$(TZ=UTC date -j -f "%s" "$secs" +%Y-%m-%d 2>/dev/null)
  elif secs=$(date -u -d "${want} 00:00:00 UTC" +%s 2>/dev/null); then
    back=$(date -u -d "@${secs}" +%Y-%m-%d 2>/dev/null)
  else
    return 1
  fi
  [[ "$back" == "$want" ]] || return 1   # date(1) normalised an impossible date
  printf '%s' "$secs"
}

# UTC MIDNIGHT, not "now", and the expiry below is parsed the same way. Both
# halves matter and both were wrong.
#
# GNU `date -d 2026-08-18 +%s` returns that day's midnight; BSD
# `date -j -f "%Y-%m-%d"` fills H:M:S from the CURRENT time. So on the expiry
# day itself the same entry read EXPIRED on Linux (exit 1) and EXPIRING in 0d
# (exit 0) on macOS -- same input, opposite verdict, which is precisely what
# the comment below the shape gate says must not happen. Comparing two UTC
# midnights removes both the time-of-day and the local-timezone term.
today_s=$(epoch_utc_midnight "$(date -u +%Y-%m-%d)")
expired=0; soon=0; total=0; malformed=0

# Fail CLOSED when there is nothing to check. The loop below skips silently on
# a directory with no .yaml in it, so `registries: 0 entries checked` exited 0
# and DELETING the registries satisfied the gate -- the one outcome a liability
# registry exists to make impossible. Measured against a scratch empty
# directory before this guard: exit 0.
shopt -s nullglob
# `.yaml` AND `.yml`. A registry filed with the other extension was invisible
# to this gate: measured here, a waiver expiring 2026-01-02 named extra.yml
# gave "0 expired" and exit 0, while the SAME file renamed to .yaml gave exit
# 1. An expiry gate a file extension can hide from is the silent permanent
# exemption this script exists to refuse. (The probe's ratify-queue loop hit
# the same defect separately and already globs *.y*ml.)
registry_files=( "${registries_dir}"/*.yaml "${registries_dir}"/*.yml )
shopt -u nullglob
if (( ${#registry_files[@]} == 0 )); then
  echo "registries: NO registry files in '${registries_dir}' -- an empty registry set is not a clean one; deleting the registries must not pass this gate." >&2
  exit 1
fi

for reg in "${registry_files[@]}"; do
  [[ -f "$reg" ]] || continue
  # One entry per `- id:`; read its id, owner and expires with a tiny state machine
  # rather than a YAML dependency — this must run before anything is installed.
  id=""; owner=""; expires=""; in_entry=0
  seq_indent=""; seq_indent_set=""
  in_entries=0; entries_key_seen=0; saw_dash=0
  entries_key_re='^[[:space:]]*("entries"|'"'"'entries'"'"'|entries)[[:space:]]*:[[:space:]]*(#.*)?$'
  flush() {
    if [[ -z "$id" ]]; then
      # AN ENTRY WITH NO USABLE id IS REPORTED, NOT DISCARDED, and the reset
      # happens on this path too. The bare `[[ -z "$id" ]] && return` got both
      # wrong at once, and the second half is the one that bites:
      #
      #   - id:                      <- empty value
      #     owner: "@ghost"
      #     expires: 2099-12-31
      #   - id: heir                 <- no owner, no expires
      #
      # Measured before this fix: `1 entries checked, 0 expired, 0 expiring,
      # 0 malformed`. The first entry VANISHED -- never counted, never flagged
      # -- and `heir` passed CLEAN, inheriting the 2099 expiry, because the
      # early return skipped the reset at the bottom of this function. An entry
      # the gate cannot see is an exemption with no owner and no expiry, which
      # is the one thing these registries exist to make impossible. Found by
      # fd1az on binance-marketdata#24.
      #
      # in_entry separates "no entry has started yet" -- the first `- ` line,
      # and the call after the loop on an empty file -- from "an entry started
      # and produced no id". Only the second is a finding.
      if (( in_entry )); then
        echo "MALFORMED  ${reg}: an entry has an empty or missing id: — it cannot be cited, renewed or attributed" >&2
        total=$((total+1))
        malformed=$((malformed+1))
      fi
      owner=""; expires=""; in_entry=0
      return
    fi
    total=$((total+1))
    # The header documents `{id, owner, created, expires, evidence}` but only
    # `expires` was enforced -- an entry with NO owner counted as clean and the
    # summary said "0 malformed". A liability with no name on it is one nobody
    # carries. Measured: an owner-less entry passed.
    if [[ -z "$owner" ]]; then
      echo "MALFORMED  ${reg}: entry '${id}' has no owner: — an unowned liability is one nobody carries" >&2
      malformed=$((malformed+1))
    fi
    if [[ -z "$expires" ]]; then
      echo "MALFORMED  ${reg}: entry '${id}' has no expires: — every entry needs one ('never' only for permanent levers)" >&2
      malformed=$((malformed+1))
    elif [[ "$expires" != "never" ]]; then
      # Validate the SHAPE before handing it to date(1). GNU date happily parses
      # relative expressions -- "tomorrow", "next-tuesday", "+30 days" -- so on
      # Linux a waiver could carry `expires: tomorrow` and be recomputed as one
      # day away on every run: a waiver that never expires, which is exactly the
      # permanent silent exemption this registry exists to prevent. BSD date
      # rejects those, so the behaviour also differed by platform, and the gate
      # that decides whether an exception is still live must not depend on which
      # machine ran it. Found by the selftest on CI, passing on macOS.
      if [[ ! "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "MALFORMED  ${reg}: entry '${id}' has expires='${expires}' which is not YYYY-MM-DD" >&2
        malformed=$((malformed+1))
      elif ! exp_s=$(epoch_utc_midnight "$expires"); then
        echo "MALFORMED  ${reg}: entry '${id}' has expires='${expires}' which is not a real YYYY-MM-DD date" >&2
        malformed=$((malformed+1))
      elif (( exp_s < today_s )); then
        echo "EXPIRED    ${reg}: '${id}' expired ${expires} (owner: ${owner:-unassigned}) — the obligation is back in force" >&2
        expired=$((expired+1))
      elif (( (exp_s - today_s) / 86400 <= soon_days )); then
        echo "EXPIRING   ${reg}: '${id}' expires ${expires} in $(( (exp_s - today_s) / 86400 ))d (owner: ${owner:-unassigned})"
        soon=$((soon+1))
      fi
    fi
    id=""; owner=""; expires=""; in_entry=0
  }
  # A BLOCK SCALAR IS CONTENT, NOT STRUCTURE -- AND IT WAS READ AS BOTH.
  #
  # `evidence: |` (or `>`), with any chomping or indentation indicator, opens a
  # literal block: every line indented deeper than the key belongs to that
  # string. This parser walked those lines like any other. The key regexes
  # below are anchored at start-of-line, which makes them immune to a body line
  # CONTAINING "expires:" -- but not to one that STARTS with it.
  #
  # Both halves of the entry check were defeated by prose. Measured on this
  # exact script before the fix:
  #
  #   an entry with `expires: 2020-01-01` whose evidence block contains a line
  #   `expires: 2099-01-01` -> exit 0, "0 expired". A LIVE EXPIRED WAIVER
  #   PASSING THE BUILD. The same entry without the block -> exit 1.
  #
  #   an entry with no `owner:` whose evidence block contains
  #   `- owner: not-a-real-owner` -> exit 0. Without the block -> exit 1.
  #
  # Each key assignment overwrites, so the prose line does not merely add a
  # candidate, it REPLACES the real one. That is the direction that matters: a
  # registry gate whose expiry can be overruled by the text of the waiver it is
  # gating enforces nothing at all.
  #
  # Reported by agatticelli (:191/:193) and independently by fd1az (:201).
  blk_indent=""
  in_blk=0
  # PERMISSIVE ON PURPOSE, and this is the third widening -- which is the
  # argument for stopping the enumeration entirely.
  #
  # Every previous version named the shapes a key may take, and every one of
  # them fails OPEN on a shape nobody thought of: an unrecognised header is not
  # skipped, it is WALKED, so its prose is read as keys and a body line reading
  # `expires: 2099-01-01` REPLACES the real expiry (last assignment wins) and an
  # expired waiver exits 0. The list of spellings that defeated the previous
  # classes, each measured: `2fa_evidence:` (leading digit), `ops/evidence:`
  # (slash), `"evidence":` and `'evidence':` (quoted), then `ops evidence:`,
  # `"ops evidence":` and `"a:b":` (whitespace and a colon INSIDE a quoted key).
  #
  # So the key half stops being an allowlist. A block header is "anything, then
  # a colon, then the indicator, then end of line" -- which is what YAML
  # actually says. Verified NOT to over-match the plausible false positives:
  # `note: see foo | bar`, `url: https://x.com/a|b` and `plain: value` are all
  # rejected, because after the colon the indicator must be the last token.
  #
  # THE COLON IS OPTIONAL, because YAML does not require it. The comment above
  # used to say a block header is "anything, then a colon, then the indicator"
  # and call that "what YAML actually says" -- it is not. A block scalar is
  # also legal as a SEQUENCE ITEM (`- |`), with no key and no colon at all.
  # Since the regex demanded one, that spelling went unrecognised, and by this
  # file's own rule an unrecognised header is WALKED. Measured on an entry
  # expired in 2020 whose evidence is a list of block scalars carrying a prose
  # `expires: 2099-01-01`: exit 0, `0 expired`. Reported by agatticelli.
  #
  # NODE PROPERTIES SIT BETWEEN THE COLON AND THE INDICATOR. YAML lets a node
  # carry an anchor and/or a tag before its content, and a block scalar is a
  # node like any other:
  #
  #   evidence: &ancla |        evidence: !!str |        evidence: &a !!str |
  #
  # All three parse, and all three went unrecognised because the keyed branch
  # allowed only whitespace after the colon -- so the property sat exactly where
  # the indicator had to be. Measured on an entry expired in 2020 whose block
  # carries a prose `expires: 2099-01-01`: exit 0, `0 expired`, all three.
  # Reported by fd1az.
  #
  # The capture indices matter and are deliberately preserved: [1] is still the
  # whole prefix, [2] the `- `, [3] the key -- the block-column logic below
  # reads all three, and inserting a group before them would silently shift it.
  blk_open_re='^([[:space:]]*(-[[:space:]]+)*)(.*:[[:space:]]*)?((&[^[:space:]]+|![^[:space:]]*)[[:space:]]+)*[|>]([0-9]+[+-]?|[+-][0-9]*)?[[:space:]]*(#.*)?$'
  # `|| [ -n "$line" ]` KEEPS A FINAL LINE WITH NO TRAILING NEWLINE. `read`
  # returns non-zero when it hits EOF without a delimiter, so a file whose last
  # byte is not `\n` loses that line entirely -- and the last line of a
  # registry is usually the last entry's `expires:`. Measured on a file ending
  # `  - id: ghost` with no newline: `0 entries checked` against `1 entry,
  # 2 malformed` for the same bytes plus one. One byte at EOF decided whether
  # the gate saw an entry at all.
  #
  # Not introduced here -- `main` behaves the same -- but a parser this file
  # spent a day making fail-closed should not lose an entry to a missing byte.
  # Reported by fd1az.
  while IFS= read -r line || [ -n "$line" ]; do
    # A TAB IN THE INDENTATION IS A MALFORMED FILE, NOT A DEEPER COLUMN.
    #
    # YAML excludes tabs from indentation outright, so this is not a style
    # rule. It has to be handled here because the block-body test below
    # compares indent WIDTHS in characters: a tab counts as one character but
    # stands for a deeper column, so a tab-indented body measures as NARROWER
    # than the key that opened it, ends the block early, and its prose is read
    # as keys again -- measured exit 0, "0 expired", on a live expired waiver.
    # Reported by agatticelli.
    #
    # Rejecting is the honest fix. Expanding tabs would mean inventing a tab
    # width the format does not define, and any width chosen is a guess that
    # decides whether a waiver is enforced.
    #
    # KNOWN OVER-REJECTION, stated rather than discovered later. The test is
    # "the run of leading whitespace contains a tab", which also catches a
    # block-scalar CONTENT line whose first character after a space indent is a
    # tab -- there the tab is content and the file is legal. Measured both
    # sides: `      col1<TAB>col2` is NOT flagged (the tab follows a non-space,
    # so it is plainly content), `      <TAB>sangrado` IS. That is the
    # fail-CLOSED direction and the message names the exact line, so the fix is
    # obvious to whoever hits it; the alternative error is a waiver that
    # expired years ago exiting 0.
    if [[ "$line" == *$'\t'* && "$line" =~ ^[[:space:]]*$'\t' ]]; then
      # >&2 LIKE EVERY OTHER DIAGNOSTIC. This was the only one on stdout, where
      # stdout carries the machine-readable summary and stderr carries the
      # findings -- so a consumer reading stderr, which is where this script
      # puts everything it wants a human to act on, would not see it at all.
      # Reported by fd1az.
      echo "MALFORMED  ${reg}: tab used for indentation (YAML forbids it); the line is: ${line}" >&2
      malformed=$((malformed+1))
      continue
    fi
    # Inside a block: blank lines stay in, and so does anything indented deeper
    # than the key that opened it. The first line at or left of that column
    # ends the block and is re-examined as structure below.
    if (( in_blk )); then
      if [[ -z "${line//[[:space:]]/}" ]]; then continue; fi
      [[ "$line" =~ ^([[:space:]]*) ]]; _cur="${BASH_REMATCH[1]}"
      if (( ${#_cur} > ${#blk_indent} )); then continue; fi
      blk_indent=""; in_blk=0
    fi
    # A new entry starts at ANY top-level list-item dash ("- <key>: ..."),
    # not specifically "- id:". Flushing only on "- id:" made an entry whose
    # `id:` is written on a later, non-dashed continuation line (e.g. owner
    # or expires listed first) invisible: that continuation line never
    # matched "- id:" so `id` was never captured, and flush() discards any
    # entry with an empty id -- silently unenforced, key order dependent.
    # AN ENTRY BOUNDARY IS A TOP-LEVEL SEQUENCE ITEM, not any dashed line.
    #
    # The test used to be `^[[:space:]]*-[[:space:]]` at ANY indentation, which
    # was harmless while an id-less flush returned silently. Once flush started
    # REPORTING an id-less entry, every nested list item and every dashed line
    # inside a literal block began opening an entry that then had to produce an
    # `id:` -- so one legal entry with `tags:` and an `evidence: |` block was
    # reported as FIVE, four of them malformed, and the message sent the reader
    # hunting for an id-less entry that does not exist. Measured by fd1az; I
    # introduced it in the same commit that fixed the silent-skip.
    #
    # The indentation of the FIRST dashed line in the file is the sequence's
    # level; anything deeper belongs to the entry, not beside it. Derived per
    # file rather than assumed, because these four registries are hand-written
    # and nothing forces them to agree on two spaces.
    # ONLY A DASH INSIDE `entries:` IS AN ENTRY BOUNDARY.
    #
    # The latch used to take the indentation of the FIRST dashed line anywhere
    # in the file and then require exact equality. An ordinary metadata list
    # ahead of `entries:` therefore latched the wrong column, after which no
    # boundary ever fired again and the whole file collapsed into ONE entry
    # with last-assignment-wins. Measured on valid YAML that yaml.safe_load
    # reads as two entries:
    #
    #   metadata:
    #     owners:
    #       - alice          <- latches column 4
    #   entries:
    #     - id: x            <- column 2, never flushes
    #       expires: 2020-01-01
    #     - id: y
    #       expires: 2099-01-01
    #
    #   -> `1 entries checked, 0 expired`, exit 0. Entry `x` is not reported,
    #      not counted and not flagged: an EXPIRED WAIVER PASSING THE BUILD,
    #      i.e. the exact fail-open this file exists to close, reintroduced by
    #      the boundary rewrite itself. Reported by fd1az.
    #
    # Accepting "any dash at or left of the latch" was the other candidate and
    # it is not enough: a metadata dash at column 0 ahead of `entries:` puts
    # every entry dash to its RIGHT and reproduces the same collapse mirrored.
    # What actually distinguishes an entry boundary is not its column but WHERE
    # IT SITS, so track the block instead of guessing from indentation.
    # THE KEY MATCHER IS TOLERANT, AND WHAT BACKS IT IS THE FAIL-CLOSED GUARD
    # BELOW -- not this pattern.
    #
    # Written first as the exact string `^entries:`, one screen below the
    # lesson that a key class cannot be an exact-string list. It missed
    # `"entries":`, `entries :` (space before the colon), a nested
    # `  entries:`, and a registry written as a bare top-level sequence with no
    # `entries:` key at all. Measured on two-entry files whose FIRST entry
    # expired in 2020: all four gave exit 0, `1 entries checked, 0 expired` --
    # the expired entry vanished and the gate passed. Reported by fd1az.
    #
    # A single-entry file hides this: the pending entry is flushed at EOF
    # regardless, so only a file with a SECOND entry shows the first being
    # swallowed. My first reproduction used one entry and reported "does not
    # reproduce", which was my fixture and not the finding.
    # THE PATTERN LIVES IN A VARIABLE. Inside `[[ =~ ]]` bash consumes quote
    # characters as quoting, so writing `("entries"|'entries'|entries)` inline
    # collapses to `(entries|entries|entries)` and the quoted spellings never
    # match -- silently, with the regex looking correct in the source. This
    # file already records the same trap for `[|>]`; a variable is the fix
    # there and here.
    if [[ "$line" =~ $entries_key_re ]]; then
      in_entries=1; entries_key_seen=1
    elif [[ "$line" =~ ^[^[:space:]#] ]] && ! [[ "$line" =~ ^-([[:space:]]|$) ]]; then
      # A SEQUENCE ITEM AT COLUMN 0 IS NOT "ANOTHER TOP-LEVEL KEY". YAML lets a
      # sequence sit at the same indentation as the key that owns it, and that
      # is not exotic -- it is what `yaml.dump(default_flow_style=False)`,
      # `yq` and `js-yaml` all emit:
      #
      #   entries:
      #   - id: expired-one
      #     expires: 2020-01-01
      #   - id: fine
      #     expires: 2099-01-01
      #
      # Without the exclusion the FIRST `- id:` matched `^[^[:space:]#]`, closed
      # the entries list on the very first entry, and the guard below never
      # fired again: exit 0, `1 entries checked, 0 expired`, against the
      # pre-guard parser's exit 1 and `2 entries, 1 expired`. Reported by
      # fd1az -- the third time closing one fail-open opened another, and the
      # first that triggers on the output of the standard serializer.
      # any other top-level key ends the list; close the open entry with it
      if (( in_entries )); then flush; fi
      in_entries=0
    fi
    [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]] && saw_dash=1
    if (( in_entries )) && [[ "$line" =~ ^([[:space:]]*)-[[:space:]] ]]; then
      _ind="${BASH_REMATCH[1]}"
      if [[ -z "$seq_indent_set" ]]; then
        seq_indent="$_ind"; seq_indent_set=1
      fi
      if [[ "$_ind" == "$seq_indent" ]]; then
        flush
        # AFTER the flush: this line opens a new entry, so from here on an
        # empty id is a finding rather than "nothing has started yet".
        in_entry=1
      fi
    fi
      # THE BLOCK OPENER IS CHECKED AFTER THE ENTRY BOUNDARY, BECAUSE ONE LINE
      # CAN BE BOTH.
      #
      # `- evidence: |` opens an entry AND opens a block. With the opener first
      # its `continue` jumped over the flush above, so the PREVIOUS entry was
      # never closed and its expiry vanished: an expired waiver followed by an
      # entry whose first key is a block scalar reported `1 entries checked,
      # 0 expired` and exit 0, where the unpatched parser reports `2 entries
      # checked, 1 expired` and exit 1. That is the same fail-open the guard was
      # added to close, reintroduced by the guard itself. Found by fd1az on
      # clcsolutions/marketdata#35.
      #
      # `in_blk` is a separate flag rather than `[[ -n "$blk_indent" ]]` because
      # an empty indent is a legal block column -- a top-level `policy: |` opens
      # at column 0 -- and overloading empty as "no block" left its body walked
      # as keys.
      # TEST THE OPENER ON THE LINE WITHOUT ITS TRAILING COMMENT.
    #
    # `.*:` spans the whole line, so ANY line whose last token is the indicator
    # immediately after a colon reads as an opener -- including when that colon
    # lives inside a `#` comment. Measured:
    #
    #   expires: 2020-01-01   # ver nota: |
    #
    # was taken as a block header, so the line `continue`d past the id/owner/
    # expires capture below and the entry was reported `has no expires:` --
    # a VALID entry declared MALFORMED, and its real expiry never evaluated.
    # The permissiveness was verified against VALUES (`note: see foo | bar`,
    # `url: ...a|b`) and never against comments. Reported by agatticelli.
    #
    # A YAML comment starts at a `#` preceded by whitespace or start-of-line,
    # so cutting there is safe for this test: a genuine header (`evidence: |`,
    # `evidence: | # why`) is unchanged, and a `#` inside a quoted VALUE only
    # ever truncates a line that was not an opener to begin with. The cut is
    # used for the TEST only -- `$line` itself is untouched, because the body
    # of a literal block keeps its `#` characters verbatim.
    # A LINE THAT IS ENTIRELY A COMMENT IS NEVER AN OPENER, and this is the
    # third over-match the widened key found. `.*` before the colon accepts
    # anything -- including a `#` -- so
    #
    #   # see: |
    #
    # matched, and at column 0 it set `blk_indent=""`, which swallows every
    # following indented line as block body: the rest of the FILE. Measured on
    # valid YAML with two entries, one expired in 2020:
    #
    #   parent      -> exit 1, `2 entries checked, 1 expired`
    #   with the widening -> exit 0, `1 entries checked, 0 expired`
    #
    # The trailing-comment strip below does not catch it: that cuts at a `#`
    # preceded by whitespace, and a line that STARTS with `#` has none.
    # Reported by agatticelli.
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    _uncommented="$line"
    if [[ "$_uncommented" =~ ^(.*[[:space:]])#.*$ ]]; then _uncommented="${BASH_REMATCH[1]}"; fi
    if [[ "$_uncommented" =~ $blk_open_re ]]; then
        # WHICH COLUMN THE BODY MUST BEAT depends on whether the header has a
        # key, and getting it wrong makes the fix for `- |` do nothing.
        #
        #   `  - evidence: |`  the body must beat the KEY's column (4), because
        #                      a sibling `    owner:` at 4 has to END the block;
        #                      measuring from the dash (2) would swallow it.
        #   `      - |`        there is no key, so the body must beat the DASH's
        #                      column (6). Measuring from past the dash (8) puts
        #                      a body at 8 level with the header, the block ends
        #                      immediately, and its prose is walked as keys --
        #                      which is exactly the fail-open this is closing.
        #
        # [1] is the whole prefix, [2] is the `- ` (empty when there is none)
        # and [3] is the key (empty for a bare sequence item).
        if [[ -z "${BASH_REMATCH[3]}" && -n "${BASH_REMATCH[2]}" ]]; then
          blk_indent="${BASH_REMATCH[1]%"${BASH_REMATCH[2]}"}"
        else
          blk_indent="${BASH_REMATCH[1]}"
        fi
        in_blk=1
        continue
      fi
    # id/owner/expires are matched by an ANCHORED key regex (start of line,
    # optional leading "- ", then the exact key), not a bare substring —
    # so they are captured no matter which position in the entry they
    # appear at, and are immune to a body-text line that happens to contain
    # "id:"/"owner:"/"expires:" as a substring of a longer word.
    if [[ "$line" =~ ^[[:space:]]*-?[[:space:]]*id:[[:space:]]*(.*)$ ]]; then
      id="${BASH_REMATCH[1]}"; id="${id%%#*}"; id="${id// /}"
    elif [[ "$line" =~ ^[[:space:]]*-?[[:space:]]*owner:[[:space:]]*(.*)$ ]]; then
      owner="${BASH_REMATCH[1]}"; owner="${owner%%#*}"; owner="${owner// /}"
    elif [[ "$line" =~ ^[[:space:]]*-?[[:space:]]*expires:[[:space:]]*(.*)$ ]]; then
      expires="${BASH_REMATCH[1]}"; expires="${expires%%#*}"; expires="${expires// /}"
    fi
  done < "$reg"
  flush
  # A FILE THE TRACKER COULD NOT PARSE IS NOT A FILE THAT PASSED.
  #
  # The `entries:` matcher is tolerant now, but tolerance is an enumeration and
  # this is the SEVENTH hole found in one -- so what backs it is this guard, not
  # the pattern. If a file has dashed lines and the tracker never found its key,
  # the shape is outside the format this script parses, and the honest answer to
  # an out-of-contract registry is MALFORMED, never exit 0. Measured before the
  # guard on a registry written as a bare top-level sequence (no `entries:` at
  # all, two entries, the first expired in 2020): exit 0, `1 entries checked,
  # 0 expired` -- the expired entry gone and the gate green.
  #
  # This file already applies exactly this discipline twice: the empty-directory
  # guard and the `total == 0` guard. Reported by fd1az, who also named the
  # principle: a file the tracker cannot parse is a file it silently passes,
  # which is the one outcome this script exists to make impossible.
  if (( saw_dash )) && ! (( entries_key_seen )); then
    echo "MALFORMED  ${reg}: has list items but no \`entries:\` key the parser can find — the file is outside the format this gate reads, so nothing in it is enforced" >&2
    malformed=$((malformed+1))
  fi
done

echo "registries: ${total} entries checked, ${expired} expired, ${soon} expiring within ${soon_days}d, ${malformed} malformed"
# total == 0 is a FAIL, not a clean run.
#
# The empty-DIRECTORY case was already fail-closed; this is the same hole one
# step in: a directory whose files yield no entries -- a glob that matches
# nothing useful, a truncating merge, a REGISTRIES_DIR override pointing
# somewhere harmless -- printed "0 entries checked, 0 expired" and exited 0,
# after which verify-standard recorded
# `registries-expiry-gated PASS "0 entries checked; expiry gates the build"`.
# A gate reporting that it gates the build while enforcing nothing is the exact
# shape this change hard-failed one directory over (require_floors_file) and
# inside the probe itself (nv_total == 0). This gate was the outlier.
if (( total == 0 )); then
  echo "MALFORMED  no entries found in ${REGISTRIES_DIR:-registries/} — a registry gate that checks zero entries reports green while enforcing nothing" >&2
  exit 1
fi

if (( expired > 0 || malformed > 0 )); then
  if [[ "$mode" == "warn" ]]; then
    echo "(--warn: reporting only. Remove --warn to make expiry gate the build.)"
    exit 0
  fi
  # SAY WHICH OF THE TWO FIRED. This branch is `expired > 0 || malformed > 0`
  # and it printed the expiry sentence either way, so a run that failed purely
  # on a malformed file reported a reason that had not happened. That was
  # tolerable while malformed was rare; the tab guard above makes
  # malformed-only a routine outcome, so the message would now be wrong more
  # often than right. A gate that names the wrong cause is one people learn to
  # read past.
  if (( expired > 0 )); then
    echo "An expired waiver is a silent permanent exemption. Renew it with a reason, or meet the obligation." >&2
  fi
  if (( malformed > 0 )); then
    echo "A malformed entry is an unenforceable one: the parser could not read its expiry, so nothing gates it." >&2
  fi
  exit 1
fi
exit 0
