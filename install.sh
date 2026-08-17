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
skills=(prod-spec prod-review prod-incident prod-implement prod-test-synth prod-ops prod-curate prod-bootstrap)

hash_tree() { # print "<sha256>  <relative path>" for every tracked TCB file
  local base="$1"; shift
  ( cd "$base" && find "$@" -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.sh' \) \
      ! -name 'config.sh' -print0 2>/dev/null | sort -z | xargs -0 shasum -a 256 )
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
      stale=$(comm -13 \
        <(hash_tree "$cfg/skills" "${skills[@]}" | awk '{print $1}' | sort) \
        <(for s in "${skills[@]}"; do
            # -L is load-bearing: in the source repo the shared material reaches
            # each skill through a references/ SYMLINK, and plain `find -type f`
            # skips symlinks — which would silently exclude _shared/ from the
            # source side and make this whole check blind to the files most
            # worth watching (the probes). Verified: without -L, editing
            # _shared/probes/verify-standard.sh went undetected.
            [[ -d "$src/$s" ]] && ( cd "$src/$s" && find -L . -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.sh' \) \
                ! -name 'config.sh' -exec shasum -a 256 {} + 2>/dev/null )
          done | awk '{print $1}' | sort) | wc -l | tr -d ' ')
      if (( stale > 0 )); then
        echo "STALE INSTALL — ${stale} source file(s) in $src are not present in the installed copy." >&2
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

mkdir -p "$cfg/skills" "$cfg/agents"
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
cp -f "$src"/agents/*.md "$cfg/agents/" 2>/dev/null || true

{ hash_tree "$cfg/skills" "${skills[@]}"; hash_tree "$cfg/agents" . 2>/dev/null; } | sort > "$manifest"
echo "installed ${#skills[@]} skills + $(ls "$src"/agents/*.md 2>/dev/null | wc -l | tr -d ' ') agents as verified copies"
echo "manifest: $manifest ($(wc -l <"$manifest" | tr -d ' ') files)"
echo
echo "Verify at any time (and from a cron or session hook):"
echo "  bash $src/install.sh --verify"
