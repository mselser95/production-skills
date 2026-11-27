//! Zone boundary test. DECISION: one Cargo package with four modules and a
//! source-level check, not four crates. Crates would make the compiler enforce
//! the direction, but at the price of a workspace, four manifests and a slower
//! cold build for a scaffold this size; a crate split is the upgrade path when
//! a zone outgrows a module. To keep the check honest it parses `use` trees
//! (grouped imports included) AND scans for fully-qualified paths and for
//! forbidden tokens, so `std::{fs}` and `std::time::Instant::now()` both fail.
//!
//! Direction: adapter -> app -> domain; platform -> app -> domain.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
use std::fs;
use std::path::{Path, PathBuf};

/// (first segment, second segment or "*") pairs a zone may import.
struct Zone {
    dir: &'static str,
    allow: &'static [(&'static str, &'static str)],
    /// Tokens that must not appear anywhere in the zone's code.
    banned: &'static [&'static str],
}

const ZONES: &[Zone] = &[
    Zone {
        dir: "domain",
        allow: &[
            ("std", "collections"),
            ("std", "fmt"),
            ("std", "error"),
            ("std", "cmp"),
            ("core", "*"),
            ("self", "*"),
            ("super", "*"),
            ("crate", "domain"),
        ],
        banned: &[
            "std::fs",
            "std::net",
            "std::io",
            "std::env",
            "std::process",
            "std::thread",
            "std::time",
            "std::sync",
            "SystemTime",
            "Instant",
            "tokio",
            "async ",
            ".await",
            "rand::",
            "f32",
            "f64",
            "crate::app",
            "crate::adapter",
            "crate::platform",
        ],
    },
    Zone {
        dir: "app",
        allow: &[
            ("std", "collections"),
            ("std", "fmt"),
            ("std", "error"),
            ("std", "cmp"),
            ("std", "sync"),
            ("core", "*"),
            ("self", "*"),
            ("super", "*"),
            ("crate", "domain"),
            ("crate", "app"),
        ],
        banned: &[
            "std::fs",
            "std::net",
            "std::io",
            "std::env",
            "std::process",
            "std::thread",
            "std::time",
            "SystemTime",
            "Instant",
            "tokio",
            "async ",
            ".await",
            "rand::",
            "f32",
            "f64",
            "crate::adapter",
            "crate::platform",
        ],
    },
    Zone {
        dir: "adapter",
        allow: &[
            ("std", "*"),
            ("core", "*"),
            ("self", "*"),
            ("super", "*"),
            ("crate", "domain"),
            ("crate", "app"),
            ("crate", "adapter"),
        ],
        banned: &["crate::platform", "std::env", "f32", "f64"],
    },
    Zone {
        dir: "platform",
        allow: &[
            ("std", "*"),
            ("core", "*"),
            ("self", "*"),
            ("super", "*"),
            ("ctrlc", "*"),
            ("crate", "app"),
            ("crate", "platform"),
        ],
        banned: &["crate::adapter", "crate::domain", "f32", "f64"],
    },
];

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let mut entries: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    entries.sort();
    for p in entries {
        if p.is_dir() {
            rust_files(&p, out);
        } else if p.extension().is_some_and(|e| e == "rs") {
            out.push(p);
        }
    }
}

/// Drops `//` comments and string/char literal contents so prose and
/// messages cannot trip (or hide) a check.
fn code_only(src: &str) -> String {
    let mut out = String::with_capacity(src.len());
    let mut chars = src.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '/' if chars.peek() == Some(&'/') => {
                for n in chars.by_ref() {
                    if n == '\n' {
                        out.push('\n');
                        break;
                    }
                }
            }
            '"' => {
                out.push('"');
                while let Some(n) = chars.next() {
                    if n == '\\' {
                        chars.next();
                    } else if n == '"' {
                        break;
                    }
                }
                out.push('"');
            }
            c => out.push(c),
        }
    }
    out
}

