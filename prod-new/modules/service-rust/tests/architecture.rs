//! What the Cargo workspace cannot express by itself.
//!
//! Zone purity: `domain` and `app` can reach no file, socket, clock, thread or
//! environment, and contain no `unsafe`. The rule this file follows: it does
//! not RECOGNISE spellings in text (four review rounds each found a new
//! spelling that got through), it ASKS THE COMPILER, with arguments of its
//! own: a scrubbed environment, config overrides, and a probe that proves the
//! gate is armed (what is and is not covered is in the README's "compiler gate
//! itself" row; the test files and the Makefile are outside any in-tree test).
//!
//! 1. The compiler gate (`compile_forbidding_unsafe`): this test runs, by
//!    itself, `cargo rustc --lib --all-features --target thumbv7em-none-eabi
//!    --profile check -- -F unsafe_code` on `domain` and on `app`. The target
//!    has no `std`, so any `std` item and any spelling of `extern crate std`
//!    (`r#std` too) is E0463; `-F unsafe_code` is a forbid set on the rustc
//!    command line, which an attribute or a `[lints]` table cannot lower
//!    (`#![allow(unsafe_code)]` is E0453). Nothing here goes through `make` or
//!    a variable the Makefile owns. A missing target FAILS with the install
//!    hint; it never skips. Code behind a `cfg` is not built there, hence:
//! 2. L1 (here): the list of source files the COMPILER read in the HOST build
//!    of the workspace (rustc's dep-info, which names every file including
//!    `#[path]` modules and `include!`d files) must all sit inside the crate's
//!    own `src/`. Alone it guards ownership (a pure crate's code lives in its
//!    `src/`), not purity: the file would still be compiled by the gate.
//! 3. L2 (here): none of those files may contain the word `cfg` (except a line
//!    that is exactly `#[cfg(test)]`), nor `include!`-family macros. Alone it
//!    guards the one thing the gate cannot see: `std` behind a `cfg` that is
//!    false on the bare-metal target.
//! 4. L3 (here): `domain` and `app` declare no features and no optional
//!    dependency, and nothing enables a feature on them or turns their default
//!    features off. Defence in depth: the gate builds with `--all-features`, so
//!    on its own L3 guards nothing the gate does not already.
//!
//! The fixtures at the end of this file run ONE attack each on a copy of the
//! domain crate through the same functions: the layer that must catch it goes
//! RED, every other layer stays clean, and an unattacked control passes.
//!
//! Why L2 refuses a word instead of parsing: without proc macros and build
//! scripts (both refused below) the identifier `cfg` cannot be synthesised by
//! `macro_rules!`, so a source with no `cfg` token has no conditional
//! compilation; and `#[cfg(test)]` code exists only in test builds. A comment
//! that mentions the word is refused too (no comment stripping, on purpose).
//!
//! The Makefile is NOT pinned any more: nothing rests on its text. The
//! remaining rules are source scans and WEAKER: only `config.rs` reads the
//! environment, and the bearer token is compared through the constant-time
//! helper.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::OnceLock;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

// ---- a minimal JSON reader, enough for `cargo metadata` (no dependency) ----

#[derive(Debug)]
enum Json {
    Obj(Vec<(String, Json)>),
    Arr(Vec<Json>),
    Str(String),
    Bool(bool),
    Other,
}

struct P<'a>(&'a [u8], usize);

impl P<'_> {
    fn ws(&mut self) {
        while self.0.get(self.1).is_some_and(u8::is_ascii_whitespace) {
            self.1 += 1;
        }
    }
    fn eat(&mut self, b: u8) {
        self.ws();
        assert_eq!(self.0.get(self.1), Some(&b), "json at {}", self.1);
        self.1 += 1;
    }
    fn peek(&mut self) -> u8 {
        self.ws();
        *self.0.get(self.1).unwrap()
    }
    fn string(&mut self) -> String {
        self.eat(b'"');
        let mut out = Vec::new();
        loop {
            let b = self.0[self.1];
            self.1 += 1;
            match b {
                b'"' => return String::from_utf8(out).unwrap(),
                b'\\' => {
                    let e = self.0[self.1];
                    self.1 += 1;
                    if e == b'u' {
                        self.1 += 4; // names here are ASCII; skip the escape
                        out.push(b'?');
                    } else {
                        out.push(match e {
                            b'n' => b'\n',
                            b't' => b'\t',
                            b'r' => b'\r',
                            other => other,
                        });
                    }
                }
                other => out.push(other),
            }
        }
    }
    fn value(&mut self) -> Json {
        match self.peek() {
            b'{' => {
                self.eat(b'{');
                let mut fields = Vec::new();
                while self.peek() != b'}' {
                    let k = self.string();
                    self.eat(b':');
                    fields.push((k, self.value()));
                    if self.peek() == b',' {
                        self.eat(b',');
                    }
                }
                self.eat(b'}');
                Json::Obj(fields)
            }
            b'[' => {
                self.eat(b'[');
                let mut items = Vec::new();
                while self.peek() != b']' {
                    items.push(self.value());
                    if self.peek() == b',' {
                        self.eat(b',');
                    }
                }
                self.eat(b']');
                Json::Arr(items)
            }
            b'"' => Json::Str(self.string()),
            b't' if self.0[self.1..].starts_with(b"true") => {
                self.1 += 4;
                Json::Bool(true)
            }
            b'f' if self.0[self.1..].starts_with(b"false") => {
                self.1 += 5;
                Json::Bool(false)
            }
            _ => {
                while !matches!(self.0.get(self.1), Some(b',' | b'}' | b']') | None) {
                    self.1 += 1;
                }
                Json::Other
            }
        }
    }
}

fn field<'a>(o: &'a Json, key: &str) -> &'a Json {
    let Json::Obj(fields) = o else {
        panic!("not an object: {o:?}")
    };
    &fields.iter().find(|(k, _)| k == key).unwrap().1
}

fn text(j: &Json) -> &str {
    let Json::Str(s) = j else {
        panic!("not a string: {j:?}")
    };
    s
}

fn cargo() -> String {
    std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_owned())
}

/// `cargo metadata --no-deps`, run once for the whole test binary.
fn metadata() -> &'static Json {
    static META: OnceLock<Json> = OnceLock::new();
    META.get_or_init(|| {
        let out = Command::new(cargo())
            .args([
                "metadata",
                "--format-version",
                "1",
                "--no-deps",
                "--offline",
            ])
            .current_dir(root())
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        P(&out.stdout, 0).value()
    })
}

fn packages(meta: &Json) -> &[Json] {
    let Json::Arr(packages) = field(meta, "packages") else {
        panic!("no packages")
    };
    packages
}

fn strings(j: &Json) -> Vec<String> {
    let Json::Arr(items) = j else {
        panic!("not an array: {j:?}")
    };
    items.iter().map(|k| text(k).to_owned()).collect()
}

fn flag(j: &Json) -> bool {
    let Json::Bool(b) = j else {
        panic!("not a bool: {j:?}")
    };
    *b
}

/// package -> sorted dependency names (normal + dev + build), straight from
/// Cargo's own view of the workspace.
fn dependency_graph() -> BTreeMap<String, Vec<String>> {
    packages(metadata())
        .iter()
        .map(|p| {
            let Json::Arr(deps) = field(p, "dependencies") else {
                panic!("no dependencies")
            };
            let mut names: Vec<String> = deps
                .iter()
                .map(|d| text(field(d, "name")).to_owned())
                .collect();
            names.sort();
            (text(field(p, "name")).to_owned(), names)
        })
        .collect()
}

/// package -> the `kind` of each of its cargo targets, joined (`lib`, `test`,
/// `custom-build`, `proc-macro`, ...), from `cargo metadata`.
fn target_kinds() -> BTreeMap<String, Vec<String>> {
    packages(metadata())
        .iter()
        .map(|p| {
            let Json::Arr(targets) = field(p, "targets") else {
                panic!("no targets")
            };
            let kinds = targets
                .iter()
                .flat_map(|t| strings(field(t, "kind")))
                .collect();
            (text(field(p, "name")).to_owned(), kinds)
        })
        .collect()
}

#[test]
fn the_dependency_graph_is_exactly_the_zone_rule() {
    let want: BTreeMap<String, Vec<String>> = [
        ("svc-domain", vec![]),
        ("svc-app", vec!["svc-domain"]),
        ("svc-adapter", vec!["svc-app", "svc-domain"]),
        ("svc-platform", vec!["ctrlc", "svc-app"]),
        (
            "svc",
            vec!["svc-adapter", "svc-app", "svc-domain", "svc-platform"],
        ),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_owned(), v.into_iter().map(str::to_owned).collect()))
    .collect();
    assert_eq!(
        dependency_graph(),
        want,
        "a zone's dependency list changed: that IS the architecture"
    );
}

#[test]
fn every_member_inherits_the_workspace_lints() {
    for member in [
        "Cargo.toml",
        "crates/domain/Cargo.toml",
        "crates/app/Cargo.toml",
        "crates/adapter/Cargo.toml",
        "crates/platform/Cargo.toml",
    ] {
        let t = squash(&fs::read_to_string(root().join(member)).unwrap());
        assert!(t.contains("[lints]workspace=true"), "{member}");
    }
}

#[test]
fn the_release_profile_keeps_overflow_checks_and_unwinds() {
    let t = squash(&fs::read_to_string(root().join("Cargo.toml")).unwrap());
    assert!(t.contains("[profile.release]"));
    assert!(t.contains("overflow-checks=true"));
    assert!(t.contains("panic=\"unwind\""));
}

// ---- the compiler gate: the test ASKS THE COMPILER, with flags no checked file can override ----

/// The bare-metal target `domain` and `app` are compiled for. It has no `std`.
const NOSTD_TARGET: &str = "thumbv7em-none-eabi";

/// How many nested `cargo` runs the checks in this file started (counted so
/// the README number is measured, not remembered).
static NESTED_CARGO_RUNS: AtomicUsize = AtomicUsize::new(0);

