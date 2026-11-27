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
#                         moving each to <path>.bak.<timestamp> (ignored for claude).
#
# Exit non-zero on verification failure, so it can gate a session or a cron.
# The code says WHICH failure, because the three call for different actions:
#   1  TCB DRIFT     — installed contents differ from the manifest (tamper)
#   2  STALE INSTALL — manifest intact, but describes an OLDER source (reinstall)
#   3  TCB WRITABLE  — contents correct, read-only guard missing (reinstall)
# Install-time refusals and failures (new; verify never returns these):
#   4  DESTINATION IS A SYMLINK  (Codex tree: skills/, agents/, a skill dir, a role file, the manifest)
#   5  NOT OURS      — a Codex destination exists and the previous manifest does not list it
#                      (--adopt moves it to <path>.bak.<timestamp>, never deletes it)
#   6  LOCKED        — another install holds <config root>/.prod-skills.lock
#   7  STEP FAILED   — a copy/move/chmod failed; the host's tree is rolled back, no manifest written
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
            [[ -e "$a" ]] && ( cd "$src/agents" && shasum -a 256 "$(basename "$a")" ) | sed 's|  |  ./|'
          done | LC_ALL=C sort)
        agent_stale=$(LC_ALL=C comm -13 <(printf '%s\n' "$man_agent_rows" | awk 'NF') <(printf '%s\n' "$exp_agent_rows" | awk 'NF'))
        agent_extra=""
      else
        # Codex role files are GENERATED, so the source has no hash to compare; the
        # PATHS are exact: one agents/prod-*.toml per source agents/prod-*.md.
        exp_agent_paths=$(for a in "$src"/agents/prod-*.md; do
            [[ -e "$a" ]] && echo "./$(basename "$a" .md).toml"
          done | LC_ALL=C sort)
        man_agent_paths=$(printf '%s\n' "$man_agent_rows" | awk 'NF{print $2}' | LC_ALL=C sort)
        agent_stale=$(LC_ALL=C comm -13 <(printf '%s\n' "$man_agent_paths" | awk 'NF') <(printf '%s\n' "$exp_agent_paths" | awk 'NF') | sed 's|^|-  |')
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

