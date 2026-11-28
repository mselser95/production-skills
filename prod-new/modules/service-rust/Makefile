# What is true today: the real cargo commands, nothing more. The fuller unit
# gates (cargo-deny, coverage, mutation testing) are a later change; when they
# exist they get their own targets here rather than being claimed early.
CARGO ?= cargo

.PHONY: check-fast check-nostd verify fmt

# Zone purity, by the COMPILER, as a convenience for a fast local loop: domain
# and app are built for a bare-metal target that has no `std` (so no file,
# socket, clock, thread or environment access compiles there, however it is
# spelled), with `-F unsafe_code` forced on the rustc command line (an
# attribute or a `[lints]` table cannot lower it). Nothing rests on this
# recipe: tests/architecture.rs runs the same compile itself, so editing this
# file cannot turn the property off, and `check-fast` does not call it. The target is installed by
# rust-toolchain.toml (`targets`).
check-nostd:
	$(CARGO) rustc --locked --profile check --manifest-path crates/domain/Cargo.toml --lib --all-features --target thumbv7em-none-eabi -- -F unsafe_code
	$(CARGO) rustc --locked --profile check --manifest-path crates/app/Cargo.toml --lib --all-features --target thumbv7em-none-eabi -- -F unsafe_code

# Cheap gate: format, lints (warnings are errors), the whole test suite, which
# includes the zone-purity compile (tests/architecture.rs, not `check-nostd`).
check-fast:
	$(CARGO) fmt --all --check
	$(CARGO) clippy --workspace --locked --all-targets -- -D warnings
	$(CARGO) test --workspace --locked

# Presubmit. Identical to `check-fast` for now, on purpose: no slower gate
# exists yet, and a target must not promise one.
verify: check-fast

fmt:
	$(CARGO) fmt --all