/// Environment variables that can hand the nested compile a wrapper, another
/// compiler or extra flags. Each is REMOVED from the nested cargo's
/// environment, together with every `CARGO_TARGET_*_{RUSTFLAGS,LINKER,RUNNER}`.
const SCRUBBED_ENV: [&str; 10] = [
    "RUSTC_WRAPPER",
    "RUSTC_WORKSPACE_WRAPPER",
    "RUSTC",
    "RUSTDOC",
    "RUSTFLAGS",
    "CARGO_ENCODED_RUSTFLAGS",
    "CARGO_BUILD_RUSTFLAGS",
    "CARGO_BUILD_RUSTC",
    "CARGO_BUILD_RUSTC_WRAPPER",
    "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER",
];

/// `rustc` as the PATH of THIS process finds it, as an absolute path. The
/// nested cargo is given it as `RUSTC`, which (measured) beats a `build.rustc`
/// key from any config file.
fn resolved_rustc() -> PathBuf {
    let path = std::env::var_os("PATH").expect("PATH is not set");
    std::env::split_paths(&path)
        .map(|d| d.join("rustc"))
        .find(|p| p.is_file())
        .expect("no `rustc` on PATH")
}

/// Closes every door a cargo configuration or the environment has to the
/// nested compile. `extra` is environment the CALLER of the test is imagined
/// to have set (a fixture simulates it; it is applied first, then scrubbed).
///
/// Measured on the pinned toolchain (cargo 1.99.1):
/// * `--config 'build.rustc-wrapper=""'` and `--config
///   'build.rustc-workspace-wrapper=""'` are accepted and beat any config
///   FILE (a string key: the highest source wins);
/// * `--config 'build.rustflags=[]'` is accepted and does NOTHING: list keys
///   from all sources are concatenated, so an empty list removes nothing.
///   What works is the environment: a (even empty) `CARGO_ENCODED_RUSTFLAGS`
///   is cargo's first choice and then NO `build.rustflags` or
///   `target.*.rustflags` key from any file is read at all;
/// * `build.rustc` from a file is beaten by `RUSTC` in the environment, and
///   it must be an absolute path (a bare name is looked up on a PATH that an
///   `[env]` table with `force = true` can change);
/// * a config `[env]` table does not set cargo's own wrapper (it only
///   decorates the processes cargo starts), and it refuses `RUSTUP_TOOLCHAIN`.
fn harden(c: &mut Command, extra: &[(String, String)]) {
    let mut names: BTreeSet<OsString> = std::env::vars_os().map(|(k, _)| k).collect();
    for (k, v) in extra {
        c.env(k, v);
        names.insert(OsString::from(k));
    }
    for name in names {
        let s = name.to_string_lossy();
        let per_target = s.starts_with("CARGO_TARGET_")
            && ["_RUSTFLAGS", "_LINKER", "_RUNNER"]
                .iter()
                .any(|suffix| s.ends_with(suffix));
        if per_target || SCRUBBED_ENV.contains(&s.as_ref()) {
            c.env_remove(&name);
        }
    }
    c.env("CARGO_ENCODED_RUSTFLAGS", "");
    c.env("RUSTC", resolved_rustc());
    c.args([
        "--config",
        "build.rustc-wrapper=\"\"",
        "--config",
        "build.rustc-workspace-wrapper=\"\"",
    ]);
}

/// A Cargo workspace the zone checks run against: this module, or a fixture.
#[derive(Clone)]
struct Tree {
    root: PathBuf,
    /// `None`: Cargo's own choice (the `CARGO_TARGET_DIR` the test runs under).
    target_dir: Option<PathBuf>,
    /// The real tree has a lockfile that must not move; a fixture has none.
    locked: bool,
    /// Layer 2 (clean environment + config overrides). Only the fixture that
    /// pins the probe turns it off.
    scrub: bool,
    /// Environment a fixture imagines the test's caller to have set.
    env: Vec<(String, String)>,
}

impl Tree {
    fn real() -> Self {
        Self {
            root: root(),
            target_dir: None,
            locked: true,
            scrub: true,
            env: Vec::new(),
        }
    }

    /// `cargo <sub> --offline [--locked] [--target-dir ..]`, run in the tree.
    fn cargo(&self, sub: &str) -> Command {
        NESTED_CARGO_RUNS.fetch_add(1, Ordering::SeqCst);
        let mut c = Command::new(cargo());
        c.current_dir(&self.root).arg(sub).arg("--offline");
        if self.locked {
            c.arg("--locked");
        }
        if let Some(dir) = &self.target_dir {
            c.arg("--target-dir").arg(dir);
        }
        if self.scrub {
            harden(&mut c, &self.env);
        } else {
            for (k, v) in &self.env {
                c.env(k, v);
            }
        }
        c
    }
}

/// The unit of a pure crate that is compiled for the no-std target: its lib,
/// with every feature on (code behind a declared feature is built too).
fn nostd_unit(target: &str) -> Vec<String> {
    ["--lib", "--all-features", "--target", target]
        .map(str::to_owned)
        .to_vec()
}

/// Why a compile failed, for a person: the tail of the compiler's output, and
/// for a missing target the one-line reason this is a FAILURE and not a skip.
fn compiler_failure(stderr: &str) -> String {
    let lines: Vec<&str> = stderr.lines().collect();
    let tail = lines[lines.len().saturating_sub(40)..].join("\n");
    if stderr.contains("may not be installed") {
        return format!(
            "a compile target is not installed (rust-toolchain.toml lists it; install it as the hint below says). This check never skips, because a skipped compile proves nothing about `std`.\n{tail}"
        );
    }
    tail
}

/// Compiles ONE unit of the crate at `rel` (relative to the tree) with
/// `-F unsafe_code` on the rustc command line (`cargo rustc ... -- -F
/// unsafe_code`). A forbid set there cannot be lowered by an attribute in the
/// crate (`#![allow(unsafe_code)]` is error E0453) or by a `[lints]` table, so
/// no property rests on those files being intact. `cargo rustc` passes the
/// flag to THIS crate only, never to a dependency. `Err` carries the reason.
fn compile_forbidding_unsafe(tree: &Tree, rel: &str, unit: &[String]) -> Result<(), String> {
    let out = tree
        .cargo("rustc")
        .arg("--manifest-path")
        .arg(tree.root.join(rel).join("Cargo.toml"))
        .args(["--profile", "check"])
        .args(unit)
        .args(["--", "-F", "unsafe_code"])
        .output()
        .unwrap();
    if out.status.success() {
        Ok(())
    } else {
        Err(compiler_failure(&String::from_utf8_lossy(&out.stderr)))
    }
}

// ---- layer 1: no cargo configuration in or above the module ----
//
// Cargo reads `.cargo/config.toml` (or `config`) from the working directory
// and EVERY parent directory, and `$CARGO_HOME/config.toml`. A config can name
// a rustc wrapper, extra rustflags, another rustc. So the module refuses any
// of those files in its own tree (target/ and .git skipped) and in the
// directories above it up to the repository root (the nearest directory with a
// `.git`; the filesystem root when there is none). `$CARGO_HOME` is the
// user's own machine and is out of scope. This is detection of what can be
// seen; layer 2 (`harden`) neutralises it for the nested compile and layer 3
// (`armed`) probes the result, so no one layer carries the property alone.

/// The only keys of `rust-toolchain.toml`'s `[toolchain]` table the module
/// accepts. `path` (a custom toolchain directory, whose `rustc` could be
/// anything) is not among them, and neither is any unknown key.
const TOOLCHAIN_KEYS: [&str; 4] = ["channel", "components", "targets", "profile"];

fn cargo_config_files(dir: &Path) -> Vec<PathBuf> {
    [".cargo/config.toml", ".cargo/config"]
        .iter()
        .map(|rel| dir.join(rel))
        .filter(|p| p.symlink_metadata().is_ok())
        .collect()
}

fn configs_below(dir: &Path, out: &mut Vec<PathBuf>) {
    out.extend(cargo_config_files(dir));
    let mut entries: Vec<_> = fs::read_dir(dir).unwrap().map(|e| e.unwrap()).collect();
    entries.sort_by_key(fs::DirEntry::file_name);
    for e in entries {
        let name = e.file_name();
        if name == "target" || name == ".git" || !e.file_type().unwrap().is_dir() {
            continue;
        }
        configs_below(&e.path(), out);
    }
}

/// The nearest directory at or above `module` that holds a `.git` (file or
/// directory): the repository root. `/` when there is none.
fn repository_root(module: &Path) -> PathBuf {
    module
        .ancestors()
        .find(|d| d.join(".git").exists())
        .map_or_else(|| PathBuf::from("/"), Path::to_path_buf)
}

/// The directories a parent walk examines: the proper ancestors of `module`,
/// nearest first, up to and INCLUDING `ceiling`. When `ceiling` is `module`
/// itself, or is not an ancestor of it at all, nothing above the module is
/// examined (a walk must never climb past the ceiling it was given).
fn dirs_above_up_to<'a>(module: &'a Path, ceiling: &Path) -> Vec<&'a Path> {
    let mut out = Vec::new();
    for dir in module.ancestors().skip(1) {
        out.push(dir);
        if dir == ceiling {
            return out;
        }
    }
    Vec::new()
}

/// A release channel and nothing else: `stable`, `beta` or `nightly`, each
/// optionally dated `-YYYY-MM-DD`, or a version `N.N` / `N.N.N`. No path
/// separator, no leading `.` or `~`: rustup reads anything else as the name of
/// a toolchain it may resolve to a directory.
fn valid_channel(c: &str) -> bool {
    let digits = |s: &str, n: Option<usize>| {
        !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) && n.is_none_or(|n| s.len() == n)
    };
    for name in ["stable", "beta", "nightly"] {
        if let Some(rest) = c.strip_prefix(name) {
            if rest.is_empty() {
                return true;
            }
            let parts: Vec<&str> = rest.strip_prefix('-').unwrap_or("!").split('-').collect();
            return parts.len() == 3
                && digits(parts[0], Some(4))
                && digits(parts[1], Some(2))
                && digits(parts[2], Some(2));
        }
    }
    let parts: Vec<&str> = c.split('.').collect();
    (parts.len() == 2 || parts.len() == 3) && parts.iter().all(|p| digits(p, None))
}

