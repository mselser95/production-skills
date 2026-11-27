# What is true today: the real cargo commands, nothing more. The fuller unit
# gates (cargo-deny, coverage, mutation testing) are a later change; when they
# exist they get their own targets here rather than being claimed early.
CARGO ?= cargo

.PHONY: check-fast check-nostd verify fmt

# Zone purity, enforced by the COMPILER: domain and app are built for a
# bare-metal target that has no `std`, so no file, socket, clock, thread or
# environment access can compile there, however it is spelled. The target is
# installed by rust-toolchain.toml (`targets`); tests/architecture.rs pins that
# this recipe and that file keep naming it.
check-nostd:
	$(CARGO) check --locked --lib -p svc-domain -p svc-app --target thumbv7em-none-eabi

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
