#!/usr/bin/env bash
# stamp-template-provenance.sh — record WHICH files this repo vendored from the
# standard, and what they hashed when it did.
#
# Run once by prod-new at scaffold time, and again by whoever LANDS a template
# update (after the update is reviewed and merged — never before, or the stamp
# certifies a state nobody checked).
#
# The list below is the vendored set: files that are COPIES of framework
# artifacts rather than this repo's own work. A file added here that the repo
# actually authors would produce permanent false drift; a framework copy left
# out of it rots invisibly, which is the failure this exists to end. When you
# vendor something new, add it here in the same commit.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2

VENDORED=(
  scripts/verify-standard.sh
  scripts/check-registries.sh
  scripts/error-handling-fitness.sh
  scripts/gate-hygiene-fitness.sh
  scripts/kill-durability.sh
  scripts/check-template-drift.sh
  scripts/row-vacuity-sweep.sh
  scripts/no-unfilled-slots.sh
  scripts/coverage.sh
  scripts/changed-line-coverage.sh
  # The stamper itself. Added 2026-08-30, and its absence was the sharpest
  # instance of the shape this file's header warns about: the script that
  # RECORDS which files came from the standard was not among them, so an edit
  # to it drifted invisibly in every scaffolded repo. Found by the new
  # producer-side digest reporting "in step" after this very file was edited.
  scripts/stamp-template-provenance.sh
  # DELIBERATELY NOT LISTED: scripts/coverage-floors.txt. Its own header says
  # "generated from the measured per-package coverage on the scaffold's first
  # run" -- it is per-repo DATA, not a framework artifact, and listing it would
  # produce permanent false drift in every repo that ever raises a floor. That
  # is the failure mode this list's header names; recording the exclusion here
  # so the next reader does not "fix" the omission.
  scripts/tests/non-vacuity-selftest.sh
  scripts/tests/sbom-ordering-selftest.sh
  scripts/tests/probe-self-gate-selftest.sh
  scripts/tests/load-rows-selftest.sh
  scripts/tests/check-registries-selftest.sh
  scripts/tests/error-handling-fitness-selftest.sh
  scripts/tests/kill-durability-state-selftest.sh
  benchmarks/load/loadgen.go
)

mkdir -p .prod
out=".prod/template-provenance.yaml"
TPL="${TEMPLATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/prod-new/template}"
# THE VERSION IS READ FROM A FILE, not resolved with git, and the previous
# version of this line is why. It ran
#   git -C ${CLAUDE_CONFIG_DIR}/skills/prod-new rev-parse --short HEAD
# against a directory install.sh produces by COPYING files. It is not a git work
# tree and never was, so `git rev-parse` failed every single time and this field
# recorded `production-skills@unknown` in every scaffold ever stamped. Measured
# 2026-08-30: `fatal: not a git repository`. A version field that always says
# `unknown` is worse than an absent one -- it looks answered.
#
# TEMPLATE-DIGEST sits beside the template inside the prod-new skill, so
# install.sh copies it like everything else and it is readable wherever the
# template is. It is a content hash over the vendored set, which means it cannot
# go stale the way a hand-bumped number does.
_digest_file="${TEMPLATE_DIGEST_FILE:-$TPL/../TEMPLATE-DIGEST}"
if [[ -r "$_digest_file" ]]; then
  src_commit="$(awk '/^short:/{print $2}' "$_digest_file")"
  [[ -n "$src_commit" ]] || src_commit="unreadable-digest"
else
  # NOT "unknown". The two states are different and the reader needs to tell
  # them apart: this one means the template was installed without its digest,
  # which is a broken install rather than an old one.
  src_commit="no-digest-beside-template"
fi

{
  printf '# Scaffold provenance — which files this repo VENDORED from the standard,\n'
  printf '# and what each hashed when it was stamped. scripts/check-template-drift.sh\n'
  printf '# compares against these: a repo copy that no longer matches was edited HERE\n'
  printf '# (a fork of the standard under the standard'"'"'s name); a TEMPLATE copy that no\n'
  printf '# longer matches means the standard moved and this repo is behind.\n'
  printf '#\n'
  printf '# Re-stamp only after a template update has been REVIEWED and landed. A stamp\n'
  printf '# taken to silence the drift report certifies a state nobody checked, which is\n'
  printf '# strictly worse than the red it replaced.\n'
  printf 'stamped_from: production-skills@%s\n' "$src_commit"
  printf 'files:\n'
} > "$out"

n=0
for f in "${VENDORED[@]}"; do
  [[ -f "$f" ]] || continue
  # TWO hashes per file, and the second is what makes this work at all.
  # A scaffolded repo's copy legitimately differs from the template's, because
  # prod-new substitutes <OWNER>/<SERVICE> into it — so comparing the repo's
  # file against the TEMPLATE's file reports drift on every slot-bearing file
  # forever. Measured: the first version of this stamp did exactly that and
  # flagged verify-standard.sh and kill-durability.sh as "behind upstream" on a
  # tree copied from the template seconds earlier. Recording both sides fixes
  # it: `sha256` is this repo's instantiated file, `template_sha256` is the
  # uninstantiated file it came from, and each is compared against its own
  # counterpart.
  tsha=""
  if [[ -n "${TPL:-}" && -f "$TPL/$f" ]]; then
    tsha="$(shasum -a 256 "$TPL/$f" | awk '{print $1}')"
  fi
  printf -- '  - path: %s\n    sha256: %s\n    template_sha256: %s\n' \
    "$f" "$(shasum -a 256 "$f" | awk '{print $1}')" "${tsha:-unknown}" >> "$out"
  n=$((n+1))
done

# A stamp over zero files is not a stamp. It would make check-template-drift.sh
# report a clean comparison having compared nothing.
if (( n == 0 )); then
  printf 'stamp-template-provenance: no vendored files found -- refusing to write an empty stamp.\n' >&2
  exit 2
fi
printf 'stamped %d vendored file(s) into %s (from production-skills@%s)\n' "$n" "$out" "$src_commit"