/// `"x"` or the TOML literal string `'x'`, the whole of `s`, with no quote of
/// either kind and no backslash inside.
fn quoted(s: &str) -> Option<&str> {
    let s = s.trim();
    let inner = ['"', '\'']
        .iter()
        .find_map(|q| s.strip_prefix(*q)?.strip_suffix(*q))?;
    (!inner.contains(['"', '\'', '\\'])).then_some(inner)
}

/// Parses the rest of an array line: quoted (`"x"` or `'x'`) strings separated by commas,
/// optionally closed by `]`. `Some(closed)`, or `None` for anything else.
fn array_items(mut rest: &str) -> Option<bool> {
    loop {
        rest = rest.trim_start_matches([' ', '\t', ',']);
        if rest.is_empty() {
            return Some(false);
        }
        if let Some(after) = rest.strip_prefix(']') {
            return after.trim().is_empty().then_some(true);
        }
        let q = rest.chars().next().filter(|c| matches!(c, '"' | '\''))?;
        let body = &rest[1..];
        let end = body.find(q)?;
        if body[..end].contains('\\') {
            return None;
        }
        rest = &body[end + 1..];
    }
}

/// Findings for the text of the module's `rust-toolchain.toml`, by allow-list:
/// every non-empty, non-comment line is the `[toolchain]` header, a line of an
/// open `components` / `targets` array, or an accepted `key = value` line
/// (`TOOLCHAIN_KEYS`); a `channel` is required and must be a release channel
/// (`valid_channel`). Anything else is a finding, never skipped.
fn toolchain_text_violations(file: &str, text: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut in_array = false;
    let mut channel = false;
    for raw in text.lines() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        if in_array {
            match array_items(line) {
                Some(closed) => in_array = !closed,
                None => found.push(format!("{file}: `{line}` is not a quoted array element")),
            }
            continue;
        }
        if line.starts_with('[') && !line.contains('=') {
            let inner = line.strip_prefix('[').and_then(|l| l.strip_suffix(']'));
            if inner.map(str::trim) != Some("toolchain") {
                found.push(format!("{file}: the table {line} is not accepted"));
            }
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            found.push(format!("{file}: the line `{line}` is not `key = value`"));
            continue;
        };
        let key = key.trim().trim_matches(['"', '\'']);
        let value = value.trim();
        if !TOOLCHAIN_KEYS.contains(&key) {
            found.push(format!(
                "{file}: the key `{key}` is not accepted (accepted: {})",
                TOOLCHAIN_KEYS.join(", ")
            ));
            continue;
        }
        match key {
            "channel" => {
                channel = true;
                if !quoted(value).is_some_and(valid_channel) {
                    found.push(format!(
                        "{file}: channel {value} is not a release channel (stable|beta|nightly[-YYYY-MM-DD] or N.N[.N])"
                    ));
                }
            }
            "profile" => {
                if !quoted(value).is_some_and(|p| p.bytes().all(|b| b.is_ascii_lowercase())) {
                    found.push(format!("{file}: profile {value} is not a plain name"));
                }
            }
            _ => match value.strip_prefix('[').and_then(array_items) {
                Some(closed) => in_array = !closed,
                None => found.push(format!("{file}: `{key} = {value}` is not a string array")),
            },
        }
    }
    if in_array {
        found.push(format!("{file}: an array is never closed"));
    }
    if !channel {
        found.push(format!("{file}: no `channel` key (it is required)"));
    }
    found
}

fn toolchain_files_below(dir: &Path, out: &mut Vec<PathBuf>) {
    out.extend(toolchain_files_in(dir));
    let mut entries: Vec<_> = fs::read_dir(dir).unwrap().map(|e| e.unwrap()).collect();
    entries.sort_by_key(fs::DirEntry::file_name);
    for e in entries {
        let name = e.file_name();
        if name == "target" || name == ".git" || !e.file_type().unwrap().is_dir() {
            continue;
        }
        toolchain_files_below(&e.path(), out);
    }
}

fn toolchain_files_in(dir: &Path) -> Vec<PathBuf> {
    ["rust-toolchain", "rust-toolchain.toml"]
        .iter()
        .map(|n| dir.join(n))
        .filter(|p| p.symlink_metadata().is_ok())
        .collect()
}

/// rustup honours a plain-text `rust-toolchain` (its one line may be a
/// directory) and, nearest to the compile's working directory, any
/// `rust-toolchain.toml`. The only toolchain file accepted is the module
/// root's `rust-toolchain.toml`, and its text is checked by allow-list; every
/// other toolchain file, in the module tree or in a directory above it up to
/// `ceiling`, is refused by its presence.
fn refused_toolchain_files(module: &Path, ceiling: &Path) -> Vec<String> {
    let mut files = Vec::new();
    toolchain_files_below(module, &mut files);
    for dir in dirs_above_up_to(module, ceiling) {
        files.extend(toolchain_files_in(dir));
    }
    let allowed = module.join("rust-toolchain.toml");
    let mut found = Vec::new();
    for f in &files {
        if *f != allowed {
            found.push(format!(
                "toolchain file {} (only the module root's rust-toolchain.toml is accepted: rustup may read this one as a toolchain directory or prefer it)",
                f.display()
            ));
        }
    }
    if files.contains(&allowed) {
        match fs::read_to_string(&allowed) {
            Ok(text) => found.extend(toolchain_text_violations(
                &allowed.display().to_string(),
                &text,
            )),
            Err(e) => found.push(format!(
                "toolchain file {} is unreadable: {e}",
                allowed.display()
            )),
        }
    }
    found
}

/// Everything layer 1 refuses for the module at `module`, looking up as far
/// as `ceiling` (inclusive). Each finding names the file.
fn refused_cargo_config(module: &Path, ceiling: &Path) -> Vec<String> {
    let mut files = Vec::new();
    configs_below(module, &mut files);
    for dir in dirs_above_up_to(module, ceiling) {
        // The user's own CARGO_HOME is their machine's, not the repository's.
        let home = std::env::var_os("CARGO_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cargo")));
        if home.as_deref() != Some(dir.join(".cargo").as_path()) {
            files.extend(cargo_config_files(dir));
        }
    }
    let mut found: Vec<String> = files
        .iter()
        .map(|f| {
            format!(
                "cargo configuration {} (it can name a rustc wrapper or flags)",
                f.display()
            )
        })
        .collect();
    found.extend(refused_toolchain_files(module, ceiling));
    found
}

#[test]
fn no_cargo_configuration_sits_in_or_above_the_module() {
    let module = root();
    let found = refused_cargo_config(&module, &repository_root(&module));
    assert!(
        found.is_empty(),
        "the compiler gate needs a module with no cargo configuration between it and the repository root:\n{}",
        found.join("\n")
    );
}

// ---- layer 3: the gate is armed, probed directly ----

const PROBE_UNSAFE_HOST: &str = "pub fn probe() -> i32 {\n    unsafe { 1 }\n}\n";
const PROBE_UNSAFE_NOSTD: &str = "#![no_std]\npub fn probe() -> i32 {\n    unsafe { 1 }\n}\n";
const PROBE_STD_NOSTD: &str = "#![no_std]\nextern crate std;\n";

/// Compiles three tiny probe crates exactly the way the gate compiles a zone
/// (same cargo, same flags, same environment handling, same config overrides,
/// working directory INSIDE the tree so the same config search path applies)
/// and requires each to FAIL for the reason the gate relies on. Whatever lowers
/// the unsafe lint, or lets `std` in, for a zone lowers it for the probe too,
/// so this does not depend on knowing the mechanism. `Err` when one compiles.
fn armed(tree: &Tree) -> Result<(), String> {
    static N: AtomicUsize = AtomicUsize::new(0);
    let dir = std::env::temp_dir().join(format!(
        "svc-arch-probe-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("src")).unwrap();
    fs::write(
        dir.join("Cargo.toml"),
        "[package]\nname = \"probe\"\nversion = \"0.0.0\"\nedition = \"2021\"\n\n[workspace]\n",
    )
    .unwrap();
    let probe_tree = Tree {
        root: tree.root.clone(),
        target_dir: Some(fixture_target().join("probe-build")),
        locked: false,
        scrub: tree.scrub,
        env: tree.env.clone(),
    };
    let mut verdict = Ok(());
    for (what, source, target, reason) in [
        (
            "`unsafe` on the host",
            PROBE_UNSAFE_HOST,
            None,
            "`unsafe` block",
        ),
        (
            "`unsafe` on the no-std target",
            PROBE_UNSAFE_NOSTD,
            Some(NOSTD_TARGET),
            "`unsafe` block",
        ),
        (
            "`extern crate std` on the no-std target",
            PROBE_STD_NOSTD,
            Some(NOSTD_TARGET),
            "E0463",
        ),
    ] {
        fs::write(dir.join("src/lib.rs"), source).unwrap();
        let mut c = probe_tree.cargo("rustc");
        c.arg("--manifest-path")
            .arg(dir.join("Cargo.toml"))
            .args(["--profile", "check", "--lib"]);
        if let Some(t) = target {
            c.args(["--target", t]);
        }
        let out = c.args(["--", "-F", "unsafe_code"]).output().unwrap();
        let stderr = String::from_utf8_lossy(&out.stderr);
        if out.status.success() {
            verdict = Err(format!(
                "the compiler gate is not armed (wrapper/config?): the probe with {what} COMPILED"
            ));
        } else if !stderr.contains(reason) {
            verdict = Err(format!(
                "the compiler gate probe with {what} failed for another reason (expected {reason}):\n{}",
                compiler_failure(&stderr)
            ));
        }
        if verdict.is_err() {
            break;
        }
    }
    let _ = fs::remove_dir_all(&dir);
    verdict
}

/// Layer 3 on the real tree, once per test binary. Every test that trusts a
/// green compile calls this first.
fn assert_armed() {
    static ARMED: OnceLock<Result<(), String>> = OnceLock::new();
    if let Err(why) = ARMED.get_or_init(|| armed(&Tree::real())) {
        panic!("{why}");
    }
}

#[test]
fn the_compiler_refuses_std_and_unsafe_code_in_domain_and_app() {
    // Run by THIS test, with its own arguments: not through `make`, not through
    // a variable a Makefile owns. Whatever else is edited, a `std` item, any
    // spelling of `extern crate std`, or an `unsafe` token is an error here.
    assert_armed();
    let tree = Tree::real();
    for rel in ["crates/domain", "crates/app"] {
        if let Err(why) = compile_forbidding_unsafe(&tree, rel, &nostd_unit(NOSTD_TARGET)) {
            panic!("{rel} does not compile for {NOSTD_TARGET} with -F unsafe_code:\n{why}");
        }
    }
}

#[test]
fn unsafe_code_is_forbidden_from_the_command_line_in_the_other_zones_too() {
    assert_armed();
    let tree = Tree::real();
    for (rel, unit) in [
        ("crates/adapter", "--lib"),
        ("crates/platform", "--lib"),
        (".", "--bin=svc"),
    ] {
        if let Err(why) = compile_forbidding_unsafe(&tree, rel, &[unit.to_owned()]) {
            panic!("{rel} does not compile with -F unsafe_code:\n{why}");
        }
    }
}

/// A valid no-std target that is NOT installed in the toolchain under test.
fn a_target_that_is_not_installed() -> &'static str {
    let out = Command::new(std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_owned()))
        .args(["--print", "sysroot"])
        .current_dir(root())
        .output()
        .unwrap();
    let sysroot = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
    [
        "thumbv6m-none-eabi",
        "thumbv7m-none-eabi",
        "thumbv8m.main-none-eabi",
        "thumbv7em-none-eabihf",
    ]
    .into_iter()
    .find(|t| !sysroot.join("lib/rustlib").join(t).exists())
    .expect("every candidate target is installed: add another name to this list")
}