/// Expands `a::{b, c::{d, e}}` into full paths.
fn expand(prefix: &str, tree: &str, out: &mut Vec<String>) {
    let tree = tree.trim();
    match tree.find('{') {
        None => out.push(format!("{prefix}{tree}")),
        Some(open) => {
            let head = format!("{prefix}{}", &tree[..open]);
            let inner = &tree[open + 1..tree.rfind('}').unwrap()];
            let (mut depth, mut start) = (0usize, 0usize);
            let mut parts = Vec::new();
            for (i, ch) in inner.char_indices() {
                match ch {
                    '{' => depth += 1,
                    '}' => depth -= 1,
                    ',' if depth == 0 => {
                        parts.push(&inner[start..i]);
                        start = i + 1;
                    }
                    _ => {}
                }
            }
            parts.push(&inner[start..]);
            for p in parts.into_iter().filter(|p| !p.trim().is_empty()) {
                expand(&head, p, out);
            }
        }
    }
}

fn use_paths(code: &str) -> Vec<String> {
    let mut paths = Vec::new();
    for stmt in code.split(';') {
        let s = stmt.trim_start();
        let s = s.strip_prefix("pub ").unwrap_or(s);
        let s = s.strip_prefix("pub(crate) ").unwrap_or(s);
        if let Some(rest) = s.strip_prefix("use ") {
            let flat: String = rest.split_whitespace().collect::<Vec<_>>().join("");
            expand("", &flat, &mut paths);
        }
    }
    paths
}

fn allowed(allow: &[(&str, &str)], path: &str) -> bool {
    let mut segs = path.split("::");
    let first = segs.next().unwrap_or("");
    let second = segs.next().unwrap_or("*");
    allow
        .iter()
        .any(|(a, b)| *a == first && (*b == "*" || *b == second))
}

/// Violations of one zone's rules in one source text.
fn violations(zone: &Zone, code: &str) -> Vec<String> {
    let mut v = Vec::new();
    for p in use_paths(code) {
        if !allowed(zone.allow, &p) {
            v.push(format!("use {p}"));
        }
    }
    for t in zone.banned {
        if code.contains(t) {
            v.push(format!("token {t:?}"));
        }
    }
    v
}

fn check_zone(zone: &Zone) -> Vec<String> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("src")
        .join(zone.dir);
    let mut files = Vec::new();
    rust_files(&root, &mut files);
    assert!(!files.is_empty(), "zone {} has no sources", zone.dir);
    let mut out = Vec::new();
    for f in files {
        let code = code_only(&fs::read_to_string(&f).unwrap());
        for v in violations(zone, &code) {
            out.push(format!("{}: {v}", f.display()));
        }
    }
    out
}

#[test]
fn every_zone_imports_only_what_its_direction_allows() {
    let all: Vec<String> = ZONES.iter().flat_map(check_zone).collect();
    assert!(
        all.is_empty(),
        "zone boundary violations:\n  {}",
        all.join("\n  ")
    );
}

#[test]
fn the_checker_itself_flags_what_it_claims_to() {
    let domain = &ZONES[0];
    let bad = [
        "use std::time::Instant;",
        "use std::{fs, collections::BTreeSet};",
        "use crate::adapter::http::Server;",
        "use rand::Rng;",
        "fn f() { let _ = std::env::var(\"X\"); }",
        "fn f(x: f64) {}",
    ];
    for src in bad {
        assert!(!violations(domain, src).is_empty(), "not flagged: {src}");
    }
    let good =
        "use std::collections::BTreeSet;\nuse std::{fmt, error::Error};\nuse crate::domain::State;";
    assert!(violations(domain, good).is_empty());
}

#[test]
fn only_the_config_module_reads_the_environment() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    rust_files(&root, &mut files);
    let offenders: Vec<_> = files
        .iter()
        .filter(|f| !f.ends_with("platform/config.rs"))
        .filter(|f| {
            let c = code_only(&fs::read_to_string(f).unwrap());
            c.contains("std::env") || c.contains("env::var") || c.contains("env::args")
        })
        .collect();
    assert!(
        offenders.is_empty(),
        "env read outside platform/config.rs: {offenders:?}"
    );
}

#[test]
fn no_unsafe_and_no_unwrap_in_non_test_code() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    rust_files(&root, &mut files);
    for f in files {
        let text = fs::read_to_string(&f).unwrap();
        let code = code_only(text.split("#[cfg(test)]").next().unwrap_or(""));
        for bad in ["unsafe ", ".unwrap()", ".expect("] {
            assert_eq!(code.matches(bad).count(), 0, "{}: {bad}", f.display());
        }
        if f.ends_with("lib.rs") || f.ends_with("main.rs") {
            assert!(
                code.contains("#![forbid(unsafe_code)]"),
                "{}: missing forbid",
                f.display()
            );
        }
    }
}
