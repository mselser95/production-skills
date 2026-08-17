# .prod/mutation — mutation-testing trend artifacts

Mutation testing is ALWAYS advisory, all tiers (`tier-policy.yaml`:
`mutation: { mode: advisory, scope: changed_code, cap_mutants_per_pr: 20 }`
— tooling immaturity + Goodhart's law). It runs on the nightly trend lane
(`.github/workflows/nightly.yaml`'s `mutation-baseline` job), never as a PR
gate, and its output lands here as `baseline-<sha>.md`.

This scaffold ships `baseline-TEMPLATE.md`: a placeholder that NAMES the
real command (`gremlins`) rather than a fake result, because no mutation
run has executed against this template's own commit history yet — the
nightly job produces the first real `baseline-<sha>.md` once this repo has
a standalone git history to run against.