#[test]
fn a_missing_no_std_target_fails_with_the_install_hint_and_never_skips() {
    let target = a_target_that_is_not_installed();
    let why = compile_forbidding_unsafe(&Tree::real(), "crates/domain", &nostd_unit(target))
        .expect_err("a compile for a target that is not installed must fail, not skip");
    assert!(why.contains("never skips"), "{why}");
    assert!(why.contains("rustup target add"), "{why}");
}

#[test]
fn domain_and_app_have_no_build_script_proc_macro_or_extra_dependency() {
    let kinds = target_kinds();
    for krate in ["svc-domain", "svc-app"] {
        let k = &kinds[krate];
        for kind in k {
            assert!(
                kind == "lib" || kind == "test",
                "{krate}: a `{kind}` target (a build script or a proc-macro runs host code at build time)"
            );
        }
        assert!(k.iter().any(|x| x == "lib"), "{krate}: no lib target");
    }
    // Their dependency lists are pinned by the dependency-graph test above:
    // domain has none, app has only domain.
}

// ---- source scans (an early, friendly message; NOT the enforcement) ----

/// Source without `//` comments and without any whitespace. A scan like this
/// is loose by nature (a block comment or a macro defeats it); it is only used
/// for the weaker rules below and as an early message. The compiler check is
/// the enforcement of zone purity.
fn squash(src: &str) -> String {
    src.lines()
        .map(|l| l.split("//").next().unwrap_or(""))
        .collect::<String>()
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect()
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            rust_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            out.push(p);
        }
    }
}

fn src_files(crate_dir: &str) -> Vec<PathBuf> {
    let mut files = Vec::new();
    rust_files(&root().join(crate_dir).join("src"), &mut files);
    files
}

#[test]
fn early_message_domain_and_app_name_no_std_items() {
    for krate in ["crates/domain", "crates/app"] {
        let lib = squash(&fs::read_to_string(root().join(krate).join("src/lib.rs")).unwrap());
        assert!(lib.contains("#![no_std]"), "{krate}: #![no_std] missing");
        for f in src_files(krate) {
            let full = fs::read_to_string(&f).unwrap();
            // Test-only code (after the `#[cfg(test)]` line) may use std.
            let prod = full.split("\n#[cfg(test)]\n").next().unwrap_or("");
            let s = squash(prod);
            // Only a hint; the no-std compile in this file is what refuses std.
            assert!(!s.contains("std::"), "{}: names `std::`", f.display());
            assert!(
                !s.contains("externcratestd"),
                "{}: extern crate std",
                f.display()
            );
        }
    }
}

#[test]
fn only_config_rs_reads_the_environment() {
    let allowed = root().join("crates/platform/src/config.rs");
    let mut files: Vec<PathBuf> = ["domain", "app", "adapter", "platform"]
        .iter()
        .flat_map(|c| src_files(&format!("crates/{c}")))
        .collect();
    files.push(root().join("src/main.rs"));
    let banned = ["std::env", "env::var", "env::args", "env!(", "option_env!("];
    for f in &files {
        if *f == allowed {
            continue;
        }
        let s = squash(&fs::read_to_string(f).unwrap());
        for token in banned {
            assert!(!s.contains(token), "{}: {token}", f.display());
        }
    }
    // The single allowed occurrences, pinned.
    let cfg = squash(&fs::read_to_string(&allowed).unwrap());
    assert_eq!(cfg.matches("option_env!(").count(), 1, "build-time read");
    assert_eq!(cfg.matches("std::env::var(").count(), 1, "runtime read");
    assert_eq!(cfg.matches("env::var").count(), 1, "no other runtime read");
}

#[test]
fn the_token_is_compared_through_the_constant_time_helper_only() {
    let http = squash(&fs::read_to_string(root().join("crates/adapter/src/http.rs")).unwrap());
    assert!(
        http.contains("ct_eq(token.as_bytes(),self.opts.auth_token.as_bytes())"),
        "the token check must go through ct_eq"
    );
    for plain in [
        "auth_token==",
        "==self.opts.auth_token",
        "auth_token!=",
        "auth_token.as_bytes()==",
        "==self.opts.auth_token.as_bytes()",
        "auth_token.as_bytes()!=",
    ] {
        assert!(
            !http.contains(plain),
            "plain comparison of the token: {plain}"
        );
    }
}

// ---- L1, L2, L3: what the no-std compile cannot see (code behind a cfg) ----

/// What the compiler did in the HOST build of one pure crate.
struct HostUnit {
    /// Features the build enabled on the crate (cargo's artifact message).
    features: Vec<String>,
    /// Every source file rustc read, canonicalised (its dep-info).
    sources: Vec<PathBuf>,
}

/// Parses rustc's dep-info (`.d`, makefile syntax): after the first rule rustc
/// writes one `path:` line per file it read; `#` lines are env-dep notes.
fn dep_info_paths(text: &str, base: &Path) -> Vec<PathBuf> {
    text.lines()
        .filter(|l| !l.starts_with('#'))
        .filter_map(|l| l.strip_suffix(':'))
        .map(|l| base.join(l.replace("\\ ", " ")))
        .collect()
}

/// The host build of the workspace, as `cargo check --workspace --lib`: the
/// same feature unification `make check-fast` gets, so a feature that
/// `adapter` switches on in `app` is in effect here. The real tree is built
/// ONCE per test binary (`host_build`); a fixture tree is built by its case.
///
/// Why this way: the compiler's own artifact message names the unit's output
/// file (`lib<crate>-<hash>.rmeta`), and rustc writes `<crate>-<hash>.d` next
/// to it, so no hash is guessed and no glob can pick a stale file. The unit
/// is the one the build actually produced, with the features it actually had.
fn host_build() -> &'static BTreeMap<String, HostUnit> {
    static BUILD: OnceLock<BTreeMap<String, HostUnit>> = OnceLock::new();
    BUILD.get_or_init(|| {
        let units = host_units(&Tree::real());
        assert_eq!(units.len(), 2, "the build did not report domain and app");
        units
    })
}

fn host_units(tree: &Tree) -> BTreeMap<String, HostUnit> {
    let out = tree
        .cargo("check")
        .args(["--workspace", "--lib", "--message-format=json"])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "the host build failed:\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    let mut units = BTreeMap::new();
    for line in stdout
        .lines()
        .filter(|l| l.contains("\"compiler-artifact\""))
    {
        let msg = P(line.as_bytes(), 0).value();
        let target = field(&msg, "target");
        let name = text(field(target, "name"));
        if (name != "svc_domain" && name != "svc_app")
            || !strings(field(target, "kind")).iter().any(|k| k == "lib")
        {
            continue;
        }
        let files = strings(field(&msg, "filenames"));
        let rmeta = PathBuf::from(files.first().expect("an artifact with no file"));
        let stem = rmeta.file_stem().unwrap().to_string_lossy().into_owned();
        let dep_info =
            rmeta.with_file_name(format!("{}.d", stem.strip_prefix("lib").unwrap_or(&stem)));
        let raw = fs::read_to_string(&dep_info)
            .unwrap_or_else(|e| panic!("no dep-info at {}: {e}", dep_info.display()));
        let sources = dep_info_paths(&raw, &tree.root)
            .into_iter()
            .map(|p| {
                fs::canonicalize(&p)
                    .unwrap_or_else(|e| panic!("{} is not readable: {e}", p.display()))
            })
            .collect();
        units.insert(
            name.to_owned(),
            HostUnit {
                features: strings(field(&msg, "features")),
                sources,
            },
        );
    }
    units
}

const PURE_CRATES: [(&str, &str, &str); 2] = [
    ("svc_domain", "svc-domain", "crates/domain"),
    ("svc_app", "svc-app", "crates/app"),
];

/// Files that are not inside `src` (both canonical).
fn outside<'a>(files: &'a [PathBuf], src: &Path) -> Vec<&'a PathBuf> {
    files.iter().filter(|f| !f.starts_with(src)).collect()
}

