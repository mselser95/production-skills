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
src_commit="$(git -C "${TEMPLATE_SRC:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/prod-new}" rev-parse --short HEAD 2>/dev/null || echo unknown)"

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
