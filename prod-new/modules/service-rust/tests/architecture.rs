//! What the Cargo workspace cannot express by itself.
//!
//! Zone purity: `domain` and `app` can reach no file, socket, clock, thread or
//! environment. Four layers, each tested, because code behind a `cfg` is never
//! built on the bare-metal target and so never seen by the compiler there:
//!
//! 1. The compiler, on a target with no `std` (`make check-nostd`, with
//!    `--all-features`): builds exactly what is NOT conditionally compiled.
//! 2. L1 (here): the list of source files the COMPILER read in the HOST build
//!    of the workspace (rustc's dep-info, which names every file including
//!    `#[path]` modules and `include!`d files) must all sit inside the crate's
//!    own `src/`.
//! 3. L2 (here): none of those files may contain the word `cfg` (except a line
//!    that is exactly `#[cfg(test)]`), nor `include!`-family macros.
//! 4. L3 (here): `domain` and `app` declare no features and no optional
//!    dependency, and nothing in the workspace enables a feature on them or
//!    turns their default features off.
//!
//! Why L2 refuses a word instead of parsing: without proc macros and build
//! scripts (both refused below) the identifier `cfg` cannot be synthesised by
//! `macro_rules!`, so a source with no `cfg` token has no conditional
//! compilation; and `#[cfg(test)]` code exists only in test builds. A comment
//! that mentions the word is refused too (no comment stripping, on purpose).
//!
//! The Makefile is pinned by one exact line, so the gate cannot be disabled
//! unnoticed (a `-` prefix, `|| true`, `.IGNORE`, a second recipe line). The
//! two remaining rules are source scans and WEAKER: only `config.rs` reads the
//! environment, and the bearer token is compared through the constant-time
//! helper.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
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

/// The bare-metal target `domain` and `app` are compiled for. It has no `std`.
const NOSTD_TARGET: &str = "thumbv7em-none-eabi";

/// The ONE recipe line of `check-nostd`, byte for byte: a tab, the command, no
/// `-`, `@-` or `+` prefix, nothing appended (`|| true`, `; true`, a
/// continuation). Reading Makefile text is acceptable for one exact line; this
/// is not a Makefile grammar.
const CHECK_NOSTD_LINE: &str = "\t$(CARGO) check --locked --lib -p svc-domain -p svc-app --all-features --target thumbv7em-none-eabi";

