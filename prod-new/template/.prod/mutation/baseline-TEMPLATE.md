# Mutation baseline — placeholder (scaffold commit)

**Status:** placeholder. No mutation run has executed yet — this template
has no standalone git history for `.github/workflows/nightly.yaml`'s
`mutation-baseline` job to have run against.

**The real command** this placeholder stands in for (advisory only, never
a PR gate — `tier-policy.yaml`: `mutation.mode = advisory`):

```sh
go install github.com/go-gremlins/gremlins/cmd/gremlins@latest
mkdir -p .prod/mutation
gremlins unleash ./internal/domain \
  --workers 2 --timeout-coefficient 2 \
  --output .prod/mutation/domain_mutations.json
gremlins unleash ./internal/app \
  --workers 2 --timeout-coefficient 2 \
  --output .prod/mutation/app_mutations.json
```

The nightly workflow's `mutation-baseline` job runs exactly this (see
`.github/workflows/nightly.yaml`) and uploads
`.prod/mutation/*_mutations.json` as a build artifact plus a
`baseline-<sha>.md` summary here on its first real run.