/// L1: the files the compiler read for a pure crate must all be inside the
/// crate's own `src/`, as messages. `crates` = (lib name, package, dir).
fn l1_violations(
    tree: &Tree,
    units: &BTreeMap<String, HostUnit>,
    crates: &[(&str, &str, &str)],
) -> Vec<String> {
    let mut bad = Vec::new();
    for (lib, _, dir) in crates {
        let unit = &units[*lib];
        let src = fs::canonicalize(tree.root.join(dir).join("src")).unwrap();
        if !unit.sources.iter().any(|f| f.ends_with("src/lib.rs")) {
            bad.push(format!(
                "{lib}: the dep-info does not list src/lib.rs: {:?}",
                unit.sources
            ));
        }
        let outside = outside(&unit.sources, &src);
        if !outside.is_empty() {
            bad.push(format!(
                "{lib}: the compiler read files outside {}: a `#[path]`, `include!` or `[lib] path` reaches out of `src`: {outside:?}",
                src.display()
            ));
        }
    }
    bad
}

#[test]
fn l1_the_compiler_read_only_files_inside_the_src_of_domain_and_app() {
    let bad = l1_violations(&Tree::real(), host_build(), &PURE_CRATES);
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}

#[test]
fn l1_a_file_outside_src_is_named() {
    let src = Path::new("/w/crates/domain/src");
    let files: Vec<PathBuf> = ["/w/crates/domain/src/lib.rs", "/w/crates/domain/host/io.rs"]
        .into_iter()
        .map(PathBuf::from)
        .collect();
    assert_eq!(outside(&files, src), [&files[1]]);
    // A sibling directory that merely shares the prefix is outside too.
    let files = [PathBuf::from("/w/crates/domain/src2/x.rs")];
    assert_eq!(outside(&files, src).len(), 1);
    // dep-info: the first rule is skipped, escaped spaces are restored.
    let d = "/t/x.d: a/lib.rs b\\ c.rs\n\n# env-dep:X=1\na/lib.rs:\nb\\ c.rs:\n";
    assert_eq!(
        dep_info_paths(d, Path::new("/w")),
        [PathBuf::from("/w/a/lib.rs"), PathBuf::from("/w/b c.rs")]
    );
}

fn is_word(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b >= 0x80
}

/// Occurrences of `word` at a word boundary (regex `\bword`), as byte offsets.
fn word_starts(src: &str, word: &str) -> Vec<usize> {
    let b = src.as_bytes();
    (0..b.len())
        .filter(|&i| b[i..].starts_with(word.as_bytes()) && (i == 0 || !is_word(b[i - 1])))
        .collect()
}

/// L2: what a pure crate's source may not contain, as messages. REFUSES, does
/// not parse. No comment stripping.
fn conditional_compilation_violations(file: &str, src: &str) -> Vec<String> {
    // The one allowed use: a line that is exactly `#[cfg(test)]` (blanked, so
    // it cannot hide a neighbour; its line numbers are kept).
    let src: String = src
        .lines()
        .map(|l| if l.trim() == "#[cfg(test)]" { "" } else { l })
        .collect::<Vec<_>>()
        .join("\n");
    let line_of = |at: usize| src[..at].matches('\n').count() + 1;
    let mut bad = Vec::new();
    for at in word_starts(&src, "cfg") {
        bad.push(format!(
            "{file}:{}: the word `cfg` (conditional compilation is refused in a pure crate; only a line that is exactly `#[cfg(test)]` is allowed; write it without the word, in a comment too)",
            line_of(at)
        ));
    }
    for at in word_starts(&src, "include") {
        let rest = &src[at + "include".len()..];
        let rest = rest
            .strip_prefix("_str")
            .or_else(|| rest.strip_prefix("_bytes"))
            .unwrap_or(rest);
        if rest.trim_start().starts_with('!') {
            bad.push(format!(
                "{file}:{}: `include!`-family macro (it reads a file the scan cannot see)",
                line_of(at)
            ));
        }
    }
    for (n, l) in src.lines().enumerate() {
        if l.trim_start().starts_with('#')
            && word_starts(l, "path")
                .into_iter()
                .any(|at| l[at + 4..].trim_start().starts_with('='))
        {
            bad.push(format!("{file}:{}: a `#[path = ...]` attribute", n + 1));
        }
    }
    bad
}

/// L2 over every file the compiler read for the pure crates, as messages.
fn l2_violations(units: &BTreeMap<String, HostUnit>, crates: &[(&str, &str, &str)]) -> Vec<String> {
    let mut bad = Vec::new();
    for (lib, _, _) in crates {
        for f in &units[*lib].sources {
            let src = fs::read_to_string(f).unwrap();
            bad.extend(conditional_compilation_violations(
                &f.display().to_string(),
                &src,
            ));
        }
    }
    bad
}

#[test]
fn l2_no_conditional_compilation_and_no_file_inclusion_in_the_files_the_compiler_read() {
    let bad = l2_violations(host_build(), &PURE_CRATES);
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}

#[test]
fn l2_scanner_refuses_every_spelling_and_allows_only_the_test_line() {
    let refused = [
        "#[cfg(debug_assertions)]\nfn a() {}",
        "#[cfg(unix)]\nfn a() {}",
        "#[cfg(not(target_os = \"none\"))]\nmod m;",
        "#[cfg(feature = \"std\")]\nmod m;",
        "let on = cfg!(debug_assertions);",
        "#[cfg_attr(not(test), path = \"../x.rs\")]\nmod m;",
        "#[r#cfg(unix)]\nfn a() {}",
        "// a comment mentioning cfg is refused too",
        "/* cfg */",
        "#[cfg(test)] mod tests {}",
        "  #[cfg(test)] // trailing",
        "#![cfg(test)]",
        "#[cfg(all(test, unix))]\nmod t {}",
        "#[\ncfg(test)]\nmod t {}",
        "include!(\"../x.rs\");",
        "include_str!(\"../x.txt\")",
        "include_bytes ! (\"../x.bin\")",
        "include\n!(\"../x.rs\");",
        "#[path = \"../hostshim/clock.rs\"]\nmod wall;",
        "#[ path=\"x.rs\" ] mod wall;",
    ];
    for src in refused {
        assert!(
            !conditional_compilation_violations("f.rs", src).is_empty(),
            "accepted: {src:?}"
        );
    }
    let allowed = [
        "#[cfg(test)]\nmod tests {\n    extern crate std;\n    use std::fs;\n}\n",
        "    #[cfg(test)]   \nmod tests {}",
        "fn configure() {} // not the word",
        "let x = my_cfg + a_cfg;",
        "fn included() { let path = 1; let _ = path; }",
        "// the include list\n",
    ];
    for src in allowed {
        assert!(
            conditional_compilation_violations("f.rs", src).is_empty(),
            "refused: {src:?}: {:?}",
            conditional_compilation_violations("f.rs", src)
        );
    }
    // The line number points at the offender, also after the allowed line.
    let v = conditional_compilation_violations("f.rs", "#[cfg(test)]\nmod t {}\n#[cfg(unix)]\n");
    assert_eq!(v.len(), 1);
    assert!(v[0].starts_with("f.rs:3:"), "{v:?}");
}

/// L3: why the features of the pure crates are not a way around the scan, as
/// messages. `built` = crate -> features the host build enabled on it.
fn feature_violations(meta: &Json, built: &BTreeMap<String, Vec<String>>) -> Vec<String> {
    let pure = ["svc-domain", "svc-app"];
    let mut bad = Vec::new();
    for p in packages(meta) {
        let name = text(field(p, "name"));
        if pure.contains(&name) {
            let Json::Obj(features) = field(p, "features") else {
                panic!("no features map")
            };
            if !features.is_empty() {
                let names: Vec<&str> = features.iter().map(|(k, _)| k.as_str()).collect();
                bad.push(format!(
                    "{name} declares features {names:?}: it must declare none"
                ));
            }
            let Json::Arr(deps) = field(p, "dependencies") else {
                panic!("no dependencies")
            };
            for d in deps.iter().filter(|d| flag(field(d, "optional"))) {
                bad.push(format!(
                    "{name} has the optional dependency {}",
                    text(field(d, "name"))
                ));
            }
        }
        let Json::Arr(deps) = field(p, "dependencies") else {
            panic!("no dependencies")
        };
        for d in deps
            .iter()
            .filter(|d| pure.contains(&text(field(d, "name"))))
        {
            let dep = text(field(d, "name"));
            let on = strings(field(d, "features"));
            if !on.is_empty() {
                bad.push(format!("{name} enables features {on:?} on {dep}"));
            }
            if !flag(field(d, "uses_default_features")) {
                bad.push(format!(
                    "{name} depends on {dep} with default-features = false"
                ));
            }
        }
    }
    for (krate, on) in built {
        if !on.is_empty() {
            bad.push(format!("the host build enabled features {on:?} on {krate}"));
        }
    }
    bad
}

#[test]
fn l3_domain_and_app_have_no_features_and_nobody_switches_one_on() {
    let built: BTreeMap<String, Vec<String>> = PURE_CRATES
        .iter()
        .map(|(lib, pkg, _)| ((*pkg).to_owned(), host_build()[*lib].features.clone()))
        .collect();
    assert_eq!(feature_violations(metadata(), &built), Vec::<String>::new());
}

