# What is true today: the real cargo commands, nothing more. The fuller unit
# gates (cargo-deny, coverage, mutation testing) are a later change; when they
# exist they get their own targets here rather than being claimed early.
CARGO ?= cargo

.PHONY: check-fast verify fmt

# Cheap gate: format, lints (warnings are errors), the whole test suite.
check-fast:
	$(CARGO) fmt --all --check
	$(CARGO) clippy --workspace --locked --all-targets -- -D warnings
	$(CARGO) test --workspace --locked

# Presubmit. Identical to `check-fast` for now, on purpose: no slower gate
# exists yet, and a target must not promise one.
verify: check-fast

fmt:
	$(CARGO) fmt --all
