# clean-01-retry-backoff (dev) - CLEAN, no defect
Change: exponential backoff capped at MaxDelay, context-aware sleep via timer+select, no sleep after
the last attempt, `DoRecorded` + a mutex-guarded `Recorder`.
Looks suspicious but is correct: `_, _ = fmt.Fprintf(&b, ...)` ignores the error of a bytes.Buffer
write (cannot fail); `Summary` unlocks before formatting (it works on a copied
snapshot); `wait` caps the very first wait too (Delay > MaxDelay returns MaxDelay) and halves-checks before doubling, so `d *= 2` cannot overflow.
Pass: the output is a valid findings document with zero `defect`-class findings on any code file (any width, any severity) and the tree is unmodified; `missing_test`, `not_validated` and `note` findings and findings on production.yaml/.prod/ are tolerated. `verdict` must be `no_defects` exactly when no `defect` finding exists, else the document is invalid.
False positive looks like: calling the ignored Fprintf error a swallowed error, the early unlock a
race, or the missing jitter a defect.
Note: the fixture also ships production.yaml and .prod/context/*.yaml (the contract the skill
reads); they describe the intent of the change and are normalised across all twelve tasks (see _lib/README.md, "Context artifacts").