/// What is wrong with the Makefile's wiring of the no-std check, as messages.
fn makefile_violations(mk: &str) -> Vec<String> {
    let mut bad = Vec::new();
    let lines: Vec<&str> = mk.lines().collect();
    // Target definition lines: a column-0 line `names: prerequisites`.
    let defs = |name: &str| -> Vec<(usize, &str)> {
        lines
            .iter()
            .enumerate()
            .filter(|(_, l)| !l.starts_with([' ', '\t', '#']))
            .filter_map(|(i, l)| l.split_once(':').map(|(h, r)| (i, h, r)))
            .filter(|(_, h, _)| h.split_whitespace().any(|t| t == name))
            .map(|(i, _, r)| (i, r))
            .collect()
    };
    let nostd = defs("check-nostd");
    if nostd.len() != 1 {
        bad.push(format!(
            "`check-nostd` must be defined exactly once, found {}",
            nostd.len()
        ));
    }
    if let Some(&(at, rest)) = nostd.first() {
        if !rest.trim().is_empty() {
            bad.push(format!(
                "`check-nostd` takes no prerequisites and no `;` or `::` recipe: {rest:?}"
            ));
        }
        // The recipe: until the next column-0 line that is not blank or a comment.
        let recipe: Vec<&str> = lines[at + 1..]
            .iter()
            .copied()
            .take_while(|l| l.trim().is_empty() || l.starts_with(['\t', '#']))
            .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
            .collect();
        if recipe != [CHECK_NOSTD_LINE] {
            bad.push(format!(
                "the recipe of `check-nostd` must be exactly one line, byte-equal to {CHECK_NOSTD_LINE:?}; found {recipe:?}"
            ));
        }
    }
    let prereqs = |name: &str| -> Vec<String> {
        defs(name)
            .iter()
            .flat_map(|(_, r)| r.split_whitespace().map(str::to_owned).collect::<Vec<_>>())
            .collect()
    };
    if defs("check-fast").len() != 1 || !prereqs("check-fast").iter().any(|t| t == "check-nostd") {
        bad.push("`check-fast` must be defined once with `check-nostd` as a prerequisite".into());
    }
    if defs("verify").len() != 1 || !prereqs("verify").iter().any(|t| t == "check-fast") {
        bad.push("`verify` must be defined once with `check-fast` as a prerequisite".into());
    }
    let phony: Vec<&str> = lines
        .iter()
        .filter_map(|l| l.strip_prefix(".PHONY:"))
        .flat_map(str::split_whitespace)
        .collect();
    if !phony.contains(&"check-nostd") {
        bad.push("`check-nostd` must be listed in .PHONY".into());
    }
    // Things that turn a failing recipe into a pass, or swap the command.
    let cargo_defs: Vec<&&str> = lines
        .iter()
        .filter(|l| {
            let t = l
                .trim_start()
                .trim_start_matches("export ")
                .trim_start_matches("override ");
            t.strip_prefix("CARGO").is_some_and(|r| {
                let r = r.trim_start();
                ["=", "?=", ":=", "::=", "+=", "!="]
                    .iter()
                    .any(|op| r.starts_with(op))
            })
        })
        .collect();
    if cargo_defs != [&"CARGO ?= cargo"] {
        bad.push(format!(
            "`CARGO ?= cargo` must be the only CARGO assignment: {cargo_defs:?}"
        ));
    }
    for l in &lines {
        let t = l.trim_start();
        for banned in [
            ".IGNORE",
            ".SILENT",
            ".ONESHELL",
            ".SHELLFLAGS",
            "SHELL",
            "MAKEFLAGS",
            "export MAKEFLAGS",
            "override MAKEFLAGS",
            "include ",
            "-include ",
            "sinclude ",
        ] {
            if !l.starts_with('\t') && t.starts_with(banned) {
                bad.push(format!("refused Makefile line (`{banned}`): {l:?}"));
            }
        }
    }
    bad
}

#[test]
fn the_no_std_target_check_is_wired_into_the_gate_and_the_toolchain() {
    let mk = fs::read_to_string(root().join("Makefile")).unwrap();
    assert_eq!(makefile_violations(&mk), Vec::<String>::new());
    assert!(
        NOSTD_TARGET.contains("-none"),
        "a target with an OS has std"
    );
    assert!(CHECK_NOSTD_LINE.ends_with(&format!("--target {NOSTD_TARGET}")));
    let tc = fs::read_to_string(root().join("rust-toolchain.toml")).unwrap();
    assert!(
        squash(&tc).contains(&format!("targets=[\"{NOSTD_TARGET}\"")),
        "rust-toolchain.toml must install {NOSTD_TARGET}"
    );
}

