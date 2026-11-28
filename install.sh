#!/usr/bin/env bash
# install.sh — install the prod-* skills as a HASH-VERIFIED COPY, not a symlink.
#
# Why not symlinks: the framework declares skill definitions part of the trusted
# computing base, but a symlinked install means any agent with write access edits
# the live TCB in place, and branch protection is unavailable on a private repo
# without a paid plan. A copy + a recorded manifest of hashes gives a mechanical
# check that survives both: `install.sh --verify` fails if an installed skill,
# shared format, policy file or agent definition no longer matches what was
# installed, whatever changed it.
#
#   install.sh            install/update the copy and (re)write the manifest
#   install.sh --verify   compare the installed tree against the manifest
#   install.sh --diff     show what drifted
#   install.sh --host claude|codex|both   which host to install/verify for
#                         (default claude: byte-for-byte the historical behaviour).
#                         Codex: skills + generated role files under $CODEX_HOME
#                         (default ~/.codex); see _shared/hosts.md for what is
#                         VERIFIED, UNVERIFIED and DEGRADED there.
#   install.sh --adopt    Codex only: replace destinations that are not ours after
#                         moving each under <cfg>/.prod-backups/<UTC timestamp>-<random>/
#                         (outside skills/ and agents/; ignored for claude).
#
# Exit non-zero on verification failure, so it can gate a session or a cron.
# The code says WHICH failure, because the three call for different actions:
#   1  TCB DRIFT     — installed contents differ from the manifest (tamper)
#   2  STALE INSTALL — manifest intact, but describes an OLDER source (reinstall)
#   3  TCB WRITABLE  — contents correct, read-only guard missing (reinstall)
# Install-time refusals and failures (new; verify never returns these):
#   4  DESTINATION IS A SYMLINK  (Codex tree: skills/, agents/, a skill dir, a role file, the manifest)
#   5  NOT OURS      — a Codex destination exists and the previous manifest does not list it
#                      (--adopt moves it under <cfg>/.prod-backups/, never deletes it)
#   6  LOCKED        — <config root>/.prod-skills.lock exists (live owner, dead owner, or unreadable:
#                      the message says which and how to remove it; it is never stolen)
#   7  STEP FAILED   — a copy/move/chmod failed, or a directory/the lock/the private work
#                      directory could not be created; the host's tree is rolled back, no manifest written
#   129/130/143 HUP/INT/TERM — the commit finished or rolled back first; never half-installed
#   (a refused role file / dangling source symlink / bad TOML exits 1)

set -uo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: install.sh [--verify|--diff] [--host claude|codex|both] [--adopt]" >&2; exit 2; }
host=claude; mode=""; adopt=0
while (( $# )); do
  case "$1" in
    --host)   [[ $# -ge 2 ]] || usage; host="$2"; shift 2 ;;
    --host=*) host="${1#--host=}"; shift ;;
    --adopt)  adopt=1; shift ;;
    *)        [[ -n "$mode" ]] || mode="$1"; shift ;;
  esac
done
mode="${mode:-install}"
case "$host" in
  claude) hosts=(claude) ;;
  codex)  hosts=(codex) ;;
  both)   hosts=(claude codex) ;;
  *) echo "install.sh: unknown host '$host' (want claude, codex or both)" >&2; usage ;;
esac

# Per-host roots. cfg is the host's config root; agent_glob is what OUR agent
# definitions look like there, so the write-guard and the Codex manifest touch
# only prod-* files and never a user's own roles.
set_host() {
  cur_host="$1"
  case "$1" in
    claude) cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; agent_glob='prod-*.md' ;;
    codex)  cfg="${CODEX_HOME:-$HOME/.codex}";         agent_glob='prod-*.toml' ;;
  esac
  manifest="$cfg/prod-skills.manifest"
}
# The agents half of the trusted set. Claude hashes the whole agents/ dir (as it
# always did); Codex hashes only our generated prod-*.toml.
agents_hash() {
  if [[ "$cur_host" == claude ]]; then hash_tree "$cfg/agents" . 2>/dev/null
  else hash_tree "$cfg/agents" . -maxdepth 1 -name "$agent_glob" 2>/dev/null; fi
}
# prod-new belongs here like every other skill. It was previously symlinked into
# the config dir by hand, which put it OUTSIDE the manifest entirely: --verify
# reported the whole trusted set as intact while the skill that scaffolds brand
# new repositories sat unhashed and unverified next to it. A skill absent from
# this array is a skill nothing protects.
skills=(prod-spec prod-review prod-incident prod-implement prod-test-synth prod-ops prod-curate prod-bootstrap prod-new)

hash_tree() { # print "<sha256>  <relative path>" for every tracked TCB file
  local base="$1"; shift
  # EVERY regular file, not just *.md/*.yaml/*.sh. prod-new ships a template/
  # tree of Go sources, a Dockerfile, a Makefile and workflows that get copied
  # verbatim into new repositories -- tampering there injects code into every
  # repo the skill ever scaffolds, and the old extension filter did not hash a
  # single one of them.
  #
  # benchmark-results/ is the ONE exclusion beyond config.sh, and it is not a
  # convenience. It holds skill-optimizer's generated scores -- output, not
  # source. Measured 2026-08-29: 179 of the 486 files in the local manifest
  # were benchmark output, and creating a single new result file made
  # `--verify` report STALE INSTALL. Running the SIGNAL tool that README tells
  # people to run therefore set off the INTEGRITY alarm. A gate that fires on a
  # legitimate, encouraged action is the gate that gets ignored, then widened,
  # then removed, and it takes the real alarms with it.
  #
  # It also made the trusted set machine-dependent: 486 files on a laptop that
  # had run benchmarks, 307 in CI on a clean checkout, for identical source.
  # Nothing is lost by excluding it -- the frozen task set and config in
  # .skill-optimizer/ ARE still hashed, and those are the reviewed inputs that
  # decide what a benchmark measures. Scores are not something tampering with
  # would compromise a skill; they are re-derived by the next run.
  ( cd "$base" && find "$@" -type f ! -name 'config.sh' \
      ! -path '*/benchmark-results/*' -print0 2>/dev/null \
      | sort -z | xargs -0 shasum -a 256 )
}


