//! What the Cargo workspace cannot express by itself.
//!
//! Enforced by the COMPILER, not here: `domain` and `app` are `#![no_std]`
//! (no file, socket, clock, environment or thread to reach) and name only the
//! crates their `Cargo.toml` lists. This file pins those lists (a changed
//! dependency list is a RED test), pins that `extern crate std` cannot sneak
//! `std` back in, and holds the two rules that are test-enforced and weaker:
//! only `config.rs` reads the environment, and the bearer token is compared
//! through the constant-time helper (both are source scans).
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

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

// ---- a minimal JSON reader, enough for `cargo metadata` (no dependency) ----

#[derive(Debug)]
enum Json {
    Obj(Vec<(String, Json)>),
    Arr(Vec<Json>),
    Str(String),
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

/// package -> sorted dependency names (normal + dev + build), straight from
/// Cargo's own view of the workspace.
fn dependency_graph() -> BTreeMap<String, Vec<String>> {
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_owned());
    let out = Command::new(cargo)
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
    let json = P(&out.stdout, 0).value();
    let Json::Arr(packages) = field(&json, "packages") else {
        panic!("no packages")
    };
    packages
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

// ---- source scans ----

/// Source without comments and without any whitespace, so `std :: fs` and
/// `std::fs` look the same.
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
fn domain_and_app_are_no_std_and_cannot_link_std_back_in() {
    for krate in ["crates/domain", "crates/app"] {
        let lib = fs::read_to_string(root().join(krate).join("src/lib.rs")).unwrap();
        let lines: Vec<&str> = lib.lines().map(str::trim).collect();
        assert!(lines.contains(&"#![no_std]"), "{krate}: #![no_std] missing");
        assert!(
            lines.contains(&"#![forbid(unsafe_code)]"),
            "{krate}: forbid(unsafe_code) missing"
        );
        for f in src_files(krate) {
            let s = squash(&fs::read_to_string(&f).unwrap());
            // The one allowed `extern crate` is `alloc`; `extern crate std
            // as s;` would link std back in and defeat no_std.
            assert_eq!(
                s.matches("externcrate").count(),
                s.matches("externcratealloc;").count(),
                "{}: an `extern crate` other than alloc",
                f.display()
            );
            // `#[path]` can only point at files of this same crate, which is
            // itself no_std, but it is how code gets smuggled between zones.
            assert!(!s.contains("#[path"), "{}: #[path]", f.display());
            assert!(!s.contains("#[macro_use"), "{}: #[macro_use]", f.display());
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