#[test]
fn l3_checker_refuses_a_feature_an_optional_dependency_and_a_dependent_that_switches_one() {
    let meta = |domain_features: &str, app_deps: &str, adapter_dep: &str| {
        let json = format!(
            r#"{{"packages":[
 {{"name":"svc-domain","features":{domain_features},"dependencies":[]}},
 {{"name":"svc-app","features":{{}},"dependencies":[{app_deps}]}},
 {{"name":"svc-adapter","features":{{}},"dependencies":[{adapter_dep}]}}]}}"#
        );
        P(json.as_bytes(), 0).value()
    };
    let dep = |name: &str, optional: bool, features: &str, defaults: bool| {
        format!(
            r#"{{"name":"{name}","optional":{optional},"features":{features},"uses_default_features":{defaults}}}"#
        )
    };
    let clean_app = dep("svc-domain", false, "[]", true);
    let clean_adapter = dep("svc-app", false, "[]", true);
    let none = BTreeMap::new();
    assert!(feature_violations(&meta("{}", &clean_app, &clean_adapter), &none).is_empty());
    let cases = [
        (
            "a [features] table",
            meta("{\"std\":[]}", &clean_app, &clean_adapter),
        ),
        (
            "a default = [] feature",
            meta("{\"default\":[]}", &clean_app, &clean_adapter),
        ),
        (
            "an optional dependency",
            meta("{}", &dep("svc-domain", true, "[]", true), &clean_adapter),
        ),
        (
            "a dependent enabling a feature",
            meta("{}", &clean_app, &dep("svc-app", false, "[\"std\"]", true)),
        ),
        (
            "default-features = false",
            meta("{}", &clean_app, &dep("svc-app", false, "[]", false)),
        ),
    ];
    for (what, m) in &cases {
        assert!(!feature_violations(m, &none).is_empty(), "{what}: accepted");
    }
    let built: BTreeMap<String, Vec<String>> =
        [("svc-app".to_owned(), vec!["std".to_owned()])].into();
    assert!(
        !feature_violations(&meta("{}", &clean_app, &clean_adapter), &built).is_empty(),
        "a feature enabled in the host build: accepted"
    );
}

// ---- fixtures: ONE attack on a copy of the domain crate, through the same checks ----
//
// Each case copies `crates/domain` into a tiny workspace of its own, applies
// one attack and runs the SAME functions the real tree is checked with
// (`compile_forbidding_unsafe`, `host_units`, `l1_violations`,
// `l2_violations`). A case names which layers must go red and requires every
// other layer it runs to stay clean, so removing a layer (or loosening it:
// `src/` -> the crate dir) turns the case RED, and the control stays green.

const FIXTURE_WORKSPACE: &str = r#"[workspace]
resolver = "2"
members = ["crates/domain"]

[workspace.package]
edition = "2021"
rust-version = "1.99"

[workspace.lints.rust]
unsafe_code = "forbid"
missing_docs = "warn"
"#;

const FIXTURE_CRATES: [(&str, &str, &str); 1] = [("svc_domain", "svc-domain", "crates/domain")];

fn fixture_target() -> PathBuf {
    std::env::var_os("CARGO_TARGET_DIR")
        .map_or_else(|| root().join("target"), PathBuf::from)
        .join("arch-fixtures")
}

/// Where fixture SOURCE trees live: a fixed directory (so nested builds are
/// reused) under the OS temp location (`TMPDIR` honoured), never inside the module, so the real module
/// (and its `rust-toolchain.toml`) is never an ancestor of a fixture. Only the
/// nested cargo's build output stays under `fixture_target()`.
fn fixture_work() -> PathBuf {
    std::env::temp_dir().join("svc-arch-fixtures")
}

fn copy_dir(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for e in fs::read_dir(from).unwrap() {
        let p = e.unwrap().path();
        let dest = to.join(p.file_name().unwrap());
        if p.is_dir() {
            copy_dir(&p, &dest);
        } else {
            fs::copy(&p, &dest).unwrap();
        }
    }
}

/// Replaces `from` with `to` in `file`, which must change.
fn edit(file: &Path, from: &str, to: &str) {
    let t = fs::read_to_string(file).unwrap();
    assert!(t.contains(from), "{}: {from:?} not found", file.display());
    fs::write(file, t.replacen(from, to, 1)).unwrap();
}

fn append(file: &Path, text: &str) {
    let mut t = fs::read_to_string(file).unwrap();
    t.push_str(text);
    fs::write(file, t).unwrap();
}

/// A fixture workspace with a copy of the real domain crate; `attack` gets the
/// crate directory. The path is fixed per case (so builds are reused).
fn fixture(case: &str, attack: fn(&Path)) -> Tree {
    let dir = fixture_work().join("work").join(case);
    let _ = fs::remove_dir_all(&dir);
    let krate = dir.join("crates/domain");
    copy_dir(&root().join("crates/domain/src"), &krate.join("src"));
    fs::copy(
        root().join("crates/domain/Cargo.toml"),
        krate.join("Cargo.toml"),
    )
    .unwrap();
    fs::write(dir.join("Cargo.toml"), FIXTURE_WORKSPACE).unwrap();
    attack(&krate);
    Tree {
        root: dir,
        target_dir: Some(fixture_target().join("build")),
        locked: false,
        scrub: true,
        env: Vec::new(),
    }
}

const UNSAFE_GETPID: &str =
    "\nextern \"C\" {\n    fn getpid() -> i32;\n}\n\n/// Not pure.\npub fn pid() -> i32 {\n    unsafe { getpid() }\n}\n";

/// The reviewer's attack: the lints table commented out, the forbid attribute
/// deleted, and an `unsafe` call into libc.
fn attack_unsafe_with_lints_commented_out(krate: &Path) {
    edit(
        &krate.join("Cargo.toml"),
        "[lints]\nworkspace = true",
        "# [lints] workspace = true",
    );
    edit(&krate.join("src/lib.rs"), "#![forbid(unsafe_code)]\n", "");
    append(&krate.join("src/lib.rs"), UNSAFE_GETPID);
}

/// The stronger attacker: the crate itself ALLOWS the lint.
fn attack_unsafe_with_allow_attribute(krate: &Path) {
    edit(
        &krate.join("src/lib.rs"),
        "#![forbid(unsafe_code)]",
        "#![allow(unsafe_code)]",
    );
    append(&krate.join("src/lib.rs"), UNSAFE_GETPID);
}

fn attack_extern_crate_raw_std(krate: &Path) {
    append(&krate.join("src/lib.rs"), "\nextern crate r#std as host;\n");
}

/// `std` behind a `cfg` that is false on the bare-metal target: the no-std
/// compile never sees it, only L2 does.
fn attack_std_behind_a_cfg(krate: &Path) {
    append(
        &krate.join("src/lib.rs"),
        "\n#[cfg(not(target_os = \"none\"))]\nmod host_only {\n    extern crate std;\n    /// Not pure.\n    pub fn args() -> usize {\n        std::env::args().count()\n    }\n}\n",
    );
}

/// A `#[path]` attribute split across lines (the L2 line scan cannot see it)
/// naming a pure file that sits in the crate directory but OUTSIDE `src/`.
fn attack_multiline_path_outside_src(krate: &Path) {
    fs::create_dir_all(krate.join("host")).unwrap();
    fs::write(
        krate.join("host/io.rs"),
        "//! Outside src.\npub fn f() {}\n",
    )
    .unwrap();
    append(
        &krate.join("src/lib.rs"),
        "\n#[path\n    = \"../host/io.rs\"]\nmod io;\n",
    );
}

/// `[lib] path` pointing out of `src/`.
fn attack_lib_path_outside_src(krate: &Path) {
    fs::create_dir_all(krate.join("host")).unwrap();
    fs::write(krate.join("host/lib.rs"), "//! Outside src.\n#![no_std]\n").unwrap();
    append(
        &krate.join("Cargo.toml"),
        "\n[lib]\npath = \"host/lib.rs\"\n",
    );
}

/// `std` behind a DECLARED feature: only `--all-features` makes the no-std
/// compile build it.
fn attack_std_behind_a_declared_feature(krate: &Path) {
    append(&krate.join("Cargo.toml"), "\n[features]\nstd = []\n");
    append(
        &krate.join("src/lib.rs"),
        "\n#[cfg(feature = \"std\")]\nextern crate std;\n",
    );
}

fn no_attack(_: &Path) {}