# --- Codex role files, generated from agents/*.md ---------------------------
#
# Codex does not read agents/*.md. Each prod-* agent becomes <codex home>/agents/<name>.toml
# with keys name, description, developer_instructions (+ model when asked for); other
# agents/*.md are NOT installed for Codex. Strings are TOML basic strings with every
# control character escaped; the source must be valid UTF-8 without NUL (valid_utf8,
# has_nul), which makes the escaper total, and each file is parse-checked
# (toml_check_all) when python3 has tomllib.
# This block sits BEFORE verify_host on purpose: `--verify --host codex` REGENERATES
# every role from the current source with the very same function and compares hashes.
# Location and keys are UNVERIFIED against the binary (see _shared/hosts.md).
#
# model: Claude names (sonnet/opus/haiku) have no VERIFIED Codex equivalent, so
# `model` is OMITTED (the role inherits) unless PROD_CODEX_MODEL_<ROLE> is set,
# <ROLE> = agent name without the prod- prefix, upper-cased, - as _. Verify must run
# with the same variables as the install, or the regenerated role differs (STALE).
#
# tools: has no Codex equivalent. The restriction is restated in WORDS at the end
# of developer_instructions, derived from the tools list; a role with NO tools line
# says it declares no restriction (on Claude Code that means "inherits everything").
# DEGRADED: instruction-only until a hook enforces it.
fm_field() { # fm_field <file> <key> -> value, folded scalars joined by spaces
  LC_ALL=C awk -v k="$2" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    !infm { next }
    $0 ~ "^" k ":" { cap=1; v=$0; sub("^" k ":[ \t]*","",v); if (v ~ /^[>|][-+]?$/) v=""; out=v; next }
    cap && /^[ \t]/ { l=$0; gsub(/^[ \t]+/,"",l); out = (out=="" ? l : out " " l); next }
    cap { cap=0 }
    END { print out }' "$1"
}
fm_fields() { # name, description, tools: one per line
  local k
  for k in name description tools; do fm_field "$1" "$k"; done
}
role_body() { LC_ALL=C awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {fm=0; c=1; next} c' "$1"; }
valid_role_name() { [[ "$1" =~ ^[a-z][a-z0-9-]*$ && "$1" == "$2" ]]; } # valid_role_name <name> <file basename>
has_nul() { ! LC_ALL=C tr -d '\000' <"$1" | cmp -s - "$1"; }
# Strict UTF-8 check of the whole source file (name, description, tools and body).
# iconv rejects invalid bytes, overlongs and surrogates; python3's decoder is the
# fallback; with neither, the file is refused (never written unvalidated).
valid_utf8() {
  if command -v iconv >/dev/null 2>&1; then iconv -f UTF-8 -t UTF-8 <"$1" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then python3 -I -c 'import sys; open(sys.argv[1], "rb").read().decode("utf-8")' "$1" 2>/dev/null
  else return 1; fi
}
# stdin text -> the inside of a TOML BASIC string. Every backslash, quote and
# control character (0x01-0x1f, 0x7f) is escaped; newlines become \n. For valid
# UTF-8 input nothing is un-representable (bytes >= 0x80 pass through; TOML allows
# them), so there is no ''' refusal. A line with nothing to escape skips the per-
# character loop (a 2 MB body is mostly such lines).
toml_esc() {
  LC_ALL=C awk 'BEGIN { for (i = 1; i < 32; i++) c[sprintf("%c", i)] = sprintf("\\u%04X", i); c[sprintf("%c", 127)] = "\\u007F"
        bad = "[\\\\\"" sprintf("%c-%c", 1, 31) sprintf("%c", 127) "]" }
    { s = $0; o = s
      if (s ~ bad) { o = ""; n = length(s)
        for (i = 1; i <= n; i++) { ch = substr(s, i, 1)
          if (ch == "\\") o = o "\\\\"; else if (ch == "\"") o = o "\\\""; else if (ch in c) o = o c[ch]; else o = o ch } }
      printf "%s%s", (NR > 1 ? "\\n" : ""), o }'
}
# Parse every generated file ONCE and compare name / description /
# developer_instructions (/ model) with the intended values. The intended values
# travel in FILES under the private work directory ($1/index: "n<TAB>toml<TAB>name<TAB>model",
# $1/n.desc, $1/n.instr), never through argv: a 2 MB role body would hit "Argument
# list too long". Returns 0 ok, 1 mismatch or parse error, 3 when no tomllib is
# available (python3 < 3.11 or absent): then the files rest on valid_utf8 + toml_esc,
# which the selftest proves by a round trip through a strict reader of exactly the
# subset the generator emits.
toml_check_all() { # toml_check_all <chk dir>
  [[ -s "$1/index" ]] || return 0
  python3 -I -c 'import tomllib' 2>/dev/null || return 3
  python3 -I - "$1" <<'PY'
import sys, os, tomllib
d = sys.argv[1]
bad = 0
for line in open(os.path.join(d, 'index'), encoding='utf-8'):
    n, f, name, model = line.rstrip('\n').split('\t')
    try:
        got = tomllib.loads(open(f, 'rb').read().decode('utf-8'))
    except Exception as e:
        print('install: %s: parse error: %s' % (f, e), file=sys.stderr); bad = 1; continue
    rd = lambda ext: open(os.path.join(d, n + ext), 'rb').read().decode('utf-8')
    want = {'name': name, 'description': rd('.desc'), 'developer_instructions': rd('.instr')}
    if model: want['model'] = model
    if got != want:
        print('install: %s: round-trip mismatch on %s' % (f, sorted(k for k in set(got) | set(want) if got.get(k) != want.get(k))), file=sys.stderr); bad = 1
sys.exit(bad)
PY
}
chk_dir=""; chk_n=0   # set by install_host only; empty while verifying (no sidecar files then)
gen_codex_role() { # gen_codex_role <agents/x.md> <out file>   (queues the parse check when chk_dir is set)
  local f="$1" out="$2" name desc tools model_var model body restr="" restline instr bf="${1##*/}"; bf="${bf%.md}"
  if has_nul "$f"; then echo "install: $f contains a NUL byte; refused" >&2; return 1; fi
  valid_utf8 "$f" || { echo "install: $f is not valid UTF-8 (or cannot be checked); refused, nothing written" >&2; return 1; }
  { IFS= read -r name; IFS= read -r desc; IFS= read -r tools; } < <(fm_fields "$f")
  [[ -n "$name" && -n "$desc" ]] || { echo "install: $f has no name/description frontmatter" >&2; return 1; }
  valid_role_name "$name" "$bf" || { echo "install: $f: name '$name' must match ^[a-z][a-z0-9-]*\$ and equal the file name" >&2; return 1; }
  body="$(role_body "$f")"
  if [[ -z "$tools" ]]; then
    restline="This role declares no tool restriction (on Claude Code a role without a tools line inherits every tool of the session); none is restated here."
  else
    case ", $tools," in *", Edit,"*|*", Write,"*) ;; *)
      restr="$restr You must not edit, create or delete files; use shell commands only to read, search and run the gates (a temporary mutation that your instructions above tell you to revert before finishing is the only exception)." ;;
    esac
    case ", $tools," in *", Bash,"*) ;; *) restr="$restr You must not run shell commands." ;; esac
    case ", $tools," in *", Agent,"*|*", Task,"*) ;; *) restr="$restr You must not spawn other agents." ;; esac
    restline="The tool allow-list of this role ($tools) cannot be enforced by this host, so it is stated here and you are bound by it.$restr"
  fi
  instr="${body}"$'\n\n## Host restrictions (Codex)\n'"$restline"
  model_var="PROD_CODEX_MODEL_$(printf '%s' "${name#prod-}" | tr 'a-z-' 'A-Z_')"
  model="${!model_var:-}"
  if [[ -n "$model" ]]; then
    [[ "$model" =~ ^[A-Za-z0-9._:/-]+$ ]] || { echo "install: $model_var has characters outside [A-Za-z0-9._:/-]" >&2; return 1; }
  fi
  {
    printf 'name = "%s"\n' "$name"                    # validated: [a-z][a-z0-9-]*, nothing to escape
    printf 'description = "%s"\n' "$(printf '%s' "$desc" | toml_esc)"
    [[ -z "$model" ]] || printf 'model = "%s"\n' "$model"
    printf 'developer_instructions = "%s"\n' "$(printf '%s' "$instr" | toml_esc)"
  } > "$out" || return 1
  if [[ -n "$chk_dir" ]]; then
    chk_n=$((chk_n+1))
    printf '%s' "$desc" > "$chk_dir/$chk_n.desc" && printf '%s' "$instr" > "$chk_dir/$chk_n.instr" \
      && printf '%s\t%s\t%s\t%s\n' "$chk_n" "$out" "$name" "$model" >> "$chk_dir/index" || return 1
  fi
}


