# .prod/context — resolved contexts and change plans

Every task executed against this repo (via `prod-spec` → `prod-implement`)
leaves its resolved-context + change-plan pair here, so a diff can always
be audited against what it claimed to do (`prod-review`'s Phase 1).

`resolved-context.yaml` and `change-plan.yaml` in this directory document
this scaffold's OWN first commit — the change that created this repo in
the first place, produced by `prod-new`'s Phase 2. Every subsequent task
adds its own pair (conventionally suffixed by task id or date); nothing
here is ever deleted, only added to.