/// (case, attack, run the no-std compile, run the host build + L1 + L2, layers that must be red)
type FixtureCase = (&'static str, fn(&Path), bool, bool, &'static [&'static str]);

#[test]
fn every_attack_on_a_copy_of_domain_turns_its_layer_red_and_the_control_stays_green() {
    let cases: [FixtureCase; 8] = [
        ("control", no_attack, true, true, &[]),
        (
            "unsafe_lints_commented_out",
            attack_unsafe_with_lints_commented_out,
            true,
            false,
            &["compiler"],
        ),
        (
            "unsafe_allow_attribute",
            attack_unsafe_with_allow_attribute,
            true,
            false,
            &["compiler"],
        ),
        (
            "extern_crate_raw_std",
            attack_extern_crate_raw_std,
            true,
            false,
            &["compiler"],
        ),
        (
            "std_behind_a_declared_feature",
            attack_std_behind_a_declared_feature,
            true,
            false,
            &["compiler"],
        ),
        (
            "std_behind_a_cfg",
            attack_std_behind_a_cfg,
            true,
            true,
            &["l2"],
        ),
        (
            "multiline_path_outside_src",
            attack_multiline_path_outside_src,
            false,
            true,
            &["l1"],
        ),
        (
            "lib_path_outside_src",
            attack_lib_path_outside_src,
            false,
            true,
            &["l1"],
        ),
    ];
    for (name, attack, run_compiler, run_host, red) in cases {
        let tree = fixture(name, attack);
        let mut layers: Vec<(&str, Vec<String>)> = Vec::new();
        if run_compiler {
            let r = compile_forbidding_unsafe(&tree, "crates/domain", &nostd_unit(NOSTD_TARGET));
            layers.push(("compiler", r.err().into_iter().collect()));
        }
        if run_host {
            let units = host_units(&tree);
            layers.push(("l1", l1_violations(&tree, &units, &FIXTURE_CRATES)));
            layers.push(("l2", l2_violations(&units, &FIXTURE_CRATES)));
        }
        for (layer, found) in &layers {
            assert_eq!(
                !found.is_empty(),
                red.contains(layer),
                "{name}: layer {layer} should be {} but found {found:?}",
                if red.contains(layer) { "RED" } else { "clean" }
            );
        }
        for want in red {
            assert!(
                layers.iter().any(|(l, _)| l == want),
                "{name}: layer {want} was not run"
            );
        }
    }
}

// ---- fixtures: cargo configuration and environment attacks on the compiler gate ----
//
// The reviewer's attack: a `.cargo/config.toml` naming a rustc wrapper that
// appends `--cap-lints allow` (which lowers even a forbid), so the unsafe call
// in domain compiled. Each case below copies the domain crate with an `unsafe`
// call into a scratch tree (the source's forbid attribute and the lints table
// untouched), puts the attack where it names, and asks the layers separately:
// layer 1 (`refused_cargo_config`), the gate compile itself (layer 2 lives in
// `Tree::cargo`), and layer 3 (`armed`). The cases share one target directory
// (each copy has its own path, so no build is ever reused between cases; a
// target directory also caches cargo's probe of the compiler, which is most of
// a nested run's cost). A MUTANT run of these cases must use a fresh
// `CARGO_TARGET_DIR`: cargo's fingerprints ignore a wrapper.

/// Appends `--cap-lints allow` to every compile (but not to the `-vV` and
/// `--print` probes cargo makes first): the reviewer's wrapper.
const WRAP_SH: &str = "#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in -vV|--print*) exec \"$@\";; esac; done\nexec \"$@\" --cap-lints allow\n";

const REVIEWER_CONFIG: &str = "[build]\nrustc-wrapper = \"tools/wrap.sh\"\n\n[env]\nRUSTC_WRAPPER = { value = \"tools/wrap.sh\", relative = true }\n";

/// What a case expects: (layer 1 refuses, the gate compile goes red, `armed`
/// answers: `None` = not asked).
type Expect = (bool, bool, Option<bool>);

struct ConfigCase {
    name: &'static str,
    /// Put `files` in a PARENT directory of the module copy instead of in it.
    parent: bool,
    /// (path relative to the directory above, content, executable). `{ROOT}`
    /// in a content is the module copy's absolute path, `{RUSTC}` the real rustc.
    files: Vec<(&'static str, String, bool)>,
    /// Environment the caller is imagined to have set.
    env: Vec<(&'static str, String)>,
    /// The domain copy calls into libc inside `unsafe` (every case but the control).
    unsafe_source: bool,
    /// Compile the host build of the crate instead of the no-std one (a
    /// `--cap-lints` in rustflags makes cargo's own probe of the bare-metal
    /// target fail, so rustflags attacks only get through on the host).
    host: bool,
    /// Layer 2 on (the real setting) or off (the probe-pin fixture).
    scrub: bool,
    expect: Expect,
}

fn config_fixture(case: &ConfigCase) -> (Tree, PathBuf) {
    let base = fixture_work().join("config-work").join(case.name);
    let _ = fs::remove_dir_all(&base);
    let module = if case.parent {
        base.join("mod")
    } else {
        base.clone()
    };
    let krate = module.join("crates/domain");
    copy_dir(&root().join("crates/domain/src"), &krate.join("src"));
    fs::copy(
        root().join("crates/domain/Cargo.toml"),
        krate.join("Cargo.toml"),
    )
    .unwrap();
    fs::write(module.join("Cargo.toml"), FIXTURE_WORKSPACE).unwrap();
    if case.unsafe_source {
        append(&krate.join("src/lib.rs"), UNSAFE_GETPID);
    }
    let fill = |s: &str| {
        s.replace("{ROOT}", &module.display().to_string())
            .replace("{RUSTC}", &resolved_rustc().display().to_string())
    };
    for (rel, content, exec) in &case.files {
        let f = base.join(rel);
        fs::create_dir_all(f.parent().unwrap()).unwrap();
        fs::write(&f, fill(content)).unwrap();
        if *exec {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&f, fs::Permissions::from_mode(0o755)).unwrap();
        }
    }
    let tree = Tree {
        root: module.clone(),
        target_dir: Some(fixture_target().join("config-build")),
        locked: false,
        scrub: case.scrub,
        env: case
            .env
            .iter()
            .map(|(k, v)| ((*k).to_owned(), fill(v)))
            .collect(),
    };
    (tree, base)
}

fn config_cases() -> Vec<ConfigCase> {
    let wrap = |dir: &'static str| (dir, WRAP_SH.to_owned(), true);
    // A wrapper that is a compiler stand-in, for `build.rustc` / `RUSTC`.
    let shim = (
        "tools/rustc-shim.sh",
        "#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in -vV|--print*) exec {RUSTC} \"$@\";; esac; done\nexec {RUSTC} \"$@\" --cap-lints allow\n".to_owned(),
        true,
    );
    let attack_env = |name: &'static str, key: &'static str, value: &str| ConfigCase {
        name,
        parent: false,
        files: vec![wrap("tools/wrap.sh"), shim.clone()],
        env: vec![(key, value.to_owned())],
        unsafe_source: true,
        host: false,
        scrub: true,
        expect: (false, true, None),
    };
    let host_only = |c: ConfigCase| ConfigCase { host: true, ..c };
    vec![
        ConfigCase {
            name: "control",
            parent: false,
            files: vec![],
            env: vec![],
            unsafe_source: false,
 host: false,
            scrub: true,
            expect: (false, false, None),
        },
        // The reviewer's two files in the module root.
        ConfigCase {
            name: "reviewer_attack_in_the_module_root",
            parent: false,
            files: vec![
                (".cargo/config.toml", REVIEWER_CONFIG.to_owned(), false),
                wrap("tools/wrap.sh"),
            ],
            env: vec![],
            unsafe_source: true,
 host: false,
            scrub: true,
            expect: (true, true, Some(true)),
        },
        // The same config in the PARENT directory (a scaffolded repository's root).
        ConfigCase {
            name: "reviewer_attack_in_a_parent_directory",
            parent: true,
            files: vec![
                (".cargo/config.toml", REVIEWER_CONFIG.to_owned(), false),
                wrap("tools/wrap.sh"),
            ],
            env: vec![],
            unsafe_source: true,
 host: false,
            scrub: true,
            expect: (true, true, None),
        },
        ConfigCase {
            name: "parent_workspace_wrapper",
            parent: true,
            files: vec![
                (
                    ".cargo/config.toml",
                    "[build]\nrustc-workspace-wrapper = \"tools/wrap.sh\"\n".to_owned(),
                    false,
                ),
                wrap("tools/wrap.sh"),
            ],
            env: vec![],
            unsafe_source: true,
 host: false,
            scrub: true,
            expect: (true, true, None),
        },
        ConfigCase {
            name: "parent_rustflags",
            parent: true,
            files: vec![(
                ".cargo/config.toml",
                format!(
                    "[build]\nrustflags = [\"--cap-lints=allow\"]\n\n[target.{NOSTD_TARGET}]\nrustflags = [\"--cap-lints=allow\"]\n"
                ),
                false,
            )],
            env: vec![],
            unsafe_source: true,
            host: true,
            scrub: true,
            expect: (true, true, None),
        },
        ConfigCase {
            name: "parent_rustc",
            parent: true,
            files: vec![
                (".cargo/config.toml", "[build]\nrustc = \"{ROOT}/../tools/rustc-shim.sh\"\n".to_owned(), false),
                shim.clone(),
            ],
            env: vec![],
            unsafe_source: true,
 host: false,
            scrub: true,
            expect: (true, true, None),
        },
        // The test's own environment.
        attack_env("env_rustc_wrapper", "RUSTC_WRAPPER", "{ROOT}/tools/wrap.sh"),
        attack_env("env_rustc_workspace_wrapper", "RUSTC_WORKSPACE_WRAPPER", "{ROOT}/tools/wrap.sh"),
        attack_env("env_rustc", "RUSTC", "{ROOT}/tools/rustc-shim.sh"),
        host_only(attack_env("env_rustflags", "RUSTFLAGS", "--cap-lints=allow")),
        host_only(attack_env(
            "env_encoded_rustflags",
            "CARGO_ENCODED_RUSTFLAGS",
            "--cap-lints=allow",
        )),
        attack_env(
            "env_target_rustflags",
            "CARGO_TARGET_THUMBV7EM_NONE_EABI_RUSTFLAGS",
            "--cap-lints=allow",
        ),
        // Layer 2 OFF: the attack gets through the compile, and only the probe
        // (layer 3) says so. This case pins the probe.
        ConfigCase {
            name: "probe_pin_layer_2_off",
            parent: false,
            files: vec![
                (".cargo/config.toml", REVIEWER_CONFIG.to_owned(), false),
                wrap("tools/wrap.sh"),
            ],
            env: vec![],
            unsafe_source: true,
 host: false,
            scrub: false,
            expect: (true, false, Some(false)),
        },
    ]
}

#[test]
fn the_compiler_gate_is_armed_and_no_cargo_configuration_can_lower_it() {
    for case in config_cases() {
        let (tree, base) = config_fixture(&case);
        let (want_refused, want_red, want_armed) = case.expect;
        let name = case.name;
        let ceiling = base.clone();
        let refused = refused_cargo_config(&tree.root, &ceiling);
        assert_eq!(
            !refused.is_empty(),
            want_refused,
            "{name}: layer 1 should {} but found {refused:?}",
            if want_refused { "refuse" } else { "stay clean" }
        );
        if want_refused && !case.files.is_empty() {
            assert!(
                refused.iter().any(|r| r.contains("config.toml")),
                "{name}: layer 1 must name the file: {refused:?}"
            );
        }
        let unit = if case.host {
            vec!["--lib".to_owned()]
        } else {
            nostd_unit(NOSTD_TARGET)
        };
        let gate = compile_forbidding_unsafe(&tree, "crates/domain", &unit);
        match (&gate, want_red) {
            (Err(why), true) => assert!(
                why.contains("`unsafe` block"),
                "{name}: the gate failed, but not on the unsafe block:\n{why}"
            ),
            (Ok(()), false) => {}
            (got, _) => panic!(
                "{name}: gate compile red = {} but expected {want_red}: {got:?}",
                got.is_err()
            ),
        }
        if let Some(want) = want_armed {
            let verdict = armed(&tree);
            assert_eq!(
                verdict.is_ok(),
                want,
                "{name}: armed() answered {verdict:?}"
            );
            if !want {
                assert!(
                    verdict.err().unwrap_or_default().contains("is not armed"),
                    "{name}: the message must say the gate is not armed"
                );
            }
        }
        let _ = fs::remove_dir_all(&base);
    }
}

#[test]
fn rust_toolchain_files_may_only_carry_channel_components_targets_and_profile() {
    let real = fs::read_to_string(root().join("rust-toolchain.toml")).unwrap();
    assert_eq!(
        toolchain_text_violations("rust-toolchain.toml", &real),
        Vec::<String>::new()
    );
    let path_key = "[toolchain]\nchannel = \"1.99.1\"\npath = \"/opt/custom\"\n";
    let quoted = "[toolchain]\n\"path\" = \"/opt/custom\"\n";
    let dotted = "toolchain.path = \"/opt/custom\"\n";
    let other_table = "[toolchain]\nchannel = \"1.99.1\"\n[overrides]\nx = 1\n";
    let after_array = "[toolchain]\ntargets = [\n  \"a=b\",\n]\npath = \"/x\"\n";
    for (what, text) in [
        ("path", path_key),
        ("quoted path", quoted),
        ("dotted path", dotted),
        ("another table", other_table),
        ("path after a multi-line array", after_array),
    ] {
        assert!(
            !toolchain_text_violations("rust-toolchain.toml", text).is_empty(),
            "{what}: accepted"
        );
    }
    let fine = "[toolchain]\nchannel = \"1.99.1\" # pinned\ncomponents = [\"clippy\"]\nprofile = \"minimal\"\ntargets = [\n  \"a=b\",\n]\n";
    assert!(toolchain_text_violations("rust-toolchain.toml", fine).is_empty());
    // TOML literal (single-quoted) strings are the same value; `[ toolchain ]` too.
    let literal = "[ toolchain ]\nchannel = '1.99.1'\ncomponents = ['clippy', \"rustfmt\"]\nprofile = 'minimal'\ntargets = [\n  'a=b',\n]\n";
    assert!(toolchain_text_violations("rust-toolchain.toml", literal).is_empty());
    // Mixed or unbalanced quotes, a quote inside, and a BOM stay refused.
    for bad in [
        "[toolchain]\nchannel = '1.99.1\"\n",
        "[toolchain]\nchannel = 'a\"b'\n",
        "[toolchain]\nchannel = '1.99.1'\ncomponents = ['x\"]\n",
        "\u{feff}[toolchain]\nchannel = \"1.99.1\"\n",
    ] {
        assert!(
            !toolchain_text_violations("rust-toolchain.toml", bad).is_empty(),
            "{bad:?}"
        );
    }
}

/// Builds `rel` files under a scratch dir and returns the findings for the
/// module at `<scratch>/mod` with the repository root at `<scratch>`.
fn toolchain_case(name: &str, files: &[(&str, &str)]) -> Vec<String> {
    let base = fixture_work().join("toolchain-work").join(name);
    let _ = fs::remove_dir_all(&base);
    fs::create_dir_all(base.join("mod/crates/domain")).unwrap();
    for (rel, content) in files {
        let f = base.join(rel);
        fs::create_dir_all(f.parent().unwrap()).unwrap();
        fs::write(&f, content).unwrap();
    }
    let found = refused_toolchain_files(&base.join("mod"), &base);
    let _ = fs::remove_dir_all(&base);
    found
}

/// Pure pin of the parent walks' bound (no cargo): files above the ceiling are
/// never reported, a file between the module and the ceiling is, and with the
/// ceiling at the module itself nothing above is examined. This is also what
/// keeps the gate green whatever `CARGO_TARGET_DIR` is: a fixture's walk can
/// never climb into the real module.
#[test]
fn the_parent_walks_stop_at_the_ceiling() {
    let scratch = std::env::temp_dir().join("svc-arch-walk-bound");
    let _ = fs::remove_dir_all(&scratch);
    let top = scratch.join("root");
    let module = top.join("a/module");
    fs::create_dir_all(top.join(".git")).unwrap();
    fs::create_dir_all(&module).unwrap();
    fs::create_dir_all(scratch.join(".cargo")).unwrap();
    fs::write(
        scratch.join("rust-toolchain.toml"),
        "[toolchain]\nchannel = \"1.99.1\"\n",
    )
    .unwrap();
    fs::write(scratch.join(".cargo/config.toml"), "[build]\n").unwrap();
    fs::write(top.join("rust-toolchain"), "1.99.1\n").unwrap();
    fs::write(
        module.join("rust-toolchain.toml"),
        "[toolchain]\nchannel = \"1.99.1\"\n",
    )
    .unwrap();

    let found = refused_cargo_config(&module, &top);
    assert_eq!(
        found.len(),
        1,
        "only the legacy file below the ceiling: {found:?}"
    );
    assert!(found[0].contains("root/rust-toolchain "), "{found:?}");
    assert!(
        found
            .iter()
            .all(|f| !f.contains("walk-bound/rust-toolchain.toml")
                && !f.contains("walk-bound/.cargo")),
        "nothing above the ceiling may be reported: {found:?}"
    );
    let dirs = dirs_above_up_to(&module, &top);
    assert_eq!(dirs, vec![top.join("a"), top.clone()]);

    // The ceiling is the module itself: nothing above is examined.
    assert!(dirs_above_up_to(&module, &module).is_empty());
    assert!(refused_toolchain_files(&module, &module).is_empty());
    assert!(refused_cargo_config(&module, &module).is_empty());
    // A ceiling that is not an ancestor at all: nothing above is examined.
    assert!(dirs_above_up_to(&module, &scratch.join("elsewhere")).is_empty());
    assert!(refused_cargo_config(&module, &scratch.join("elsewhere")).is_empty());
    let _ = fs::remove_dir_all(&scratch);
}

#[test]
fn only_the_module_roots_rust_toolchain_toml_is_accepted_and_it_names_a_release_channel() {
    let real = fs::read_to_string(root().join("rust-toolchain.toml")).unwrap();
    let green: [(&str, Vec<(&str, &str)>); 2] = [
        ("shipped", vec![("mod/rust-toolchain.toml", &real)]),
        (
            "multiline_components",
            vec![(
                "mod/rust-toolchain.toml",
                "[toolchain]\nchannel = \"nightly-2026-01-02\"\ncomponents = [\n  \"clippy\",\n  \"rustfmt\"\n]\n",
            )],
        ),
    ];
    for (name, files) in green {
        let found = toolchain_case(name, &files);
        assert!(found.is_empty(), "{name}: refused {found:?}");
    }
    let good = "[toolchain]\nchannel = \"1.99.1\"\n";
    let with = |channel: &str| format!("[toolchain]\nchannel = \"{channel}\"\n");
    type RedCase<'a> = (&'a str, Vec<(&'a str, String)>, &'a str);
    let red: Vec<RedCase> = vec![
        (
            "legacy_root",
            vec![("mod/rust-toolchain", "stable\n".into())],
            "mod/rust-toolchain",
        ),
        (
            "legacy_path",
            vec![("mod/rust-toolchain", "/opt/custom\n".into())],
            "mod/rust-toolchain",
        ),
        (
            "legacy_parent",
            vec![("rust-toolchain", "stable\n".into())],
            "rust-toolchain",
        ),
        (
            "legacy_beside_toml",
            vec![
                ("mod/rust-toolchain", "stable\n".into()),
                ("mod/rust-toolchain.toml", good.into()),
            ],
            "mod/rust-toolchain",
        ),
        (
            "toml_in_subdir",
            vec![
                ("mod/rust-toolchain.toml", good.into()),
                ("mod/crates/domain/rust-toolchain.toml", good.into()),
            ],
            "crates/domain/rust-toolchain.toml",
        ),
        (
            "toml_in_parent",
            vec![
                ("mod/rust-toolchain.toml", good.into()),
                ("rust-toolchain.toml", good.into()),
            ],
            "rust-toolchain.toml",
        ),
        (
            "path_key",
            vec![("mod/rust-toolchain.toml", format!("{good}path = \"x\"\n"))],
            "path",
        ),
        (
            "channel_dot_slash",
            vec![("mod/rust-toolchain.toml", with("./tc"))],
            "channel",
        ),
        (
            "channel_absolute",
            vec![("mod/rust-toolchain.toml", with("/abs"))],
            "channel",
        ),
        (
            "channel_tilde",
            vec![("mod/rust-toolchain.toml", with("~/x"))],
            "channel",
        ),
        (
            "channel_dotdot",
            vec![("mod/rust-toolchain.toml", with("stable/../x"))],
            "channel",
        ),
        (
            "channel_backslash",
            vec![("mod/rust-toolchain.toml", with("stable\\\\x"))],
            "channel",
        ),
        (
            "bare_line",
            vec![("mod/rust-toolchain.toml", format!("{good}./tc\n"))],
            "./tc",
        ),
        (
            "other_table",
            vec![("mod/rust-toolchain.toml", format!("{good}[other]\n"))],
            "[other]",
        ),
        (
            "no_channel",
            vec![(
                "mod/rust-toolchain.toml",
                "[toolchain]\nprofile = \"minimal\"\n".into(),
            )],
            "channel",
        ),
        (
            "bare_line_in_array",
            vec![(
                "mod/rust-toolchain.toml",
                format!("{good}components = [\n  ./tc\n]\n"),
            )],
            "./tc",
        ),
    ];
    for (name, files, names) in red {
        let files: Vec<(&str, &str)> = files.iter().map(|(p, c)| (*p, c.as_str())).collect();
        let found = toolchain_case(name, &files);
        assert!(!found.is_empty(), "{name}: accepted");
        assert!(
            found.iter().any(|f| f.contains(names)),
            "{name}: the finding must name `{names}`: {found:?}"
        );
    }
}