# --- Codex role files, generated from agents/*.md ---------------------------
#
# Codex does not read agents/*.md. Each prod-* agent becomes <codex home>/agents/<name>.toml
# with keys name, description, developer_instructions (+ model when asked for); other
# agents/*.md are NOT installed for Codex. Strings are TOML basic strings with every
# control character escaped, and each file is parse-checked (toml_check) when python3
# has tomllib.
# Location and keys are UNVERIFIED against the binary (see _shared/hosts.md).
#
# model: Claude names (sonnet/opus/haiku) have no VERIFIED Codex equivalent, so
# `model` is OMITTED (the role inherits) unless PROD_CODEX_MODEL_<ROLE> is set,
# <ROLE> = agent name without the prod- prefix, upper-cased, - as _.
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
# stdin text -> the inside of a TOML BASIC string. Every backslash, quote and
# control character (0x01-0x1f, 0x7f) is escaped; newlines become \n. Nothing is
# un-representable, so there is no ''' refusal. Bytes >= 0x80 pass through (a
# non-UTF-8 byte makes the parse check below refuse the file).
toml_esc() {
  LC_ALL=C awk 'BEGIN { for (i = 1; i < 32; i++) c[sprintf("%c", i)] = sprintf("\\u%04X", i); c[sprintf("%c", 127)] = "\\u007F" }
    { s = $0; o = ""; n = length(s)
      for (i = 1; i <= n; i++) { ch = substr(s, i, 1)
        if (ch == "\\") o = o "\\\\"; else if (ch == "\"") o = o "\\\""; else if (ch in c) o = o c[ch]; else o = o ch }
      printf "%s%s", (NR > 1 ? "\\n" : ""), o }'
}
# Parse every generated file ONCE and compare name / description /
# developer_instructions (/ model) with the intended values. Returns 0 ok, 1
# mismatch or parse error, 3 when no tomllib is available (python3 < 3.11 or
# absent): then the files rest on toml_esc alone, which the selftest proves by round
# trip where tomllib exists. Arguments: groups of <file> <name> <desc> <instr> <model>.
toml_check_all() {
  (( $# )) || return 0
  python3 -I -c 'import tomllib' 2>/dev/null || return 3
  python3 -I - "$@" <<'PY'
import sys, tomllib
a = sys.argv[1:]
bad = 0
for f, name, desc, instr, model in zip(*[iter(a)] * 5):
    try:
        d = tomllib.loads(open(f, 'rb').read().decode('utf-8'))
    except Exception as e:
        print('install: %s: parse error: %s' % (f, e), file=sys.stderr); bad = 1; continue
    want = {'name': name, 'description': desc, 'developer_instructions': instr}
    if model: want['model'] = model
    if d != want:
        print('install: %s: round-trip mismatch on %s' % (f, sorted(k for k in set(d) | set(want) if d.get(k) != want.get(k))), file=sys.stderr); bad = 1
sys.exit(bad)
PY
}
chk_args=()
gen_codex_role() { # gen_codex_role <agents/x.md> <out file>   (queues the parse check; see toml_check_all)
  local f="$1" out="$2" name desc tools model_var model body restr="" restline instr
  if has_nul "$f"; then echo "install: $f contains a NUL byte; refused" >&2; return 1; fi
  { IFS= read -r name; IFS= read -r desc; IFS= read -r tools; } < <(fm_fields "$f")
  [[ -n "$name" && -n "$desc" ]] || { echo "install: $f has no name/description frontmatter" >&2; return 1; }
  valid_role_name "$name" "$(basename "$f" .md)" || { echo "install: $f: name '$name' must match ^[a-z][a-z0-9-]*\$ and equal the file name" >&2; return 1; }
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
  chk_args+=("$out" "$name" "$desc" "$instr" "$model")
}

# --- locking, ownership, staging -------------------------------------------
#
# DESTRUCTIVE OPERATIONS and their guards (the review asked for this list):
#   rename of a skill dir / role file to trash or <path>.bak.<ts>  (mv, same parent)
#       Codex: only after lstat says not-a-symlink AND (listed in the previous
#       manifest OR --adopt, which backs up instead of deleting). Claude: historic
#       behaviour, replaces skills/<our names> and agents/*.md of our names.
#   rm -rf on $cfg/{skills,agents}/.prod-trash.<pid>.* and .prod-stage.<pid>.*
#       (names we created this run with a non-clobbering mkdir/cp; rm -rf never
#       follows a symlink, and the u+w pass before it skips symlinks: ! -type l)
#   chmod u+w / a-w: Codex only on paths under our own stage/trash names and our
#       freshly moved-in units; Claude keeps the historic chmod -R.
#   writes: only into the stage names above, the lock dir, the manifest temp; the
#       manifest is replaced by rename (a symlinked manifest is refused on Codex).
tmp_paths=(); locks=(); made_dirs=()
cleanup() {
  local p
  for p in "${tmp_paths[@]:-}"; do
    [[ -n "$p" ]] || continue
    if [[ -d "$p" && ! -L "$p" ]]; then find "$p" ! -type l -exec chmod u+w {} + 2>/dev/null; fi
    if [[ -e "$p" || -L "$p" ]]; then rm -rf "$p" 2>/dev/null; fi
  done
  for p in "${locks[@]:-}"; do [[ -n "$p" ]] && { rm -f "$p/pid"; rmdir "$p" 2>/dev/null; }; done
  # directories THIS run created, newest first; rmdir only succeeds on an empty one,
  # so a completed install keeps them and a refused/failed first install leaves nothing
  for ((p=${#made_dirs[@]}-1; p>=0; p--)); do rmdir "${made_dirs[$p]}" 2>/dev/null; done
  return 0
}
trap cleanup EXIT

lock_host() {
  local lk="$cfg/.prod-skills.lock" old
  if [[ ! -d "$cfg" ]]; then
    mkdir -p "$cfg" || { echo "install: cannot create $cfg" >&2; exit 7; }
    made_dirs+=("$cfg")
  fi
  if ! mkdir "$lk" 2>/dev/null; then
    old="$(find "$lk" -maxdepth 0 -mmin +10 2>/dev/null)"
    if [[ -n "$old" ]]; then
      echo "install: another install is running, or died holding $lk (older than 10 minutes, pid $(cat "$lk/pid" 2>/dev/null || echo '?')). Not stealing it: if no install is running, remove that directory by hand." >&2
    else
      echo "install: another install is running (lock $lk, pid $(cat "$lk/pid" 2>/dev/null || echo '?'))" >&2
    fi
    exit 6
  fi
  locks+=("$lk")
  echo "$$" > "$lk/pid" 2>/dev/null || true
}

refuse_sym=0; refuse_foreign=0; adopt_paths=""
owned_in_manifest() { # owned_in_manifest <skill name | ./role.toml>
  [[ -f "$manifest" ]] || return 1
  case "$1" in
    ./*) awk -v p="$1" '$2 == p { f = 1 } END { exit !f }' "$manifest" ;;
    *)   awk -v p="$1/" 'index($2, p) == 1 { f = 1 } END { exit !f }' "$manifest" ;;
  esac
}
check_dest() { # check_dest <path> <ownership key>
  if [[ -L "$1" ]]; then
    echo "install: refusing: $1 is a symlink (destination is a symlink); it is yours, replace it with a real path yourself" >&2; refuse_sym=1
  elif [[ -e "$1" ]] && ! owned_in_manifest "$2"; then
    if (( adopt )); then
      adopt_paths="$adopt_paths$1"$'\n'
      echo "install: --adopt: $1 is not ours; it will be moved to $1.bak.<timestamp>"
    else
      echo "install: refusing to overwrite $1: not installed by this tool; move it away or pass --adopt" >&2; refuse_foreign=1
    fi
  fi
}
# Everything that can be refused is refused HERE, before any host is written.
precheck_host() {
  [[ "$cur_host" == codex ]] || return 0
  local d s a n l seen=" "
  for d in "$cfg/skills" "$cfg/agents" "$manifest"; do
    if [[ -L "$d" ]]; then
      echo "install: refusing: $d is a symlink (destination is a symlink); it is yours, replace it with a real path yourself" >&2; refuse_sym=1
    fi
  done
  (( refuse_sym )) && return 0
  for s in "${skills[@]}"; do
    [[ -d "$src/$s" ]] || { echo "install: source skill missing: $src/$s" >&2; exit 1; }
    l="$(find -L "$src/$s" -type l 2>/dev/null | head -n 1)"
    [[ -z "$l" ]] || { echo "install: dangling symlink in the source: $l" >&2; exit 1; }
    check_dest "$cfg/skills/$s" "$s"
  done
  for a in "$src"/agents/*.md; do
    [[ -e "$a" ]] || continue
    n="$(basename "$a" .md)"
    case "$n" in prod-*) ;; *) echo "install: agents/$n.md is not a prod-* agent; not installed for Codex" >&2; continue ;; esac
    valid_role_name "$(fm_field "$a" name)" "$n" || { echo "install: $a: frontmatter name must match ^[a-z][a-z0-9-]*\$ and equal the file name" >&2; exit 1; }
    case "$seen" in *" $n "*) echo "install: duplicate agent name $n" >&2; exit 1 ;; esac
    seen="$seen$n "
    check_dest "$cfg/agents/$n.toml" "./$n.toml"
  done
}

# STAGING: every skill and role is built beside its destination under a
# .prod-stage.<pid>.<name> sibling (same parent, so the final rename is atomic and
# needs no write permission on the unit itself). Only when ALL units of the host
# are built does the COMMIT start: each existing destination is renamed away
# (trash, or <path>.bak.<ts> for an adopted one) and its stage renamed in. A failure
# anywhere rolls the renames back, so a host is all-or-nothing; the manifest is
# built last, in a temp file, and renamed into place as the final step.
u_src=(); u_dst=(); u_old=(); u_state=()
rollback_units() {
  local i
  for ((i=${#u_src[@]}-1; i>=0; i--)); do
    if [[ "${u_state[$i]:-0}" == 2 ]]; then
      mv "${u_dst[$i]}" "${u_src[$i]}" || echo "install: rollback: cannot move ${u_dst[$i]} back to its stage" >&2
    fi
    if [[ "${u_state[$i]:-0}" -ge 1 && -n "${u_old[$i]}" ]]; then
      mv "${u_old[$i]}" "${u_dst[$i]}" || echo "install: rollback: cannot restore ${u_dst[$i]} from ${u_old[$i]}" >&2
    fi
  done
}
fail_step() { rollback_units; echo "install: $* -- this host was rolled back, no manifest written" >&2; exit 7; }
add_unit() { # add_unit <stage path> <dest path>
  u_src+=("$1"); u_dst+=("$2"); u_old+=(""); u_state+=(0); tmp_paths+=("$1")
}

install_host() {
local old_umask i s a n d st ts mt rc trash_fail=0 n_roles=0
old_umask="$(umask)"
# Codex: explicit modes, independent of the caller's umask (dirs 0755, files from
# the source's own modes minus group/other write, then read-only below).
[[ "$cur_host" == codex ]] && umask 022
u_src=(); u_dst=(); u_old=(); u_state=(); chk_args=()
[[ -d "$cfg/skills" ]] || made_dirs+=("$cfg/skills")
[[ -d "$cfg/agents" ]] || made_dirs+=("$cfg/agents")
mkdir -p "$cfg/skills" "$cfg/agents" || fail_step "cannot create $cfg/skills and $cfg/agents"
# The installed copy is left READ-ONLY at the end of this script. It needs no
# unlock before being replaced: units are renamed away whole, never edited in place
# (the old Claude path ran a blanket chmod -R u+w over skills/ and agents/, which
# also unlocked every FOREIGN file there and could not be undone on a failed
# install; that side effect is gone, the trash is unlocked only to be deleted).
agstage="$cfg/.prod-stage.$$.agents"; agtrash="$cfg/.prod-trash.$$.agents"
tmp_paths+=("$agstage" "$agtrash")
mkdir "$agstage" "$agtrash" || fail_step "cannot create the staging directories under $cfg"
for s in "${skills[@]}"; do
  st="$cfg/skills/.prod-stage.$$.$s"
  add_unit "$st" "$cfg/skills/$s"
  cp -R "$src/$s" "$st" || fail_step "cannot copy skill $s"
  # shared material travels as real files, resolved from the repo's symlinks
  if [[ -d "$src/$s/references" ]]; then
    rm -rf "$st/references" || fail_step "cannot reset $st/references"
    mkdir -p "$st/references" || fail_step "cannot create $st/references"
    for r in "$src/$s/references"/*; do
      [[ -e "$r" ]] || continue
      if [[ -d "$r" ]]; then
        mkdir -p "$st/references/$(basename "$r")" || fail_step "cannot create references/$(basename "$r")"
        if [[ "$cur_host" == codex ]]; then
          cp -RL "$r"/. "$st/references/$(basename "$r")/" || fail_step "cannot copy references/$(basename "$r") of $s"
        else
          cp -RL "$r"/* "$st/references/$(basename "$r")/" 2>/dev/null || true
        fi
      else
        cp -L "$r" "$st/references/$(basename "$r")" || fail_step "cannot copy $r"
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
  n="$(basename "$a" .md)"
  if [[ "$cur_host" == claude ]]; then
    st="$agstage/$n.md"; add_unit "$st" "$cfg/agents/$n.md"
    cp "$a" "$st" || fail_step "cannot copy agent $n"
  else
    case "$n" in prod-*) ;; *) continue ;; esac   # Codex: only prod-* roles are generated, hashed and locked
    st="$agstage/$n.toml"; add_unit "$st" "$cfg/agents/$n.toml"
    gen_codex_role "$a" "$st" || { rollback_units; echo "install: cannot generate Codex role for $a" >&2; exit 1; }
    n_roles=$((n_roles+1))
  fi
done
if (( ${#chk_args[@]} )); then
  toml_check_all "${chk_args[@]}"; rc=$?
  if (( rc == 3 )); then echo "install: note: python3 with tomllib not found; role files were not parse-checked (escaping only)" >&2
  elif (( rc != 0 )); then rollback_units; echo "install: the generated role files do not round-trip through a TOML parser; refusing" >&2; exit 1; fi
fi

# COMMIT
ts="$(date +%Y%m%d%H%M%S)"
for ((i=0; i<${#u_src[@]}; i++)); do
  d="${u_dst[$i]}"
  if [[ -e "$d" || -L "$d" ]]; then
    if [[ "$cur_host" == codex && $'\n'"$adopt_paths" == *$'\n'"$d"$'\n'* ]]; then
      u_old[$i]="$d.bak.$ts"; [[ -e "${u_old[$i]}" ]] && u_old[$i]="$d.bak.$ts.$$"
    else
      # skills: a sibling of the destination (same parent: atomic, no write bit needed on
      # the unit). Agent files: a directory beside agents/, because the Claude manifest
      # hashes the whole agents/ dir and a trash file inside it would be counted.
      case "$d" in
        "$cfg"/agents/*) u_old[$i]="$agtrash/$(basename "$d")" ;;
        *) u_old[$i]="$(dirname "$d")/.prod-trash.$$.$(basename "$d")"; tmp_paths+=("${u_old[$i]}") ;;
      esac
    fi
    mv "$d" "${u_old[$i]}" || { u_old[$i]=""; fail_step "cannot move $d aside"; }
    u_state[$i]=1
  fi
  mv "${u_src[$i]}" "$d" || fail_step "cannot move ${u_src[$i]} into place"
  u_state[$i]=2
done

# Read-only AFTER the new units are in place and BEFORE the manifest. This does
# not stop a determined writer -- it can be undone with one chmod -- and it is not
# meant to. It removes the SILENT case: an accidental write to the trusted copy now
# fails loudly at the moment it happens. Prevention is impossible under
# bypassPermissions; making the act explicit is not.
for s in "${skills[@]}"; do chmod -R a-w "$cfg/skills/$s" || fail_step "cannot make $cfg/skills/$s read-only"; done
if [[ "$cur_host" == claude ]]; then
  chmod -R a-w "$cfg"/agents/$agent_glob 2>/dev/null || true
else
  for ((i=0; i<${#u_dst[@]}; i++)); do
    case "${u_dst[$i]}" in "$cfg"/agents/*) chmod a-w "${u_dst[$i]}" || fail_step "cannot make ${u_dst[$i]} read-only" ;; esac
  done
fi

# The manifest is written LAST and atomically (temp file + rename): an incomplete
# install never leaves a manifest that describes it.
mt="$cfg/.prod-skills.manifest.tmp.$$"; tmp_paths+=("$mt")
{ hash_tree "$cfg/skills" "${skills[@]}"; agents_hash; } | sort > "$mt" || fail_step "cannot write the manifest"
[[ -s "$mt" ]] || fail_step "the manifest came out empty"
if [[ "$cur_host" == codex ]]; then chmod 0444 "$mt" || fail_step "cannot chmod the manifest"; fi
mv "$mt" "$manifest" || fail_step "cannot move the manifest into place"

# The replaced units were renamed aside; delete the trash only now that the new
# install is complete and recorded. (Adopted ones stay as <path>.bak.<ts>.)
for ((i=0; i<${#u_old[@]}; i++)); do
  case "${u_old[$i]}" in
    "") ;;
    *.bak.*) ;;
    *) find "${u_old[$i]}" ! -type l -exec chmod u+w {} + 2>/dev/null
       rm -rf "${u_old[$i]}" || { echo "install: could not remove the replaced copy ${u_old[$i]}; the new install is complete, remove it by hand" >&2; trash_fail=1; } ;;
  esac
done
umask "$old_umask"
if [[ "$cur_host" == claude ]]; then
  echo "installed ${#skills[@]} skills + $(ls "$src"/agents/*.md 2>/dev/null | wc -l | tr -d ' ') agents as verified copies"
else
  echo "installed ${#skills[@]} skills + $n_roles agents as verified copies"
fi
echo "manifest: $manifest ($(wc -l <"$manifest" | tr -d ' ') files)"
echo
echo "Verify at any time (and from a cron or session hook):"
echo "  bash $src/install.sh --verify$( [[ "$cur_host" == claude ]] || echo " --host $cur_host" )"
(( trash_fail == 0 )) || return 7
}
for h in "${hosts[@]}"; do set_host "$h"; lock_host; done
for h in "${hosts[@]}"; do set_host "$h"; precheck_host; done
if (( refuse_sym )); then echo "install: nothing was installed (exit 4: destination is a symlink)" >&2; exit 4; fi
if (( refuse_foreign )); then echo "install: nothing was installed (exit 5: destinations not installed by this tool)" >&2; exit 5; fi
for h in "${hosts[@]}"; do
  set_host "$h"
  (( ${#hosts[@]} > 1 )) && echo "== host: $h =="
  install_host || exit $?
done
