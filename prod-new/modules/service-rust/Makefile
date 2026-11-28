# What is true today: the real cargo commands, nothing more. The fuller unit
# gates (cargo-deny, coverage, mutation testing) are a later change; when they
# exist they get their own targets here rather than being claimed early.
CARGO ?= cargo

.PHONY: check-fast check-nostd verify fmt

# Zone purity, enforced by the COMPILER: domain and app are built for a
# bare-metal target that has no `std`, so no file, socket, clock, thread or
# environment access can compile there, however it is spelled. `--all-features`
# is a second layer (the crates declare none; tests/architecture.rs pins that).
# The target is installed by rust-toolchain.toml (`targets`); the recipe is
# pinned by tests/architecture.rs as ONE exact line, so it cannot be turned
# into a no-op (a `-` prefix, `|| true`, `.IGNORE`) without a RED test.
check-nostd:
	$(CARGO) check --locked --lib -p svc-domain -p svc-app --all-features --target thumbv7em-none-eabi

# Cheap gate: format, lints (warnings are errors), zone purity, the whole test suite.
check-fast: check-nostd
	$(CARGO) fmt --all --check
	$(CARGO) clippy --workspace --locked --all-targets -- -D warnings
	$(CARGO) test --workspace --locked

# Presubmit. Identical to `check-fast` for now, on purpose: no slower gate
# exists yet, and a target must not promise one.
verify: check-fast

fmt:
	$(CARGO) fmt --all
