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
#
# Exit 1 on verification failure, so it can gate a session or a cron.

set -uo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
manifest="$cfg/prod-skills.manifest"
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
  ( cd "$base" && find "$@" -type f ! -name 'config.sh' -print0 2>/dev/null \
      | sort -z | xargs -0 shasum -a 256 )
}

case "${1:-install}" in
  --verify|--diff)
    [[ -f "$manifest" ]] || { echo "no manifest at $manifest — run install.sh first" >&2; exit 1; }
    current=$(hash_tree "$cfg/skills" "${skills[@]}"; hash_tree "$cfg/agents" . 2>/dev/null)
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
      # The source side keeps its path (prefixed with the skill, since `find .`
      # yields ./SKILL.md in every one of them and the bare name would be
      # ambiguous across nine skills); only the hash is compared, exactly as
      # before, so which files this branch FIRES on is unchanged.
      stale_rows=$(comm -13 \
        <(hash_tree "$cfg/skills" "${skills[@]}" | awk '{print $1}' | sort) \
        <(for s in "${skills[@]}"; do
            # -L is load-bearing: in the source repo the shared material reaches
            # each skill through a references/ SYMLINK, and plain `find -type f`
            # skips symlinks — which would silently exclude _shared/ from the
            # source side and make this whole check blind to the files most
            # worth watching (the probes). Verified: without -L, editing
            # _shared/probes/verify-standard.sh went undetected.
            # Same file set as hash_tree above -- every regular file. Filtering
            # by extension here while hash_tree hashes everything would leave the
            # staleness check blind to exactly the files the manifest just
            # started protecting (prod-new's template sources).
            [[ -d "$src/$s" ]] && ( cd "$src/$s" && find -L . -type f ! -name 'config.sh' \
                -exec shasum -a 256 {} + 2>/dev/null )
          done | awk '{print $1}' | sort) )
      stale=$(printf '%s' "$stale_rows" | grep -c . || true)
      if (( stale > 0 )); then
        echo "STALE INSTALL — ${stale} source file(s) in $src are not present in the installed copy." >&2
        # Map each stale hash back to the path(s) carrying it, so the operator
        # sees WHICH component is untrusted without rerunning this comparison.
        while read -r h; do
          [[ -n "$h" ]] || continue
          for s in "${skills[@]}"; do
            [[ -d "$src/$s" ]] || continue
            ( cd "$src/$s" && find -L . -type f ! -name 'config.sh' \
                -exec shasum -a 256 {} + 2>/dev/null ) \
              | awk -v h="$h" -v s="$s" '$1==h {sub(/^\.\//,"",$2); print "  stale: " s "/" $2}'
          done
        done <<<"$stale_rows" | sort -u >&2
        echo "The manifest is intact but describes an OLDER trusted set. Re-run install.sh." >&2
        exit 2
      fi
      exit 0
    fi
    echo "TCB DRIFT — the installed skills no longer match the manifest:" >&2
    [[ "$1" == --diff ]] && diff <(sort "$manifest") <(echo "$current" | sort) >&2
    diff <(sort "$manifest") <(echo "$current" | sort) 2>/dev/null | grep -E '^[<>]' | \
      awk '{print ($1==">" ? "  changed/added: " : "  missing/was:   ") $3}' | sort -u >&2
    echo "Re-run install.sh only after reviewing the change: this is the trusted set." >&2
    exit 1
    ;;
esac

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

mkdir -p "$cfg/skills" "$cfg/agents"
# The installed copy is left READ-ONLY at the end of this script, so make it
# writable again before rewriting it. install.sh is the only legitimate writer:
# any other in-place edit of an installed skill is tampering by definition,
# which is what makes read-only the right protection HERE and the wrong one on
# a repo's registries/ or verification/ratified/ (those receive legitimate
# edits constantly, and a guard that blocks normal work is a guard that gets
# turned off).
chmod -R u+w "$cfg/skills" "$cfg/agents" 2>/dev/null || true
for s in "${skills[@]}"; do
  rm -rf "$cfg/skills/$s"
  cp -R "$src/$s" "$cfg/skills/$s"
  # shared material travels as real files, resolved from the repo's symlinks
  if [[ -d "$src/$s/references" ]]; then
    rm -rf "$cfg/skills/$s/references"; mkdir -p "$cfg/skills/$s/references"
    for r in "$src/$s/references"/*; do
      [[ -e "$r" ]] || continue
      if [[ -d "$r" ]]; then mkdir -p "$cfg/skills/$s/references/$(basename "$r")"
        cp -RL "$r"/* "$cfg/skills/$s/references/$(basename "$r")/" 2>/dev/null || true
      else cp -L "$r" "$cfg/skills/$s/references/$(basename "$r")"; fi
    done
  fi
  # per-skill config stays LOCAL and unhashed: it holds org facts, not policy
  [[ -f "$src/$s/config.sh" ]] && cp "$src/$s/config.sh" "$cfg/skills/$s/config.sh"
done
# Remove first, then copy. `cp -f` onto an existing SYMLINK follows it and
# writes through to the target, so a hand-made symlink survives every install --
# and `find -type f` skips symlinks, which kept the three agent definitions out
# of the manifest entirely in one config dir while they were hashed in the
# other. Agent definitions carry the write-masks that bound what a cheap model
# may touch; an unhashed one is an unverified security instruction.
for a in "$src"/agents/*.md; do
  [[ -e "$a" ]] || continue
  rm -f "$cfg/agents/$(basename "$a")"
  cp "$a" "$cfg/agents/$(basename "$a")"
done

{ hash_tree "$cfg/skills" "${skills[@]}"; hash_tree "$cfg/agents" . 2>/dev/null; } | sort > "$manifest"

# Read-only, AFTER the manifest is written. This does not stop a determined
# writer -- it can be undone with one chmod -- and it is not meant to. It
# removes the SILENT case: an accidental or incidental write to the trusted copy
# now fails loudly at the moment it happens, instead of being discovered later by
# the drift check, or not at all. Prevention is impossible under
# bypassPermissions; making the act explicit is not.
for s in "${skills[@]}"; do chmod -R a-w "$cfg/skills/$s" 2>/dev/null || true; done
chmod -R a-w "$cfg"/agents/prod-*.md 2>/dev/null || true
echo "installed ${#skills[@]} skills + $(ls "$src"/agents/*.md 2>/dev/null | wc -l | tr -d ' ') agents as verified copies"
echo "manifest: $manifest ($(wc -l <"$manifest" | tr -d ' ') files)"
echo
echo "Verify at any time (and from a cron or session hook):"
echo "  bash $src/install.sh --verify"