#[test]
fn makefile_pin_refuses_every_way_to_ignore_the_nostd_compile() {
    let mk = fs::read_to_string(root().join("Makefile")).unwrap();
    let canon = format!("{CHECK_NOSTD_LINE}\n");
    assert!(
        mk.contains(&canon),
        "the pinned line is not in the Makefile"
    );
    let with = |to: &str| mk.replacen(&canon, to, 1);
    let cases = [
        ("a - prefix", with(&canon.replace("\t$", "\t-$"))),
        ("a @- prefix", with(&canon.replace("\t$", "\t@-$"))),
        ("a + prefix", with(&canon.replace("\t$", "\t+$"))),
        ("|| true", with(&canon.replace('\n', " || true\n"))),
        ("; true", with(&canon.replace('\n', " ; true\n"))),
        ("a second line", with(&format!("{canon}\ttrue\n"))),
        (
            "a blank then a second line",
            with(&format!("{canon}\n\ttrue\n")),
        ),
        (
            "--all-features dropped",
            with(&canon.replace(" --all-features", "")),
        ),
        ("a package dropped", with(&canon.replace(" -p svc-app", ""))),
        (
            "a continuation",
            with(&canon.replace('\n', " \\\n\t|| true\n")),
        ),
        ("a .IGNORE line", format!("{mk}\n.IGNORE: check-nostd\n")),
        ("a .IGNORE line, no target", format!("{mk}\n.IGNORE:\n")),
        ("MAKEFLAGS -k", format!("MAKEFLAGS += -k\n{mk}")),
        ("MAKEFLAGS ik", format!("MAKEFLAGS = ik\n{mk}")),
        ("SHELL replaced", format!("SHELL = /usr/bin/true\n{mk}")),
        ("CARGO replaced", format!("{mk}\nCARGO = true\n")),
        ("an include", format!("-include local.mk\n{mk}")),
        ("check-nostd twice", format!("{mk}\ncheck-nostd:\n\ttrue\n")),
        (
            "check-nostd with a prerequisite",
            mk.replacen("check-nostd:\n", "check-nostd: fmt\n", 1),
        ),
        (
            "check-nostd not in check-fast",
            mk.replacen("check-fast: check-nostd", "check-fast:", 1),
        ),
        (
            "check-nostd not phony",
            mk.replacen(" check-nostd ", " ", 1),
        ),
        (
            "verify without check-fast",
            mk.replacen("verify: check-fast", "verify:", 1),
        ),
    ];
    for (what, text) in cases {
        assert_ne!(text, mk, "{what}: the probe did not change the Makefile");
        assert!(
            !makefile_violations(&text).is_empty(),
            "{what}: accepted\n{text}"
        );
    }
    // Comments and blank lines around the recipe are fine.
    assert!(makefile_violations(&format!("{mk}\n# a comment\n")).is_empty());
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
            // Only a hint; `make check-nostd` is what refuses std.
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
/// `adapter` switches on in `app` is in effect here. Run ONCE per test binary.
///
/// Why this way: the compiler's own artifact message names the unit's output
/// file (`lib<crate>-<hash>.rmeta`), and rustc writes `<crate>-<hash>.d` next
/// to it, so no hash is guessed and no glob can pick a stale file. The unit
/// is the one the build actually produced, with the features it actually had.
fn host_build() -> &'static BTreeMap<String, HostUnit> {
    static BUILD: OnceLock<BTreeMap<String, HostUnit>> = OnceLock::new();
    BUILD.get_or_init(|| {
        let out = Command::new(cargo())
            .args([
                "check",
                "--locked",
                "--offline",
                "--workspace",
                "--lib",
                "--message-format=json",
            ])
            .current_dir(root())
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
            let sources = dep_info_paths(&raw, &root())
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
        assert_eq!(units.len(), 2, "the build did not report domain and app");
        units
    })
}

const PURE_CRATES: [(&str, &str, &str); 2] = [
    ("svc_domain", "svc-domain", "crates/domain"),
    ("svc_app", "svc-app", "crates/app"),
];

/// Files that are not inside `src` (both canonical).
fn outside<'a>(files: &'a [PathBuf], src: &Path) -> Vec<&'a PathBuf> {
    files.iter().filter(|f| !f.starts_with(src)).collect()
}

#[test]
fn l1_the_compiler_read_only_files_inside_the_src_of_domain_and_app() {
    for (lib, _, dir) in PURE_CRATES {
        let unit = &host_build()[lib];
        let src = fs::canonicalize(root().join(dir).join("src")).unwrap();
        assert!(
            unit.sources.iter().any(|f| f.ends_with("src/lib.rs")),
            "{lib}: the dep-info does not list lib.rs: {:?}",
            unit.sources
        );
        let bad = outside(&unit.sources, &src);
        assert!(
            bad.is_empty(),
            "{lib}: the compiler read files outside {}: a `#[path]` or `include!` reaches out of `src`: {bad:?}",
            src.display()
        );
    }
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

#[test]
fn l2_no_conditional_compilation_and_no_file_inclusion_in_the_files_the_compiler_read() {
    let mut bad = Vec::new();
    for (lib, _, _) in PURE_CRATES {
        for f in &host_build()[lib].sources {
            let src = fs::read_to_string(f).unwrap();
            bad.extend(conditional_compilation_violations(
                &f.display().to_string(),
                &src,
            ));
        }
    }
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