verify_host() {
    [[ -f "$manifest" ]] || { echo "no manifest at $manifest — run install.sh first" >&2; exit 1; }
    current=$(hash_tree "$cfg/skills" "${skills[@]}"; agents_hash)
    if diff -q <(sort "$manifest") <(echo "$current" | sort) >/dev/null; then
      echo "TCB verified: $(wc -l <"$manifest" | tr -d ' ') files match the manifest"
      # Integrity is not currency. The check above answers "has the INSTALLED
      # copy been altered", which is the tamper question — but a clean answer
      # there says nothing about whether the installed copy is the CURRENT one.
      # Fix a probe in this repo, forget to reinstall, and every skill keeps
      # running the old probe while --verify reports a spotless TCB. That is a
      # false all-clear about the very component that decides what passes, so
      # it is reported here rather than left for someone to notice.
      # Report the NAMES, not just a count. The drift branch twenty lines below
      # already prints every affected path; this branch printed a bare number,
      # so the same question -- "what is untrusted right now?" -- got a strictly
      # worse answer depending on which way the tree happened to be wrong. And a
      # count cannot be acted on: "2 source file(s)" reads identically whether
      # the pair is two READMEs or verify-standard.sh plus the tier policy, so
      # the operator has to redo this comm by hand to learn which it was.
      # Measured 2026-08-29: the two were prod-ops/SKILL.md and
      # prod-curate/SKILL.md, and naming them is precisely what showed the cause
      # was a single commit that never got reinstalled.
      #
      # PATH-AWARE since the review of the hosts change: the comparison is over
      # (hash, path) ROWS, not hashes alone. Hash-only said "verified" over a tree
      # with a file at the wrong place or a missing top-level SKILL.md (a nested
      # copy, or two interleaved installs). Every row the SOURCE would install
      # must be in the manifest at that path with that hash (else STALE), and the
      # manifest's skill rows must be exactly those (an extra path is STALE too).
      # -L is load-bearing: the shared material reaches each skill through a
      # references/ SYMLINK, and plain `find -type f` would skip it, blinding this
      # check to _shared/. Same file set as hash_tree: every regular file.
      have=(); for s in "${skills[@]}"; do [[ -d "$src/$s" ]] && have+=("$s"); done
      exp_rows=$( (( ${#have[@]} )) && cd "$src" && find -L "${have[@]}" -type f ! -name 'config.sh' ! -path '*/benchmark-results/*' \
          -exec shasum -a 256 {} + 2>/dev/null | LC_ALL=C sort)
      man_skill_rows=$(grep -v '  \./' "$manifest" | LC_ALL=C sort)
      man_agent_rows=$(grep '  \./' "$manifest" | LC_ALL=C sort)
      stale_rows=$(LC_ALL=C comm -13 <(printf '%s\n' "$man_skill_rows" | awk 'NF') <(printf '%s\n' "$exp_rows" | awk 'NF'))
      # EXTRA is by PATH: a changed file keeps its path (it is STALE, not extra), a
      # path the source does not have at all is extra.
      extra_rows=$(LC_ALL=C comm -23 <(printf '%s\n' "$man_skill_rows" | awk 'NF{print $2}' | LC_ALL=C sort) <(printf '%s\n' "$exp_rows" | awk 'NF{print $2}' | LC_ALL=C sort) | sed 's|^|-  |')
      if [[ "$cur_host" == claude ]]; then
        # agents/*.md are copied verbatim: same (hash, path) rule, missing/changed only
        # (the Claude manifest hashes the whole agents/ dir, so extras stay allowed).
        exp_agent_rows=$(for a in "$src"/agents/*.md; do
            [[ -e "$a" ]] && ( cd "$src/agents" && shasum -a 256 "${a##*/}" ) | sed 's|  |  ./|'
          done | LC_ALL=C sort)
        agent_stale=$(LC_ALL=C comm -13 <(printf '%s\n' "$man_agent_rows" | awk 'NF') <(printf '%s\n' "$exp_agent_rows" | awk 'NF'))
        agent_extra=""
      else
        # Codex role files are GENERATED, so the expected rows are REGENERATED from the
        # CURRENT source by the installer's own gen_codex_role into a scratch directory
        # inside a private mktemp -d, then compared as (hash, path) rows exactly like
        # Claude's verbatim copies. Mapping, same situation => same code as on Claude:
        #   installed role edited AND the manifest rewritten to match => the expected row
        #     is not in the manifest => STALE (2), as for an edited Claude agent;
        #   source agent edited, not reinstalled => STALE (2), as on Claude;
        #   installed role edited, manifest untouched => DRIFT (1), above.
        # (the same PROD_CODEX_MODEL_* variables as at install time must be set)
        vw="$(mktemp -d "${TMPDIR:-/tmp}/prod-verify.XXXXXXXX" 2>&1)" || { echo "install: verify: cannot create a scratch directory under ${TMPDIR:-/tmp}: $vw" >&2; exit 1; }
        trap 'rm -rf "$vw"' EXIT
        exp_agent_rows=""; gen_bad=""
        for a in "$src"/agents/prod-*.md; do
          [[ -e "$a" ]] || continue
          n="${a##*/}"; n="${n%.md}"
          if gen_codex_role "$a" "$vw/$n.toml" 2>"$vw/$n.err"; then
            exp_agent_rows="$exp_agent_rows$(cd "$vw" && shasum -a 256 "$n.toml" | sed 's|  |  ./|')"$'\n'
          else
            cat "$vw/$n.err" >&2; gen_bad="$gen_bad-  ./$n.toml"$'\n'
          fi
        done
        exp_agent_rows=$(printf '%s\n' "$exp_agent_rows" | LC_ALL=C sort)
        exp_agent_paths=$(for a in "$src"/agents/prod-*.md; do
            [[ -e "$a" ]] || continue; n="${a##*/}"; echo "./${n%.md}.toml"
          done | LC_ALL=C sort)
        man_agent_paths=$(printf '%s\n' "$man_agent_rows" | awk 'NF{print $2}' | LC_ALL=C sort)
        agent_stale=$(printf '%s\n%s\n' "$(LC_ALL=C comm -13 <(printf '%s\n' "$man_agent_rows" | awk 'NF') <(printf '%s\n' "$exp_agent_rows" | awk 'NF'))" "$gen_bad" | awk 'NF')
        agent_extra=$(LC_ALL=C comm -23 <(printf '%s\n' "$man_agent_paths" | awk 'NF') <(printf '%s\n' "$exp_agent_paths" | awk 'NF') | sed 's|^|-  |')
      fi
      stale_rows=$(printf '%s\n%s\n' "$stale_rows" "$agent_stale" | awk 'NF')
      extra_rows=$(printf '%s\n%s\n' "$extra_rows" "$agent_extra" | awk 'NF')
      # MODE IS PART OF THE TRUSTED SET, and until 2026-08-29 nothing checked it.
      #
      # Line ~307 chmods the installed tree read-only, and the comment there
      # states the property it buys: an incidental write to the trusted copy
      # "fails loudly at the moment it happens" instead of being discovered
      # later or not at all. That property is worth exactly as much as the
      # weakest file's mode -- and the manifest cannot see modes, only hashes.
      #
      # So the interrupted-install window was invisible: install.sh writes the
      # manifest (line 299) and THEN chmods (line 307), so a crash between them
      # leaves a trusted set whose contents are correct and whose permissions
      # are wide open. --verify printed "TCB verified" over it, truthfully about
      # hashes and misleadingly about trust. Found by expanding the
      # source_of_truth scenario checklist in .prod/failure-modes.md rather than
      # by an incident, which is the entire point of having a denominator.
      #
      # config.sh and benchmark-results/ are EXCLUDED, matching hash_tree's own
      # exclusions -- they are deliberately outside the trusted set, config.sh
      # is meant to be edited by hand (every skill's docs say so), and firing on
      # it would be an assertion that goes off when nothing is wrong. That is
      # the failure mode this repo has already recorded four times; the first
      # draft of this check had it.
      writable=$(for s in "${skills[@]}"; do
          [[ -d "$cfg/skills/$s" ]] && find "$cfg/skills/$s" -type f \
            ! -name 'config.sh' ! -path '*/benchmark-results/*' \
            \( -perm -u+w -o -perm -g+w -o -perm -o+w \) 2>/dev/null
        done
        find "$cfg"/agents -maxdepth 1 -name "$agent_glob" -type f \
          \( -perm -u+w -o -perm -g+w -o -perm -o+w \) 2>/dev/null)
      wcount=$(printf '%s' "$writable" | grep -c . || true)
      if (( wcount > 0 )); then
        echo "TCB WRITABLE — ${wcount} file(s) in the trusted set are not read-only." >&2
        echo "The contents match the manifest, so nothing has been tampered with YET." >&2
        echo "What is missing is the guard that makes the next accidental write fail loudly:" >&2
        printf '%s\n' "$writable" | sed "s|^$cfg/|  writable: |" | sort -u >&2
        echo "Usually an install interrupted between the manifest write and the chmod. Re-run install.sh." >&2
        exit 3
      fi

      stale=$(printf '%s' "$stale_rows" | grep -c . || true)
      extra=$(printf '%s' "$extra_rows" | grep -c . || true)
      if (( stale > 0 || extra > 0 )); then
        # The rows carry their paths, so the operator sees WHICH component is
        # untrusted without rerunning this comparison (and the source tree is
        # hashed once, above, not once per stale row).
        if (( stale > 0 )); then
          echo "STALE INSTALL — ${stale} source file(s) in $src are not present in the installed copy." >&2
          printf '%s\n' "$stale_rows" | awk '{p=$2; if (p ~ /^\.\//) p="agents/" substr(p,3); print "  stale: " p}' | sort -u >&2
        fi
        if (( extra > 0 )); then
          echo "STALE INSTALL — ${extra} installed file(s) are not part of the source tree (extra path, or a file at the wrong place)." >&2
          printf '%s\n' "$extra_rows" | awk '{p=$2; if (p ~ /^\.\//) p="agents/" substr(p,3); print "  extra: " p}' | sort -u >&2
        fi
        echo "The manifest is intact but describes an OLDER trusted set. Re-run install.sh." >&2
        exit 2
      fi
      exit 0
    fi
    echo "TCB DRIFT — the installed skills no longer match the manifest:" >&2
    [[ "$mode" == --diff ]] && diff <(sort "$manifest") <(echo "$current" | sort) >&2
    diff <(sort "$manifest") <(echo "$current" | sort) 2>/dev/null | grep -E '^[<>]' | \
      awk '{print ($1==">" ? "  changed/added: " : "  missing/was:   ") $3}' | sort -u >&2
    echo "Re-run install.sh only after reviewing the change: this is the trusted set." >&2
    exit 1
}
if [[ "$mode" == --verify || "$mode" == --diff ]]; then
  # Each host verifies in its own subshell so verify_host's exits stay local.
  # One host: its exit code is the process's, messages untouched. Both: every
  # host runs, a failing one is NAMED, and the exit is the lowest non-zero code
  # (1 TCB DRIFT outranks 2 STALE INSTALL outranks 3 TCB WRITABLE).
  rc=0; failed=""
  for h in "${hosts[@]}"; do
    set_host "$h"
    (( ${#hosts[@]} > 1 )) && echo "== host: $h =="
    ( verify_host ); r=$?
    if (( r != 0 )); then
      failed="$failed $h(exit $r)"
      (( rc == 0 || r < rc )) && rc=$r
    fi
  done
  if (( rc != 0 && ${#hosts[@]} > 1 )); then echo "install.sh: verify FAILED for:$failed" >&2; fi
  exit "$rc"
fi

# Wire the repo's own hooks, because core.hooksPath is LOCAL CONFIG and does
# not travel with a clone. Without this the mirroring hook exists in the tree
# and runs on exactly one machine -- the one that wrote it -- which is the same
# shape as a mechanism that is implemented, tested, and never injected.
#
# Idempotent, and scoped to this repo only.
if git -C "$src" rev-parse --git-dir >/dev/null 2>&1 && [[ -d "$src/.githooks" ]]; then
  current="$(git -C "$src" config --get core.hooksPath 2>/dev/null || true)"
  if [[ "$current" != ".githooks" ]]; then
    git -C "$src" config core.hooksPath .githooks
    echo "hooks: core.hooksPath set to .githooks (mirrors now sync on commit)"
  fi
fi

# --- source consistency, BEFORE anything enters the trusted set -------------
#
# NINE of the eleven tracked copies of the shared probe are symlinks into
# _shared/ and cannot drift. The other two are real files: the CANONICAL copy at
# _shared/probes/verify-standard.sh, which is what the symlinks point at, and the
# greenfield TEMPLATE's copy.
#
# Re-measured at the reconciliation merge of 2026-08-26 -- it said "ten of the
# eleven", which double-counted the canonical file as one of its own symlinks.
# Authority: `git ls-files -s | awk '$1=="120000"'` over paths named
# verify-standard.sh gives 9, against 11 tracked paths in total.
#
# The template's copy is a real file correctly so, because the template is
# COPIED OUT into a new repo and a
# symlink would dangle the moment it left. That correctness is exactly what
# lets it rot, and it did: it sat 186 lines behind _shared for long enough that
# a commit added a `driven:` block to the template's production.yaml declaring
# five mechanisms, while the template's own probe had no `mechanisms-driven`
# row to read them. A repo born from prod-new therefore shipped a declaration
# nothing verified -- the framework's own defect class, in the framework's own
# scaffold.
#
# The mapping is spelled out rather than inferred from basenames. A clever
# matcher that silently stops matching is the same vacuous gate this whole
# standard exists to refuse.
mirrors=(
  "prod-new/template/scripts/verify-standard.sh:_shared/probes/verify-standard.sh"
  # row-vacuity-sweep travels with the probe it sweeps: it extracts patterns
  # from verify-standard.sh, so a template copy that drifted from _shared would
  # sweep a DIFFERENT file than the one that runs. Added 2026-08-29.
  "prod-new/template/scripts/row-vacuity-sweep.sh:_shared/probes/row-vacuity-sweep.sh"
  # The non-vacuity selftest joins the mirrored set for the reason the probe
  # did: it is the verifier OF the verifier, and it was previously re-authored
  # per repo instead of vendored. Three repos wrote their own in one session
  # and all three shipped the same vacuous control (`grep -qF ""`, which
  # matches every input). A file that gets re-invented is a file that gets
  # re-broken, so it is now shared, hashed, and drift-checked like the probe.
  "prod-new/template/scripts/tests/non-vacuity-selftest.sh:_shared/probes/non-vacuity-selftest.sh"
  # REGISTERED AT THE RECONCILIATION MERGE (2026-08-26), and the gap is worth
  # recording because it is the exact shape this array exists to prevent.
  # fix/probe-sigpipe-pipefail-membership added this selftest in BOTH locations
  # and they were byte-identical on that branch -- but the branch predates the
  # derivation-based drift check that arrived with
  # fix/probe-defects-and-shared-selftest, so nothing was ever going to notice
  # them diverging. Two correct copies with no gate between them is not a
  # mirrored file, it is two files that happen to agree today.
  "prod-new/template/scripts/tests/probe-self-gate-selftest.sh:_shared/probes/tests/probe-self-gate-selftest.sh"
  # MOVED HERE FROM .githooks/pre-commit AT THE RECONCILIATION MERGE
  # (2026-08-26). fix/registry-gate-block-scalars-and-template-rot added these
  # three by APPENDING them to a hardcoded array in the hook, which is where the
  # list lived when that branch started. In parallel,
  # fix/probe-defects-and-shared-selftest replaced that array with a derivation
  # FROM THIS FILE. Both changes are right and they are incompatible as written:
  # keeping the hook's copy would have re-created the two-lists-that-must-agree
  # defect the derivation exists to kill, and keeping the derivation alone would
  # have silently dropped all three of these mirrors while the hook went on
  # printing "N mirror(s) already in step". So the derivation stays and the
  # entries move to the one list it reads.
  #
  # ADDED AFTER THE ROT WAS MEASURED. check-registries.sh had no canonical copy
  # at all, so the template drifted in the direction nothing watches: the
  # adopting repos improved it while the template stayed at 88 lines, missing
  # REGISTRIES_DIR, the fail-closed on zero entries, the mandatory owner, the
  # sequence-boundary derivation and the block-scalar guard. Every repo
  # bootstrapped by prod-new got the 88-line version -- a registry gate that
  # passes an expired waiver whose renewal note happens to contain an
  # `expires:` line, and passes an EMPTY registries/ directory outright. The
  # install-time refusal could not see it: it compares a copy to a source, and
  # there was no source.
  "prod-new/template/scripts/check-registries.sh:_shared/probes/check-registries.sh"
  "prod-new/template/scripts/tests/check-registries-selftest.sh:_shared/probes/check-registries-selftest.sh"
  # ADDED WITH THE ROW IT COVERS. The sbom ordering selftest lifts the probe's
  # program out by its PYSBOM marker, so a template copy that drifts from
  # _shared would extract a marker that no longer exists -- and the selftest
  # would refuse to run in every repo prod-new scaffolds. That is the loud
  # failure, but only because it was built to refuse. Mirror it anyway.
  "prod-new/template/scripts/tests/sbom-ordering-selftest.sh:_shared/probes/sbom-ordering-selftest.sh"
  # The suite-run selftest lifts the probe's block by anchor and drives the
  # template coverage.sh, so a drifted copy would certify a different probe.
  "prod-new/template/scripts/tests/single-suite-run-selftest.sh:_shared/probes/single-suite-run-selftest.sh"
  # Added 2026-10-02: the acceptance-spec gate, vendored so a scaffolded repo's
  # copy is drift-checked like every other probe.
  # Added 2026-10-02: gate-run, the context-sparing gate runner (full log kept,
  # only failures + tail printed), vendored so scaffolded repos' agents have it.
  "prod-new/template/scripts/gate-run.sh:_shared/probes/gate-run.sh"
  "prod-new/template/scripts/tests/gate-run-selftest.sh:_shared/probes/gate-run-selftest.sh"
  "prod-new/template/scripts/acceptance-coverage.sh:_shared/probes/acceptance-coverage.sh"
  "prod-new/template/scripts/tests/acceptance-coverage-selftest.sh:_shared/probes/acceptance-coverage-selftest.sh"
  "prod-new/template/scripts/tests/acceptance-audit-selftest.sh:_shared/probes/acceptance-audit-selftest.sh"
  # Added 2026-10-02: acceptance-gap (visible vs held-out pass-rate gap, the
  # build-to-the-test detector), vendored so scaffolded repos' orchestrators
  # have it beside acceptance-coverage.
  "prod-new/template/scripts/acceptance-gap.sh:_shared/probes/acceptance-gap.sh"
  "prod-new/template/scripts/tests/acceptance-gap-selftest.sh:_shared/probes/acceptance-gap-selftest.sh"
  # ADDED WITH THE THREE ROWS IT COVERS: dimension 25's `load-baseline`, the
  # `error-handling-fitness` row, and dimension 27's advisory
  # `simulation-advisory`. It lifts `row`, `spec_field`, the three row
  # functions and the LOAD_MAX_AGE_DAYS window out of verify-standard.sh BY
  # NAME, so a template copy that drifted from _shared would either lift a
  # function that no longer exists -- and this selftest refuses loudly, by
  # construction -- or certify the OLD freshness window while the vendored
  # probe enforces a new one. The second shape is silent, which is exactly why
  # it belongs in the mirrored set rather than in the "someone will notice"
  # category.
  "prod-new/template/scripts/tests/load-rows-selftest.sh:_shared/probes/load-rows-selftest.sh"
  # The false-FAIL selftest lifts the registry / import / revision-stamp functions
  # out of the probe by anchor, so a template copy that drifted from _shared would
  # lift from a DIFFERENT file than the one that runs.
  "prod-new/template/scripts/tests/probe-false-fail-selftest.sh:_shared/probes/probe-false-fail-selftest.sh"
)
drift=0
for m in "${mirrors[@]}"; do
  copy="$src/${m%%:*}"; orig="$src/${m##*:}"
  if [[ ! -f "$copy" || ! -f "$orig" ]]; then
    echo "install: mirror declared but missing on disk: ${m%%:*} <- ${m##*:}" >&2
    drift=1; continue
  fi
  if ! cmp -s "$copy" "$orig"; then
    echo "install: SOURCE DRIFT — ${m%%:*} differs from ${m##*:}" >&2
    echo "         $(wc -l <"$copy" | tr -d ' ') lines vs $(wc -l <"$orig" | tr -d ' ')." \
         "Installing would ratify a stale standard into the trusted set." >&2
    echo "         Fix with:  cp '${m##*:}' '${m%%:*}'   then re-run." >&2
    drift=1
  fi
done
if (( drift )); then
  echo "install: refusing to install with source drift (${#mirrors[@]} mirror(s) checked)" >&2
  exit 1
fi
echo "source consistency: ${#mirrors[@]} mirrored file(s) match _shared"

# --- locking, ownership, private work directory, commit ----------------------
#
# ONE PRIVATE WORK DIRECTORY PER HOST PER RUN. Right after the lock is taken,
# install_host creates  work=$(mktemp -d "<cfg>/.prod-work.XXXXXXXX")  : a random
# name, created atomically by mktemp (it never reuses or follows an existing
# name), mode 0700, inside <cfg> so every rename into skills/ and agents/ stays on
# the same filesystem. EVERYTHING temporary lives in it and nowhere else:
#
#   <cfg>/.prod-work.XXXXXXXX/   0700, created by this run
#       stage/skills/<name>        stage/agents/<file>      what will be installed
#       trash/skills/<name>        trash/agents/<file>      the replaced copies
#       chk/                       sidecar files of the TOML check
#       manifest.new               the manifest, before its final rename
#
# Because the directory is new and private, nothing inside it can have been
# planted: `cp -R` into it, `>` into it and `mv` into it never follow a symlink
# that somebody else made. There is no pid-derived or otherwise predictable name
# anywhere. <cfg> itself may be a symlink: that is the user's choice (a dotfiles
# layout), documented in _shared/hosts.md.
#
# The operations that touch a path OUTSIDE the work directory, with their guards:
#   mkdir <cfg> (+ chmod 0755 on Codex)   only when absent; dirs this run made are rmdir-ed on failure
#   mkdir <cfg>/.prod-skills.lock         atomic; exists => exit 6, never stolen, removed on exit
#   mkdir <cfg>/skills, <cfg>/agents      mkdir -p, only the two names; Codex refuses symlinks earlier (exit 4)
#   mkdir <cfg>/.prod-backups[/<id>]      --adopt only; a symlink at .prod-backups is refused; <id> by mktemp -d
#   chmod u+w <destination unit dir>      top directory only, only if it is a real dir and not writable
#                                         (a read-only directory cannot change parent on Linux); undone on rollback
#   mv <destination> -> work/trash | .prod-backups/<id>    rename; the target name was checked free
#   mv work/stage/... -> <destination>    rename; re-checked free just before (it was just moved away)
#   chmod -R a-w <our skill dirs>, chmod a-w <our role files>   our freshly moved-in units only
#   mv -f work/manifest.new -> <manifest> rename; a symlinked manifest is removed first (the link, not the
#                                         target) because mv would move INTO a link to a directory; Codex refuses it (exit 4)
#   rm -rf <work>                         only the exact path this run created, after chmod u+rwx on its dirs
# A leftover .prod-work.* of a killed run is NEVER touched: it is named once on stderr.
workdirs=(); locks=(); made_dirs=(); keep_work=0; sig=0; done_hosts=(); failing_host=""; committed=0
orig_umask="$(umask)"
host_umask() { if [[ "$cur_host" == codex ]]; then umask 022; else umask "$orig_umask"; fi; }
remove_work() { # remove_work <dir this run created>
  local w="$1"
  [[ -n "$w" && -d "$w" && ! -L "$w" ]] || return 0
  find "$w" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$w" 2>/dev/null
  [[ ! -e "$w" ]]
}
cleanup() {
  local rc=$? p msg x
  for p in "${workdirs[@]:-}"; do
    [[ -n "$p" ]] || continue
    if (( keep_work )); then echo "install: kept $p: a previous copy that could not be put back is inside it" >&2; continue; fi
    remove_work "$p" || echo "install: could not remove $p; it is safe to delete" >&2
  done
  for p in "${locks[@]:-}"; do [[ -n "$p" ]] && { rm -f "$p/pid"; rmdir "$p" 2>/dev/null; }; done
  # directories THIS run created, newest first; rmdir only succeeds on an empty one,
  # so a completed install keeps them and a refused/failed first install leaves nothing
  for ((p=${#made_dirs[@]}-1; p>=0; p--)); do rmdir "${made_dirs[$p]}" 2>/dev/null; done
  if (( rc != 0 )) && [[ -n "$failing_host" ]] && (( ${#done_hosts[@]} )); then
    msg=""; for x in "${done_hosts[@]}"; do msg="$msg$x: installed; "; done
    echo "install: ${msg}${failing_host}: rolled back (exit $rc)" >&2
  fi
  return 0
}
trap cleanup EXIT
# Signals only SET A FLAG. The commit loop checks it between units (chk_sig) and
# rolls everything back, so the process never exits between "moved aside" and
# "moved in". After the manifest rename the install is complete and the flag is moot.
trap 'sig=130' INT
trap 'sig=143' TERM
trap 'sig=129' HUP

lock_busy() { # lock_busy <lock dir>: say who holds it and exit 6. It NEVER steals the lock.
  local lk="$1" pid="" old=""
  [[ -n "$(find "$lk" -maxdepth 0 -mmin +10 2>/dev/null)" ]] && old=" (older than 10 minutes)"
  # the pid file must be a regular file, not a symlink (nor a FIFO: opening one hangs):
  # read at most 16 bytes, digits only; nothing else is ever echoed
  if [[ -d "$lk" && ! -L "$lk" && -f "$lk/pid" && ! -L "$lk/pid" ]]; then pid="$(head -c 16 "$lk/pid" 2>/dev/null | tr -d '\n')"; fi
  [[ "$pid" =~ ^[0-9]{1,10}$ ]] || pid=""
  if [[ -z "$pid" ]]; then
    echo "install: the lock $lk exists$old and its owner is unreadable (a stale lock, or an install that is just starting). Not stealing it: if no install is running, remove it with:  rm -rf '$lk'" >&2; exit 6
  elif kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then
    echo "install: another install is running (lock $lk, pid $pid)$old. Not stealing it." >&2; exit 6
  else
    echo "install: stale lock $lk$old: its owner, pid $pid, is not running. Not stealing it: remove it with:  rm -rf '$lk'" >&2; exit 6
  fi
}
lock_host() {
  local lk="$cfg/.prod-skills.lock" err
  host_umask   # before the FIRST mkdir: $cfg itself may be created just below
  if [[ ! -d "$cfg" ]]; then
    mkdir -p "$cfg" || { echo "install: cannot create $cfg" >&2; exit 7; }
    made_dirs+=("$cfg"); [[ "$cur_host" == codex ]] && chmod 0755 "$cfg"
  fi
  if ! err="$(mkdir "$lk" 2>&1)"; then
    if [[ -e "$lk" || -L "$lk" ]]; then lock_busy "$lk"
    else echo "install: cannot create the lock directory $lk: $(printf '%s' "$err" | tr -c '[:print:]' '?')" >&2; exit 7; fi
  fi
  locks+=("$lk")
  ( set -C; echo "$$" > "$lk/pid" ) 2>/dev/null || true   # noclobber: never through a planted name
}

refuse_sym=0; refuse_foreign=0; adopt_paths=""
man_rows=""   # the previous manifest's PATH column, one per line between newlines (loaded once per host)
owned_in_manifest() { # owned_in_manifest <skill name | ./role.toml>
  case "$1" in
    ./*) [[ "$man_rows" == *$'\n'"$1"$'\n'* ]] ;;
    *)   [[ "$man_rows" == *$'\n'"$1/"* ]] ;;
  esac
}
check_dest() { # check_dest <path> <ownership key>
  if [[ -L "$1" ]]; then
    echo "install: refusing: $1 is a symlink (destination is a symlink); it is yours, replace it with a real path yourself" >&2; refuse_sym=1
  elif [[ -e "$1" ]] && ! owned_in_manifest "$2"; then
    if (( adopt )); then
      adopt_paths="$adopt_paths$1"$'\n'
      echo "install: --adopt: $1 is not ours; it will be moved under $cfg/.prod-backups/"
    else
      echo "install: refusing to overwrite $1: not installed by this tool; move it away or pass --adopt" >&2; refuse_foreign=1
    fi
  fi
}
# Everything that can be refused is refused HERE, before any host is written.
precheck_host() {
  [[ "$cur_host" == codex ]] || return 0
  local d s a n l sp seen=" "
  for d in "$cfg/skills" "$cfg/agents" "$manifest"; do
    if [[ -L "$d" ]]; then
      echo "install: refusing: $d is a symlink (destination is a symlink); it is yours, replace it with a real path yourself" >&2; refuse_sym=1
    fi
  done
  (( refuse_sym )) && return 0
  man_rows=$'\n'; [[ ! -f "$manifest" ]] || man_rows="$man_rows$(awk '{print $2}' "$manifest")"$'\n'
  sp=()
  for s in "${skills[@]}"; do
    [[ -d "$src/$s" ]] || { echo "install: source skill missing: $src/$s" >&2; exit 1; }
    sp+=("$src/$s")
  done
  l="$(find -L "${sp[@]}" -type l 2>/dev/null | head -n 1)"   # one find for all nine: a dangling link anywhere
  [[ -z "$l" ]] || { echo "install: dangling symlink in the source: $l" >&2; exit 1; }
  for s in "${skills[@]}"; do check_dest "$cfg/skills/$s" "$s"; done
  for a in "$src"/agents/*.md; do
    [[ -e "$a" ]] || continue
    n="${a##*/}"; n="${n%.md}"
    case "$n" in prod-*) ;; *) echo "install: agents/$n.md is not a prod-* agent; not installed for Codex" >&2; continue ;; esac
    valid_role_name "$(fm_field "$a" name)" "$n" || { echo "install: $a: frontmatter name must match ^[a-z][a-z0-9-]*\$ and equal the file name" >&2; exit 1; }
    case "$seen" in *" $n "*) echo "install: duplicate agent name $n" >&2; exit 1 ;; esac
    seen="$seen$n "
    check_dest "$cfg/agents/$n.toml" "./$n.toml"
  done
}

# STAGING AND COMMIT. Every skill and role is built under work/stage. Only when ALL
# units of the host are built does the COMMIT start: each existing destination is
# renamed into work/trash (or .prod-backups/<id> for an adopted one) and its stage
# renamed in. A failure or a signal anywhere rolls the renames back, so a host is
# all-or-nothing; the manifest is built last, inside work, and renamed into place as
# the final step.
u_src=(); u_dst=(); u_old=(); u_state=(); u_relock=()
unlock_top() { [[ -d "$1" && ! -L "$1" && ! -w "$1" ]] && chmod u+w "$1"; return 0; }  # a read-only dir cannot change parent on Linux
rollback_units() {
  (( committed )) && return 0
  local i
  for ((i=${#u_src[@]}-1; i>=0; i--)); do
    if [[ "${u_state[$i]:-0}" == 2 ]]; then
      unlock_top "${u_dst[$i]}"
      mv "${u_dst[$i]}" "${u_src[$i]}" || echo "install: rollback: cannot move ${u_dst[$i]} back to its stage" >&2
    fi
    if [[ "${u_state[$i]:-0}" -ge 1 && -n "${u_old[$i]}" ]]; then
      if [[ -e "${u_dst[$i]}" || -L "${u_dst[$i]}" ]]; then
        echo "install: rollback: ${u_dst[$i]} is occupied; your previous copy is kept at ${u_old[$i]}" >&2; keep_work=1
      else
        mv "${u_old[$i]}" "${u_dst[$i]}" || { echo "install: rollback: cannot restore ${u_dst[$i]} from ${u_old[$i]}" >&2; keep_work=1; }
        [[ "${u_relock[$i]:-0}" == 1 ]] && chmod a-w "${u_dst[$i]}" 2>/dev/null
      fi
    fi
  done
}
fail_step() { rollback_units; echo "install: $* -- this host was rolled back, no manifest written" >&2; exit 7; }
chk_sig() { (( sig == 0 )) && return 0; rollback_units; echo "install: interrupted by a signal; this host was rolled back, nothing is half-installed" >&2; exit "$sig"; }
add_unit() { # add_unit <stage path> <dest path>
  u_src+=("$1"); u_dst+=("$2"); u_old+=(""); u_state+=(0); u_relock+=(0)
}

install_host() {
local i s a n d st mf rc rb sp trash_fail=0 n_roles=0 old kind base bk="" mk_s=0 mk_a=0
failing_host="$cur_host"; committed=0; chk_n=0
host_umask
u_src=(); u_dst=(); u_old=(); u_state=(); u_relock=()
# a leftover of an interrupted run is named, never touched
for old in "$cfg"/.prod-work.*; do
  [[ -e "$old" || -L "$old" ]] || continue
  echo "install: stale work directory from an interrupted install: ${old//[![:print:]]/?}; it is safe to delete (if one of our skills is missing from the home, its previous copy may be under $old/trash)" >&2
done
work="$(mktemp -d "$cfg/.prod-work.XXXXXXXX" 2>&1)" || { echo "install: cannot create a private work directory under $cfg: $(printf '%s' "$work" | tr -c '[:print:]' '?')" >&2; exit 7; }
workdirs+=("$work")
mkdir -p "$work/stage/skills" "$work/stage/agents" "$work/trash/skills" "$work/trash/agents" "$work/chk" || fail_step "cannot create the work directory layout"
[[ "$cur_host" == codex ]] && chk_dir="$work/chk" || chk_dir=""
[[ -d "$cfg/skills" ]] || { mk_s=1; made_dirs+=("$cfg/skills"); }
[[ -d "$cfg/agents" ]] || { mk_a=1; made_dirs+=("$cfg/agents"); }
mkdir -p "$cfg/skills" "$cfg/agents" || fail_step "cannot create $cfg/skills and $cfg/agents"
if [[ "$cur_host" == codex ]]; then   # explicit modes for what this run created, whatever the umask
  (( mk_s )) && { chmod 0755 "$cfg/skills" || fail_step "cannot chmod $cfg/skills"; }
  (( mk_a )) && { chmod 0755 "$cfg/agents" || fail_step "cannot chmod $cfg/agents"; }
fi
# --adopt: the backups of THIS host go to <cfg>/.prod-backups/<UTC timestamp>-<random>/{skills,agents},
# outside skills/ and agents/ (Codex would discover a skills/*.bak.*/SKILL.md as a duplicate skill).
# The id comes from mktemp -d: random, atomic, never an existing name.
if [[ "$adopt_paths" == "$cfg/"* || "$adopt_paths" == *$'\n'"$cfg/"* ]]; then
  if [[ ! -e "$cfg/.prod-backups" && ! -L "$cfg/.prod-backups" ]]; then mkdir "$cfg/.prod-backups" || fail_step "cannot create $cfg/.prod-backups"; made_dirs+=("$cfg/.prod-backups"); fi
  [[ -d "$cfg/.prod-backups" && ! -L "$cfg/.prod-backups" ]] || fail_step "$cfg/.prod-backups is not a real directory"
  bk="$(mktemp -d "$cfg/.prod-backups/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX" 2>&1)" || fail_step "cannot create a backup directory: $(printf '%s' "$bk" | tr -c '[:print:]' '?')"
  made_dirs+=("$bk")
  mkdir "$bk/skills" "$bk/agents" || fail_step "cannot create the backup layout"
  made_dirs+=("$bk/skills" "$bk/agents")
fi
# The installed copy is left READ-ONLY at the end of this script. It needs no
# unlock before being replaced: units are renamed away whole, never edited in place
# (the old Claude path ran a blanket chmod -R u+w over skills/ and agents/, which
# also unlocked every FOREIGN file there and could not be undone on a failed
# install; that side effect is gone).
for s in "${skills[@]}"; do
  chk_sig
  st="$work/stage/skills/$s"
  add_unit "$st" "$cfg/skills/$s"
  cp -R "$src/$s" "$st" || fail_step "cannot copy skill $s"
  # shared material travels as real files, resolved from the repo's symlinks
  if [[ -d "$src/$s/references" ]]; then
    rm -rf "$st/references" || fail_step "cannot reset $st/references"
    mkdir -p "$st/references" || fail_step "cannot create $st/references"
    for r in "$src/$s/references"/*; do
      [[ -e "$r" ]] || continue
      rb="${r##*/}"
      if [[ -d "$r" ]]; then
        mkdir -p "$st/references/$rb" || fail_step "cannot create references/$rb"
        if [[ "$cur_host" == codex ]]; then
          cp -RL "$r"/. "$st/references/$rb/" || fail_step "cannot copy references/$rb of $s"
        else
          cp -RL "$r"/* "$st/references/$rb/" 2>/dev/null || true
        fi
      else
        cp -L "$r" "$st/references/$rb" || fail_step "cannot copy $r"
      fi
    done
  fi
  # per-skill config stays LOCAL and unhashed: it holds org facts, not policy
  if [[ -f "$src/$s/config.sh" ]]; then cp "$src/$s/config.sh" "$st/config.sh" || fail_step "cannot copy config.sh of $s"; fi
done
# Agent definitions. Stage, then rename over: a plain `cp` onto an existing SYMLINK
# would follow it and write through to its target, and `find -type f` skips
# symlinks, which once kept the agent definitions out of the manifest entirely.
# Agent definitions carry the write-masks that bound what a cheap model may touch;
# an unhashed one is an unverified security instruction.
for a in "$src"/agents/*.md; do
  [[ -e "$a" ]] || continue
  chk_sig
  n="${a##*/}"; n="${n%.md}"
  if [[ "$cur_host" == claude ]]; then
    st="$work/stage/agents/$n.md"; add_unit "$st" "$cfg/agents/$n.md"
    cp "$a" "$st" || fail_step "cannot copy agent $n"
  else
    case "$n" in prod-*) ;; *) continue ;; esac   # Codex: only prod-* roles are generated, hashed and locked
    st="$work/stage/agents/$n.toml"; add_unit "$st" "$cfg/agents/$n.toml"
    gen_codex_role "$a" "$st" || { rollback_units; echo "install: cannot generate Codex role for $a" >&2; exit 1; }
    n_roles=$((n_roles+1))
  fi
done
if [[ "$cur_host" == codex ]]; then
  toml_check_all "$work/chk"; rc=$?
  if (( rc == 3 )); then echo "install: note: python3 with tomllib not found; role files were not parse-checked (UTF-8 validated and escaped only)" >&2
  elif (( rc != 0 )); then rollback_units; echo "install: the generated role files do not round-trip through a TOML parser; refusing" >&2; exit 1; fi
fi

# COMMIT. chk_sig runs only BETWEEN units: a unit that was moved aside is always
# moved in (or rolled back) before the flag is looked at.
for ((i=0; i<${#u_src[@]}; i++)); do
  chk_sig
  d="${u_dst[$i]}"
  if [[ -e "$d" || -L "$d" ]]; then
    base="${d##*/}"
    case "$d" in "$cfg"/agents/*) kind=agents ;; *) kind=skills ;; esac
    if [[ "$cur_host" == codex && -n "$bk" && $'\n'"$adopt_paths" == *$'\n'"$d"$'\n'* ]]; then old="$bk/$kind/$base"
    else old="$work/trash/$kind/$base"; fi
    [[ ! -e "$old" && ! -L "$old" ]] || fail_step "the name $old is already taken"
    if [[ -d "$d" && ! -L "$d" && ! -w "$d" ]]; then chmod u+w "$d" || fail_step "cannot unlock $d"; u_relock[$i]=1; fi
    mv "$d" "$old" || { [[ "${u_relock[$i]}" == 1 ]] && chmod a-w "$d" 2>/dev/null; fail_step "cannot move $d aside"; }
    u_old[$i]="$old"; u_state[$i]=1
  fi
  [[ ! -e "$d" && ! -L "$d" ]] || fail_step "$d appeared while installing; not moving anything into it"
  mv "${u_src[$i]}" "$d" || fail_step "cannot move ${u_src[$i]} into place"
  u_state[$i]=2
done
chk_sig

# Read-only AFTER the new units are in place and BEFORE the manifest. This does
# not stop a determined writer -- it can be undone with one chmod -- and it is not
# meant to. It removes the SILENT case: an accidental write to the trusted copy now
# fails loudly at the moment it happens. Prevention is impossible under
# bypassPermissions; making the act explicit is not.
sp=(); for s in "${skills[@]}"; do sp+=("$cfg/skills/$s"); done
chmod -R a-w "${sp[@]}" || fail_step "cannot make the skills under $cfg/skills read-only"
if [[ "$cur_host" == claude ]]; then
  chmod -R a-w "$cfg"/agents/$agent_glob 2>/dev/null || true
else
  for ((i=0; i<${#u_dst[@]}; i++)); do
    case "${u_dst[$i]}" in "$cfg"/agents/*) chmod a-w "${u_dst[$i]}" || fail_step "cannot make ${u_dst[$i]} read-only" ;; esac
  done
fi

# The manifest is written LAST, inside work, and renamed into place: an incomplete
# install never leaves a manifest that describes it.
mf="$work/manifest.new"
{ hash_tree "$cfg/skills" "${skills[@]}"; agents_hash; } | sort > "$mf" || fail_step "cannot write the manifest"
[[ -s "$mf" ]] || fail_step "the manifest came out empty"
if [[ "$cur_host" == codex ]]; then chmod 0444 "$mf" || fail_step "cannot chmod the manifest"; fi
chk_sig
[[ ! -d "$manifest" || -L "$manifest" ]] || fail_step "$manifest is a directory"
# mv would move INTO a symlink to a directory; remove the link itself (never its target).
# Codex refused a symlinked manifest earlier (exit 4); on Claude it is replaced by rename.
if [[ -L "$manifest" ]]; then rm -f "$manifest" || fail_step "cannot replace the symlinked manifest"; fi
mv -f "$mf" "$manifest" || fail_step "cannot move the manifest into place"
committed=1; failing_host=""   # the commit point: from here on the new install is the state

# The replaced units sit in work/trash; the whole work directory goes only now that
# the new install is complete and recorded. (Adopted ones stay under .prod-backups.)
remove_work "$work" || { echo "install: could not remove the replaced copies in $work; the new install is complete, remove that directory by hand" >&2; trash_fail=1; }
(( sig == 0 )) || echo "install: a signal arrived after the commit point; the install had completed and is intact" >&2
if [[ "$cur_host" == claude ]]; then
  agent_files=("$src"/agents/*.md); [[ -e "${agent_files[0]}" ]] || agent_files=()
  echo "installed ${#skills[@]} skills + ${#agent_files[@]} agents as verified copies"
else
  echo "installed ${#skills[@]} skills + $n_roles agents as verified copies"
fi
echo "manifest: $manifest ($(wc -l <"$manifest" | tr -d ' ') files)"
[[ -z "$bk" ]] || echo "adopted files were moved under $bk"
echo
echo "Verify at any time (and from a cron or session hook):"
echo "  bash $src/install.sh --verify$( [[ "$cur_host" == claude ]] || echo " --host $cur_host" )"
(( trash_fail == 0 )) || return 7
}
# Locks for every chosen host first, then every refusal, THEN the first write.
for h in "${hosts[@]}"; do set_host "$h"; lock_host; done
chk_sig
for h in "${hosts[@]}"; do set_host "$h"; precheck_host; done
if (( refuse_sym )); then echo "install: nothing was installed (exit 4: destination is a symlink)" >&2; exit 4; fi
if (( refuse_foreign )); then echo "install: nothing was installed (exit 5: destinations not installed by this tool)" >&2; exit 5; fi
for h in "${hosts[@]}"; do
  set_host "$h"
  chk_sig
  (( ${#hosts[@]} > 1 )) && echo "== host: $h =="
  install_host; r=$?
  (( committed )) && done_hosts+=("$h")
  (( r == 0 )) || exit "$r"
done
